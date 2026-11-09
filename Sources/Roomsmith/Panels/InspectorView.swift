import SwiftUI
import RoomsmithCore

/// Context-sensitive numeric properties of the selection.
struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let p = model.project
        Group {
            if model.selection.isEmpty {
                InspectorProjectView()
            } else if model.selection.count == 1, let id = model.selection.first, let kind = p.kind(of: id) {
                switch kind {
                case .wall: InspectorWallView(id: id).id(id)
                case .room: InspectorRoomView(id: id).id(id)
                case .opening: InspectorOpeningView(id: id).id(id)
                case .dimension: InspectorDimensionView(id: id).id(id)
                case .furniture: InspectorFurnitureView(id: id).id(id)
                case .group: InspectorGroupView(id: id).id(id)
                case .background: InspectorBackgroundView(id: id).id(id)
                default: ContentUnavailableView("Nothing to edit", systemImage: "slider.horizontal.3",
                                           description: Text("This object has no properties here. Select a wall, room or furniture in the plan."))
                }
            } else {
                InspectorMultiView()
            }
        }
        .accessibilityIdentifier("inspector")
    }
}

/// Shared helpers for the inspector forms.
extension AppModel {
    var unit: LengthUnit { project.settings.displayUnit }

    /// Renames furniture, rooms, groups, openings.
    func rename(_ id: UUID, to name: String) -> Bool {
        perform("Rename") { p in
            try p.ensureEditable(id)
            switch p.kind(of: id) {
            case .furniture: try p.modify(\.instances, id, "Furniture") { $0.name = name }
            case .room: try p.modify(\.rooms, id, "Room") { $0.name = name }
            case .group: try p.modify(\.groups, id, "Group") { $0.name = name }
            case .opening: try p.updateOpening(id, name: name)
            default: throw CommandError.invalid("This object has no name", ids: [id])
            }
        }
    }
}

struct LockToggle: View {
    @Environment(AppModel.self) private var model
    let id: UUID
    let locked: Bool

    var body: some View {
        Toggle("Locked", isOn: Binding(get: { locked }, set: { v in model.perform(v ? "Lock" : "Unlock") { try $0.setLocked([id], v) } }))
    }
}

/// Collision list for the selected objects; only when enabled in the settings.
struct CollisionSection: View {
    @Environment(AppModel.self) private var model
    let ids: [UUID]

    var body: some View {
        let p = model.project
        if p.settings.collisionWarnings, !ids.isEmpty, ids.count <= 200, let lid = p.levelId(of: ids[0]) {
            let issues = CollisionChecker.check(p, levelId: lid, only: Set(ids))
            if !issues.isEmpty {
                Section("Collision warnings") {
                    ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                        Label(text(issue, p), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).font(.callout)
                    }
                }
            }
        }
    }

    private func text(_ i: CollisionIssue, _ p: Project) -> String {
        let a = p.displayName(of: i.a)
        let b = i.b.map { p.displayName(of: $0) } ?? ""
        switch i.kind {
        case .furnitureOverlap: return "\(a) overlaps \(b)"
        case .furnitureWall: return "\(a) touches a wall"
        case .blocksOpening: return "\(a) blocks \(b)"
        case .outsideRooms: return "\(a) is outside all rooms"
        }
    }
}

/// Nothing selected: project and level summary.
struct InspectorProjectView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let p = model.project
        let lid = model.activeLevelId
        Form {
            Section("Project") {
                LabeledContent("Name") {
                    NameField(title: "Project name", value: p.name) { v in model.perform("Rename Project") { $0.name = v } }
                }
                LabeledContent("Revision") { Text("\(p.revision)").monospacedDigit() }
                LabeledContent("Unit") { Text(p.settings.displayUnit.rawValue) }
            }
            if let level = model.activeLevel {
                Section("Level: \(level.name)") {
                    LabeledContent("Elevation") { Text(model.unit.format(level.elevation)) }
                    LabeledContent("Height") { Text(model.unit.format(level.height)) }
                    LabeledContent("Walls") { Text("\(p.walls.filter { $0.levelId == lid }.count)") }
                    LabeledContent("Rooms") { Text("\(p.rooms.filter { $0.levelId == lid }.count)") }
                    LabeledContent("Openings") { Text("\(p.openings.filter { p.wall($0.wallId)?.levelId == lid }.count)") }
                    LabeledContent("Furniture") { Text("\(p.instances.filter { $0.levelId == lid }.count)") }
                    LabeledContent("Groups") { Text("\(p.groups.filter { $0.levelId == lid }.count)") }
                    LabeledContent("Dimensions") { Text("\(p.dimensions.filter { $0.levelId == lid }.count)") }
                }
            }
            InspectorBackgroundList()
            Section("Totals") {
                LabeledContent("Levels") { Text("\(p.levels.count)") }
                LabeledContent("Designs") { Text("\(p.definitions.count)") }
                LabeledContent("Products") { Text("\(p.products.count)") }
            }
            Section { Text("Select an object in the plan, the 3D view or the object list to edit it.").font(.caption).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
    }
}
