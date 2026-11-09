import Foundation

/// Remembers what an AI agent added while the app was open, so the UI can show a "New" badge until the user looks at it.
/// Runtime only: nothing here is saved to the project or the library, and it never marks a document as edited.
public struct NewItemTracker: Equatable, Sendable {
    public private(set) var ids: Set<UUID> = []
    public init() {}

    public var isEmpty: Bool { ids.isEmpty }
    public func contains(_ id: UUID) -> Bool { ids.contains(id) }

    /// Marks everything in `after` that was not in `before`, but only for changes made by an agent.
    public mutating func noteAdded(before: Set<UUID>, after: Set<UUID>, origin: ChangeOrigin) {
        guard origin.isAgent else { return }
        ids.formUnion(after.subtracting(before))
    }

    /// Marks the given ids as new when `origin` is an agent.
    public mutating func noteAdded(_ added: [UUID], origin: ChangeOrigin) {
        guard origin.isAgent else { return }
        ids.formUnion(added)
    }

    /// Reads one document change event. Only a new command by an agent marks objects; undo and redo (by anyone) never
    /// mark anything, removed objects lose their badge, and opening another project clears all.
    public mutating func apply(_ event: ChangeEvent) {
        if event.kind == .reset { ids.removeAll(); return }
        if ids.isEmpty && event.kind != .command { return }
        let removed = event.changes.objects.filter { $0.op == .removed }.map(\.id)
        if !removed.isEmpty { ids.subtract(removed) }
        guard event.kind == .command, event.origin.isAgent else { return }
        let added = event.changes.objects.filter { $0.op == .added && Self.listedKinds.contains($0.kind) }.map(\.id)
        ids.formUnion(added)
    }

    /// The user looked at these (selected a row, clicked a tile).
    public mutating func markSeen(_ seen: some Collection<UUID>) {
        guard !ids.isEmpty else { return }
        ids.subtract(seen)
    }

    /// Forgets ids that no longer exist.
    public mutating func prune(existing: Set<UUID>) {
        guard !ids.isEmpty else { return }
        ids.formIntersection(existing)
    }

    public mutating func removeAll() { ids.removeAll() }

    /// Object kinds that have a row in the object list.
    static let listedKinds: Set<ObjectKind> = [.wall, .room, .opening, .dimension, .furniture, .group]
}

public extension Project {
    /// Ids of every object that has a row in the sidebar object list (walls, openings, rooms, furniture incl. lamps, groups, dimensions).
    var listedObjectIds: Set<UUID> {
        Set(walls.map(\.id) + openings.map(\.id) + rooms.map(\.id) + instances.map(\.id) + groups.map(\.id) + dimensions.map(\.id))
    }
}
