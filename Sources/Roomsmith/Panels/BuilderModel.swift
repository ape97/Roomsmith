import Foundation
import RoomsmithCore

enum BuilderSupport {
    /// Axis-aligned bounds of the visible base components (rotation ignored). Nil when nothing is visible.
    static func nominalSize(of components: [Component]) -> Size3? {
        let vis = components.filter(\.visible)
        guard !vis.isEmpty else { return nil }
        func span(_ lo: (Component) -> MM, _ hi: (Component) -> MM) -> MM {
            max(1, (vis.map(hi).max() ?? 0) - (vis.map(lo).min() ?? 0))
        }
        return Size3(span({ $0.position.x - $0.size.width / 2 }, { $0.position.x + ($0.size.width + 1) / 2 }),
                     span({ $0.position.y - $0.size.depth / 2 }, { $0.position.y + ($0.size.depth + 1) / 2 }),
                     span({ $0.position.z - $0.size.height / 2 }, { $0.position.z + ($0.size.height + 1) / 2 }))
    }

    /// Validation message for a draft, or nil when it can be saved.
    static func validate(_ d: FurnitureDefinition, project: Project) -> String? {
        var ids = Set(project.materials.map(\.id))
        ids.formUnion(BuiltinCatalog.materials.map(\.id))
        do {
            try Validator.validateDefinition(d, materialIds: ids)
            for c in d.components where c.shape == .mesh {
                if let a = c.meshAssetId, !project.assets.contains(where: { $0.id == a }) {
                    return "Mesh component \(c.name) refers to a missing asset"
                }
            }
            return nil
        } catch {
            return userMessage(for: error)
        }
    }

    /// Centre of the walls and rooms of a level (mm); the origin when the level is empty.
    static func contentCentre(_ p: Project, levelId: UUID) -> P2 {
        var pts: [P2] = []
        for w in p.walls where w.levelId == levelId { pts += [w.start, w.end] }
        for r in p.rooms where r.levelId == levelId { pts += r.points }
        guard let minX = pts.map(\.x).min(), let maxX = pts.map(\.x).max(),
              let minY = pts.map(\.y).min(), let maxY = pts.map(\.y).max() else { return P2(0, 0) }
        return P2((minX + maxX) / 2, (minY + maxY) / 2)
    }

    static func uniqueStateName(_ base: String, in d: FurnitureDefinition) -> String {
        var n = d.states.count + 1
        while d.states.contains(where: { $0.name.caseInsensitiveCompare("\(base) \(n)") == .orderedSame }) { n += 1 }
        return "\(base) \(n)"
    }

    static func uniqueGroupName(_ base: String, in d: FurnitureDefinition) -> String {
        var n = d.optionGroups.count + 1
        while d.optionGroups.contains(where: { $0.name.caseInsensitiveCompare("\(base) \(n)") == .orderedSame }) { n += 1 }
        return "\(base) \(n)"
    }

    static func uniqueChoiceName(_ base: String, in g: OptionGroup) -> String {
        var n = g.choices.count + 1
        while g.choices.contains(where: { $0.name.caseInsensitiveCompare("\(base) \(n)") == .orderedSame }) { n += 1 }
        return "\(base) \(n)"
    }
}
