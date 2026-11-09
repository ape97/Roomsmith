import Foundation

public extension Project {
    func level(_ id: UUID) -> Level? { levels.first { $0.id == id } }
    func wall(_ id: UUID) -> Wall? { walls.first { $0.id == id } }
    func room(_ id: UUID) -> Room? { rooms.first { $0.id == id } }
    func opening(_ id: UUID) -> Opening? { openings.first { $0.id == id } }
    func dimension(_ id: UUID) -> Dimension? { dimensions.first { $0.id == id } }
    func material(_ id: UUID) -> Material? { materials.first { $0.id == id } }
    func definition(_ id: UUID) -> FurnitureDefinition? { definitions.first { $0.id == id } }
    func instance(_ id: UUID) -> FurnitureInstance? { instances.first { $0.id == id } }
    func group(_ id: UUID) -> FurnitureGroup? { groups.first { $0.id == id } }
    func product(_ id: UUID) -> CatalogProduct? { products.first { $0.id == id } }
    func asset(_ id: UUID) -> ProjectAsset? { assets.first { $0.id == id } }
    func background(_ id: UUID) -> BackgroundImage? { backgrounds.first { $0.id == id } }
    func savedCamera(_ id: UUID) -> SavedCamera? { cameras.first { $0.id == id } }

    /// Kind of the object with this id, searching all collections.
    func kind(of id: UUID) -> ObjectKind? {
        if instances.contains(where: { $0.id == id }) { return .furniture }
        if walls.contains(where: { $0.id == id }) { return .wall }
        if rooms.contains(where: { $0.id == id }) { return .room }
        if openings.contains(where: { $0.id == id }) { return .opening }
        if groups.contains(where: { $0.id == id }) { return .group }
        if dimensions.contains(where: { $0.id == id }) { return .dimension }
        if levels.contains(where: { $0.id == id }) { return .level }
        if materials.contains(where: { $0.id == id }) { return .material }
        if definitions.contains(where: { $0.id == id }) { return .definition }
        if products.contains(where: { $0.id == id }) { return .product }
        if assets.contains(where: { $0.id == id }) { return .asset }
        if backgrounds.contains(where: { $0.id == id }) { return .background }
        if cameras.contains(where: { $0.id == id }) { return .camera }
        return nil
    }

    /// Per-object revision of any object.
    func rev(of id: UUID) -> Int64? {
        switch kind(of: id) {
        case .level: level(id)?.rev
        case .wall: wall(id)?.rev
        case .room: room(id)?.rev
        case .opening: opening(id)?.rev
        case .dimension: dimension(id)?.rev
        case .furniture: instance(id)?.rev
        case .group: group(id)?.rev
        case .material: material(id)?.rev
        case .definition: definition(id)?.rev
        case .product: product(id)?.rev
        case .asset: asset(id)?.rev
        case .background: background(id)?.rev
        case .camera: savedCamera(id)?.rev
        case nil: nil
        }
    }

    /// Level an object lives on (walls, rooms, openings via their wall, furniture, groups, dimensions, backgrounds).
    func levelId(of id: UUID) -> UUID? {
        if let x = instance(id) { return x.levelId }
        if let x = wall(id) { return x.levelId }
        if let x = room(id) { return x.levelId }
        if let x = opening(id) { return wall(x.wallId)?.levelId }
        if let x = group(id) { return x.levelId }
        if let x = dimension(id) { return x.levelId }
        if let x = background(id) { return x.levelId }
        if level(id) != nil { return id }
        return nil
    }

    /// Display name of an object.
    func displayName(of id: UUID) -> String {
        if let x = instance(id) { return x.name }
        if let x = room(id) { return x.name }
        if let x = group(id) { return x.name }
        if let x = level(id) { return x.name }
        if let x = opening(id) { return x.name.isEmpty ? x.kind.rawValue.capitalized : x.name }
        if wall(id) != nil { return "Wall" }
        if dimension(id) != nil { return "Dimension" }
        if let x = material(id) { return x.name }
        if let x = definition(id) { return x.name }
        if let x = product(id) { return x.name }
        if let x = asset(id) { return x.originalName }
        if let x = savedCamera(id) { return x.name }
        if background(id) != nil { return "Background image" }
        return id.uuidString.lowercased()
    }

    /// Length of a wall axis in mm.
    func wallLength(_ w: Wall) -> Double { Geo.distance(w.start, w.end) }

    /// Elevation of a level (0 if unknown).
    func elevation(of levelId: UUID) -> MM { level(levelId)?.elevation ?? 0 }

    /// All ids in the project (for uniqueness checks).
    var allIds: [UUID] {
        levels.map(\.id) + walls.map(\.id) + rooms.map(\.id) + openings.map(\.id) + dimensions.map(\.id)
            + materials.map(\.id) + definitions.map(\.id) + instances.map(\.id) + groups.map(\.id)
            + products.map(\.id) + assets.map(\.id) + backgrounds.map(\.id) + cameras.map(\.id)
    }
}
