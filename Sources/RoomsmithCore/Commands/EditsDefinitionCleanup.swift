import Foundation

/// What `Project.replaceDefinition` did.
public struct DefinitionReplacement: Equatable, Sendable {
    /// Placed pieces that now use the new design.
    public var instanceIds: [UUID]
    /// Old designs that were removed because nothing uses them any more.
    public var removedDefinitionIds: [UUID]
    /// Old designs that stayed (built-in or linked to a product).
    public var keptDefinitionIds: [UUID]
}

public extension Project {
    /// Deletes own furniture designs that no placed piece uses. All or nothing: a built-in design, a design with placed
    /// pieces or an unknown id makes the whole call fail with every problem named, and nothing changes. A product linked to
    /// a deleted design stays (its link is cleared, like `deleteUnusedCatalogEntry`). Returns the deleted ids.
    @discardableResult
    mutating func deleteDefinitions(_ ids: [UUID]) throws -> [UUID] {
        var seen = Set<UUID>()
        let unique = ids.filter { seen.insert($0).inserted }
        let counts = placedCounts()
        var problems: [String] = []
        var bad: [UUID] = []
        for id in unique {
            guard let d = definition(id) else {
                problems.append("\(id.uuidString.lowercased()): is not a furniture design"); bad.append(id); continue
            }
            if d.builtin { problems.append("'\(d.name)': built-in designs cannot be deleted"); bad.append(id) }
            else if let n = counts[id], n > 0 { problems.append("'\(d.name)': still used by \(n) placed piece(s)"); bad.append(id) }
        }
        if !problems.isEmpty { throw CommandError.invalid("Cannot delete: " + problems.joined(separator: "; "), ids: bad) }
        guard !unique.isEmpty else { return [] }
        return try deleteObjects(unique)
    }

    /// Deletes every design `prunableDefinitions()` lists (own, nothing placed, no product link). Returns the deleted ids;
    /// empty when there is nothing to remove.
    @discardableResult
    mutating func removeUnusedDefinitions() throws -> [UUID] {
        try deleteDefinitions(prunableDefinitions().map(\.id))
    }

    /// Switches every piece placed from one of the `fromIds` designs to the design `toId`, so a model can be swapped in one
    /// step. Per piece: position, size, rotation, name, lock, visibility and product stay; state, option choices and
    /// material overrides move to the new design's state, option group and part of the same name (case ignored), else
    /// to its default state or the design's own look; group configurations of the pieces follow. With `removeOld` the old
    /// designs are then deleted when they are own designs without a product link and no piece uses them any more. With `only`,
    /// just those pieces switch (each must be placed from one of `fromIds`). All or nothing; a locked piece fails the call.
    @discardableResult
    mutating func replaceDefinition(_ fromIds: [UUID], with toId: UUID, only: [UUID]? = nil, removeOld: Bool = true) throws -> DefinitionReplacement {
        guard let target = definition(toId) else { throw CommandError.notFound("Definition", toId) }
        var seen = Set<UUID>()
        let froms = fromIds.filter { seen.insert($0).inserted }
        guard !froms.isEmpty else { throw CommandError.invalid("Name at least one design to replace", ids: [toId]) }
        if froms.contains(toId) { throw CommandError.invalid("A design cannot replace itself", ids: [toId]) }
        for f in froms where definition(f) == nil { throw CommandError.notFound("Definition", f) }

        var maps: [UUID: DesignMaps] = [:]
        for f in froms { maps[f] = DesignMaps(from: definition(f)!, to: target) }
        if let only {
            for id in only where instance(id).map({ maps[$0.definitionId] == nil }) ?? true {
                throw CommandError.invalid("Piece \(id.uuidString.lowercased()) is not placed from a design to replace", ids: [id])
            }
        }
        let moving = instances.filter { maps[$0.definitionId] != nil && (only?.contains($0.id) ?? true) }
        for i in moving { try ensureEditable(i.id) }
        var memberMaps: [UUID: DesignMaps] = [:]
        for i in moving { memberMaps[i.id] = maps[i.definitionId] }

        for i in moving {
            let m = memberMaps[i.id]!
            try updateInstance(i.id) { inst in
                inst.definitionId = toId
                inst.stateId = inst.stateId.flatMap { m.states[$0] ?? target.defaultStateId }
                inst.materialOverrides = m.remapMaterials(inst.materialOverrides)
                inst.optionSelection = m.remapOptions(inst.optionSelection)
            }
        }
        for g in groups.indices where groups[g].memberIds.contains(where: { memberMaps[$0] != nil }) {
            for c in groups[g].configurations.indices {
                for (member, var pose) in groups[g].configurations[c].poses {
                    guard let m = memberMaps[member] else { continue }
                    pose.stateId = pose.stateId.flatMap { m.states[$0] ?? target.defaultStateId }
                    pose.materialOverrides = pose.materialOverrides.map(m.remapMaterials)
                    groups[g].configurations[c].poses[member] = pose
                }
            }
        }

        var removed: [UUID] = [], kept: [UUID] = []
        let linked = Set(products.compactMap(\.definitionId))
        for f in froms {
            guard let d = definition(f) else { continue }
            let free = !d.builtin && d.productId == nil && !linked.contains(f) && !instances.contains { $0.definitionId == f }
            if removeOld, free { removed.append(f) } else { kept.append(f) }
        }
        if !removed.isEmpty { try deleteObjects(removed) }
        return DefinitionReplacement(instanceIds: moving.map(\.id), removedDefinitionIds: removed, keptDefinitionIds: kept)
    }
}

/// Which state, part and option of one design stands for which of another: same name (case and surrounding spaces ignored),
/// each target entry used once, in list order.
private struct DesignMaps {
    var states: [UUID: UUID] = [:]
    var components: [UUID: UUID] = [:]
    var optionGroups: [UUID: UUID] = [:]
    var optionChoices: [UUID: UUID] = [:]

    init(from old: FurnitureDefinition, to new: FurnitureDefinition) {
        func key(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        func pair<T>(_ a: [T], _ b: [T], id: (T) -> UUID, name: (T) -> String) -> [UUID: UUID] {
            var free = Array(b.enumerated())
            var out: [UUID: UUID] = [:]
            for x in a {
                guard let at = free.firstIndex(where: { key(name($0.element)) == key(name(x)) }) else { continue }
                out[id(x)] = id(free[at].element)
                free.remove(at: at)
            }
            return out
        }
        states = pair(old.states, new.states, id: { $0.id }, name: { $0.name })
        components = pair(old.components, new.components, id: { $0.id }, name: { $0.name })
        optionGroups = pair(old.optionGroups, new.optionGroups, id: { $0.id }, name: { $0.name })
        for og in old.optionGroups {
            guard let ng = optionGroups[og.id].flatMap({ id in new.optionGroups.first { $0.id == id } }) else { continue }
            optionChoices.merge(pair(og.choices, ng.choices, id: { $0.id }, name: { $0.name }), uniquingKeysWith: { a, _ in a })
        }
    }

    func remapMaterials(_ overrides: [UUID: UUID]) -> [UUID: UUID] {
        Dictionary(overrides.compactMap { k, v in components[k].map { ($0, v) } }, uniquingKeysWith: { a, _ in a })
    }

    func remapOptions(_ selection: [UUID: UUID]) -> [UUID: UUID] {
        Dictionary(selection.compactMap { g, c in
            guard let ng = optionGroups[g], let nc = optionChoices[c] else { return nil }
            return (ng, nc)
        }, uniquingKeysWith: { a, _ in a })
    }
}
