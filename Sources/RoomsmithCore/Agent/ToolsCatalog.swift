import Foundation

// MARK: - catalog.*

enum CatalogTools {
    /// Key of the virtual built-in entry that inserts the whole modular sofa group.
    static let modularSofaKey = "sofa.modular"

    private static let productProperties: [String: JSONValue] = [
        "name": S.str("Product name."), "category": S.str("Free category, e.g. Sofa."),
        "description": S.str("Short description."), "notes": S.str("Own notes."),
        "manufacturer": S.str("Manufacturer."), "model": S.str("Model name."), "articleNumber": S.str("Article number."),
        "links": S.arr("Shop or data sheet links (http/https).", items: S.obj("Link.", ["title": S.str("Title."), "url": S.str("http(s) URL.")], required: ["url"])),
        "priceMinor": S.int("Price in minor currency units (cents). null removes it."),
        "currency": S.str("ISO currency code, default EUR."), "priceDate": S.str("Date of the price, yyyy-MM-dd. null removes it."),
        "dimensions": S.size("Product size. null removes it."), "weightGrams": S.int("Weight in grams. null removes it."),
        "materialText": S.str("Material description."), "colorText": S.str("Colour description."),
        "tags": S.arr("Tags.", items: S.str("Tag.")),
        "status": S.str("Purchase status.", values: PurchaseStatus.allCases.map(\.rawValue)),
        "variants": S.arr("Variant names.", items: S.str("Variant.")),
        "custom": S.obj("Free key/value fields (string values)."),
    ]

    /// Applies the given keys of `a` to a product. `null` clears the optional fields.
    private static func apply(_ a: Args, to x: inout CatalogProduct) throws {
        if let v = try a.nonEmptyString("name") { x.name = v }
        if let v = try a.string("category") { x.category = v }
        if let v = try a.string("description") { x.description = v }
        if let v = try a.string("notes") { x.notes = v }
        if let v = try a.string("manufacturer") { x.manufacturer = v }
        if let v = try a.string("model") { x.model = v }
        if let v = try a.string("articleNumber") { x.articleNumber = v }
        if let v = try a.string("materialText") { x.materialText = v }
        if let v = try a.string("colorText") { x.colorText = v }
        if let v = try a.string("currency") {
            guard v.count == 3 else { throw ToolError.invalid("currency", "must be a 3-letter ISO code") }
            x.currency = v.uppercased()
        }
        if a.isNull("priceMinor") { x.priceMinor = nil }
        else if let v = try a.int("priceMinor") {
            guard v >= 0 else { throw ToolError.invalid("priceMinor", "must not be negative") }
            x.priceMinor = v
        }
        if a.isNull("priceDate") { x.priceDate = nil }
        else if let v = try a.string("priceDate") {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
            guard f.date(from: v) != nil else { throw ToolError.invalid("priceDate", "must be a date like 2026-11-08") }
            x.priceDate = v
        }
        if a.isNull("dimensions") { x.dimensions = nil } else if let v = try a.size3("dimensions") { x.dimensions = v }
        if a.isNull("weightGrams") { x.weightGrams = nil }
        else if let v = try a.int("weightGrams") {
            guard v >= 0 else { throw ToolError.invalid("weightGrams", "must not be negative") }
            x.weightGrams = v
        }
        if let v = try a.stringList("tags") { x.tags = v }
        if let v = try a.stringList("variants") { x.variants = v }
        if let v = try a.enumValue("status", PurchaseStatus.self) { x.status = v }
        if let list = try a.array("links") {
            x.links = try list.enumerated().map { i, item in
                guard let url = item["url"]?.stringValue else { throw ToolError.invalid("links[\(i)].url", "is required") }
                let link = ProductLink(title: item["title"]?.stringValue ?? url, url: url)
                guard link.isValid else { throw ToolError.invalid("links[\(i)].url", "must be an http or https URL") }
                return link
            }
        }
        if let o = try a.object("custom") {
            var c: [String: String] = [:]
            for (k, v) in o.values {
                guard let s = v.stringValue else { throw ToolError.invalid("custom.\(k)", "must be a string") }
                c[k] = s
            }
            x.custom = c
        }
    }

