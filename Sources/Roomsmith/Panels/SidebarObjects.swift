import SwiftUI
import RoomsmithCore

/// One line of the object tree. Plain value so building 1000 rows stays cheap.
struct ObjectRow: Identifiable, Hashable {
    enum Section: Int { case walls, rooms, furniture, groups, dimensions, other }
    var id: UUID
    var section: Section
    var title: String
    var detail: String
    var symbol: String
    var indent: Int
    var expandable: Bool
    var locked: Bool
    var hidden: Bool
    /// False for child rows (openings under a wall, members under a group): section headers count top-level objects only.
    var counted = true
}

enum ObjectTree {
    static func sectionTitle(_ s: ObjectRow.Section) -> String {
        switch s {
        case .walls: "Walls"; case .rooms: "Rooms"; case .furniture: "Furniture"
        case .groups: "Groups"; case .dimensions: "Dimensions"; case .other: "Other"
        }
    }

    /// Rows per section for the level. With search text the tree is flat and filtered.
    static func build(_ p: Project, levelId: UUID, search: String, collapsed: Set<UUID>) -> [(ObjectRow.Section, [ObjectRow])] {
        let unit = p.settings.displayUnit
        let words = search.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let flat = !words.isEmpty
        func matches(_ title: String, _ extra: String = "") -> Bool {
            guard flat else { return true }
            let h = (title + " " + extra).lowercased()
            return words.allSatisfy { h.contains($0) }
        }

        var openingsByWall: [UUID: [Opening]] = [:]
        for o in p.openings { openingsByWall[o.wallId, default: []].append(o) }
        var instById: [UUID: FurnitureInstance] = [:]
        for i in p.instances where i.levelId == levelId { instById[i.id] = i }

        func openingRow(_ o: Opening, indent: Int) -> ObjectRow {
            let sym = o.kind == .door ? "door.left.hand.open" : (o.kind == .window ? "window.vertical.closed" : "rectangle.portrait")
            var row = ObjectRow(id: o.id, section: .walls, title: p.displayName(of: o.id), detail: unit.format(o.width),
                             symbol: sym, indent: indent, expandable: false, locked: false, hidden: false)
            row.counted = indent == 0 && flat
            return row
        }

        var walls: [ObjectRow] = []
        var n = 0
        for w in p.walls where w.levelId == levelId {
            n += 1
            let title = "Wall \(n)"
            let ops = openingsByWall[w.id] ?? []
            let opMatches = flat ? ops.filter { matches(p.displayName(of: $0.id), "opening \($0.kind.rawValue)") } : ops
            if flat {
                if matches(title, "wall") { walls.append(wallRow(w, title, unit, ops.count, indent: 0)) }
                walls += opMatches.map { openingRow($0, indent: 0) }
            } else {
                walls.append(wallRow(w, title, unit, ops.count, indent: 0))
                if !collapsed.contains(w.id) { walls += ops.map { openingRow($0, indent: 1) } }
            }
        }

        var rooms: [ObjectRow] = []
        for r in p.rooms where r.levelId == levelId && matches(r.name, "room") {
            rooms.append(ObjectRow(id: r.id, section: .rooms, title: r.name, detail: LengthUnit.areaText(Geo.area(r.points)),
                                   symbol: "square.dashed", indent: 0, expandable: false, locked: false, hidden: false))
        }

        func furnitureRow(_ i: FurnitureInstance, indent: Int) -> ObjectRow {
            ObjectRow(id: i.id, section: .furniture, title: i.name, detail: "", symbol: "chair.lounge",
                      indent: indent, expandable: false, locked: i.locked, hidden: !i.visible)
        }
        var furniture: [ObjectRow] = []
        for i in p.instances where i.levelId == levelId && (flat || i.groupId == nil) && matches(i.name, "furniture") {
            furniture.append(furnitureRow(i, indent: 0))
        }

        var groups: [ObjectRow] = []
        for g in p.groups where g.levelId == levelId {
            let members = g.memberIds.compactMap { instById[$0] }
            let groupMatches = matches(g.name, "group")
            if flat {
                if groupMatches {
                    groups.append(ObjectRow(id: g.id, section: .groups, title: g.name, detail: "\(members.count)", symbol: "rectangle.3.group",
                                            indent: 0, expandable: false, locked: g.locked, hidden: false))
                }
                continue
            }
            groups.append(ObjectRow(id: g.id, section: .groups, title: g.name, detail: "\(members.count)", symbol: "rectangle.3.group",
                                    indent: 0, expandable: !members.isEmpty, locked: g.locked,
                                    hidden: !members.isEmpty && members.allSatisfy { !$0.visible }))
            if !collapsed.contains(g.id) {
                for m in members {
                    var row = furnitureRow(m, indent: 1)
                    row.section = .groups
                    row.counted = false
                    groups.append(row)
                }
            }
        }

        var dims: [ObjectRow] = []
        for d in p.dimensions where d.levelId == levelId && matches("Dimension") {
            dims.append(ObjectRow(id: d.id, section: .dimensions, title: "Dimension", detail: unit.format(MM(Geo.distance(d.a, d.b).rounded())),
                                  symbol: "ruler", indent: 0, expandable: false, locked: false, hidden: false))
        }
        let all: [(ObjectRow.Section, [ObjectRow])] = [(.walls, walls), (.rooms, rooms), (.furniture, furniture), (.groups, groups), (.dimensions, dims)]
        return all.filter { !$0.1.isEmpty }
    }

