import AppKit
import SwiftUI
import RoomsmithCore

/// Main window: sidebar (levels, objects, catalog) | plan and/or 3D | inspector, with toolbar and status bar.
/// Sidebar, inspector, status bar and the plan/3D choice can each be hidden (View menu); the choice is remembered.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(Workspace.self) private var workspace
    @AppStorage(ViewKey.showSidebar, store: AppDefaults.store) private var showSidebar = true
    @AppStorage(ViewKey.showInspector, store: AppDefaults.store) private var showInspector = true
    @AppStorage(ViewKey.showStatusBar, store: AppDefaults.store) private var showStatusBar = true
    @AppStorage(EditorLayoutKey.axis, store: AppDefaults.store) private var axisRaw = SplitAxis.sideBySide.rawValue
    @AppStorage(EditorLayoutKey.detached, store: AppDefaults.store) private var detached = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(get: { showSidebar ? .all : .detailOnly }, set: { showSidebar = ($0 != .detailOnly) })
    }

    var body: some View {
        @Bindable var model = model
        @Bindable var workspace = workspace
        NavigationSplitView(columnVisibility: columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
        } detail: {
            VStack(spacing: 0) {
                if workspace.showsTabBar { WorkspaceTabBar() }
                editors
                if showStatusBar {
                    StatusBar()
                        .glassPanel(in: Capsule())
                        .padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
            .inspector(isPresented: $showInspector) {
                InspectorView()
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
            }
        }
        .navigationTitle(model.windowTitle)
        .toolbar(id: "roomsmith.main") { toolbar }
        // Showing 3D in the main window while it is detached would duplicate it: dock first.
        .onChange(of: model.layout) { _, new in
            if detached && new != .plan { dismissWindow(id: EditorLayoutKey.sceneWindowID) }
            fallBackToSelectIfToolUnavailable()
        }
        // A tool the layout cannot use (3D only) gives way to Select, whichever way it was switched on.
        .onChange(of: model.tool) { _, _ in fallBackToSelectIfToolUnavailable() }
        // Agent `view.set detach3D`: the same window actions as the View menu and the toolbar button.
        .onChange(of: model.sceneWindowRequest) { _, request in
            guard let request else { return }
            if request.detach, !detached { openWindow(id: EditorLayoutKey.sceneWindowID) }
            else if !request.detach, detached { dismissWindow(id: EditorLayoutKey.sceneWindowID) }
            else { model.pendingDetach = nil; model.keepPlanOnDock = false }  // already there: nothing pending
        }
        // Reads the cursor in its own tiny view, so mouse moves do not invalidate this body.
        .background(PresenterPointerRelay())
        // Esc clears the selection also when the focus is on the sidebar, the inspector or the toolbar.
        .background(EscapeClearsSelection(model: model))
        // The presenter panel is a sheet of the window, so the menu item and shortcut work even when the toolbar
        // item is removed or the toolbar is hidden. The toolbar button toggles the same flag.
        .sheet(isPresented: $model.showPresenter) {
            if let engine = model.presenter {
                VStack(spacing: 0) {
                    PresenterPanel(engine: engine)
                    Divider()
                    HStack {
                        Spacer()
                        Button("Done") { model.showPresenter = false }
                            // Esc closes; Return stays with the panel's own default button (Start).
                            .keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier("presenterDoneButton")
                    }
                    .padding(10)
                }
            }
        }
        .sheet(isPresented: $workspace.showComparisonSheet) { ComparisonSheet() }
        .onChange(of: model.id) { _, _ in ensurePresenter() }
        .sheet(isPresented: $model.showAgentPanel) { AgentPanel().frame(minWidth: 560, minHeight: 420) }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .furnitureBuilder(let id): FurnitureBuilderView(definitionId: id).frame(minWidth: 780, minHeight: 480)
            case .reports: ReportsSheet()
            case .photoToFurniture(let entry): PhotoToFurnitureSheet(improveEntryId: entry)
            case .photoBuilder(let draft): FurnitureBuilderView(definitionId: nil, draft: draft).frame(minWidth: 780, minHeight: 480)
            }
        }
        .onAppear(perform: onFirstAppear)
    }

    @ViewBuilder private var editors: some View {
        if let c = workspace.compare, let right = workspace.rightModel {
            ComparePanes(left: workspace.active, right: right, state: c)
        } else {
            singleEditors
        }
    }

    // Each project gets its own view identity: the 3D view builds its renderer once, for the model it first sees.
    @ViewBuilder private var singleEditors: some View {
        switch model.layout {
        case .plan: PlanView().id(model.id)
        case .scene: SceneView().id(model.id)
        case .split:
            // Not HSplitView: inside NavigationSplitView + inspector it loops in AppKit's constraint pass and crashes.
            EditorSplit().id(model.id)
        }
    }

    private func fallBackToSelectIfToolUnavailable() {
        if !model.tool.isAvailable(in: model.layout) { model.tool = .select }
    }

    // MARK: Toolbar

    /// Icons only, each with a tooltip. One principal item (the tool segment); everything else is a customizable
    /// trailing item (View > Customize Toolbar…). Controls here are fine: they live in the window toolbar, not in the
    /// split-view detail column.
    @ToolbarContentBuilder private var toolbar: some CustomizableToolbarContent {
        ToolbarItem(id: "tools", placement: .principal) {
            ToolPicker()
        }
        ToolbarItem(id: "layout", placement: .primaryAction) {
            LayoutPicker()
        }
        ToolbarItem(id: "arrangement", placement: .primaryAction, showsByDefault: false) {
            ArrangementPicker()
        }
        ToolbarItem(id: "detach", placement: .primaryAction, showsByDefault: false) {
            Button {
                if detached { dismissWindow(id: EditorLayoutKey.sceneWindowID) }
                else { openWindow(id: EditorLayoutKey.sceneWindowID) }
            } label: {
                Label(detached ? "Dock 3D" : "3D Window", systemImage: detached ? "rectangle.on.rectangle" : "macwindow.badge.plus")
            }
            .help(detached ? "Dock the 3D view back into this window" : "Open the 3D view in a separate window")
            .accessibilityIdentifier("detach3DButton")
        }
        ToolbarItem(id: "present", placement: .primaryAction) {
            PresentButton()
        }
        ToolbarItem(id: "agents", placement: .primaryAction, showsByDefault: false) {
            Button { model.showAgentPanel = true } label: {
                Label("Agents", systemImage: model.store.agentWriteEnabled ? "sparkles" : "lock")
            }
            .help("Agent access and activity")
            .accessibilityIdentifier("agentsButton")
        }
        ToolbarItem(id: "inspector", placement: .primaryAction) {
            Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                .help("Show or hide the inspector")
                .accessibilityIdentifier("inspectorButton")
        }
    }

    // MARK: Launch

    private func ensurePresenter() {
        if model.presenter == nil { model.presenter = PresenterEngine(source: PresenterModelFrameSource(model: model)) }
    }

    private func onFirstAppear() {
        ensurePresenter()
        if AppDefaults.isTestMode {
            detached = false
            TestHooks.apply(model: model, hide: { what in
                switch what {
                case "sidebar": showSidebar = false
                case "inspector": showInspector = false
                case "statusbar": showStatusBar = false
                default: break
                }
            })
        } else if detached {
            // The separate 3D window was open when the app quit: bring it back (its frame is remembered, so it returns
            // to the display it was on).
            openWindow(id: EditorLayoutKey.sceneWindowID)
        }
    }
}

