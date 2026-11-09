import SwiftUI

/// Arrangement of plan and 3D when both are shown in the main window.
enum SplitAxis: String, CaseIterable, Identifiable {
    case sideBySide, stacked
    var id: String { rawValue }
    var title: String { self == .sideBySide ? "Side by Side" : "Stacked" }
    var symbol: String { self == .sideBySide ? "rectangle.split.2x1" : "rectangle.split.1x2" }
}

/// `@AppStorage` keys for the editor arrangement (view state only, never part of the document).
enum EditorLayoutKey {
    static let axis = "editorSplitAxis"
    static let detached = "scene3DDetached"
    static let fractionSideBySide = "editorSplitFractionSideBySide"
    static let fractionStacked = "editorSplitFractionStacked"
    static let sceneWindowID = "scene"
}

/// Plan | 3D with a draggable divider, side by side or stacked (plan on top). The fraction is remembered per axis.
/// The divider follows the pointer through a `@GestureState` (no storage writes while dragging) and stores the fraction
/// when the drag ends; a double click resets it to 50 %.
/// Not HSplitView/VSplitView: inside NavigationSplitView + inspector they loop in AppKit's constraint pass and crash.
/// Both editors stay in one ZStack so switching the axis keeps their view state.
struct EditorSplit: View {
    @AppStorage(EditorLayoutKey.axis, store: AppDefaults.store) private var axisRaw = SplitAxis.sideBySide.rawValue
    @AppStorage(EditorLayoutKey.fractionSideBySide, store: AppDefaults.store) private var fractionH = 0.5
    @AppStorage(EditorLayoutKey.fractionStacked, store: AppDefaults.store) private var fractionV = 0.5
    /// Pointer travel (points) of the drag in progress; resets itself when the gesture ends.
    @GestureState private var dragDelta: CGFloat = 0
    @Environment(AppModel.self) private var model

    private var axis: SplitAxis { SplitAxis(rawValue: axisRaw) ?? .sideBySide }
    private var fraction: Double { axis == .sideBySide ? fractionH : fractionV }
    private func setFraction(_ f: Double) { if axis == .sideBySide { fractionH = f } else { fractionV = f } }

    var body: some View {
        GeometryReader { geo in
            let horizontal = axis == .sideBySide
            let full = horizontal ? geo.size.width : geo.size.height
            let total = max(full - 1, 1)
            // Narrow windows (minimum window: detail ~520 pt) get smaller minimum sides so the divider stays movable.
            let minSide = min(total >= 800 ? 300.0 : 220.0, total / 2)
            let lo = minSide / total, hi = 1 - minSide / total
            let stored = min(max(fraction, lo), hi)
            let f = min(max(stored + Double(dragDelta) / total, lo), hi)
            let first = (total * f).rounded()
            let second = max(full - first - 1, 0)
            let cross = horizontal ? geo.size.height : geo.size.width
            ZStack(alignment: .topLeading) {
                PlanView()
                    .id(model.id)
                    .frame(width: horizontal ? first : cross, height: horizontal ? cross : first)
                    .clipped()
                SceneView()
                    .id(model.id)
                    .frame(width: horizontal ? second : cross, height: horizontal ? cross : second)
                    .clipped()
                    .offset(x: horizontal ? first + 1 : 0, y: horizontal ? 0 : first + 1)
                divider(horizontal: horizontal, cross: cross, first: first, total: total, f: f, stored: stored, lo: lo, hi: hi)
            }
        }
    }

    private func divider(horizontal: Bool, cross: CGFloat, first: CGFloat, total: CGFloat,
                         f: Double, stored: Double, lo: Double, hi: Double) -> some View {
        Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.6))
            .frame(width: horizontal ? 1 : cross, height: horizontal ? cross : 1)
            .overlay(
                Color.clear
                    .frame(width: horizontal ? 9 : cross, height: horizontal ? cross : 9)
                    .contentShape(Rectangle())
                    .pointerStyle(horizontal ? .columnResize : .rowResize)
                    .onTapGesture(count: 2) { setFraction(0.5) }
                    // Global space: the divider moves while dragging, a local translation would feed back.
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .updating($dragDelta) { v, state, _ in state = horizontal ? v.translation.width : v.translation.height }
                        .onEnded { v in
                            let delta = horizontal ? v.translation.width : v.translation.height
                            setFraction(min(max(stored + Double(delta) / total, lo), hi))
                        })
            )
            .offset(x: horizontal ? first : 0, y: horizontal ? 0 : first)
            .zIndex(1)
            .accessibilityElement()
            .accessibilityLabel("Plan and 3D divider")
            .accessibilityValue("\(Int((f * 100).rounded())) percent for the plan")
            .accessibilityHint("Double click to reset to 50 percent")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: setFraction(min(f + 0.05, hi))
                case .decrement: setFraction(max(f - 0.05, lo))
                @unknown default: break
                }
            }
    }
}