    private static func wallRow(_ w: Wall, _ title: String, _ unit: LengthUnit, _ openings: Int, indent: Int) -> ObjectRow {
        ObjectRow(id: w.id, section: .walls, title: title, detail: unit.format(MM(Geo.distance(w.start, w.end).rounded())),
                  symbol: "line.diagonal", indent: indent, expandable: openings > 0, locked: w.locked, hidden: false)
    }
}

/// Remembers the last built tree. Not observed: `body` only reads it, and the key (revision, level, search,
/// collapsed rows) decides whether the tree is rebuilt, so a redraw without a document change costs nothing.
@MainActor private final class ObjectTreeCache {
    struct Key: Equatable {
        var projectId: UUID, revision: Int64, levelId: UUID, search: String, collapsed: Set<UUID>
    }
    private var key: Key?
    private var value: [(ObjectRow.Section, [ObjectRow])] = []

    func sections(_ project: Project, contentRevision: Int64, levelId: UUID, search: String, collapsed: Set<UUID>) -> [(ObjectRow.Section, [ObjectRow])] {
        let k = Key(projectId: project.id, revision: contentRevision, levelId: levelId, search: search, collapsed: collapsed)
        if k != key {
            value = ObjectTree.build(project, levelId: levelId, search: search, collapsed: collapsed)
            key = k
        }
        return value
    }
}

/// Object tree of the active level: walls (with openings), rooms, furniture, groups (with members).
struct SidebarObjectsView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var collapsed: Set<UUID> = []
    @State private var collapsedSections: Set<Int> = []
    @State private var cache = ObjectTreeCache()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var model = model
        let sections = cache.sections(model.project, contentRevision: model.store.contentRevision, levelId: model.activeLevelId, search: search, collapsed: collapsed)
        VStack(spacing: 0) {
            TextField("Search objects", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 8).padding(.bottom, 6)
                .accessibilityIdentifier("objectSearch")
            ScrollViewReader { proxy in
                List(selection: $model.selection) {
                    ForEach(sections, id: \.0) { section, rows in
                        Section {
                            if !collapsedSections.contains(section.rawValue) || !search.isEmpty {
                                ForEach(rows) { row in
                                    ObjectRowView(row: row, isCollapsed: collapsed.contains(row.id)) { toggle(row.id) }
                                        .tag(row.id)
                                        .listRowBackground(
                                            SelectionBackdrop(selected: model.selection.contains(row.id))
                                        )
                                }
                            }
                        } header: {
                            Button {
                                if collapsedSections.contains(section.rawValue) { collapsedSections.remove(section.rawValue) }
                                else { collapsedSections.insert(section.rawValue) }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: collapsedSections.contains(section.rawValue) ? "chevron.right" : "chevron.down").font(.caption2)
                                    Text("\(ObjectTree.sectionTitle(section)) (\(rows.filter(\.counted).count))")
                                }
                                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listStyle(.sidebar)
                .overlay {
                    if sections.isEmpty {
                        if search.isEmpty {
                            ContentUnavailableView("No objects on this level", systemImage: "square.dashed",
                                                   description: Text("Draw a wall or a room with the tools in the toolbar, or drag furniture from the catalog into the plan."))
                        } else {
                            ContentUnavailableView.search(text: search)
                        }
                    }
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    ObjectContextMenu(ids: Array(ids))
                } primaryAction: { ids in
                    model.frame(Array(ids))
                }
                .onChange(of: model.selection) { _, new in
                    if new.count == 1, let id = new.first { if reduceMotion { proxy.scrollTo(id) } else { withAnimation { proxy.scrollTo(id) } } }
                }
            }
        }
        .accessibilityIdentifier("objectList")
    }

    private func toggle(_ id: UUID) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }
}