// MARK: - Toolbar controls

private struct ToolPicker: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let layout = model.layout
        // Not a system Picker: its segments cannot be disabled one by one.
        HStack(spacing: 1) {
            ForEach(EditorTool.pickerTools) { t in
                let enabled = t.isAvailable(in: layout)
                let selected = model.tool == t
                Button { model.tool = t } label: {
                    Image(systemName: t.symbol)
                        .font(.system(size: 13))
                        .frame(width: 26, height: 20)
                        .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.35)
                .help(t.help(in: layout))
                .accessibilityLabel(t.title)
                .accessibilityIdentifier("toolPicker.\(t.rawValue)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
        .help("Drawing tool")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toolPicker")
    }
}

private struct LayoutPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(Workspace.self) private var workspace
    var body: some View {
        @Bindable var model = model
        Picker("Layout", selection: $model.layout) {
            ForEach(ViewLayout.allCases) { Label($0.title, systemImage: $0.symbol).tag($0).help($0.title) }
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        .disabled(workspace.compare != nil)
        .help("Show plan, 3D or both")
        .accessibilityIdentifier("layoutPicker")
    }
}

private struct ArrangementPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(Workspace.self) private var workspace
    @AppStorage(EditorLayoutKey.axis, store: AppDefaults.store) private var axisRaw = SplitAxis.sideBySide.rawValue
    var body: some View {
        Picker("Arrangement", selection: Binding(
            get: { workspace.compare?.axis.rawValue ?? axisRaw },
            set: { v in
                if workspace.compare != nil { workspace.compare?.axis = SplitAxis(rawValue: v) ?? .sideBySide } else { axisRaw = v }
            })) {
            ForEach(SplitAxis.allCases) { Label($0.title, systemImage: $0.symbol).tag($0.rawValue).help($0.title) }
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        .disabled(model.layout != .split && workspace.compare == nil)
        .help("Plan and 3D side by side or stacked")
        .accessibilityIdentifier("arrangementPicker")
    }
}

/// Opens the presenter controls (source, target, start/stop, status), shown as a sheet by `ContentView`.
private struct PresentButton: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Button { model.showPresenter.toggle() } label: {
            Label("Present", systemImage: model.presenter?.isPresenting == true ? "tv.fill" : "tv")
        }
        .help("Show the plan or 3D view on an Apple TV or another screen")
        .accessibilityIdentifier("presentButton")
    }
}

/// The presenter draws a marker where the mouse is on the plan (only when the user enabled the pointer). Kept in its own
/// view so only this view re-evaluates on mouse moves.
private struct PresenterPointerRelay: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onChange(of: model.cursorPoint) { _, p in model.presenter?.reportPointer(p) }
    }
}

/// Bottom line: errors, status, selection count, revision.
struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            if let e = model.lastError {
                Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .help(e)
                    .accessibilityLabel("Error: \(e)")
            } else if let s = model.statusMessage {
                Text(s).foregroundStyle(.secondary).lineLimit(2).help(s)
            }
            Spacer()
            if let c = model.cursorPoint {
                Text("x \(c.x)  y \(c.y) mm").monospacedDigit().foregroundStyle(.secondary)
            }
            if !model.selection.isEmpty { Text("\(model.selection.count) selected").foregroundStyle(.secondary) }
            Text(model.activeLevel?.name ?? "").foregroundStyle(.secondary)
            Text("rev \(model.project.revision)").monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 14).padding(.vertical, 6)
        .accessibilityIdentifier("statusBar")
    }
}
