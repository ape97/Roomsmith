import Foundation

/// Building library entries from project furniture and putting entries back into a project.
public enum LibraryContent {
    /// Packs furniture (instances or groups) of `project`. `packageURL` is needed when models or textures travel along.
    public static func pack(project: Project, ids: [UUID], packageURL: URL?) throws -> FurnitureTransfer {
        try FurnitureTransfer.make(from: project, ids: ids, packageURL: packageURL)
    }

    /// Packs a design on its own (no instance needed): it is placed once in a scratch copy of the project.
    public static func pack(project: Project, definitionId: UUID, packageURL: URL?) throws -> FurnitureTransfer {
        guard project.definition(definitionId) != nil else { throw CommandError.notFound("Definition", definitionId) }
        guard let level = project.levels.first else { throw CommandError.invalid("The project has no level") }
        var scratch = project
        let inst = try scratch.addInstance(definitionId: definitionId, levelId: level.id, position: P3(0, 0, 0))
        return try FurnitureTransfer.make(from: scratch, ids: [inst], packageURL: packageURL)
    }

    /// Overall size, material names, first design and a suggested name of packed furniture.
    public struct Summary: Sendable, Equatable {
        public var name: String
        public var size: Size3
        public var materialNames: [String]
        public var definitionId: UUID?
    }

    public static func summary(of t: FurnitureTransfer) -> Summary {
        func def(_ id: UUID) -> FurnitureDefinition? { t.definitions.first { $0.id == id } }
        var minX = Int64.max, maxX = Int64.min, minY = Int64.max, maxY = Int64.min, maxZ: Int64 = 1
        for i in t.instances {
            let s = i.size ?? def(i.definitionId)?.size ?? Size3(1, 1, 1)
            // Rotation is ignored: the size is the axis-aligned footprint of the unrotated pieces.
            minX = min(minX, i.position.x - s.width / 2); maxX = max(maxX, i.position.x + (s.width + 1) / 2)
            minY = min(minY, i.position.y - s.depth / 2); maxY = max(maxY, i.position.y + (s.depth + 1) / 2)
            maxZ = max(maxZ, i.position.z + s.height)
        }
        let size = t.instances.isEmpty ? Size3(1, 1, 1) : Size3(max(1, maxX - minX), max(1, maxY - minY), maxZ)
        var names: [String] = []
        func note(_ id: UUID?) {
            guard let id else { return }
            let n = t.materials.first { $0.id == id }?.name ?? BuiltinCatalog.materials.first { $0.id == id }?.name
            if let n, !names.contains(n) { names.append(n) }
        }
        for d in t.definitions { for c in d.components { note(c.materialId) } }
        for d in t.definitions { for g in d.optionGroups { for ch in g.choices { for e in ch.effects.values { note(e.materialId) } } } }
        for i in t.instances { for m in i.materialOverrides.values { note(m) } }
        let first = t.instances.first
        let name: String
        if t.instances.count == 1, let f = first { name = f.name }
        else if let f = first { name = "\(f.name) and \(t.instances.count - 1) more" }
        else { name = "Furniture" }
        return Summary(name: name, size: size, materialNames: names, definitionId: first?.definitionId)
    }

    /// Entry metadata for packed furniture; the caller stores it with `LibraryStore.add`.
    public static func makeEntry(from t: FurnitureTransfer, section: LibrarySection = .own, name: String? = nil, description: String = "",
                                 tags: [String] = [], status: PurchaseStatus? = nil, spec: ParametricSpec? = nil,
                                 categoryId: UUID? = nil) -> LibraryEntry {
        let s = summary(of: t)
        let st = status ?? (section == .planned ? .idea : nil)
        return LibraryEntry(section: section, name: name ?? s.name, description: description, size: s.size, materialNames: s.materialNames,
                            tags: tags, status: st, definitionId: s.definitionId, spec: spec, categoryId: categoryId)
    }

    /// Saves furniture (instances or groups) of `project` as a new entry of `store`, optionally into a category.
    /// This is what dropping scene objects onto a category header and "Save to My Furniture" do.
    @discardableResult
    public static func save(project: Project, ids: [UUID], packageURL: URL?, into store: LibraryStore, categoryId: UUID? = nil,
                            section: LibrarySection = .own) throws -> LibraryEntry {
        let kept = ids.filter { project.instance($0) != nil || project.group($0) != nil }
        guard !kept.isEmpty else { throw LibraryError.invalid("Select furniture first") }
        let t = try pack(project: project, ids: kept, packageURL: packageURL)
        return try store.add(makeEntry(from: t, section: section, categoryId: categoryId), transfer: t)
    }

    /// The furniture of a built-in piece as a transfer (the piece is placed once in an empty scratch project), so a
    /// placeholder can be copied into the library and edited there.
    public static func transfer(fromCatalog key: String) throws -> FurnitureTransfer {
        var scratch = Project.empty(name: "Catalog")
        guard let level = scratch.levels.first else { throw CommandError.invalid("The project has no level") }
        let inst = try scratch.placeDragged(.catalog(key), levelId: level.id, at: P2(0, 0))
        return try pack(project: scratch, ids: [inst], packageURL: nil)
    }
}

/// Puts a library entry into an open project.
@MainActor
public enum LibraryPlacement {
    /// Imports the entry's furniture as one command (one undo step) with fresh ids everywhere, its middle at `at`.
    /// The library itself stays unchanged. With `restOnFurniture` a single piece dropped over a table (or shelf) stands on it.
    @discardableResult
    public static func place(_ entryId: UUID, from library: LibraryStore, into target: DocumentStore, targetPackage: URL?, levelId: UUID,
                             at: P2, options: CommandOptions = .user, restOnFurniture: Bool = false) throws -> [UUID] {
        let t = try library.transfer(for: entryId)
        var offset = P2(0, 0)
        if let c = t.center { offset = P2(at.x - c.x, at.y - c.y) }
        return try FurnitureTransferService.importTransfer(t, into: target, targetPackage: targetPackage, levelId: levelId,
                                                           offset: offset, options: options, undoName: "Place from library",
                                                           restOnFurniture: restOnFurniture)
    }
}
