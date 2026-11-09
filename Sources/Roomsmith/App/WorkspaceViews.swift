import AppKit
import SwiftUI
import RoomsmithCore

/// One tab per open project. Shown when more than one project is open or a compare split is on.
struct WorkspaceTabBar: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(workspace.tabs) { tab in
                        TabItem(model: tab)
                    }
                }
                .padding(.horizontal, 2)
            }
            Button { workspace.newProject() } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help("New project in a new tab")
                .accessibilityLabel("New project in a new tab")
                .accessibilityIdentifier("newTabButton")
            if workspace.compare != nil {
                Button { workspace.endCompare() } label: { Label("End Compare", systemImage: "xmark.rectangle") }
                    .buttonStyle(.borderless)
                    .help("Show one project again")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .accessibilityIdentifier("workspaceTabs")
    }
}

private struct TabItem: View {
    @Environment(Workspace.self) private var workspace
    let model: AppModel

    private var isActive: Bool { workspace.activeId == model.id }
    private var isRight: Bool { workspace.compare?.rightId == model.id }

    var body: some View {
        let title = model.fileURL?.deletingPathExtension().lastPathComponent ?? model.project.name
        HStack(spacing: 5) {
            if isRight { Image(systemName: "rectangle.split.2x1").font(.caption2).foregroundStyle(.secondary) }
            Text(title).lineLimit(1)
            if model.store.isDirty { Circle().fill(.secondary).frame(width: 6, height: 6).help("Unsaved changes") }
            Button { workspace.closeWithConfirmation(model.id) } label: { Image(systemName: "xmark").font(.caption2) }
                .buttonStyle(.borderless)
                .help("Close this project")
                .accessibilityLabel("Close project \(title)")
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(isActive ? Color.accentColor.opacity(0.22) : (isRight ? Color.accentColor.opacity(0.10) : Color.clear)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor).opacity(isActive ? 0 : 0.7)))
        .contentShape(Rectangle())
        .onTapGesture { workspace.activate(model.id) }
        .focusable()
        .onKeyPress(.space) { workspace.activate(model.id); return .handled }
        .contextMenu {
            if !isActive {
                Button("Show Next to \(workspace.active.project.name)") {
                    workspace.startCompare(with: model.id)
                }
            }
            Button("Close", role: .destructive) { workspace.closeWithConfirmation(model.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Project \(title)")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { workspace.activate(model.id) }
        .accessibilityAction(named: "Close project") { workspace.closeWithConfirmation(model.id) }
    }
}

/// Two projects side by side or stacked, each with its own plan or 3D view, camera, selection and undo history.
struct ComparePanes: View {
    @Environment(Workspace.self) private var workspace
    let left: AppModel
    let right: AppModel
    let state: CompareState

    var body: some View {
        let layout = state.axis == .sideBySide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        layout {
            CompareHalf(model: left, side: .left)
            Divider()
            CompareHalf(model: right, side: .right)
        }
    }
}

private struct CompareHalf: View {
    @Environment(Workspace.self) private var workspace
    let model: AppModel
    let side: CompareSide

    private var content: PaneContent {
        side == .left ? (workspace.compare?.leftContent ?? .plan) : (workspace.compare?.rightContent ?? .plan)
    }
    private var focused: Bool { (workspace.compare?.focus ?? .left) == side }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch content {
                case .plan: PlanView()
                case .scene: SceneView()
                }
            }
            // A pane's 3D view builds its renderer once, so each project needs its own view identity.
            .id("\(model.id.uuidString)-\(content.rawValue)")
            .environment(model)
            .clipped()
        }
        .overlay(RoundedRectangle(cornerRadius: 0).strokeBorder(Color.accentColor.opacity(focused ? 0.6 : 0), lineWidth: 2).allowsHitTesting(false))
        // Focus follows the pointer: sidebar, inspector, status bar and menus then act on this project.
        .onHover { if $0 { workspace.setFocus(side) } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(side == .left ? "Left" : "Right") pane, \(model.project.name)")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Picker("View", selection: Binding(
                get: { content },
                set: { v in
                    if side == .left { workspace.compare?.leftContent = v } else { workspace.compare?.rightContent = v }
                })) {
                ForEach(PaneContent.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 110)
            .help("Show the plan or the 3D view of this project")
            Spacer()
            if model.store.isDirty { Text("Edited").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(.bar)
        .contentShape(Rectangle())
        .onTapGesture { workspace.setFocus(side) }
        .accessibilityAction(named: "Use this pane for commands") { workspace.setFocus(side) }
    }
}

/// Key figures of two projects next to each other: total area, rooms with area, furniture, wall length.
struct ComparisonSheet: View {
    @Environment(Workspace.self) private var workspace
    @State private var leftId: UUID?
    @State private var rightId: UUID?

