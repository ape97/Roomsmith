import Foundation

// Telling furniture designs apart from their copies. Agents and imports create a fresh design for every replaced model
// or every paste; these helpers recognise an identical one (so it can be reused) and fold same-named ones in the list.

public extension FurnitureDefinition {
    /// A position-based id: the same slot gives the same id in every design, whatever the real ids are.
    private static func slot(_ kind: UInt8, _ index: Int) -> UUID {
        UUID(uuid: (kind, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8((index >> 16) & 0xff), UInt8((index >> 8) & 0xff), UInt8(index & 0xff), 0))
    }

    /// The design with every id (design, parts, states, animations, lamps, option groups and choices, and the references
    /// between them) replaced by one derived from its position in its list, and the revision cleared. Two designs that
    /// look and behave the same have equal normalized forms, whatever their ids. Material and asset ids are kept.
    func idNormalized() -> FurnitureDefinition {
        var d = self
        d.id = Self.slot(0, 0)
        d.rev = 0
        var comp: [UUID: UUID] = [:]
        for (i, c) in components.enumerated() { comp[c.id] = Self.slot(1, i); d.components[i].id = Self.slot(1, i) }
        var state: [UUID: UUID] = [:]
        for (i, s) in states.enumerated() { state[s.id] = Self.slot(2, i) }
        func poses<T>(_ p: [UUID: T]) -> [UUID: T] {
            Dictionary(p.map { (comp[$0.key] ?? $0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        }
        d.states = states.map { s in
            var n = s
            n.id = state[s.id] ?? s.id
            n.poses = poses(s.poses)
            return n
        }
        d.defaultStateId = defaultStateId.map { state[$0] ?? $0 }
        d.tracks = tracks.enumerated().map { i, t in
            var n = t
            n.id = Self.slot(3, i)
            n.fromStateId = t.fromStateId.map { state[$0] ?? $0 }
            n.toStateId = state[t.toStateId] ?? t.toStateId
            n.keyframes = t.keyframes.map { AnimationTrack.Keyframe(t: $0.t, poses: poses($0.poses)) }
            return n
        }
        d.lights = lights.enumerated().map { i, l in
            var n = l
            n.id = Self.slot(4, i)
            return n
        }
        d.optionGroups = optionGroups.enumerated().map { gi, g in
            var choice: [UUID: UUID] = [:]
            for (ci, c) in g.choices.enumerated() { choice[c.id] = Self.slot(6, gi * 64 + ci) }
            var n = g
            n.id = Self.slot(5, gi)
            n.defaultChoiceId = g.defaultChoiceId.map { choice[$0] ?? $0 }
            n.choices = g.choices.map { c in
                var nc = c
                nc.id = choice[c.id] ?? c.id
                nc.effects = poses(c.effects)
                return nc
            }
            return n
        }
        return d
    }

    /// True when `other` is the same design under another id: same name, category, size, parts, states, animations, lamps,
    /// options, tags and product link. Built-in designs only equal built-in ones.
    func isSameDesign(as other: FurnitureDefinition) -> Bool {
        idNormalized() == other.idNormalized()
    }
}

/// One row of the project's own furniture list: a design name shown once.
public struct ListedDefinition: Identifiable, Equatable, Sendable {
    /// The design the row stands for (see `Project.listedOwnDefinitions`).
    public var definition: FurnitureDefinition
    /// Pieces placed from `definition`.
    public var placedCount: Int
    /// Designs of the project with this name, `definition` included (1 = no copies).
    public var copies: Int
    public var id: UUID { definition.id }
}

public extension Project {
    /// Pieces placed per design id.
    func placedCounts() -> [UUID: Int] {
        instances.reduce(into: [:]) { $0[$1.definitionId, default: 0] += 1 }
    }

    /// The project's own (not built-in) designs with every name once, in order of the first design of that name.
    /// Rule: designs whose names are equal (case and surrounding spaces ignored) are one row; the row stands for the design
    /// with the most placed pieces, a tie goes to the one created last (the newest model). Nothing is deleted or changed;
    /// `copies` says how many designs the row folds.
    func listedOwnDefinitions() -> [ListedDefinition] {
        let counts = placedCounts()
        var order: [String] = []
        var groups: [String: [FurnitureDefinition]] = [:]
        for d in definitions where !d.builtin {
            let key = d.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(d)
        }
        return order.compactMap { key in
            guard let members = groups[key] else { return nil }
            var best = members[0]
            for m in members.dropFirst() where (counts[m.id] ?? 0) >= (counts[best.id] ?? 0) { best = m }
            return ListedDefinition(definition: best, placedCount: counts[best.id] ?? 0, copies: members.count)
        }
    }

    /// Own designs no piece is placed from. Includes ones a product points at; see `prunableDefinitions`.
    func unusedDefinitions() -> [FurnitureDefinition] {
        let used = Set(instances.map(\.definitionId))
        return definitions.filter { !$0.builtin && !used.contains($0.id) }
    }

    /// Unused own designs that "remove unused" may delete: no piece is placed from them and no product is linked to them
    /// (a design saved as a planned item stays until it is deleted by hand).
    func prunableDefinitions() -> [FurnitureDefinition] {
        let linked = Set(products.compactMap(\.definitionId))
        return unusedDefinitions().filter { $0.productId == nil && !linked.contains($0.id) }
    }

    /// Designs with the same name as `name` (case and surrounding spaces ignored), for hints after a create.
    func definitions(named name: String) -> [FurnitureDefinition] {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return definitions.filter { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key }
    }

    /// The project's own design identical to `d` (see `FurnitureDefinition.isSameDesign`), if any. Built-in designs are
    /// not candidates (they are reused by catalog key).
    func ownTwin(of d: FurnitureDefinition) -> FurnitureDefinition? {
        let wanted = d.idNormalized()
        return definitions.first { !$0.builtin && $0.id != d.id && $0.idNormalized() == wanted }
    }
}