/// The detached 3D window: normal resizable, full-screen capable window; docks back when closed.
/// Its frame (and so its display) is remembered; quitting with the window open keeps it detached for the next launch.
struct SceneWindowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage(EditorLayoutKey.detached, store: AppDefaults.store) private var detached = false

    var body: some View {
        SceneView()
            .id(model.id)
            .frame(minWidth: 480, minHeight: 360)
            .navigationTitle("\(model.windowTitle) – 3D")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { dismissWindow(id: EditorLayoutKey.sceneWindowID) } label: {
                        Label("Dock 3D View", systemImage: "rectangle.on.rectangle")
                    }
                    .help("Close this window and show 3D next to the plan again")
                }
            }
            .background(WindowFrameMemory(name: AppDefaults.isTestMode ? nil : "Roomsmith3DWindow"))
            .background(EscapeClearsSelection(model: model))
            .onAppear {
                // An agent docked again (or showed 3D in the main window) before this window appeared: close it.
                if model.pendingDetach == false { dismissWindow(id: EditorLayoutKey.sceneWindowID); return }
                detached = true; model.layout = .plan; model.pendingDetach = nil
            }
            .onDisappear {
                let keepPlan = model.keepPlanOnDock
                model.pendingDetach = nil
                model.keepPlanOnDock = false
                // Windows also close when the app quits: that must not forget that 3D was detached.
                guard detached, !AppDefaults.isTerminating else { return }
                detached = false
                // Another layout chosen meanwhile (e.g. Plan + 3D) must not be overridden; neither must an agent's
                // explicit request for the plan only (`view.set {detach3D: false, layout: plan}`).
                if model.layout == .plan, !keepPlan { model.layout = .split }
            }
    }
}

/// Remembers the frame of the hosting window under `name` (AppKit autosave), so the window returns to the same display.
struct WindowFrameMemory: NSViewRepresentable {
    let name: String?

    final class Probe: NSView {
        var name: String?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let name, let window else { return }
            window.setFrameAutosaveName(name)
        }
    }

    func makeNSView(context: Context) -> Probe { let v = Probe(); v.name = name; return v }
    func updateNSView(_ view: Probe, context: Context) {}
}

/// View menu: panels, layout, arrangement and the detached 3D window. Entries that cannot apply are disabled.
struct ViewLayoutCommands: Commands {
    let model: AppModel
    @AppStorage(ViewKey.showSidebar, store: AppDefaults.store) private var showSidebar = true
    @AppStorage(ViewKey.showInspector, store: AppDefaults.store) private var showInspector = true
    @AppStorage(ViewKey.showStatusBar, store: AppDefaults.store) private var showStatusBar = true
    @AppStorage(EditorLayoutKey.axis, store: AppDefaults.store) private var axisRaw = SplitAxis.sideBySide.rawValue
    @AppStorage(EditorLayoutKey.detached, store: AppDefaults.store) private var detached = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some Commands {
        // The system adds Show/Hide Toolbar and Customize Toolbar… to the toolbar group because the toolbar is customizable.
        CommandGroup(after: .toolbar) {
            Divider()
            Button(showSidebar ? "Hide Sidebar" : "Show Sidebar") { showSidebar.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .control])
            Button(showInspector ? "Hide Inspector" : "Show Inspector") { showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button(showStatusBar ? "Hide Status Bar" : "Show Status Bar") { showStatusBar.toggle() }
                .keyboardShortcut("/", modifiers: .command)
            Divider()
            planToggle
            sceneToggle
            Button(model.showSceneControls ? "Hide 3D Controls" : "Show 3D Controls") { model.showSceneControls.toggle() }
                .disabled(model.layout == .plan && !detached)
            Divider()
            layoutToggle("Plan + 3D", .split, key: "1")
            layoutToggle("Plan Only", .plan, key: "2")
            layoutToggle("3D Only", .scene, key: "3")
            Picker("Arrangement", selection: $axisRaw) {
                ForEach(SplitAxis.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .disabled(model.layout != .split)
            Divider()
            if detached {
                Button("Dock 3D View") { dismissWindow(id: EditorLayoutKey.sceneWindowID) }
            } else {
                Button("Open 3D in Separate Window") { openWindow(id: EditorLayoutKey.sceneWindowID) }
                    .keyboardShortcut("3", modifiers: [.command, .option])
            }
            Divider()
            Button("Present…") { model.showPresenter = true }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(model.presenter == nil)
            Button(model.showAgentPanel ? "Hide Agent Panel" : "Show Agent Panel") { model.showAgentPanel.toggle() }
                .keyboardShortcut("a", modifiers: [.command, .option])
            Divider()
        }
    }

    /// Hiding the plan leaves 3D only; it is disabled while the plan is all there is.
    private var planToggle: some View {
        let shown = model.layout != .scene
        return Button(shown ? "Hide Plan" : "Show Plan") { model.layout = shown ? .scene : .split }
            .disabled(model.layout == .plan)
    }

    private var sceneToggle: some View {
        let shown = model.layout != .plan
        return Button(shown ? "Hide 3D View" : "Show 3D View") { model.layout = shown ? .plan : .split }
            .disabled(model.layout == .scene)
    }

    private func layoutToggle(_ title: String, _ layout: ViewLayout, key: KeyEquivalent) -> some View {
        Toggle(title, isOn: Binding(get: { model.layout == layout }, set: { _ in model.layout = layout }))
            .keyboardShortcut(key, modifiers: .command)
    }
}
