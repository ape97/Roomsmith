import Foundation

/// What a library row stands for when it is dragged into the plan.
public enum FurnitureDragSource: Equatable, Sendable {
    case catalog(String)
    case definition(UUID)

    static let catalogPrefix = "roomsmith-furniture-catalog:"
    static let definitionPrefix = "roomsmith-furniture-definition:"

    /// Text carried by the drag pasteboard.
    public var payload: String {
        switch self {
        case .catalog(let k): Self.catalogPrefix + k
        case .definition(let id): Self.definitionPrefix + id.uuidString
        }
    }

    public init?(payload: String) {
        if payload.hasPrefix(Self.catalogPrefix) {
            let k = String(payload.dropFirst(Self.catalogPrefix.count))
            guard !k.isEmpty else { return nil }
            self = .catalog(k)
        } else if payload.hasPrefix(Self.definitionPrefix), let id = UUID(uuidString: String(payload.dropFirst(Self.definitionPrefix.count))) {
            self = .definition(id)
        } else { return nil }
    }
}

public extension Project {
    /// Display name of the dragged item (command name "Place <Name>").
    func dragName(_ source: FurnitureDragSource) -> String {
        switch source {
        case .catalog(let k): BuiltinCatalog.entries.first { $0.key == k }?.name ?? "Furniture"
        case .definition(let id): definition(id)?.name ?? "Furniture"
        }
    }

    /// Definition used to preview a drag (project copy if present, else the built-in design).
    func dragDefinition(_ source: FurnitureDragSource) -> FurnitureDefinition? {
        switch source {
        case .catalog(let k): definitions.first { $0.catalogKey == k } ?? BuiltinCatalog.definition(k)
        case .definition(let id): definition(id)
        }
    }

    /// Places the dragged item with its instance position at `at` (exact mm). Reuses the project's copy of a catalog
    /// design and adds missing built-in materials, like the "Add" button. With `restOnFurniture` the piece stands on the
    /// furniture under `at` (`RestingSurface.z`) instead of on the floor.
    @discardableResult
    mutating func placeDragged(_ source: FurnitureDragSource, levelId: UUID, at: P2, rotationDeg: Double = 0,
                               restOnFurniture: Bool = false) throws -> UUID {
        let id = try placeDraggedOnFloor(source, levelId: levelId, at: at, rotationDeg: rotationDeg)
        if restOnFurniture, let idx = instances.firstIndex(where: { $0.id == id }) {
            let inst = instances[idx]
            instances[idx].position.z = RestingSurface.z(for: inst, at: at, in: self, wasResting: false)
        }
        return id
    }

    private mutating func placeDraggedOnFloor(_ source: FurnitureDragSource, levelId: UUID, at: P2, rotationDeg: Double) throws -> UUID {
        switch source {
        case .definition(let id):
            return try addInstance(definitionId: id, levelId: levelId, position: P3(at.x, at.y, 0), rotationDeg: rotationDeg)
        case .catalog(let key):
            guard let def = BuiltinCatalog.definition(key) else { throw CommandError.invalid("Unknown catalog entry \(key)") }
            let defId = definitions.first { $0.catalogKey == key }?.id ?? addDefinition(def)
            for mid in Set(def.components.compactMap(\.materialId)) where material(mid) == nil {
                if let m = BuiltinCatalog.materials.first(where: { $0.id == mid }) { addMaterial(m) }
            }
            return try addInstance(definitionId: defId, levelId: levelId, position: P3(at.x, at.y, 0), rotationDeg: rotationDeg)
        }
    }
}
