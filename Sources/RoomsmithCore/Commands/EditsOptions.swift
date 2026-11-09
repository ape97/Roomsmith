import Foundation

/// Furniture options (variants): define and delete option groups of a design, and choose per placed piece.
public extension Project {
    // MARK: Option groups

    /// Adds an option group, or replaces the one with the same id or (case-insensitive) name. A replaced group keeps its
    /// id; an incoming choice with a new id but the name of an old choice keeps the old id, so selections survive a
    /// re-definition. Selections of choices that no longer exist are dropped. Returns the group id.
    @discardableResult
    mutating func defineOptionGroup(definitionId: UUID, _ group: OptionGroup) throws -> UUID {
        guard let def = definition(definitionId) else { throw CommandError.notFound("Definition", definitionId) }
        let existing = def.optionGroups.first { $0.id == group.id || $0.name.caseInsensitiveCompare(group.name) == .orderedSame }
        var g = group
        if let existing {
            g.id = existing.id
            let oldIds = Set(existing.choices.map(\.id))
            var remap = [UUID: UUID]()
            for i in g.choices.indices where !oldIds.contains(g.choices[i].id) {
                if let old = existing.choices.first(where: { $0.name.caseInsensitiveCompare(g.choices[i].name) == .orderedSame }),
                   !g.choices.contains(where: { $0.id == old.id }) {
                    remap[g.choices[i].id] = old.id
                    g.choices[i].id = old.id
                }
            }
            if let d = g.defaultChoiceId, let m = remap[d] { g.defaultChoiceId = m }
        }
        let gid = g.id
        try modify(\.definitions, definitionId, "Definition") { d in
            if let i = d.optionGroups.firstIndex(where: { $0.id == gid }) { d.optionGroups[i] = g } else { d.optionGroups.append(g) }
        }
        pruneOptionSelections(definitionId: definitionId)
        return gid
    }

    /// Removes an option group; placed pieces forget their choice in it.
    mutating func deleteOptionGroup(definitionId: UUID, groupId: UUID) throws {
        guard let d = definition(definitionId) else { throw CommandError.notFound("Definition", definitionId) }
        guard d.optionGroups.contains(where: { $0.id == groupId }) else { throw CommandError.notFound("Option group", groupId) }
        try modify(\.definitions, definitionId, "Definition") { $0.optionGroups.removeAll { $0.id == groupId } }
        pruneOptionSelections(definitionId: definitionId)
    }

    // MARK: Selection

    /// Selects choices (group id → choice id) on placed pieces; `reset` returns groups to their default choice. The
    /// pieces' own material overrides of the parts a touched group colours are cleared, so the chosen option shows.
    /// All pieces must be furniture whose design has the groups; any miss rejects the whole call.
    mutating func setOptions(_ instanceIds: [UUID], select: [UUID: UUID], reset: [UUID] = []) throws {
        for id in instanceIds {
            try ensureEditable(id)
            guard let inst = instance(id) else { throw CommandError.notFound("Furniture", id) }
            guard let def = definition(inst.definitionId) else { throw CommandError.notFound("Definition", inst.definitionId) }
            var touched: [OptionGroup] = []
            for gid in Array(select.keys) + reset {
                guard let g = def.optionGroups.first(where: { $0.id == gid }) else {
                    throw CommandError(.notFound, "Option group \(gid.uuidString.lowercased()) does not exist for this furniture", ids: [id])
                }
                touched.append(g)
            }
            for (gid, cid) in select {
                guard let g = def.optionGroups.first(where: { $0.id == gid }), g.choices.contains(where: { $0.id == cid }) else {
                    throw CommandError(.notFound, "Option choice \(cid.uuidString.lowercased()) does not exist in that group", ids: [id])
                }
            }
            try modify(\.instances, id, "Furniture") { i in
                for (gid, cid) in select { i.optionSelection[gid] = cid }
                for gid in reset { i.optionSelection[gid] = nil }
                for g in touched { for cid in g.materialComponentIds { i.materialOverrides[cid] = nil } }
            }
        }
    }

    // MARK: Cleanup

    /// Drops option data that points at parts or materials that no longer exist; repairs a default that is gone.
    /// Called by `updateDefinition`, which every part or state change goes through.
    internal mutating func pruneOptionGroups(definitionId: UUID) {
        guard let di = definitions.firstIndex(where: { $0.id == definitionId }), !definitions[di].optionGroups.isEmpty else { return }
        let cids = Set(definitions[di].components.map(\.id))
        let mids = Set(materials.map(\.id))
        for gi in definitions[di].optionGroups.indices {
            for ci in definitions[di].optionGroups[gi].choices.indices {
                var effects = definitions[di].optionGroups[gi].choices[ci].effects
                for (k, var e) in effects {
                    if !cids.contains(k) { effects[k] = nil; continue }
                    if let m = e.materialId, !mids.contains(m) { e.materialId = nil }
                    effects[k] = e.isEmpty ? nil : e
                }
                definitions[di].optionGroups[gi].choices[ci].effects = effects
            }
            let g = definitions[di].optionGroups[gi]
            if let d = g.defaultChoiceId, !g.choices.contains(where: { $0.id == d }) { definitions[di].optionGroups[gi].defaultChoiceId = nil }
        }
        pruneOptionSelections(definitionId: definitionId)
    }

    /// Removes selections of placed pieces that name a group or choice the design no longer has.
    internal mutating func pruneOptionSelections(definitionId: UUID) {
        guard let d = definition(definitionId) else { return }
        let choices = Dictionary(uniqueKeysWithValues: d.optionGroups.map { ($0.id, Set($0.choices.map(\.id))) })
        for i in instances.indices where instances[i].definitionId == definitionId && !instances[i].optionSelection.isEmpty {
            instances[i].optionSelection = instances[i].optionSelection.filter { choices[$0.key]?.contains($0.value) == true }
        }
    }

    /// Drops a deleted material from every option effect.
    internal mutating func pruneOptionMaterial(_ materialId: UUID) {
        for di in definitions.indices {
            for gi in definitions[di].optionGroups.indices {
                for ci in definitions[di].optionGroups[gi].choices.indices {
                    var effects = definitions[di].optionGroups[gi].choices[ci].effects
                    for (k, var e) in effects where e.materialId == materialId {
                        e.materialId = nil
                        effects[k] = e.isEmpty ? nil : e
                    }
                    definitions[di].optionGroups[gi].choices[ci].effects = effects
                }
            }
        }
    }
}
