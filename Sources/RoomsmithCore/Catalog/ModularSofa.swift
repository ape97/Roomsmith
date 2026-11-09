import Foundation

extension BuiltinCatalog {
    public enum ModularSofaKey {
        public static let corner = "sofa.modular.corner"
        public static let middle = "sofa.modular.middle"
        public static let endLeft = "sofa.modular.end-left"
        public static let endRight = "sofa.modular.end-right"
        public static let ottoman = "sofa.modular.ottoman"
    }

    /// Members of the modular sofa group, in this order. Two corners are needed for the U-shape.
    private enum Role: CaseIterable {
        case cornerA, cornerB, middle1, middle2, endLeft, endRight, ottoman

        var key: String {
            switch self {
            case .cornerA, .cornerB: ModularSofaKey.corner
            case .middle1, .middle2: ModularSofaKey.middle
            case .endLeft: ModularSofaKey.endLeft
            case .endRight: ModularSofaKey.endRight
            case .ottoman: ModularSofaKey.ottoman
            }
        }
        var label: String {
            switch self {
            case .cornerA: "Corner A"
            case .cornerB: "Corner B"
            case .middle1: "Middle 1"
            case .middle2: "Middle 2"
            case .endLeft: "End left"
            case .endRight: "End right"
            case .ottoman: "Ottoman"
            }
        }
    }

    private struct Slot {
        var x: MM, y: MM, rotation: Double
        init(_ x: MM, _ y: MM, _ rotation: Double) { self.x = x; self.y = y; self.rotation = rotation }
    }

    /// Local layouts (mm, group origin = centre of corner A, back line at y = 0, front towards −Y). Modules touch edge to edge.
    private static let layouts: [(name: String, slots: [Role: Slot], visible: Set<Role>)] = [
        ("L-shape",
         [.cornerA: Slot(0, 0, 0), .middle1: Slot(1175, 0, 0), .endRight: Slot(2665, 0, 0), .middle2: Slot(0, -1175, 90),
          .ottoman: Slot(925, -800, 0)],
         [.cornerA, .middle1, .endRight, .middle2, .ottoman]),
        ("Straight",
         [.endLeft: Slot(315, 0, 0), .middle1: Slot(1805, 0, 0), .middle2: Slot(3205, 0, 0), .endRight: Slot(4695, 0, 0),
          .ottoman: Slot(1805, -800, 0)],
         [.endLeft, .middle1, .middle2, .endRight, .ottoman]),
        ("U-shape",
         [.cornerA: Slot(0, 0, 0), .middle1: Slot(1175, 0, 0), .middle2: Slot(2575, 0, 0), .cornerB: Slot(3750, 0, 270),
          .endLeft: Slot(0, -1265, 90), .endRight: Slot(3750, -1265, 270), .ottoman: Slot(1875, -800, 0)],
         [.cornerA, .middle1, .middle2, .cornerB, .endLeft, .endRight, .ottoman]),
    ]

    /// Modular sofa: adds the five module definitions (if missing), seven instances and one group with the configurations
    /// L-shape (active), Straight and U-shape. Modules not used by a configuration are hidden in it. Returns the group id.
    /// Throws when a module definition is missing from the catalog. Must run inside a document command (`store.run`).
    public static func insertModularSofa(into p: inout Project, levelId: UUID, origin: P2) throws -> UUID {
        var defIds: [String: UUID] = [:]
        for key in Role.allCases.map(\.key) where defIds[key] == nil {
            guard let def = definition(key) else { throw CommandError.notFound("Catalog definition", StableID.uuid("\(key)/definition")) }
            defIds[key] = def.id
            if !p.definitions.contains(where: { $0.id == def.id }) { p.definitions.append(def) }
            for materialId in Set(def.components.compactMap(\.materialId)) where !p.materials.contains(where: { $0.id == materialId }) {
                if let m = materials.first(where: { $0.id == materialId }) { p.materials.append(m) }
            }
        }
        let groupId = UUID()
        var instanceIds: [Role: UUID] = [:]
        var members: [UUID] = []
        let active = layouts[0]
        for role in Role.allCases {
            let slot = active.slots[role] ?? layouts[2].slots[role] ?? Slot(0, 0, 0)
            guard let definitionId = defIds[role.key] else { throw CommandError.invalid("Modular sofa module \(role.key) is missing") }
            var inst = FurnitureInstance(definitionId: definitionId, levelId: levelId, name: "Modular sofa – \(role.label)",
                                         position: P3(origin.x + slot.x, origin.y + slot.y, 0), rotationDeg: slot.rotation)
            inst.groupId = groupId
            inst.visible = active.visible.contains(role)
            instanceIds[role] = inst.id
            members.append(inst.id)
            p.instances.append(inst)
        }
        var group = FurnitureGroup(id: groupId, name: "Modular sofa", levelId: levelId, origin: P3(origin.x, origin.y, 0), memberIds: members)
        for layout in layouts {
            var poses: [UUID: MemberPose] = [:]
            for role in Role.allCases {
                guard let id = instanceIds[role] else { continue }
                let slot = layout.slots[role] ?? layouts[2].slots[role] ?? Slot(0, 0, 0)
                poses[id] = MemberPose(local: P3(slot.x, slot.y, 0), rotationDeg: slot.rotation, visible: layout.visible.contains(role))
            }
            group.configurations.append(GroupConfiguration(name: layout.name, poses: poses))
        }
        group.activeConfigurationId = group.configurations.first?.id
        p.groups.append(group)
        return groupId
    }
}
