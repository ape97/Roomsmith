import AppKit
import RealityKit
import RoomsmithCore
import SwiftUI

/// Camera modes offered by the picker. `aerial` is the orbit camera tilted to a bird's-eye angle and fitted to the level.
enum SceneViewMode: String, CaseIterable, Identifiable {
    case orbit, free, top, aerial, firstPerson
    var id: String { rawValue }
    var title: String {
        switch self {
        case .orbit: "Orbit"
        case .free: "Free"
        case .firstPerson: "First person"
        case .top: "Top"
        case .aerial: "Aerial"
        }
    }
    /// Icon of the compact picker, used when the 3D column is too narrow for the titles.
    var symbol: String {
        switch self {
        case .orbit: "rotate.3d"
        case .free: "arrow.up.and.down.and.arrow.left.and.right"
        case .firstPerson: "figure.walk"
        case .top: "square.grid.2x2"
        case .aerial: "binoculars"
        }
    }
    var help: String {
        switch self {
        case .orbit: "Orbit: drag to turn around the point looked at, ⇧ drag or right drag to pan, scroll or pinch to zoom"
        case .free: "Free camera: drag to look, ⇧ drag or right drag to slide, W A S D fly, Q E down/up, ⇧ faster, ⌥ slower"
        case .top: "Top: drag to pan, scroll or pinch to zoom"
        case .aerial: "Aerial: bird's-eye view of the whole level"
        case .firstPerson: "First person: W A S D walk, hold Space to walk through walls and furniture, drag to look, click to capture the mouse, Esc to release"
        }
    }
}

/// UI state of one 3D view (not part of the document).
@MainActor
@Observable
final class SceneUIState {
    var viewMode: SceneViewMode = .orbit
    var hud: String?
    /// Walk mode readout (eye height, speed, field of view, scale); nil outside first person.
    var walk: WalkHUDInfo?
    @ObservationIgnored weak var renderer: SceneRenderer?
}

/// Live 3D view: the scene renders the document, mouse and trackpad edit it through the command engine.
///
/// View settings (ceilings, only the active level, wall opacity) live in `AppModel` (remembered per user, not in the
/// document) so the agent view tools can change them too.
struct SceneView: View {
    @Environment(AppModel.self) private var model
    @State private var summary = SceneSummaryCache()
    @State private var ui = SceneUIState()
    @State private var showDisplay = false
    @State private var showLight = false
    @State private var showWalk = false
    /// Slider value; read from the live camera when the popover opens (the rig itself is not observable).
    @State private var fov = 60.0

    private var options: SceneOptions {
        SceneOptions(showCeilings: model.showCeilings, onlyActiveLevel: model.onlyActiveLevel, wallOpacity: model.wallOpacity,
                     showLamps: model.showLamps)
    }

    var body: some View {
        // The controls are an `.overlay`, so their minimum width never raises the minimum
        // size of the split-view detail (that made the window re-run constraints forever).
        SceneCanvas(model: model, ui: ui, options: options)
            .frame(minWidth: 0, minHeight: 0)
            .overlay { overlay }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(summary.text(model.project, revision: model.store.contentRevision, levelId: model.activeLevel?.id ?? model.activeLevelId,
                                         selected: model.selection.count, view: "3D view"))
        .accessibilityIdentifier("sceneView")
    }

