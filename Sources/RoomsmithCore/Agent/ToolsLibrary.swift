import Foundation

/// Renders the thumbnail of a library entry. Implemented by the app (needs the 3D renderer); nil in contexts without a window.
@MainActor
public protocol AgentLibraryBridge: AnyObject {
    /// PNG of the stored furniture, `size` x `size` pixels. Does not touch any open project.
    func renderLibraryThumbnail(_ transfer: FurnitureTransfer, size: Int) async throws -> Data
}

// MARK: - library.*

/// The global furniture library (Own, Planned, AI) next to the built-in catalog. The library is a folder on disk, not part
/// of any project; only `library.place` changes the open project.
enum LibraryTools {
    static let thumbnailSizeRange: ClosedRange<Int64> = 32...1024
    static let defaultThumbnailSize = Int64(LibraryStore.thumbnailPixels)

    private static let sectionValues = LibrarySection.allCases.map(\.rawValue)
    private static let statusValues = PurchaseStatus.allCases.map(\.rawValue)

    @MainActor
    private static func store(_ env: ToolEnv) -> LibraryStore { LibraryStore(root: env.context.libraryRoot) }

    /// Maps library errors to agent errors.
    private static func run<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let e as LibraryError {
            switch e {
            case .notFound(let id): throw ToolError.notFound("Library entry", id)
            case .invalid(let m): throw ToolError.invalid(nil, m)
            case .io(let m): throw AgentError(code: AgentError.internal, message: m)
            }
        } catch let e as CommandError {
            throw AgentError(e)
        }
    }

    private static func entry(_ s: LibraryStore, _ id: UUID) throws -> LibraryEntry {
        guard let e = s.entry(id) else { throw ToolError.notFound("Library entry", id) }
        return e
    }

    static func row(_ e: LibraryEntry) -> [String: JSONValue] {
        var o: [String: JSONValue] = [
            "id": J.id(e.id), "section": .string(e.section.rawValue), "name": .string(e.name), "description": .string(e.description),
            "size": J.size(e.size), "materialNames": .array(e.materialNames.map { .string($0) }),
            "tags": .array(e.tags.map { .string($0) }), "rev": .int(e.rev),
        ]
        o["status"] = e.status.map { .string($0.rawValue) } ?? .null
        return o
    }

    /// `row` plus the category: `categoryId` is null for "Unsorted" (also when the stored id no longer names a category).
    static func row(_ e: LibraryEntry, in index: LibraryIndex) -> [String: JSONValue] {
        var o = row(e)
        o["categoryId"] = index.effectiveCategoryId(e).map(J.id) ?? .null
        return o
    }

    static func categoryRow(_ c: LibraryCategory, count: Int) -> [String: JSONValue] {
        ["id": J.id(c.id), "name": .string(c.name), "order": .int(Int64(c.order)), "entries": .int(Int64(count))]
    }

    /// The categories with their entry counts, in display order.
    static func categoryRows(_ index: LibraryIndex) -> JSONValue {
        .array(index.sortedCategories.map { c in
            .object(categoryRow(c, count: index.entries.filter { index.effectiveCategoryId($0) == c.id }.count))
        })
    }

    /// Reads `categoryId` of add/update: `.some(nil)` is an explicit null ("Unsorted"), nil means not given. The category must exist.
    private static func categoryArg(_ a: Args, _ index: LibraryIndex) throws -> UUID?? {
        if a.isNull("categoryId") { return .some(nil) }
        guard let id = try a.uuid("categoryId") else { return nil }
        guard index.category(id) != nil else { throw ToolError.invalid("categoryId", "unknown category \(id.uuidString.lowercased()); see library.list") }
        return .some(id)
    }

    @MainActor
    static func specs() -> [ToolSpec] {
        [list(), get(), addFromObject(), update(), delete(), place(), thumbnail()] + categorySpecs()
    }

    /// The category tools and `library.duplicate`; part of `specs()`.
    @MainActor
    static func categorySpecs() -> [ToolSpec] {
        [createCategory(), updateCategory(), deleteCategory(), duplicate()]
    }

    @MainActor
    static func list() -> ToolSpec {
        .read("library.list",
              "Lists the user's global furniture library (paginated): sections Own, Planned and AI. Rows carry id, section, name, description, size, materialNames, tags, status, rev and categoryId (null: Unsorted); `categories` lists the user's categories in display order. The Standard section is the built-in catalog (catalog.list_builtin). The library is shared by all projects.",
              ["query": S.str("Words that must all occur in name, description, section, status, tags or materials."),
               "section": S.str("Only this section.", values: sectionValues),
               "status": S.str("Only entries with this purchase status.", values: statusValues),
               "categoryId": S.uuid("Only entries of this category, or the string \"unsorted\" for entries without one."),
               "limit": S.limit, "cursor": S.cursor]) { env, a in
            let page = try PageRequest(a)
            let s = store(env)
            let load = s.load()
            let section = try a.enumValue("section", LibrarySection.self)
            let status = try a.enumValue("status", PurchaseStatus.self)
            var category = LibrarySearch.CategoryFilter.any
            if let raw = a.values["categoryId"], raw.stringValue?.lowercased() == "unsorted" { category = .unsorted }
            else if let id = try a.uuid("categoryId") {
                guard load.index.category(id) != nil else { throw ToolError.invalid("categoryId", "unknown category \(id.uuidString.lowercased())") }
                category = .category(id)
            }
            let hits = LibrarySearch.filter(load.index.entries, query: try a.string("query") ?? "", section: section, status: status,
                                            categories: load.index.categories, category: category)
            var counts: [String: JSONValue] = [:]
            for sec in LibrarySection.allCases { counts[sec.rawValue] = .int(Int64(load.index.entries.filter { $0.section == sec }.count)) }
            var extra: [String: JSONValue] = ["sectionCounts": .object(counts), "categories": categoryRows(load.index)]
            if let w = load.warning { extra["warning"] = .string(w) }
            let index = load.index
            return page.result(hits, revision: env.project.revision, { .object(row($0, in: index)) }, extra: extra)
        }
    }

    @MainActor
    static func get() -> ToolSpec {
        .read("library.get",
              "Returns one library entry with its parametric spec (when it was built with the furniture builder), photo file names and the designs inside (name, size).",
              ["id": S.uuid("Library entry id from library.list.")], required: ["id"]) { env, a in
            let s = store(env)
            let e = try entry(s, try a.requireUUID("id"))
            var o = row(e, in: s.load().index)
            o["definitionId"] = e.definitionId.map(J.id) ?? .null
            o["photoAssetNames"] = .array(e.photoAssetNames.map { .string($0) })
            o["createdAt"] = .string(ISO8601DateFormatter().string(from: e.createdAt))
            if let spec = e.spec, let data = try? JSONEncoder().encode(spec), let v = try? JSONDecoder().decode(JSONValue.self, from: data) {
                o["spec"] = v
            } else {
                o["spec"] = .null
            }
            let t = try run { try s.transfer(for: e.id) }
            o["definitions"] = .array(t.definitions.map { d in .object(["name": .string(d.name), "size": J.size(d.size)]) })
            o["pieces"] = .int(Int64(t.instances.count))
            return .object(o)
        }
    }

    @MainActor
    static func addFromObject() -> ToolSpec {
        .action("library.add_from_object",
                "Saves furniture of the active project into the global library as a new entry (designs, materials, products and models travel along; the project is not changed). Give `ids` (furniture instances or groups) or `definitionId` (a design on its own). Needs write access.",
                ["ids": S.uuids("Furniture instance ids (or group ids) of the active project."),
                 "definitionId": S.uuid("A design of the project instead of placed furniture."),
                 "section": S.str("Target section (default own).", values: sectionValues),
                 "name": S.str("Entry name (default: the furniture's name)."),
                 "description": S.str("Free text."),
                 "tags": S.arr("Search tags.", items: ["type": "string"]),
                 "status": S.str("Purchase status (planned entries default to idea).", values: statusValues),
                 "categoryId": S.uuid("Category from library.list (default: Unsorted).")]) { env, a in
            try env.requireWriteAccess("library.add_from_object changes the global library")
            let index = store(env).load().index
            let category = try categoryArg(a, index) ?? nil
            let p = env.project
            let packageURL = env.context.fileURL
            let t: FurnitureTransfer
            if let def = try a.uuid("definitionId") {
                if a.has("ids") { throw ToolError.invalid("ids", "cannot be combined with definitionId") }
                t = try run { try LibraryContent.pack(project: p, definitionId: def, packageURL: packageURL) }
            } else {
                let ids = try a.requireUUIDList("ids")
                try p.requireAll(ids)
                t = try run { try LibraryContent.pack(project: p, ids: ids, packageURL: packageURL) }
            }
            let section = try a.enumValue("section", LibrarySection.self) ?? .own
            let entry = LibraryContent.makeEntry(from: t, section: section, name: try a.nonEmptyString("name"),
                                                 description: try a.string("description") ?? "", tags: try a.stringList("tags") ?? [],
                                                 status: try a.enumValue("status", PurchaseStatus.self), categoryId: category)
            let saved = try run { try store(env).add(entry, transfer: t) }
            NotificationCenter.default.post(name: .roomsmithLibraryAgentAdded, object: saved.id)
            return .object(["entry": .object(row(saved, in: store(env).load().index))])
        }
    }

    @MainActor
    static func update() -> ToolSpec {
        .action("library.update",
                "Changes a library entry: name, description, tags, status (null clears it), section and category (`categoryId`, null moves it to Unsorted). With `fromObjectId` (a furniture instance or group of the active project) the stored furniture is replaced by that piece (its builder recipe is dropped) and the picture is rendered anew; without it the stored furniture stays. Needs write access.",
                ["id": S.uuid("Library entry id."), "name": S.str("New name."), "description": S.str("New description."),
                 "tags": S.arr("Replaces the tags.", items: ["type": "string"]),
                 "status": S.str("Purchase status, or null to clear.", values: statusValues),
                 "section": S.str("Move to this section.", values: sectionValues),
                 "categoryId": S.uuid("Move to this category from library.list, or null for Unsorted."),
                 "fromObjectId": S.uuid("Furniture instance or group of the active project that replaces the stored furniture.")],
                required: ["id"]) { env, a in
            try env.requireWriteAccess("library.update changes the global library")
            let s = store(env)
            let id = try a.requireUUID("id")
            _ = try entry(s, id)
            let name = try a.nonEmptyString("name"), text = try a.string("description"), tags = try a.stringList("tags")
            let section = try a.enumValue("section", LibrarySection.self)
            let status = try a.enumValue("status", PurchaseStatus.self)
            let clearStatus = a.isNull("status")
            let from = try a.uuid("fromObjectId")
            let category = try categoryArg(a, s.load().index)
            guard name != nil || text != nil || tags != nil || section != nil || status != nil || clearStatus || from != nil || category != nil else {
                throw ToolError.invalid(nil, "Give at least one field to change: name, description, tags, status, section, categoryId, fromObjectId")
            }
            var replacement: FurnitureTransfer?
            if let from {
                let p = env.project
                try p.requireAll([from])
                replacement = try run { try LibraryContent.pack(project: p, ids: [from], packageURL: env.context.fileURL) }
            }
            if let replacement { _ = try run { try s.replaceTransfer(id, with: replacement) } }
            let saved = try run {
                try s.update(id) { e in
                    if let name { e.name = name }
                    if let text { e.description = text }
                    if let tags { e.tags = tags }
                    if let section { e.section = section }
                    if let status { e.status = status } else if clearStatus { e.status = nil }
                    if let category { e.categoryId = category }
                }
            }
            return .object(["entry": .object(row(saved, in: s.load().index))])
        }
    }

    @MainActor
    static func createCategory() -> ToolSpec {
        .action("library.create_category",
                "Creates a category (a collapsible group of the My Furniture library) at the end of the list. The name must be unique, ignoring case. Needs write access.",
                ["name": S.str("Category name.")], required: ["name"]) { env, a in
            try env.requireWriteAccess("library.create_category changes the global library")
            let name = try a.requireNonEmptyString("name")
            let c = try run { try store(env).createCategory(name: name) }
            return .object(["category": .object(categoryRow(c, count: 0))])
        }
    }

    @MainActor
    static func updateCategory() -> ToolSpec {
        .action("library.update_category",
                "Renames a category and/or moves it in the list. `position` is the new place, 0 for first. Needs write access.",
                ["id": S.uuid("Category id from library.list."), "name": S.str("New name."),
                 "position": S.int("New place in the list, 0 is first (clamped to the end).")], required: ["id"]) { env, a in
            try env.requireWriteAccess("library.update_category changes the global library")
            let s = store(env)
            let id = try a.requireUUID("id")
            let name = try a.nonEmptyString("name"), position = try a.int("position")
            guard name != nil || position != nil else { throw ToolError.invalid(nil, "Give at least one field to change: name, position") }
            guard s.load().index.category(id) != nil else { throw ToolError.notFound("Library category", id) }
            if let position, position < 0 { throw ToolError.invalid("position", "must be 0 or more") }
            if let name { _ = try run { try s.renameCategory(id, to: name) } }
            if let position {
                var ids = s.categories().map(\.id)
                ids.removeAll { $0 == id }
                ids.insert(id, at: min(Int(position), ids.count))
                _ = try run { try s.reorderCategories(ids) }
            }
            return .object(["categories": categoryRows(s.load().index)])
        }
    }

    @MainActor
    static func deleteCategory() -> ToolSpec {
        .action("library.delete_category",
                "Deletes a category. Its entries move to `moveTo` (another category) or, without it, to Unsorted; no entry is deleted. Cannot be undone. Needs write access.",
                ["id": S.uuid("Category id."), "moveTo": S.uuid("Another existing category that takes over the entries.")],
                required: ["id"]) { env, a in
            try env.requireWriteAccess("library.delete_category changes the global library")
            let s = store(env)
            let id = try a.requireUUID("id")
            let moveTo = try a.uuid("moveTo")
            guard let c = s.load().index.category(id) else { throw ToolError.notFound("Library category", id) }
            try run { try s.deleteCategory(id, moveTo: moveTo) }
            return .object(["deleted": J.id(id), "name": .string(c.name), "categories": categoryRows(s.load().index)])
        }
    }

    @MainActor
    static func duplicate() -> ToolSpec {
        .action("library.duplicate",
                "Copies a library entry as \"<name> 2\" (next free number) in the same category: own furniture file and thumbnail, revision 1. Needs write access.",
                ["id": S.uuid("Library entry id.")], required: ["id"]) { env, a in
            try env.requireWriteAccess("library.duplicate changes the global library")
            let s = store(env)
            let e = try entry(s, try a.requireUUID("id"))
            let copy = try run { try s.duplicate(e.id) }
            NotificationCenter.default.post(name: .roomsmithLibraryAgentAdded, object: copy.id)
            return .object(["entry": .object(row(copy, in: s.load().index))])
        }
    }

    @MainActor
    private static func delete() -> ToolSpec {
        .action("library.delete",
                "Deletes a library entry with its stored furniture, thumbnail and unused photos. Projects that used the furniture keep their copies. Cannot be undone. Needs write access.",
                ["id": S.uuid("Library entry id.")], required: ["id"]) { env, a in
            try env.requireWriteAccess("library.delete changes the global library")
            let s = store(env)
            let e = try entry(s, try a.requireUUID("id"))
            try run { try s.remove(e.id) }
            return .object(["deleted": J.id(e.id), "name": .string(e.name)])
        }
    }

    @MainActor
    private static func place() -> ToolSpec {
        .write("library.place",
               "Places a library entry into the active project: its designs, materials, products and models are added (reused when equal) and the furniture is created with new ids, its middle at `position`. One undo step. The library stays unchanged. Entries with models or textures need a saved project.",
               ["id": S.uuid("Library entry id from library.list."), "position": S.p2("Where the middle of the furniture goes (plan coordinates)."),
                "levelId": S.uuid("Level; default the active level.")], required: ["id", "position"]) { p, env, a in
            let s = store(env)
            let e = try entry(s, try a.requireUUID("id"))
            let at = try a.requireP2("position")
            let level = try env.level(a, in: p)
            var t = try run { try s.transfer(for: e.id) }
            var offset = P2(0, 0)
            if let c = t.center { offset = P2(at.x - c.x, at.y - c.y) }
            var staged: (stored: [UUID: ProjectAsset], created: [URL]) = ([:], [])
            if !t.assets.isEmpty {
                guard let pkg = env.context.fileURL else {
                    throw ToolError.invalid(nil, "Save the project first: the models and textures of this entry are stored in the project file")
                }
                staged = try run { try FurnitureTransfer.stageAssets(t.assets, into: pkg) }
            }
            do {
                let result = try t.importInto(&p, stored: staged.stored, levelId: level, offset: offset)
                if env.dryRun { for u in staged.created { try? FileManager.default.removeItem(at: u) } }
                return .object(["entryId": J.id(e.id), "newIds": J.ids(result.instanceIds)])
            } catch {
                for u in staged.created { try? FileManager.default.removeItem(at: u) }
                throw error
            }
        }
    }

    @MainActor
    private static func thumbnail() -> ToolSpec {
        var spec = ToolSpec.asyncRead("library.thumbnail",
                   "Returns the rendered thumbnail (PNG) of a library entry, inline as an image and/or written to `path` (which needs write access). Rendered once per revision and cached at the default size; other sizes are rendered each time and not cached. Rendering needs the Roomsmith window.",
                   RenderTools.outputProperties.merging([
                       "id": S.uuid("Library entry id."),
                       "size": S.int("Pixel size 32...1024 (default \(LibraryStore.thumbnailPixels), the cached size). Other sizes are always rendered fresh and not cached.")
                   ]) { a, _ in a }, required: ["id"]) { env, a in
            let out = try RenderTools.output(env, a)
            let s = store(env)
            let e = try entry(s, try a.requireUUID("id"))
            let size = try a.int("size") ?? defaultThumbnailSize
            guard thumbnailSizeRange.contains(size) else {
                throw ToolError.invalid("size", "must be between \(thumbnailSizeRange.lowerBound) and \(thumbnailSizeRange.upperBound)")
            }
            let png: Data
            var cached = true
            let cacheable = size == defaultThumbnailSize
            if cacheable, let data = s.thumbnail(e) {
                png = data
            } else {
                guard let bridge = env.context.libraryBridge else {
                    throw AgentError.unsupportedFeature("library.thumbnail needs the Roomsmith window to render; this app context has none.")
                }
                let t = try run { try s.transfer(for: e.id) }
                png = try await bridge.renderLibraryThumbnail(t, size: Int(size))
                if cacheable { try? s.storeThumbnail(png, for: e) }
                cached = false
            }
            var o: [String: JSONValue] = ["id": J.id(e.id), "rev": .int(e.rev), "cached": .bool(cached)]
            try RenderTools.deliver(png, out, dryRun: false, into: &o)
            return .object(o)
        }
        spec.readOnly = false  // writes the thumbnail cache, and a file when `path` is given
        return spec
    }
}
