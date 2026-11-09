import AVFoundation
import AppKit
import Observation
import RoomsmithCore

/// Runs the presenter: renders the chosen layout, encodes it to HLS, serves it and plays it in an `AVPlayer`
/// that can hand the stream to an Apple TV via AirPlay. Also feeds the live presenter window on an extra display (the primary, real-time path).
///
/// Network rules: nothing listens before `start()`. The server binds to the LAN address only after `start()` and
/// only when test mode is off (`ROOMSMITH_TEST_MODE` is not `1`); otherwise it binds to 127.0.0.1.
@MainActor
@Observable
final class PresenterEngine {
    // MARK: Settings (observable by the panel)
    var layout: PresenterLayout = .plan { didSet { if layout != oldValue { rebuildComposition(); forceRender = true } } }
    var resolution: PresenterResolution = .hd1080 { didSet { if resolution != oldValue { rebuildComposition(); forceRender = true } } }

    // MARK: State
    private(set) var status = PresenterStatus()
    /// Player for the preview and AirPlay; nil while not presenting.
    private(set) var player: AVPlayer?
    /// URL the player uses (LAN host when the server listens on the LAN).
    private(set) var streamURL: URL?
    /// Message about the presenter window (e.g. the display was removed); independent of the stream state.
    private(set) var windowMessage: String?
    var isWindowOpen: Bool { windowController != nil }
    /// Set by the panel while it is visible; with it (or a running stream) a newly connected display gets the live window.
    var presenterModeActive = false {
        didSet { if presenterModeActive, !oldValue { openWindowOnExternalDisplayIfNeeded() } }
    }
    /// Name of the external display the live window would use, nil when there is none (drives the panel hint).
    private(set) var externalDisplayName: String?
    private var knownDisplays: Set<UInt32> = []
    /// Displays whose live window the user closed; no auto-open there until the display is reconnected.
    private var dismissedDisplays: Set<UInt32> = []
    private var windowDisplayID: UInt32?
    @ObservationIgnored nonisolated(unsafe) private var screenObserver: NSObjectProtocol?
    let pointer: PresenterPointer

    // MARK: Parts
    private let source: any PresenterFrameSource
    private let allowLAN: Bool
    private var composition: PresenterComposition
    private var compositor: PresenterCompositor
    private var encoder: HLSEncoder?
    private var store: HLSSegmentStore?
    private var server: HLSServer?
    private var windowController: PresenterWindowController?
    // Cancelled from the nonisolated deinit (Task.cancel is thread-safe).
    @ObservationIgnored nonisolated(unsafe) private var renderTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var monitorTask: Task<Void, Never>?
    private var lastStamp: Int?
    private var forceRender = true
    private var generation = 0

    static let segmentInterval = 0.5
    /// Segments that must exist before the player gets the URL (a player needs about three target durations).
    static let segmentsBeforePlay = 3
    /// Player buffer and live offset in seconds (defaults, not measured).
    static let forwardBuffer = 1.0
    static let liveOffset = 1.0

    init(source: any PresenterFrameSource) {
        self.source = source
        self.pointer = source.pointer ?? PresenterPointer()
        source.pointer = self.pointer
        self.allowLAN = !AppDefaults.isTestMode
        let c = PresenterComposition(layout: .plan, resolution: .hd1080)
        self.composition = c
        self.compositor = PresenterCompositor(composition: c)
        knownDisplays = Set(Self.candidates().map(\.id))
        externalDisplayName = PresenterScreenChoice.choose(Self.candidates(), known: knownDisplays)?.name
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        renderTask?.cancel()
        monitorTask?.cancel()
    }

    // MARK: Live window on an extra display (primary path: real time through the mirroring path)

    private static func candidates() -> [PresenterScreenChoice.Candidate] {
        NSScreen.screens.enumerated().map { i, s in
            let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? UInt32(i)
            return .init(id: id, name: s.localizedName, isMain: i == 0)
        }
    }

    private func screensChanged() {
        let all = Self.candidates()
        let added = PresenterScreenChoice.added(all, known: knownDisplays)
        knownDisplays = Set(all.map(\.id))
        dismissedDisplays.formIntersection(knownDisplays)
        externalDisplayName = PresenterScreenChoice.choose(all, known: knownDisplays)?.name
        if added != nil { openWindowOnExternalDisplayIfNeeded(preferring: added) }
    }

    /// Opens the live window on the best external display when presenter mode is on, no window is open and the
    /// user has not closed the window on that display since it was connected.
    func openWindowOnExternalDisplayIfNeeded(preferring: PresenterScreenChoice.Candidate? = nil) {
        guard (presenterModeActive || isPresenting), windowController == nil else { return }
        let open = Self.candidates().filter { !dismissedDisplays.contains($0.id) }
        guard let pick = preferring.flatMap({ p in open.first { $0.id == p.id } })
                ?? PresenterScreenChoice.choose(open, known: knownDisplays) else { return }
        openLiveWindow(on: pick)
    }