    /// Camera mode switch. A hand-built segmented control: the system segmented
    /// `Picker` makes the split-view detail renegotiate its minimum size forever
    /// (window "Update Constraints" crash) when hosted in this layout.
    private func modePicker(compact: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(SceneViewMode.allCases) { mode in
                Button {
                    ui.renderer?.setViewMode(mode)
                } label: {
                    Group {
                        if compact {
                            Image(systemName: mode.symbol)
                                .accessibilityLabel(mode.title)
                        } else {
                            Text(mode.title)
                        }
                    }
                        .font(.callout)
                        .lineLimit(1)
                        .padding(.horizontal, compact ? 8 : 10)
                        .padding(.vertical, 3)
                        .background(
                            ui.viewMode == mode ? Color.accentColor : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(ui.viewMode == mode ? Color.white : Color.primary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(mode.help)
                .accessibilityIdentifier("sceneView.mode.\(mode.rawValue)")
                .accessibilityAddTraits(ui.viewMode == mode ? .isSelected : [])
            }
        }
    }

    private var overlay: some View {
        VStack {
            // View > 3D Controls (AppModel.showSceneControls) hides the floating bars; the HUD stays.
            if model.showSceneControls { controls }
            Spacer()
            if let w = ui.walk, ui.viewMode == .firstPerson { walkHud(w) }
            if let hud = ui.hud {
                Text(hud)
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .glassPanel(in: Capsule())
                    .accessibilityIdentifier("sceneView.hud")
            }
        }
        .padding(12)
    }

    /// Full titles when the column is wide enough, otherwise the icon variant of the mode switch.
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            controlsRow(compact: false)
            controlsRow(compact: true)
            // Narrow pane: the tool buttons drop under the mode switch instead of running out of the pane (their
            // popovers would anchor to a clipped button).
            controlsRow(compact: true, stacked: true)
        }
    }

    private func controlsRow(compact: Bool, stacked: Bool = false) -> some View {
        GlassGroup {
            let layout = stacked ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 8)) : AnyLayout(HStackLayout(alignment: .top))
            layout {
                modePicker(compact: compact)
                    .padding(4)
                    .glassPanel(in: RoundedRectangle(cornerRadius: 10), interactive: true)
                    .accessibilityIdentifier("sceneView.cameraMode")

                if !stacked { Spacer(minLength: 8) }

                HStack(spacing: 4) {
                    Button { ui.renderer?.frameSelection() } label: {
                        Label("Frame selection", systemImage: "scope")
                    }
                    .help("Frame selection (everything when nothing is selected)")
                    .accessibilityIdentifier("sceneView.frame")
                    Button { ui.renderer?.resetView() } label: {
                        Label("Reset view", systemImage: "arrow.counterclockwise")
                    }
                    .help("Reset view")
                    .accessibilityIdentifier("sceneView.reset")
                    SavedViewsButton(ui: ui)
                    displayMenu
                    lightMenu
                    if ui.viewMode == .firstPerson { walkMenu }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .padding(6)
                .glassPanel(in: RoundedRectangle(cornerRadius: 10), interactive: true)
            }
        }
    }

    /// Walk readout: eye height, speed, field of view mode, optional 1 m reference bar.
    private func walkHud(_ w: WalkHUDInfo) -> some View {
        VStack(spacing: 6) {
            if let pt = w.scalePoints {
                VStack(spacing: 2) {
                    Rectangle().fill(Color.primary).frame(width: CGFloat(pt), height: 3)
                    Text(String(format: "1 m at %.1f m", Double(w.scaleDepthDm) / 10)).font(.caption2.monospacedDigit())
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .glassPanel(in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("sceneView.walk.scale")
            }
            Text(String(format: "Eye %.2f m%@   %.1f m/s   FOV %d° %@", Double(w.eyeMm) / 1000, w.crouching ? " (crouching)" : "",
                        Double(w.speedTenthsMps) / 10, w.fovDeg, w.calibrated ? "calibrated" : "standard")
                 + (w.locked ? "   Esc frees the mouse" : "   click captures the mouse"))
                .font(.system(.callout, design: .monospaced))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .glassPanel(in: Capsule())
                .accessibilityIdentifier("sceneView.walk.hud")
        }
    }

    /// Sun, sky and mood. A popover for the same reason as `displayMenu`.
    private var lightMenu: some View {
        Button { showLight.toggle() } label: {
            Label("Light", systemImage: "sun.max")
        }
        .help("Light: time of day, date, north, mood and shadows")
        .accessibilityIdentifier("sceneView.light")
        .popover(isPresented: $showLight, arrowEdge: .bottom) { LightPanel() }
    }

    private var walkMenu: some View {
        Button { showWalk.toggle() } label: {
            Label("Walk settings", systemImage: "figure.walk")
        }
        .help("Walk settings: eye height, speed, field of view, collision")
        .accessibilityIdentifier("sceneView.walkSettings")
        .popover(isPresented: $showWalk, arrowEdge: .bottom) {
            WalkSettingsPopover(autoScreenHeightMm: ui.renderer?.walk.autoScreenHeightMm)
        }
    }

    /// Display options. A popover instead of a `Menu`: the AppKit-backed `Menu` makes the
    /// split-view detail renegotiate its minimum size forever (window "Update Constraints" crash).
    private var displayMenu: some View {
        @Bindable var model = model
        return Button { showDisplay.toggle() } label: {
            Label("Display", systemImage: "eye")
        }
        .help("Display options")
        .accessibilityIdentifier("sceneView.display")
        .popover(isPresented: $showDisplay, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Ceilings", isOn: $model.showCeilings)
                Toggle("Lamps", isOn: $model.showLamps)
                Toggle("Only active level", isOn: $model.onlyActiveLevel)
                Divider()
                Text("Wall opacity").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach([(1.0, "100 %"), (0.6, "60 %"), (0.3, "30 %")], id: \.0) { value, title in
                        Button(title) { model.wallOpacity = value }
                            .buttonStyle(.bordered)
                            .tint(abs(model.wallOpacity - value) < 0.01 ? Color.accentColor : nil)
                            .accessibilityIdentifier("sceneView.wallOpacity.\(Int(value * 100))")
                    }
                }
                Divider()
                HStack {
                    Text("Field of view").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(fov.rounded()))°").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: $fov, in: 10...120, step: 1) { Text("Field of view") }
                    .labelsHidden()
                    .onChange(of: fov) { _, v in ui.renderer?.camera.setFieldOfView(v) }
                    .disabled(ui.viewMode == .top || ui.viewMode == .firstPerson)
                    .help(ui.viewMode == .top ? "The top view uses a fixed narrow lens"
                          : ui.viewMode == .firstPerson ? "Walk mode takes the field of view from the walk settings" : "Wider shows more of the room")
                    .accessibilityIdentifier("sceneView.fov")
            }
            .padding(14)
            .frame(width: 230)
            .onAppear { fov = ui.renderer?.camera.rig.fov ?? 60 }
        }
    }
}

