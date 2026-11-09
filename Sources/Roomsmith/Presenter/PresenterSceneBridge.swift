import CoreGraphics
import Foundation
import RoomsmithCore

/// Bridges the asynchronous offscreen 3D render (an `OffscreenSceneSession`) to the synchronous
/// `PresenterFrameSource.sceneFrame(size:)`: a task renders the scene when the document or the camera changed and keeps
/// the last image; `sceneFrame` just returns it. `stamp` grows with every new image so the engine re-composes.
///
/// Cost control: the task only runs while the presenter wants a 3D pane (`setWanted`), polls cheaply and starts a
/// render at most `maxFramesPerSecond` times per second, and only when the content key changed (project revision,
/// level, view settings, camera, size). It keeps one `OffscreenSceneSession` while it runs, so a camera move draws a
/// single frame instead of building the scene again (that rebuild made the TV picture lag behind the Mac).
@MainActor
final class PresenterSceneBridge {
    static let maxFramesPerSecond = 15.0

    /// Weak: the model owns the presenter that owns this bridge.
    private weak var model: AppModel?
    private(set) var stamp = 0
    private(set) var image: PresenterImage?
    private var wanted: CGSize?
    private var task: Task<Void, Never>?
    private var lastKey: Int?
    private var lastOpenings: OpeningMotion?
    private var session: OffscreenSceneSession?
    /// Number of finished renders (for status and tests).
    private(set) var renderCount = 0

    init(model: AppModel) { self.model = model }

    /// Starts or stops rendering. `nil` stops (no 3D pane shown or presenter idle).
    func setWanted(_ size: CGSize?) {
        wanted = size
        guard size != nil else {
            task?.cancel(); task = nil
            closeSession()
            // Nobody shows the last picture any more; a full-size frame would stay in memory until the next 3D pane.
            // The stamp still moves so the engine re-composes without it.
            if image != nil { image = nil; stamp &+= 1 }
            return
        }
        guard task == nil else { return }
        lastKey = nil
        lastOpenings = nil
        task = Task { [weak self] in await self?.loop() }
    }

    /// Camera of the live 3D view when one is open, else nil (the render then uses the document camera).
    private func liveCamera() -> CameraState? {
        model.flatMap { SceneSnapshot.liveView(for: $0)?.renderer.camera.rig.state }
    }

    /// Open poses of doors and windows in the live 3D view (nil without one: everything closed).
    private func liveOpenings() -> OpeningMotion? {
        model.flatMap { SceneSnapshot.liveView(for: $0)?.renderer.walk.openings }
    }

    private func key(size: CGSize, camera: CameraState?) -> Int {
        var h = Hasher()
        guard let model else { return 0 }
        let p = model.project
        h.combine(p.id); h.combine(model.store.contentRevision); h.combine(model.activeLevelId)
        h.combine(model.showCeilings); h.combine(model.showLamps); h.combine(model.onlyActiveLevel); h.combine(model.wallOpacity)
        h.combine(Int(size.width)); h.combine(Int(size.height))
        h.combine(camera ?? p.camera)
        return h.finalize()
    }

    private func loop() async {
        let interval = Duration.seconds(1 / Self.maxFramesPerSecond)
        while !Task.isCancelled, model != nil {
            let started = ContinuousClock.now
            if let size = wanted {
                let camera = liveCamera()
                let openings = liveOpenings()
                let k = key(size: size, camera: camera)
                // A door or window moving in the live view changes the picture without touching the document.
                if k != lastKey || openings != lastOpenings {
                    lastKey = k
                    lastOpenings = openings
                    await render(size: size, camera: camera, openings: openings)
                }
            }
            let rest = interval - (ContinuousClock.now - started)
            try? await Task.sleep(for: max(rest, .milliseconds(10)))
        }
    }

    private func closeSession() {
        session?.teardown()
        session = nil
    }

    private func render(size: CGSize, camera: CameraState?, openings: OpeningMotion?) async {
        guard let model else { return }
        let started = ContinuousClock.now
        do {
            let w = Int(size.width.rounded()), h = Int(size.height.rounded())
            if let s = session, s.width != w || s.height != h { closeSession() }
            let current: OffscreenSceneSession
            if let session {
                current = session
            } else {
                current = try await OffscreenSceneSession(model: model, size: size, dark: false)
                guard !Task.isCancelled, wanted != nil else { current.teardown(); return }
                session = current
            }
            let cg = try await current.image(camera: camera, openings: openings)
            guard !Task.isCancelled else { return }
            image = .cgImage(cg)
            renderCount += 1
            stamp &+= 1
            Self.testHook(cg, count: renderCount, ms: (ContinuousClock.now - started).ms)
        } catch {
            guard !Task.isCancelled else { return }
            // Start over with a fresh session next time.
            closeSession()
            model.lastError = "Presenter 3D view: \(userMessage(for: error))"
        }
    }

    /// `ROOMSMITH_PRESENTER_3D=<path>` (test mode only): writes every finished 3D pane picture to `<path>` and prints a
    /// `ROOMSMITH_PRESENTER_3D n=… ms=…` line, since the preview video cannot be drawn into a window picture.
    private static func testHook(_ image: CGImage, count: Int, ms: Double) {
        guard AppDefaults.isTestMode, let path = ProcessInfo.processInfo.environment["ROOMSMITH_PRESENTER_3D"], !path.isEmpty
        else { return }
        try? SceneSnapshot.png(from: image)?.write(to: URL(fileURLWithPath: path))
        PerfLog.line(String(format: "ROOMSMITH_PRESENTER_3D n=%d ms=%.1f", count, ms))
    }
}