    /// The panel button: the best external display, even if the user closed the window there before.
    func openLiveWindow() {
        guard let pick = PresenterScreenChoice.choose(Self.candidates(), known: knownDisplays) else {
            windowMessage = "No extra display found"
            return
        }
        openLiveWindow(on: pick)
    }

    private func openLiveWindow(on pick: PresenterScreenChoice.Candidate) {
        let all = Self.candidates()
        guard !pick.isMain, let index = all.firstIndex(where: { $0.id == pick.id }),
              NSScreen.screens.indices.contains(index) else { return }
        dismissedDisplays.remove(pick.id)
        openPresenterWindow(on: NSScreen.screens[index])
    }

    /// Position of the mouse in plan millimetres, reported by the main window; nil when it leaves the plan.
    func reportPointer(_ p: P2?) { pointer.report(p) }

    var isPresenting: Bool { status.isActive }

    // MARK: Start / stop (explicit user actions)

    func start() {
        guard status.apply(.startRequested) else { return }
        generation += 1
        let gen = generation
        let size = resolution.size
        let store = HLSSegmentStore(capacity: 8, window: 6, startOffset: -Self.segmentInterval * 2)
        let encoder = HLSEncoder(configuration: .init(width: Int(size.width), height: Int(size.height),
                                                      frameRate: 30, segmentInterval: Self.segmentInterval), store: store)
        let bind: HLSServer.Bind
        var lanHost: String?
        if allowLAN, let lan = PresenterLANAddress.current() {
            bind = .lan(interfaceName: lan.name)
            lanHost = lan.address
        } else {
            bind = .loopback
        }
        let server = HLSServer(bind: bind) { name in store.resource(named: name) }
        server.onFailure = { [weak self] _ in
            Task { @MainActor in self?.fail(.serverStopped, generation: gen) }
        }
        self.store = store
        self.encoder = encoder
        self.server = server
        lastStamp = nil
        forceRender = true

        do {
            try encoder.start(onFailure: { [weak self] message in
                Task { @MainActor in self?.fail(.encoderFailed(message), generation: gen) }
            })
        } catch {
            fail(.encoderFailed(error.localizedDescription), generation: gen)
            return
        }
        startRenderLoop()
        monitorTask = Task { [weak self] in
            do {
                let port = try await server.start()
                guard let self, self.generation == gen else { return }
                let host = lanHost ?? PresenterLANAddress.loopbackHost
                guard let url = PresenterLANAddress.streamURL(host: host, port: port, token: server.token) else {
                    self.fail(.serverFailed("Could not build the stream address"), generation: gen)
                    return
                }
                self.streamURL = url
                await self.monitor(url: url, store: store, generation: gen)
            } catch let error as HLSServer.ServerError {
                self?.fail(error == .localNetworkDenied ? .localNetworkDenied : .serverFailed(error.localizedDescription), generation: gen)
            } catch {
                self?.fail(.serverFailed(error.localizedDescription), generation: gen)
            }
        }
    }

    func stop() {
        guard status.apply(.stopRequested) else { return }
        teardown(final: .stopped)
    }

    /// Final cleanup when the owner goes away (tab closed): stops a running stream like `stop()`, and, whatever the status
    /// is (an idle engine can still own a live window and its render loop), closes the window and ends the render loop.
    func shutdown() {
        stop()
        windowController?.onClose = nil
        closePresenterWindow()
        stopRenderLoop()
    }

    private func fail(_ failure: PresenterFailure, generation gen: Int) {
        guard generation == gen, status.state != .idle else { return }
        status.apply(.failure(failure))
        teardown(final: nil)
    }

    /// Stops everything started by `start()`. `final` is applied to the status once the encoder is down.
    private func teardown(final event: PresenterEvent?) {
        generation += 1
        monitorTask?.cancel(); monitorTask = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        streamURL = nil
        let encoder = self.encoder, server = self.server
        self.encoder = nil; self.server = nil; self.store = nil
        server?.stop()
        if windowController == nil { stopRenderLoop() }
        guard let event else { Task { await encoder?.stop() }; return }
        Task { [weak self] in
            await encoder?.stop()
            self?.status.apply(event)
        }
    }

    // MARK: Monitoring (waits for segments, then watches player and route)