// MARK: - AppKit bridge

struct SceneCanvas: NSViewRepresentable {
    let model: AppModel
    let ui: SceneUIState
    let options: SceneOptions

    func makeNSView(context: Context) -> SceneARView {
        let renderer = SceneRenderer(model: model, interactive: true)
        renderer.ui = ui
        ui.renderer = renderer
        let view = SceneARView(renderer: renderer)
        renderer.attach(to: view)
        renderer.start()
        renderer.setOptions(options)
        renderer.updateViewMode()
        SceneSnapshot.register(view)
        SceneSnapshot.runEnvHooksIfRequested(model: model)
        return view
    }

    /// Takes whatever the container offers, so the render view never feeds a size back into the split view.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SceneARView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 300)
    }

    func updateNSView(_ view: SceneARView, context: Context) {
        view.renderer.setOptions(options)
    }

    static func dismantleNSView(_ view: SceneARView, coordinator: ()) {
        view.renderer.teardown()
        SceneSnapshot.unregister(view)
    }
}

/// The render view. It only translates `NSEvent`s into calls on `SceneRenderer` (points are in view coordinates,
/// origin bottom left); all behaviour lives in `SceneRenderer+Interaction`.
@MainActor
final class SceneARView: ARView {
    let renderer: SceneRenderer
    /// Carriers for the 3D drop, kept while one drag runs (see `restingField`).
    var dropFieldCache: (revision: Int64, levelId: UUID, showLamps: Bool, field: RestingField)?

    init(renderer: SceneRenderer) {
        self.renderer = renderer
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        setAccessibilityIdentifier("sceneView.canvas")
        setAccessibilityLabel("3D scene")
        renderer.camera.viewSize = bounds.size
        registerDropTypes()
    }