    private func figures(_ id: UUID?) -> ProjectFigures? {
        (id.flatMap { workspace.model($0) }).map { ProjectFigures($0.project) }
    }

    var body: some View {
        let l = figures(leftId ?? workspace.active.id)
        let r = figures(rightId ?? workspace.rightModel?.id ?? workspace.compareCandidates.first?.id)
        VStack(alignment: .leading, spacing: 12) {
            Text("Compare Projects").font(.title3.weight(.semibold))
            if workspace.tabs.count < 2 {
                Text("Open a second project (File > Open…) to compare figures.").foregroundStyle(.secondary)
            } else {
                HStack {
                    picker("Left", selection: $leftId, fallback: workspace.active.id)
                    picker("Right", selection: $rightId, fallback: workspace.rightModel?.id ?? workspace.compareCandidates.first?.id)
                }
                if let l, let r {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                        GridRow { Text(""); Text(l.name).bold(); Text(r.name).bold() }
                        GridRow { Text("Total area"); Text("\(l.totalAreaM2) m²"); Text("\(r.totalAreaM2) m²") }
                        GridRow { Text("Rooms"); Text("\(l.rooms.count)"); Text("\(r.rooms.count)") }
                        GridRow { Text("Furniture"); Text("\(l.furnitureCount)"); Text("\(r.furnitureCount)") }
                        GridRow { Text("Wall length"); Text(Self.metres(l.wallLengthMM)); Text(Self.metres(r.wallLengthMM)) }
                    }
                    Divider()
                    ScrollView {
                        HStack(alignment: .top, spacing: 24) {
                            roomList(l)
                            roomList(r)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { workspace.showComparisonSheet = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(minWidth: 560, minHeight: 360)
        .accessibilityIdentifier("comparisonSheet")
    }

    private func picker(_ title: String, selection: Binding<UUID?>, fallback: UUID?) -> some View {
        Picker(title, selection: Binding(get: { selection.wrappedValue ?? fallback }, set: { selection.wrappedValue = $0 })) {
            ForEach(workspace.tabs) { Text($0.project.name).tag(Optional($0.id)) }
        }
    }

    private func roomList(_ f: ProjectFigures) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(f.name).font(.callout.weight(.medium))
            ForEach(Array(f.rooms.enumerated()), id: \.offset) { _, room in
                HStack {
                    Text(room.name)
                    Spacer(minLength: 8)
                    Text("\(room.areaM2) m²").monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            if f.rooms.isEmpty { Text("No rooms").foregroundStyle(.secondary).font(.callout) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func metres(_ mm: Double) -> String { String(format: "%.2f m", mm / 1000) }
}

/// Menu "Projects": tabs, compare and transfer of the selection.
struct WorkspaceCommands: Commands {
    let workspace: Workspace

    var body: some Commands {
        CommandMenu("Projects") {
            let tabs = workspace.tabs
            let model = workspace.focused
            let others = tabs.filter { $0.id != model.id }
            Button("Next Project") { step(1) }.keyboardShortcut("]", modifiers: [.command, .shift]).disabled(tabs.count < 2)
            Button("Previous Project") { step(-1) }.keyboardShortcut("[", modifiers: [.command, .shift]).disabled(tabs.count < 2)
            Divider()
            Menu("Show Next to") {
                ForEach(workspace.compareCandidates) { o in
                    Button(o.project.name) { workspace.startCompare(with: o.id) }
                }
            }
            .disabled(workspace.compareCandidates.isEmpty)
            Button(workspace.compare?.axis == .stacked ? "Compare Side by Side" : "Compare Stacked") {
                workspace.compare?.axis = workspace.compare?.axis == .stacked ? .sideBySide : .stacked
            }
            .disabled(workspace.compare == nil)
            Button("End Compare") { workspace.endCompare() }.disabled(workspace.compare == nil)
            Button("Compare Figures…") { workspace.showComparisonSheet = true }.disabled(tabs.count < 2)
            Divider()
            let ids = workspace.transferable(model.selectionIds, in: model)
            Menu("Copy Selection to") {
                ForEach(others) { o in
                    Button(o.project.name) { workspace.transferReportingErrors(ids: ids, from: model, to: o, move: false) }
                }
            }
            .disabled(ids.isEmpty || others.isEmpty)
            Menu("Move Selection to") {
                ForEach(others) { o in
                    Button(o.project.name) { workspace.transferReportingErrors(ids: ids, from: model, to: o, move: true) }
                }
            }
            .disabled(ids.isEmpty || others.isEmpty)
        }
    }

    private func step(_ d: Int) {
        let tabs = workspace.tabs
        guard tabs.count > 1, let i = tabs.firstIndex(where: { $0.id == workspace.activeId }) else { return }
        workspace.activate(tabs[(i + d + tabs.count) % tabs.count].id)
    }
}