    static func productJSON(_ x: CatalogProduct) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": J.id(x.id), "kind": "product", "name": .string(x.name), "rev": .int(x.rev), "category": .string(x.category),
            "status": .string(x.status.rawValue),
        ]
        if let p = x.priceMinor { o["priceMinor"] = .int(p); o["currency"] = .string(x.currency) }
        if let d = x.dimensions { o["dimensions"] = J.size(d) }
        if let m = x.manufacturer.isEmpty ? nil : x.manufacturer { o["manufacturer"] = .string(m) }
        if let d = x.definitionId { o["definitionId"] = J.id(d) }
        return .object(o)
    }

    private static func virtualSofaMatches(query: String, category: String?) -> Bool {
        if let category, category.lowercased() != "living" { return false }
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        let hay = "sofa.modular modular sofa couch seating living group"
        return words.allSatisfy { hay.contains($0) }
    }

    private static func builtinRow(_ e: CatalogEntry) -> JSONValue {
        let d = e.make()
        return .object(["key": .string(e.key), "name": .string(e.name), "category": .string(e.category),
                        "tags": .array(e.tags.map { .string($0) }), "size": J.size(d.size), "type": "furniture"])
    }

    private static let sofaRow: JSONValue = .object([
        "key": .string(modularSofaKey), "name": "Modular sofa (complete group)", "category": "Living",
        "tags": ["sofa", "modular", "couch", "seating", "group"], "type": "group",
        "note": "Inserts 7 modules as one group with the configurations L-shape, Straight and U-shape. `position` is the centre of corner module A.",
    ])

    /// Adds the built-in definition and its materials to the project when missing; returns the definition id.
    static func ensureDefinition(_ p: inout Project, _ entry: CatalogEntry) -> UUID {
        let def = entry.make()
        if !p.definitions.contains(where: { $0.id == def.id }) { p.definitions.append(def) }
        for m in Set(def.components.compactMap(\.materialId)) where p.material(m) == nil {
            if let mat = BuiltinCatalog.materials.first(where: { $0.id == m }) { p.materials.append(mat) }
        }
        return def.id
    }

    @MainActor
    static func specs() -> [ToolSpec] {
        [
            .write("catalog.create_product",
                   "Creates a product record (wish list entry or real purchase) with price, links and notes. Prices are integer cents.",
                   productProperties.merging(["id": S.uuid("Optional id."),
                                              "linkTo": S.uuid("Optionally link the new product to this furniture, group or definition.")]) { a, _ in a },
                   required: ["name"]) { p, _, a in
                var x = CatalogProduct(id: try a.uuid("id") ?? UUID(), name: try a.requireNonEmptyString("name"))
                try apply(a, to: &x)
                let id = p.addProduct(x)
                if let target = try a.uuid("linkTo") {
                    try p.requireAll([target])
                    try p.linkProduct(id, to: target)
                }
                return .object(["id": J.id(id)])
            },
            .write("catalog.update_product", "Changes a product; only the given keys change. null clears priceMinor, priceDate, dimensions, weightGrams.",
                   productProperties.merging(["id": S.uuid("Product id.")]) { a, _ in a }, required: ["id"]) { p, _, a in
                let id = try a.requireUUID("id")
                guard p.product(id) != nil else { throw ToolError.notFound("Product", id) }
                guard productProperties.keys.contains(where: a.present) else {
                    throw ToolError.invalid(nil, "Give at least one field to change: \(productProperties.keys.sorted().joined(separator: ", "))")
                }
                try p.updateProduct(id) { try apply(a, to: &$0) }
                return .object([:])
            },
            .read("catalog.search_products", "Searches the project's products (paginated). Filters: query (name substring), category, status.",
                  ["query": S.str("Case-insensitive name substring."), "category": S.str("Exact category (case-insensitive)."),
                   "status": S.str("Purchase status.", values: PurchaseStatus.allCases.map(\.rawValue)),
                   "limit": S.limit, "cursor": S.cursor]) { env, a in
                let p = env.project
                let page = try PageRequest(a)
                let q = try a.string("query")?.lowercased(), cat = try a.string("category")?.lowercased()
                let status = try a.enumValue("status", PurchaseStatus.self)
                let hits = p.products.filter { x in
                    (q.map { x.name.lowercased().contains($0) } ?? true) && (cat.map { x.category.lowercased() == $0 } ?? true)
                        && (status.map { x.status == $0 } ?? true)
                }
                return page.result(hits, revision: p.revision, productJSON)
            },
            .write("catalog.link_product", "Links a product to furniture, a group or a definition; productId null removes the link.",
                   ["productId": S.uuid("Product id, or null to unlink."), "objectId": S.uuid("Furniture, group or definition.")],
                   required: ["objectId"]) { p, _, a in
                let object = try a.requireUUID("objectId")
                let product = try a.uuid("productId")
                if !a.present("productId") { throw ToolError.missing("productId") }
                try p.requireAll([object])
                if let product, p.product(product) == nil { throw ToolError.notFound("Product", product) }
                try p.linkProduct(product, to: object)
                return .object(["objectId": J.id(object), "productId": product.map(J.id) ?? .null])
            },
            .read("catalog.list_builtin", "Lists the built-in furniture catalog (paginated) with key, name, category, tags and size. Use the key with catalog.insert_builtin.",
                  ["query": S.str("Words that must all occur in name, key, category or tags."), "category": S.str("Category.", values: BuiltinCatalog.categories),
                   "limit": S.limit, "cursor": S.cursor]) { env, a in
                let page = try PageRequest(a)
                let query = try a.string("query") ?? ""
                let category = try a.string("category")
                var entries = BuiltinCatalog.search(query)
                if let category {
                    guard let canonical = BuiltinCatalog.categories.first(where: { $0.caseInsensitiveCompare(category) == .orderedSame }) else {
                        throw ToolError.invalid("category", "must be one of: \(BuiltinCatalog.categories.joined(separator: ", "))")
                    }
                    entries = entries.filter { $0.category == canonical }
                }
                var rows: [Either] = entries.map { .entry($0) }
                if virtualSofaMatches(query: query, category: category) { rows.insert(.sofa, at: 0) }
                return page.result(rows, revision: env.project.revision, { row in
                    switch row {
                    case .sofa: sofaRow
                    case .entry(let e): builtinRow(e)
                    }
                }, extra: ["categories": .array(BuiltinCatalog.categories.map { .string($0) })])
            },
            .write("catalog.insert_builtin",
                   "Places a built-in catalog piece: adds its definition to the project when needed and creates an instance. Key `sofa.modular` inserts the complete modular sofa as one group (position = centre of module Corner A).",
                   ["key": S.str("Catalog key from catalog.list_builtin."), "position": S.p3("Footprint centre; z = height above the floor (default 0)."),
                    "rotationDeg": S.num("Rotation in degrees, counter-clockwise from above (default 0)."),
                    "levelId": S.uuid("Level; default the active level."), "name": S.str("Instance name (default: catalog name).")],
                   required: ["key", "position"]) { p, env, a in
                let key = try a.requireNonEmptyString("key")
                let level = try env.level(a, in: p)
                let position = try a.requireP3("position")
                let rotation = try a.double("rotationDeg") ?? 0
                if key.caseInsensitiveCompare(modularSofaKey) == .orderedSame {
                    let gid = try BuiltinCatalog.insertModularSofa(into: &p, levelId: level, origin: position.xy)
                    let members = p.group(gid)?.memberIds ?? []
                    if rotation != 0 { try p.rotateObjects([gid], by: rotation, pivot: position.xy) }
                    return .object(["id": J.id(gid), "groupId": J.id(gid), "memberIds": J.ids(members)])
                }
                guard let entry = BuiltinCatalog.entries.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) else {
                    throw AgentError(code: AgentError.notFound,
                                     message: "No catalog entry with key '\(key)'. Use catalog.list_builtin to find keys.")
                }
                let definitionId = ensureDefinition(&p, entry)
                let id = try p.addInstance(definitionId: definitionId, levelId: level, position: position, rotationDeg: rotation,
                                           name: try a.string("name"))
                return .object(["id": J.id(id), "definitionId": J.id(definitionId), "key": .string(entry.key)])
            },
            importModel(),
        ]
    }

    /// File types the importer accepts (the same as File > Import 3D Model…).
    static let modelExtensions: Set<String> = ["usdz", "usd", "usda", "usdc"]
    /// Largest sides outside this range (mm) get a "check the scale" warning but are still imported.
    static let plausibleLargestSide: ClosedRange<MM> = 20...20_000

    @MainActor
    private static func importModel() -> ToolSpec {
        var spec = ToolSpec.asyncRead("catalog.import_model",
            "Imports a USD/USDZ model like File > Import 3D Model…: copies the file into the project package (assets/), measures it and creates a furniture design (category Imported). With `place` it also puts one instance there. One undo step. Needs write access and a saved project (project.save_as first if it has no file yet). Returns designId, optional instanceId and the size in mm (width = X, depth = Z, height = Y of the model). Needs the Roomsmith app.",
            ["path": S.str("Absolute path of a .usdz, .usd, .usda or .usdc file."),
             "name": S.str("Design name (default: file name without extension)."),
             "place": S.obj("Also place an instance of the new design.",
                            ["position": S.p3("Footprint centre; z = height above the floor (default 0)."),
                             "levelId": S.uuid("Level; default the active level.")], required: ["position"])],
            required: ["path"]) { env, a in
            try env.requireWriteAccess("catalog.import_model creates a design")
            let raw = try a.requireNonEmptyString("path")
            guard raw.hasPrefix("/"), !raw.contains("\0") else { throw ToolError.invalid("path", "must be an absolute path") }
            let url = URL(fileURLWithPath: raw).standardizedFileURL
            guard modelExtensions.contains(url.pathExtension.lowercased()) else {
                throw ToolError.invalid("path", "must be a 3D model file (\(modelExtensions.sorted().joined(separator: ", ")))")
            }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
                throw ToolError.notFoundText("No file at \(url.path)")
            }
            guard let package = env.context.fileURL else {
                throw AgentError(code: "NO_FILE", message: "The project has not been saved yet; call project.save_as with a path first. Imported models are stored inside the project package.")
            }
            let name = try a.nonEmptyString("name") ?? url.deletingPathExtension().lastPathComponent
            var placement: (position: P3, level: UUID)?
            if let place = try a.object("place") {
                let position = try place.requireP3("position")
                guard position.xy.isInRange else { throw ToolError.invalid("place.position", "outside the allowed coordinate range") }
                placement = (position, try env.level(place, in: env.project))
            }
            let size = try await env.context.measureModelForAgent(url)
            guard size.isValid else { throw ToolError.invalid("path", "the model measures \(size.width) x \(size.depth) x \(size.height) mm, outside the allowed size") }
            let assetsDir = package.appendingPathComponent("assets", isDirectory: true)
            let (asset, wasNew): (ProjectAsset, Bool)
            do {
                (asset, wasNew) = try await Task.detached(priority: .userInitiated) {
                    let before = Set((try? FileManager.default.contentsOfDirectory(atPath: assetsDir.path)) ?? [])
                    let asset = try ProjectPackage.importAsset(url, kind: .mesh, into: package)
                    return (asset, !before.contains(ProjectPackage.assetURL(asset, in: package).lastPathComponent))
                }.value
            } catch {
                throw AgentError(code: AgentError.internal, message: "Could not store the model: \(error)")
            }
            var designId = UUID(), instanceId: UUID?
            let options = CommandOptions(origin: .agent(env.clientId))
            do {
                let result = try env.store.apply("Agent: import model", options: options) { p in
                    var stored = asset
                    stored.measuredSize = size
                    let assetId = p.addAsset(stored)
                    var part = Component(name: "Model", shape: .mesh, position: P3(0, 0, size.height / 2), size: size)
                    part.meshAssetId = assetId
                    var def = FurnitureDefinition(name: name, category: "Imported", size: size, components: [part])
                    def.tags = ["imported"]
                    designId = p.addDefinition(def)
                    if let placement {
                        instanceId = try p.addInstance(definitionId: def.id, levelId: placement.level, position: placement.position)
                    }
                }
                var extra: [String: JSONValue] = ["designId": J.id(designId), "name": .string(name), "size": J.size(size),
                                                  "assetId": J.id(asset.id)]
                if let instanceId { extra["instanceId"] = J.id(instanceId); extra["id"] = J.id(instanceId) }
                if !plausibleLargestSide.contains(max(size.width, size.depth, size.height)) {
                    extra["warning"] = "Check the scale: the file may use unexpected units."
                }
                return ToolRegistry.mutationJSON(committed: result.committed, revision: result.revision, changes: result.changes,
                                                 extra: .object(extra), dryRun: false, project: env.store.project)
            } catch {
                // Same content may be referenced by an earlier import; only remove a file this call created.
                if wasNew, !env.store.project.assets.contains(where: { $0.storedName == asset.storedName }) {
                    try? FileManager.default.removeItem(at: ProjectPackage.assetURL(asset, in: package))
                }
                throw error
            }
        }
        spec.readOnly = false  // changes the project (own undo step), but is async and so not a plain write tool
        return spec
    }

    private enum Either {
        case sofa
        case entry(CatalogEntry)
    }
}