    @MainActor required init(frame frameRect: NSRect) { fatalError("use init(renderer:)") }
    @MainActor required dynamic init?(coder decoder: NSCoder) { fatalError("use init(renderer:)") }

    // MARK: Responder

    /// No size of its own: the SwiftUI container decides, so the hosting split view never re-negotiates minimum sizes.
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resignFirstResponder() -> Bool {
        renderer.releaseInput()
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey), name: NSWindow.didResignKeyNotification, object: window)
    }

    /// A window that is no longer key gets no mouse-exited event, so the hover highlight would stay on.
    @objc private func windowResignedKey(_ note: Notification) {
        renderer.releaseInput()
        renderer.mouseExited()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        renderer.applyAppearance(dark: SceneEnvironment.isDark(effectiveAppearance))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        renderer.viewResized(size: newSize)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas where a.owner === self { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    private func point(_ event: NSEvent) -> SIMD2<Double> {
        let p = convert(event.locationInWindow, from: nil)
        return SIMD2(Double(p.x), Double(p.y))
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        renderer.mouseDown(point: point(event), shift: event.modifierFlags.contains(.shift), option: event.modifierFlags.contains(.option),
                           clickCount: event.clickCount)
        if renderer.showsHandCursor { NSCursor.closedHand.set() }
    }

    override func mouseDragged(with event: NSEvent) {
        renderer.mouseDragged(point: point(event), dx: Double(event.deltaX), dy: Double(event.deltaY),
                              shift: event.modifierFlags.contains(.shift), option: event.modifierFlags.contains(.option))
    }

    override func mouseUp(with event: NSEvent) {
        renderer.mouseUp(point: point(event), shift: event.modifierFlags.contains(.shift))
        window?.invalidateCursorRects(for: self)
        if renderer.showsHandCursor { NSCursor.openHand.set() }
    }

    /// Hand tool (or Space held): open hand over the whole view; a closed hand is set while dragging.
    override func resetCursorRects() {
        if renderer.showsHandCursor { addCursorRect(bounds, cursor: .openHand) }
        else if renderer.showsMeasureCursor { addCursorRect(bounds, cursor: .crosshair) }
        else { super.resetCursorRects() }
    }

    override func rightMouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func rightMouseDragged(with event: NSEvent) { renderer.panDrag(dx: Double(event.deltaX), dy: Double(event.deltaY)) }
    override func rightMouseUp(with event: NSEvent) { renderer.panDragEnded() }
    override func otherMouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func otherMouseDragged(with event: NSEvent) { renderer.panDrag(dx: Double(event.deltaX), dy: Double(event.deltaY)) }
    override func otherMouseUp(with event: NSEvent) { renderer.panDragEnded() }

    override func mouseMoved(with event: NSEvent) {
        if renderer.walk.pointerLocked { renderer.mouseDelta(dx: Double(event.deltaX), dy: Double(event.deltaY)) }
        renderer.mouseMoved(point: point(event))
    }
    override func mouseExited(with event: NSEvent) { renderer.mouseExited() }

    // MARK: Trackpad

    override func scrollWheel(with event: NSEvent) {
        renderer.scrollWheel(point: point(event), dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY),
                             precise: event.hasPreciseScrollingDeltas,
                             shift: event.modifierFlags.contains(.shift), command: event.modifierFlags.contains(.command),
                             phase: event.phase, momentum: event.momentumPhase,
                             directionInverted: event.isDirectionInvertedFromDevice)
    }

    override func magnify(with event: NSEvent) {
        renderer.magnify(point: point(event), magnification: Double(event.magnification), phase: event.phase)
    }

    override func rotate(with event: NSEvent) {
        renderer.rotate(degrees: Double(event.rotation), phase: event.phase)
    }

    override func smartMagnify(with event: NSEvent) { renderer.smartMagnify() }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if !renderer.keyDown(code: event.keyCode, modifiers: event.modifierFlags, isRepeat: event.isARepeat,
                                characters: event.charactersIgnoringModifiers) { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        if !renderer.keyUp(code: event.keyCode) { super.keyUp(with: event) }
    }
}
