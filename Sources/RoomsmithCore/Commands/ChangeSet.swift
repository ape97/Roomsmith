import Foundation

/// Who caused a change.
public enum ChangeOrigin: Codable, Sendable, Hashable, CustomStringConvertible {
    case user
    case agent(String)
    case system

    public var isAgent: Bool { if case .agent = self { return true } else { return false } }
    public var description: String {
        switch self {
        case .user: "user"
        case .agent(let id): "agent:\(id)"
        case .system: "system"
        }
    }
}

public enum ChangeOp: String, Codable, Sendable { case added, modified, removed }

public struct ObjectChange: Codable, Sendable, Hashable {
    public var id: UUID
    public var kind: ObjectKind
    public var op: ChangeOp
    public init(id: UUID, kind: ObjectKind, op: ChangeOp) { self.id = id; self.kind = kind; self.op = op }
}

/// Difference between two project states, computed by `ChangeSet.diff`.
public struct ChangeSet: Codable, Sendable, Equatable {
    public var objects: [ObjectChange] = []
    public var settingsChanged = false
    public var cameraChanged = false
    /// Name or other project-level fields.
    public var metaChanged = false
    public init() {}

    public var isEmpty: Bool { objects.isEmpty && !settingsChanged && !cameraChanged && !metaChanged }
    public var touchedIds: Set<UUID> { Set(objects.map(\.id)) }
    public func ids(_ kind: ObjectKind, _ ops: Set<ChangeOp> = [.added, .modified, .removed]) -> [UUID] {
        objects.filter { $0.kind == kind && ops.contains($0.op) }.map(\.id)
    }
    public func contains(kind: ObjectKind) -> Bool { objects.contains { $0.kind == kind } }
    public mutating func merge(_ o: ChangeSet) {
        objects += o.objects
        settingsChanged = settingsChanged || o.settingsChanged
        cameraChanged = cameraChanged || o.cameraChanged
        metaChanged = metaChanged || o.metaChanged
    }

    /// Computes the changes from `old` to `new` and stamps every added/modified object in `new` with `stamp`.
    /// Unchanged collections cost O(1) (arrays sharing storage compare by identity first).
    public static func diff(from old: Project, to new: inout Project, stamp: Int64) -> ChangeSet {
        var cs = ChangeSet()
        diffList(old.levels, &new.levels, .level, stamp, &cs)
        diffList(old.walls, &new.walls, .wall, stamp, &cs)
        diffList(old.rooms, &new.rooms, .room, stamp, &cs)
        diffList(old.openings, &new.openings, .opening, stamp, &cs)
        diffList(old.dimensions, &new.dimensions, .dimension, stamp, &cs)
        diffList(old.materials, &new.materials, .material, stamp, &cs)
        diffList(old.definitions, &new.definitions, .definition, stamp, &cs)
        diffList(old.instances, &new.instances, .furniture, stamp, &cs)
        diffList(old.groups, &new.groups, .group, stamp, &cs)
        diffList(old.products, &new.products, .product, stamp, &cs)
        diffList(old.assets, &new.assets, .asset, stamp, &cs)
        diffList(old.backgrounds, &new.backgrounds, .background, stamp, &cs)
        diffList(old.cameras, &new.cameras, .camera, stamp, &cs)
        cs.settingsChanged = old.settings != new.settings
        cs.cameraChanged = old.camera != new.camera
        cs.metaChanged = old.name != new.name || old.id != new.id
        return cs
    }

    private static func diffList<T: Revisioned>(_ old: [T], _ new: inout [T], _ kind: ObjectKind, _ stamp: Int64, _ cs: inout ChangeSet) {
        if old == new { return }
        var oldIndex = [UUID: Int](minimumCapacity: old.count)
        for (i, o) in old.enumerated() { oldIndex[o.id] = i }
        var seen = Set<UUID>(minimumCapacity: new.count)
        for i in new.indices {
            let id = new[i].id
            seen.insert(id)
            if let oi = oldIndex[id] {
                var candidate = new[i]
                candidate.rev = old[oi].rev
                if candidate != old[oi] {
                    new[i].rev = stamp
                    cs.objects.append(ObjectChange(id: id, kind: kind, op: .modified))
                } else if new[i].rev != old[oi].rev {
                    new[i].rev = old[oi].rev // only the rev differed: keep the committed rev
                }
            } else {
                new[i].rev = stamp
                cs.objects.append(ObjectChange(id: id, kind: kind, op: .added))
            }
        }
        for o in old where !seen.contains(o.id) {
            cs.objects.append(ObjectChange(id: o.id, kind: kind, op: .removed))
        }
    }
}

/// Document objects with a stable id and a per-object revision.
public protocol Revisioned: Identifiable, Equatable where ID == UUID {
    var rev: Int64 { get set }
}

extension Level: Revisioned {}
extension Wall: Revisioned {}
extension Room: Revisioned {}
extension Opening: Revisioned {}
extension Dimension: Revisioned {}
extension Material: Revisioned {}
extension FurnitureDefinition: Revisioned {}
extension FurnitureInstance: Revisioned {}
extension FurnitureGroup: Revisioned {}
extension CatalogProduct: Revisioned {}
extension ProjectAsset: Revisioned {}
extension BackgroundImage: Revisioned {}
extension SavedCamera: Revisioned {}
