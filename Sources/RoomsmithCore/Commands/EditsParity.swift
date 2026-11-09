import Foundation

/// Edits added for agent/UI parity: renaming any named object, aligning, state/animation/configuration upkeep and
/// reference lookups that guard deletion.
public enum AlignEdge: String, CaseIterable, Sendable {
    case left, right, top, bottom, centerX, centerY
}

/// One place that still points at an object someone wants to delete.
public struct ObjectReference: Equatable, Sendable {
    public var id: UUID
    public var kind: ObjectKind
    public var name: String
    /// What the reference is, e.g. "wall left material".
    public var role: String
}

public extension Project {
    // MARK: Rename

    /// Renames any object that has a name: level, room, opening, furniture, group, material, definition, product,
    /// saved camera. Walls, dimensions, backgrounds and assets have no name.
    mutating func renameObject(_ id: UUID, to raw: String) throws {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { throw CommandError.invalid("Name must not be empty", ids: [id]) }
        try ensureEditable(id)
        switch kind(of: id) {
        case .level: try modify(\.levels, id, "Level") { $0.name = name }
        case .room: try modify(\.rooms, id, "Room") { $0.name = name }
        case .opening: try modify(\.openings, id, "Opening") { $0.name = name }
        case .furniture: try modify(\.instances, id, "Furniture") { $0.name = name }
        case .group: try modify(\.groups, id, "Group") { $0.name = name }
        case .material: try modify(\.materials, id, "Material") { $0.name = name }
        case .definition: try modify(\.definitions, id, "Definition") { $0.name = name }
        case .product: try modify(\.products, id, "Product") { $0.name = name }
        case .camera: try modify(\.cameras, id, "Camera") { $0.name = name }
        default: throw CommandError.invalid("This object has no name", ids: [id])
        }
    }

    // MARK: Align

    /// Objects that can be aligned: no members of a selected group, no openings, levels or backgrounds.
    func alignTargets(_ ids: [UUID]) -> [UUID] {
        let selected = Set(ids)
        var seen = Set<UUID>()
        return ids.filter { id in
            guard seen.insert(id).inserted else { return false }
            guard let k = kind(of: id), k != .opening, k != .level, k != .background else { return false }
            if let g = instance(id)?.groupId, selected.contains(g) { return false }
            return true
        }
    }

    /// Axis-aligned bounds of an object in plan coordinates (furniture by rotated footprint, groups by members).
    func alignBounds(_ id: UUID) -> (lo: P2, hi: P2)? {
        var pts: [P2] = []
        func add(_ i: FurnitureInstance) {
            guard let d = definition(i.definitionId) else { pts.append(i.position.xy); return }
            pts += FurnitureResolver.footprint(of: i, definition: d).corners.map { P2(rounding: $0) }
        }
        if let i = instance(id) { add(i) }
        else if let g = group(id) { for m in g.memberIds { if let i = instance(m) { add(i) } } }
        else { pts = referencePoints(id) }
        guard let f = pts.first else { return nil }
        var lo = f, hi = f
        for q in pts { lo = P2(min(lo.x, q.x), min(lo.y, q.y)); hi = P2(max(hi.x, q.x), max(hi.y, q.y)) }
        return (lo, hi)
    }

    /// Aligns objects to one edge (left = min x, right = max x, top = max y / north, bottom = min y) or to the centre of
    /// their common bounds. Centre targets are rounded half away from zero to whole mm. Needs at least two targets.
    /// Returns the ids that moved.
    @discardableResult
    mutating func alignObjects(_ ids: [UUID], edge: AlignEdge) throws -> [UUID] {
        for id in ids { try ensureEditable(id) }
        let items = alignTargets(ids).compactMap { id in alignBounds(id).map { (id, $0) } }
        guard items.count >= 2 else { throw CommandError.invalid("Aligning needs at least two alignable objects", ids: ids) }
        func half(_ twice: MM) -> MM { MM.saturatingRounded(Double(twice) / 2) }
        let minX = items.map { $0.1.lo.x }.min()!, maxX = items.map { $0.1.hi.x }.max()!
        let minY = items.map { $0.1.lo.y }.min()!, maxY = items.map { $0.1.hi.y }.max()!
        var moved: [UUID] = []
        for (id, b) in items {
            let d: P3
            switch edge {
            case .left: d = P3(minX - b.lo.x, 0, 0)
            case .right: d = P3(maxX - b.hi.x, 0, 0)
            case .top: d = P3(0, maxY - b.hi.y, 0)
            case .bottom: d = P3(0, minY - b.lo.y, 0)
            case .centerX: d = P3(half((minX + maxX) - (b.lo.x + b.hi.x)), 0, 0)
            case .centerY: d = P3(0, half((minY + maxY) - (b.lo.y + b.hi.y)), 0)
            }
            if d.x != 0 || d.y != 0 {
                try moveObjects([id], by: d)
                moved.append(id)
            }
        }
        return moved
    }

    // MARK: States and animation

    /// Removes a state with the tracks that start or end in it. A default state falls back to the first remaining one;
    /// instances in the state return to the default (see `updateDefinition`).
    mutating func deleteState(definitionId: UUID, stateId: UUID) throws {
        guard let d = definition(definitionId) else { throw CommandError.notFound("Definition", definitionId) }
        guard d.states.contains(where: { $0.id == stateId }) else { throw CommandError.notFound("State", stateId) }
        try updateDefinition(definitionId) { d in
            d.states.removeAll { $0.id == stateId }
            d.tracks.removeAll { $0.toStateId == stateId || $0.fromStateId == stateId }
            if d.defaultStateId == stateId { d.defaultStateId = d.states.first?.id }
        }
    }