private struct ObjectRowView: View {
    @Environment(AppModel.self) private var model
    let row: ObjectRow
    let isCollapsed: Bool
    let toggle: () -> Void

    /// Furniture and groups can be dragged into another open project (plan or 3D of the other pane).
    private var draggable: Bool { row.section == .furniture || row.section == .groups }

    private func dragProvider() -> NSItemProvider {
        let picked = model.selection.contains(row.id) ? model.selectionIds : [row.id]
        let ids = model.workspace?.transferable(picked, in: model) ?? []
        return NSItemProvider(object: TransferToken(sourceId: model.id, ids: ids.isEmpty ? [row.id] : ids).payload as NSString)
    }

    var body: some View {
        content.modifier(TransferDragModifier(enabled: draggable, provider: dragProvider))
    }

    private var content: some View {
        HStack(spacing: 6) {
            if row.indent > 0 { Spacer().frame(width: 14 * CGFloat(row.indent)) }
            if row.expandable {
                Button(action: toggle) { Image(systemName: isCollapsed ? "chevron.right" : "chevron.down").font(.caption2) }
                    .buttonStyle(.borderless)
                    .frame(width: 12)
                    .help(isCollapsed ? "Expand" : "Collapse")
                    .accessibilityLabel(isCollapsed ? "Expand \(row.title)" : "Collapse \(row.title)")
            }
            Image(systemName: row.symbol).foregroundStyle(Color(nsColor: .secondaryLabelColor)).frame(width: 16)
            Text(row.title).lineLimit(1).truncationMode(.middle).foregroundStyle(Color(nsColor: .labelColor))
                .help(row.title)
            Spacer(minLength: 4)
            if model.newItems.contains(row.id) { NewBadge() }
            if !row.detail.isEmpty { Text(row.detail).font(.caption).foregroundStyle(Color(nsColor: .secondaryLabelColor)).lineLimit(1) }
            if row.hidden { Image(systemName: "eye.slash").font(.caption).foregroundStyle(Color(nsColor: .secondaryLabelColor)) }
            if row.locked { Image(systemName: "lock.fill").font(.caption).foregroundStyle(Color(nsColor: .secondaryLabelColor)) }
        }
        .opacity(row.hidden ? 0.55 : 1)
        .onHover { inside in
            if inside { model.hoveredId = row.id } else if model.hoveredId == row.id { model.hoveredId = nil }
        }
    }
}

/// `.onDrag` only for rows that can travel (other rows stay plain selectable rows).
private struct TransferDragModifier: ViewModifier {
    let enabled: Bool
    let provider: () -> NSItemProvider

    func body(content: Content) -> some View {
        if enabled { content.onDrag(provider) } else { content }
    }
}

/// Context menu for sidebar rows; acts on the clicked rows (or the selection when one of them is selected).
private struct ObjectContextMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(Workspace.self) private var workspace
    let ids: [UUID]

    var body: some View {
        let lockable = model.lockableIds(ids)
        let hideable = model.hideableIds(ids)
        let groupable = model.groupableIds(ids)
        let groups = model.groupIds(for: ids)
        Button("Frame") { model.frame(ids) }.disabled(ids.isEmpty)
        Divider()
        Button("Duplicate") { model.duplicateObjects(ids) }.disabled(ids.isEmpty)
        Button("Delete", role: .destructive) { model.deleteObjects(ids) }.disabled(ids.isEmpty)
        Divider()
        Button(!lockable.isEmpty && lockable.allSatisfy(model.isLockedForMenu) ? "Unlock" : "Lock") { model.toggleLock(ids) }
            .disabled(lockable.isEmpty)
        Button(!hideable.isEmpty && hideable.allSatisfy(model.isHidden) ? "Show" : "Hide") { model.toggleVisible(ids) }
            .disabled(hideable.isEmpty)
        Divider()
        Button("Group") { model.groupObjects(ids) }.disabled(groupable.isEmpty)
        Button("Ungroup") { model.ungroupObjects(ids) }.disabled(groups.isEmpty)
        Divider()
        SaveToLibraryMenu(title: "Save to My Furniture", ids: ids, model: model)
        let travelling = workspace.transferable(ids, in: model)
        let others = workspace.tabs.filter { $0.id != model.id }
        if !travelling.isEmpty, !others.isEmpty {
            Divider()
            Menu("Copy to") {
                ForEach(others) { o in
                    Button(o.project.name) { workspace.transferReportingErrors(ids: travelling, from: model, to: o, move: false) }
                }
            }
            Menu("Move to") {
                ForEach(others) { o in
                    Button(o.project.name) { workspace.transferReportingErrors(ids: travelling, from: model, to: o, move: true) }
                }
            }
        }
    }
}
