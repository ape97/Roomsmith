import Foundation

// MARK: - furniture.update_definition, furniture.create_from_template

enum FurnitureDesignTools {
    static let templates = ["cabinet", "table", "shelf", "sofa", "box"]

    private static func positive(_ s: Size3, _ field: String) throws -> Size3 {
        guard s.width > 0, s.depth > 0, s.height > 0 else { throw ToolError.invalid(field, "width, depth and height must be greater than 0") }
        guard sizeLimit.contains(s.width), sizeLimit.contains(s.depth), sizeLimit.contains(s.height) else {
            throw AgentError(code: AgentError.outOfRange, message: "\(field): width, depth and height must be between \(sizeLimit.lowerBound) and \(sizeLimit.upperBound) mm",
                             details: .object(["field": .string(field)]))
        }
        return s
    }

    private static func uniqueName(_ list: [Component], _ name: String, except: UUID?, _ field: String) throws {
        if list.contains(where: { $0.id != except && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw ToolError.invalid(field, "component names must be unique (duplicate '\(name)')")
        }
    }

    private static func object(_ item: JSONValue, _ f: String, allowed: Set<String>) throws -> Args {
        guard case .object(let raw) = item else { throw ToolError.invalid(f, "must be an object") }
        if let bad = raw.keys.first(where: { !allowed.contains($0) }) {
            throw ToolError.invalid("\(f).\(bad)", "unknown key; allowed: \(allowed.sorted().joined(separator: ", "))")
        }
        return Args(values: raw)
    }

    private static let componentSchema = S.obj("One part.", [
        "name": S.str("Unique name within the design."),
        "shape": S.str("Primitive.", values: PrimitiveShape.allCases.filter { $0 != .mesh }.map(\.rawValue)),
        "position": S.p3("Centre of the part (local)."), "size": S.size("Box size of the part."),
        "rotation": S.obj("Degrees around x, y, z."), "pivot": S.p3("Rotation pivot."),
        "material": .object(["description": "Material id or name."]), "visible": S.bool("Default true."),
        "id": S.uuid("Optional id."),
    ], required: ["name", "shape", "position", "size"])

    private static let patchSchema = S.obj("Changes to one existing part; only the given keys change.", [
        "component": S.str("Component id or exact name."), "name": S.str("New unique name."),
        "shape": S.str("New primitive.", values: PrimitiveShape.allCases.filter { $0 != .mesh }.map(\.rawValue)),
        "position": S.p3("Centre of the part (local)."), "size": S.size("Box size of the part."),
        "rotation": S.obj("Degrees around x, y, z."), "pivot": S.p3("Rotation pivot (null = centre)."),
        "material": .object(["description": "Material id or name; null removes the material."]), "visible": S.bool("Show or hide."),
    ], required: ["component"])

    @MainActor
    static func specs() -> [ToolSpec] {
        [
            .write("furniture.update_definition",
                   "Changes an existing furniture design without breaking its instances: name, category, nominal size, tags, and its parts (add, change, remove). Parts keep their ids, so placed instances, their material overrides and states stay valid; removing a part also removes it from states and animation keyframes, and instance overrides of removed parts are dropped. Instances with their own size (set by scene.resize or a drag) keep it exactly; instances without one follow the new nominal size (the result counts them as followingInstances). To rebuild a design from scratch use furniture.create_definition.",
                   ["id": S.uuid("Design id from furniture.list_definitions."), "name": S.str("New name."), "category": S.str("New category."),
                    "size": S.size("New nominal overall size."), "tags": S.arr("Replaces all tags.", items: S.str("Tag.")),
                    "updateComponents": S.arr("Changes to existing parts.", items: patchSchema),
                    "addComponents": S.arr("New parts.", items: componentSchema),
                    "removeComponents": S.arr("Parts to remove (id or name).", items: S.str("Component id or exact name."))],
                   required: ["id"]) { p, _, a in
                let id = try a.requireUUID("id")
                guard let old = p.definition(id) else {
                    if p.kind(of: id) != nil { throw ToolError.invalid("id", "\(id.uuidString.lowercased()) is not a furniture design") }
                    throw ToolError.notFound("Definition", id)
                }
                let keys = ["name", "category", "size", "tags", "updateComponents", "addComponents", "removeComponents"]
                guard keys.contains(where: a.present) else { throw ToolError.invalid(nil, "Give at least one of: \(keys.joined(separator: ", "))") }
                var d = old
                if let n = try a.nonEmptyString("name") { d.name = n }
                if let c = try a.nonEmptyString("category") { d.category = c }
                if let s = try a.size3("size") { d.size = try positive(s, "size") }
                if let t = try a.stringList("tags") { d.tags = t }
                // Remove first, so a removed name can be reused by an added part in the same call.
                let removed = try (a.stringList("removeComponents") ?? []).map { try FurnitureTools.component(old, $0, field: "removeComponents").id }
                if Set(removed).count != removed.count { throw ToolError.invalid("removeComponents", "lists a part twice") }
                d.components.removeAll { removed.contains($0.id) }
                let patchAllowed: Set<String> = ["component", "name", "shape", "position", "size", "rotation", "pivot", "material", "visible"]
                var touched = Set<UUID>()
                for (i, item) in (try a.array("updateComponents") ?? []).enumerated() {
                    let f = "updateComponents[\(i)]"
                    let pa = try object(item, f, allowed: patchAllowed)
                    let c = try FurnitureTools.component(old, try pa.requireNonEmptyString("component"), field: "\(f).component")
                    guard let idx = d.components.firstIndex(where: { $0.id == c.id }) else {
                        throw ToolError.invalid("\(f).component", "'\(c.name)' is removed in the same call")
                    }
                    guard touched.insert(c.id).inserted else { throw ToolError.invalid("\(f).component", "'\(c.name)' is changed twice in one call") }
                    var x = d.components[idx]
                    if let n = try pa.nonEmptyString("name") { x.name = n }
                    if let sh = try pa.enumValue("shape", PrimitiveShape.self) {
                        guard sh != .mesh else { throw ToolError.invalid("\(f).shape", "mesh components cannot be set through the API") }
                        guard x.shape != .mesh else { throw ToolError.invalid("\(f).shape", "a mesh component keeps its shape") }
                        x.shape = sh
                    }
                    if let v = try pa.p3("position") { x.position = v }
                    if let v = try pa.size3("size") { x.size = try positive(v, "\(f).size") }
                    if let r = pa.raw("rotation"), !r.isNull { x.rotation = try Args.parseR3(r, "\(f).rotation") }
                    if pa.isNull("pivot") { x.pivot = nil } else if let v = try pa.p3("pivot") { x.pivot = v }
                    if pa.isNull("material") { x.materialId = nil } else if let m = pa.raw("material") { x.materialId = try p.resolveMaterial(m, field: "\(f).material") }
                    if let v = try pa.bool("visible") { x.visible = v }
                    d.components[idx] = x
                }
                for (i, item) in (try a.array("addComponents") ?? []).enumerated() {
                    let f = "addComponents[\(i)]"
                    let ca = try object(item, f, allowed: ["id", "name", "shape", "position", "size", "rotation", "pivot", "material", "visible"])
                    guard let shape = try ca.enumValue("shape", PrimitiveShape.self) else { throw ToolError.missing("\(f).shape") }
                    guard shape != .mesh else { throw ToolError.invalid("\(f).shape", "mesh components cannot be created through the API") }
                    var c = Component(id: try ca.uuid("id") ?? UUID(), name: try ca.requireNonEmptyString("name"), shape: shape,
                                      position: try ca.requireP3("position"), size: try positive(try ca.requireSize3("size"), "\(f).size"),
                                      rotation: try ca.raw("rotation").map { try Args.parseR3($0, "\(f).rotation") } ?? .zero, pivot: try ca.p3("pivot"))
                    if let m = ca.raw("material"), !m.isNull { c.materialId = try p.resolveMaterial(m, field: "\(f).material") }
                    if let v = try ca.bool("visible") { c.visible = v }
                    if d.components.contains(where: { $0.id == c.id }) || old.components.contains(where: { $0.id == c.id }) {
                        throw ToolError.invalid("\(f).id", "already used by a part of this design")
                    }
                    d.components.append(c)
                }
                guard !d.components.isEmpty else { throw ToolError.invalid("removeComponents", "a design needs at least one part") }
                var seen: [Component] = []
                for c in d.components { try uniqueName(seen, c.name, except: nil, "components"); seen.append(c) }
                // Drop references to removed parts in states and keyframes (updateDefinition only repairs instances).
                let alive = Set(d.components.map(\.id))
                for i in d.states.indices { d.states[i].poses = d.states[i].poses.filter { alive.contains($0.key) } }
                for t in d.tracks.indices {
                    for k in d.tracks[t].keyframes.indices { d.tracks[t].keyframes[k].poses = d.tracks[t].keyframes[k].poses.filter { alive.contains($0.key) } }
                }
                let result = d
                try p.updateDefinition(id) { $0 = result }
                let placed = p.instances.filter { $0.definitionId == id }
                // Only a changed nominal size moves instances without their own size.
                let following = old.size != result.size ? placed.filter { $0.size == nil }.count : 0
                return .object(["id": J.id(id), "componentCount": .int(Int64(result.components.count)),
                                "componentIds": .object(result.components.reduce(into: [:]) { $0[$1.name] = J.id($1.id) }),
                                "removedComponents": .int(Int64(removed.count)), "instanceCount": .int(Int64(placed.count)),
                                "followingInstances": .int(Int64(following))])
            },
            .write("furniture.create_from_template",
                   "Creates a furniture design from a parametric template: cabinet (shelves, doors, plinth), table (legInset, topThickness), shelf (boards), sofa (armWidth, seatHeight) or box. The parts are plain primitives and can be refined with furniture.update_definition. Built-in catalogue designs are inserted with the catalog tools instead.",
                   ["template": S.str("Template.", values: templates), "name": S.str("Design name."), "size": S.size("Overall size (width, depth, height)."),
                    "shelves": S.int("cabinet: number of shelves (default 2)."), "doors": S.int("cabinet: number of doors, 0...6 and at most width/150, but always at least 1 allowed (default 2)."),
                    "plinth": S.int("cabinet: plinth height in mm (default 60)."), "legInset": S.int("table: leg inset from the edge in mm (default 50)."),
                    "topThickness": S.int("table: top thickness in mm (default 30)."), "boards": S.int("shelf: number of boards (default 4)."),
                    "armWidth": S.int("sofa: arm width in mm (default 150)."), "seatHeight": S.int("sofa: seat height in mm (default 420)."),
                    "material": .object(["description": "Material id or name for all parts."])],
                   required: ["template", "name", "size"]) { p, _, a in
                guard let t = try a.string("template"), templates.contains(t) else {
                    throw ToolError.invalid("template", "must be one of: \(templates.joined(separator: ", "))")
                }
                let name = try a.requireNonEmptyString("name")
                let size = try positive(try a.requireSize3("size"), "size")
                let mat = try a.raw("material").flatMap { $0.isNull ? nil : $0 }.map { try p.resolveMaterial($0, field: "material") }
                func count(_ key: String, _ def: Int64, _ range: ClosedRange<Int64>) throws -> Int64 {
                    let v = try a.int(key) ?? def
                    guard range.contains(v) else { throw ToolError.invalid(key, "must be between \(range.lowerBound) and \(range.upperBound)") }
                    return v
                }
                let d: FurnitureDefinition
                switch t {
                case "cabinet":
                    let doors = try count("doors", 2, 0...6)
                    guard doors <= max(1, size.width / 150) else {
                        throw ToolError.invalid("doors", "at most \(max(1, size.width / 150)) doors fit a width of \(size.width) mm (each door needs 150 mm)")
                    }
                    d = ParametricBuilder.cabinet(name: name, size: size, shelves: Int(try count("shelves", 2, 0...20)), doors: Int(doors),
                                                  plinth: try count("plinth", 60, 0...1000), materialId: mat)
                case "table":
                    d = ParametricBuilder.table(name: name, size: size, legInset: try count("legInset", 50, 0...1000),
                                                topThickness: try count("topThickness", 30, 1...1000), materialId: mat)
                case "shelf":
                    d = ParametricBuilder.shelf(name: name, size: size, boards: Int(try count("boards", 4, 1...30)), materialId: mat)
                case "sofa":
                    d = ParametricBuilder.sofa(name: name, size: size, armWidth: try count("armWidth", 150, 0...2000),
                                               seatHeight: try count("seatHeight", 420, 1...2000), materialId: mat)
                default:
                    d = ParametricBuilder.box(name: name, size: size, materialId: mat)
                }
                for m in Set(d.components.compactMap(\.materialId)) where p.material(m) == nil {
                    if let builtin = BuiltinCatalog.materials.first(where: { $0.id == m }) { p.materials.append(builtin) }
                }
                let id = p.addDefinition(d)
                return .object(["id": J.id(id), "template": .string(t), "size": J.size(d.size), "componentCount": .int(Int64(d.components.count)),
                                "componentIds": .object(d.components.reduce(into: [:]) { $0[$1.name] = J.id($1.id) })])
            },
        ]
    }
}