    /// Sets the animation between two states (replaces an existing track with the same from/to).
    /// `from == nil` means from any state.
    @discardableResult
    mutating func setAnimation(definitionId: UUID, from: UUID?, to: UUID, durationMs: Int = 800,
                               easing: Easing = .easeInOut) throws -> UUID {
        guard let d = definition(definitionId) else { throw CommandError.notFound("Definition", definitionId) }
        for s in [from, to].compactMap({ $0 }) where !d.states.contains(where: { $0.id == s }) {
            throw CommandError.notFound("State", s)
        }
        if let from, from == to { throw CommandError.invalid("An animation needs two different states", ids: [definitionId]) }
        return try addTrack(definitionId: definitionId,
                            AnimationTrack(fromStateId: from, toStateId: to, durationMs: durationMs, easing: easing))
    }

    // MARK: Group configurations

    mutating func renameConfiguration(groupId: UUID, configurationId: UUID, to raw: String) throws {
        let n = raw.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { throw CommandError.invalid("Configuration name must not be empty", ids: [groupId]) }
        try ensureEditable(groupId)
        guard let g = group(groupId) else { throw CommandError.notFound("Group", groupId) }
        guard g.configurations.contains(where: { $0.id == configurationId }) else { throw CommandError.notFound("Configuration", configurationId) }
        if g.configurations.contains(where: { $0.id != configurationId && $0.name.caseInsensitiveCompare(n) == .orderedSame }) {
            throw CommandError.invalid("A configuration named “\(n)” already exists", ids: [groupId])
        }
        try modify(\.groups, groupId, "Group") { gr in
            if let k = gr.configurations.firstIndex(where: { $0.id == configurationId }) { gr.configurations[k].name = n }
        }
    }

    /// Copies a configuration as "<name> copy" (counter from 2 on a clash). Returns the new id.
    @discardableResult
    mutating func duplicateConfiguration(groupId: UUID, configurationId: UUID) throws -> UUID {
        try ensureEditable(groupId)
        guard let g = group(groupId) else { throw CommandError.notFound("Group", groupId) }
        guard let c = g.configurations.first(where: { $0.id == configurationId }) else { throw CommandError.notFound("Configuration", configurationId) }
        var name = "\(c.name) copy", k = 2
        while g.configurations.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { name = "\(c.name) copy \(k)"; k += 1 }
        let copy = GroupConfiguration(name: name, poses: c.poses)
        try modify(\.groups, groupId, "Group") { $0.configurations.append(copy) }
        return copy.id
    }

    // MARK: References

    /// The ids a delete of `ids` takes with it, transitively: members of deleted groups, everything on deleted levels
    /// (walls, rooms, furniture, groups, dimensions, backgrounds) and the openings of deleted walls. Includes `ids`.
    /// References from these objects do not block deleting what they point at.
    func deletionSet(_ ids: [UUID]) -> Set<UUID> {
        var out = Set<UUID>()
        var queue = ids
        while let id = queue.popLast() {
            guard out.insert(id).inserted else { continue }
            switch kind(of: id) {
            case .group: queue += group(id)?.memberIds ?? []
            case .wall: queue += openings.filter { $0.wallId == id }.map(\.id)
            case .level:
                queue += walls.filter { $0.levelId == id }.map(\.id) + rooms.filter { $0.levelId == id }.map(\.id)
                    + instances.filter { $0.levelId == id }.map(\.id) + groups.filter { $0.levelId == id }.map(\.id)
                    + dimensions.filter { $0.levelId == id }.map(\.id) + backgrounds.filter { $0.levelId == id }.map(\.id)
            default: break
            }
        }
        return out
    }

    /// Everything that still uses a material, product or furniture definition. Empty for other kinds.
    func references(to id: UUID) -> [ObjectReference] {
        var out: [ObjectReference] = []
        func add(_ ref: UUID, _ kind: ObjectKind, _ role: String) { out.append(ObjectReference(id: ref, kind: kind, name: displayName(of: ref), role: role)) }
        switch kind(of: id) {
        case .material:
            for w in walls {
                if w.leftMaterialId == id { add(w.id, .wall, "left material") }
                if w.rightMaterialId == id { add(w.id, .wall, "right material") }
            }
            for r in rooms {
                if r.floorMaterialId == id { add(r.id, .room, "floor material") }
                if r.ceilingMaterialId == id { add(r.id, .room, "ceiling material") }
            }
            for o in openings where o.frameMaterialId == id { add(o.id, .opening, "frame material") }
            for i in instances where i.materialOverrides.values.contains(id) { add(i.id, .furniture, "material override") }
            for g in groups where g.configurations.contains(where: { $0.poses.values.contains { $0.materialOverrides?.values.contains(id) == true } }) {
                add(g.id, .group, "configuration material override")
            }
            for d in definitions where d.components.contains(where: { $0.materialId == id }) { add(d.id, .definition, "component material") }
            for d in definitions where d.optionGroups.contains(where: { $0.choices.contains { $0.effects.values.contains { $0.materialId == id } } }) {
                add(d.id, .definition, "option material")
            }
        case .product:
            for i in instances where i.productId == id { add(i.id, .furniture, "product") }
            for g in groups where g.productId == id { add(g.id, .group, "product") }
            for d in definitions where d.productId == id { add(d.id, .definition, "product") }
        case .definition:
            for i in instances where i.definitionId == id { add(i.id, .furniture, "placed instance") }
        default: break
        }
        return out
    }
}