    private func monitor(url: URL, store: HLSSegmentStore, generation gen: Int) async {
        let deadline = Date().addingTimeInterval(20)
        while store.totalAppended < Self.segmentsBeforePlay {
            if Task.isCancelled || generation != gen { return }
            if Date() > deadline {
                fail(.encoderFailed("No video was produced"), generation: gen)
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard generation == gen else { return }
        let item = AVPlayerItem(url: url)
        // Latency tuning (defaults, not measured on a real Apple TV): keep the buffer small and stay near the live edge.
        item.preferredForwardBufferDuration = Self.forwardBuffer
        item.configuredTimeOffsetFromLive = CMTime(seconds: Self.liveOffset, preferredTimescale: 600)
        item.automaticallyPreservesTimeOffsetFromLive = true
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        player.allowsExternalPlayback = true
        player.isMuted = true
        player.play()
        self.player = player
        status.apply(.ready(latencyEstimate: Self.segmentInterval * Double(Self.segmentsBeforePlay)))

        var lastExternal = false
        var tick = 0
        var liveEdge = PresenterLiveEdge()
        while !Task.isCancelled, generation == gen {
            try? await Task.sleep(for: .milliseconds(500))
            guard generation == gen else { return }
            if let error = player.currentItem?.error ?? player.error {
                fail(.playerFailed(error.localizedDescription), generation: gen)
                return
            }
            let external = player.isExternalPlaybackActive
            if external != lastExternal {
                lastExternal = external
                status.apply(.externalPlaybackChanged(active: external, routeName: nil))
            }
            tick += 1
            if tick % 2 == 0, let range = player.currentItem?.seekableTimeRanges.last?.timeRangeValue {
                let behind = CMTimeGetSeconds(range.end) - CMTimeGetSeconds(player.currentTime())
                if behind.isFinite, behind >= 0 {
                    status.apply(.latencyUpdated(behind))
                    let now = ProcessInfo.processInfo.systemUptime
                    if liveEdge.evaluate(behind: behind, now: now) == .seek {
                        let target = CMTime(seconds: CMTimeGetSeconds(range.end) - Self.liveOffset, preferredTimescale: 600)
                        await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                        guard generation == gen else { return }
                        player.play()
                    }
                }
            }
        }
    }

    // MARK: Rendering

    private func rebuildComposition() {
        composition = PresenterComposition(layout: layout, resolution: resolution)
        compositor = PresenterCompositor(composition: composition)
        if renderTask != nil { source.setSceneSize(composition.sourceSize(for: .scene3D)) }
    }

    private func startRenderLoop() {
        guard renderTask == nil else { return }
        source.setSceneSize(composition.sourceSize(for: .scene3D))
        renderTask = Task { [weak self] in
            while !Task.isCancelled {
                // The engine is only held while it renders, not while the loop sleeps; a released engine ends the loop.
                guard let delay = self?.renderStep() else { return }
                try? await Task.sleep(for: delay)
            }
        }
    }

    /// One tick of the render loop; returns how long to wait for the next one. Display rate (about 60 Hz) while the live
    /// window is open, otherwise 20 Hz for the stream only. renderIfNeeded does nothing unless the content changed, so an
    /// idle main view is not starved.
    private func renderStep() -> Duration {
        renderIfNeeded()
        return .milliseconds(windowController != nil ? 16 : 50)
    }

    private func stopRenderLoop() {
        renderTask?.cancel()
        renderTask = nil
        source.setSceneSize(nil)
    }

    private func renderIfNeeded() {
        let stamp = source.contentStamp
        guard forceRender || stamp != lastStamp else { return }
        forceRender = false
        lastStamp = stamp
        // The composition may change between frames; the encoder size is fixed at start, so a resolution change
        // while streaming only takes effect on the next start (the panel disables it while live).
        let plan = composition.sourceSize(for: .plan).flatMap { source.planFrame(size: $0) }
        let scene = composition.sourceSize(for: .scene3D).flatMap { source.sceneFrame(size: $0) }
        guard let buffer = compositor.compose(plan: plan, scene: scene) else {
            // Buffer pool exhausted: render again on the next tick instead of waiting for a content change.
            lastStamp = nil
            forceRender = true
            return
        }
        encoder?.submit(PresenterFrame(buffer))
        if let windowController, let image = PresenterImage.pixelBuffer(buffer).cgImage { windowController.show(image) }
    }

    // MARK: Presenter window (primary: live on an extra display)

    func openPresenterWindow(on screen: NSScreen) {
        // Never cover the Mac's own (first) screen.
        guard let index = NSScreen.screens.firstIndex(of: screen), index > 0 else {
            windowMessage = "The presenter window needs an extra display"
            return
        }
        windowController?.onClose = nil
        closePresenterWindow()
        windowMessage = nil
        let id = Self.candidates()[index].id
        windowDisplayID = id
        let controller = PresenterWindowController(screen: screen)
        controller.onClose = { [weak self] reason in
            guard let self else { return }
            self.windowController = nil
            if let reason { self.windowMessage = reason } else if let id = self.windowDisplayID { self.dismissedDisplays.insert(id) }
            if self.encoder == nil { self.stopRenderLoop() }
        }
        windowController = controller
        forceRender = true
        startRenderLoop()
        controller.present()
    }

    func closePresenterWindow() {
        windowController?.close()
        windowController = nil
        if encoder == nil { stopRenderLoop() }
    }
}
