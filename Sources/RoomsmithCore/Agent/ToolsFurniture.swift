import Foundation

// MARK: - furniture.*

enum FurnitureTools {
    // MARK: Lookups by id or name

    private static func notFoundName(_ what: String, _ name: String, among names: [String]) -> AgentError {
        let list = names.isEmpty ? "none defined" : names.joined(separator: ", ")
        return ToolError.notFoundText("\(what) '\(name)' does not exist (available: \(list))")
    }

    /// Component of a definition by UUID or exact (case-insensitive) name.
    static func component(_ d: FurnitureDefinition, _ ref: String, field: String) throws -> Component {
        if let u = UUID(uuidString: ref), let c = d.components.first(where: { $0.id == u }) { return c }
        let hits = d.components.filter { $0.name.caseInsensitiveCompare(ref) == .orderedSame }
        if hits.count > 1 { throw ToolError.invalid(field, "component name '\(ref)' is ambiguous; use the component id") }
        guard let c = hits.first else { throw notFoundName("Component", ref, among: d.components.map(\.name)) }
        return c
    }

    static func state(_ d: FurnitureDefinition, _ ref: String, field: String) throws -> FurnitureState {
        if let u = UUID(uuidString: ref), let s = d.states.first(where: { $0.id == u }) { return s }
        guard let s = d.states.first(where: { $0.name.caseInsensitiveCompare(ref) == .orderedSame }) else {
            throw notFoundName("State", ref, among: d.states.map(\.name))
        }
        return s
    }

    /// Option group of a design by UUID or exact (case-insensitive) name.
    static func optionGroup(_ d: FurnitureDefinition, _ ref: String, field: String) throws -> OptionGroup {
        if let u = UUID(uuidString: ref), let g = d.optionGroups.first(where: { $0.id == u }) { return g }
        guard let g = d.optionGroups.first(where: { $0.name.caseInsensitiveCompare(ref) == .orderedSame }) else {
            throw notFoundName("Option group", ref, among: d.optionGroups.map(\.name))
        }
        return g
    }

    /// Choice of an option group by UUID or exact (case-insensitive) name.
    static func optionChoice(_ g: OptionGroup, _ ref: String, field: String) throws -> OptionChoice {
        if let u = UUID(uuidString: ref), let c = g.choices.first(where: { $0.id == u }) { return c }
        guard let c = g.choices.first(where: { $0.name.caseInsensitiveCompare(ref) == .orderedSame }) else {
            throw notFoundName("Choice", ref, among: g.choices.map(\.name))
        }
        return c
    }

    static func configuration(_ g: FurnitureGroup, _ ref: String, field: String) throws -> GroupConfiguration {
        if let u = UUID(uuidString: ref), let c = g.configurations.first(where: { $0.id == u }) { return c }
        let hits = g.configurations.filter { $0.name.caseInsensitiveCompare(ref) == .orderedSame }
        if hits.count > 1 { throw ToolError.invalid(field, "configuration name '\(ref)' is ambiguous; use the id") }
        guard let c = hits.first else { throw notFoundName("Configuration", ref, among: g.configurations.map(\.name)) }
        return c
    }

    // MARK: Parsing

    private static func parsePose(_ v: JSONValue, _ field: String) throws -> ComponentPose {
        guard case .object = v else { throw ToolError.invalid(field, "must be an object with position, rotation, size, visible") }
        var pose = ComponentPose()
        if let x = v["position"], !x.isNull { pose.position = try Args.parseP3(x, "\(field).position") }
        if let x = v["rotation"], !x.isNull { pose.rotation = try Args.parseR3(x, "\(field).rotation") }
        if let x = v["size"], !x.isNull { pose.size = try positive(try Args.parseSize3(x, "\(field).size"), "\(field).size") }
        if let x = v["visible"], !x.isNull {
            guard let b = x.boolValue else { throw ToolError.invalid("\(field).visible", "must be true or false") }
            pose.visible = b
        }
        return pose
    }

    @discardableResult
    private static func positive(_ s: Size3, _ field: String) throws -> Size3 {
        guard s.width > 0, s.depth > 0, s.height > 0 else { throw ToolError.invalid(field, "width, depth and height must be greater than 0") }
        return s
    }

    /// `poses` as `{componentNameOrId: {position?, rotation?, size?, visible?}}`.
    private static func parsePoses(_ a: Args, _ d: FurnitureDefinition, key: String = "poses") throws -> [UUID: ComponentPose] {
        guard let o = try a.object(key) else { return [:] }
        var out: [UUID: ComponentPose] = [:]
        for (ref, v) in o.values.sorted(by: { $0.key < $1.key }) {
            let c = try component(d, ref, field: "\(key).\(ref)")
            out[c.id] = try parsePose(v, "\(key).\(ref)")
        }
        return out
    }

    private static func parseComponents(_ p: inout Project, _ list: [JSONValue]) throws -> [Component] {
        var out: [Component] = []
        for (i, item) in list.enumerated() {
            let f = "components[\(i)]"
            guard case .object(let raw) = item else { throw ToolError.invalid(f, "must be an object") }
            let ca = Args(values: raw)
            let allowed: Set<String> = ["id", "name", "shape", "position", "size", "rotation", "pivot", "material", "visible"]
            if let bad = raw.keys.first(where: { !allowed.contains($0) }) {
                throw ToolError.invalid("\(f).\(bad)", "unknown key; allowed: \(allowed.sorted().joined(separator: ", "))")
            }
            let name = try ca.requireNonEmptyString("name")
            guard let shape = try ca.enumValue("shape", PrimitiveShape.self) else { throw ToolError.missing("\(f).shape") }
            guard shape != .mesh else { throw ToolError.invalid("\(f).shape", "mesh components cannot be created through the API") }
            var c = Component(id: try ca.uuid("id") ?? UUID(), name: name, shape: shape,
                              position: try ca.requireP3("position"), size: try positive(try ca.requireSize3("size"), "\(f).size"),
                              rotation: try ca.raw("rotation").map { try Args.parseR3($0, "\(f).rotation") } ?? .zero,
                              pivot: try ca.p3("pivot"))
            if let m = ca.raw("material") { c.materialId = try p.resolveMaterial(m, field: "\(f).material") }
            if let v = try ca.bool("visible") { c.visible = v }
            if out.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                throw ToolError.invalid("\(f).name", "component names must be unique (duplicate '\(name)')")
            }
            out.append(c)
        }
        return out
    }

    /// `options` as `{"<group name or id>": "<choice name or id>" | null}`, resolved against one design. null returns the
    /// group to its default choice.
    private static func parseOptions(_ v: JSONValue, definition d: FurnitureDefinition, field: String = "options") throws -> (select: [UUID: UUID], reset: [UUID]) {
        guard let o = v.objectValue else { throw ToolError.invalid(field, "must be an object {\"<group>\": \"<choice>\" or null}") }
        var select: [UUID: UUID] = [:], reset: [UUID] = []
        for (ref, x) in o.sorted(by: { $0.key < $1.key }) {
            let g = try optionGroup(d, ref, field: "\(field).\(ref)")
            if x.isNull { reset.append(g.id); continue }
            guard let cref = x.stringValue else { throw ToolError.invalid("\(field).\(ref)", "must be a choice name or id, or null") }
            select[g.id] = try optionChoice(g, cref, field: "\(field).\(ref)").id
        }
        return (select, reset)
    }

    /// Applies an `options` argument to one placed piece.
    private static func applyOptions(_ p: inout Project, instance id: UUID, _ v: JSONValue, field: String = "options") throws {
        guard let inst = p.instance(id), let d = p.definition(inst.definitionId) else { throw ToolError.notFound("Furniture", id) }
        let r = try parseOptions(v, definition: d, field: field)
        try p.setOptions([id], select: r.select, reset: r.reset)
    }

    /// `effects` of one choice as `{"<component>": {material?: id/name or null, visible?: bool}}`.
    private static func parseEffects(_ p: inout Project, _ v: JSONValue, definition d: FurnitureDefinition, field: String) throws -> [UUID: OptionEffect] {
        guard let o = v.objectValue else { throw ToolError.invalid(field, "must be an object {\"<component>\": {material?, visible?}}") }
        var out: [UUID: OptionEffect] = [:]
        for (ref, x) in o.sorted(by: { $0.key < $1.key }) {
            let f = "\(field).\(ref)"
            let c = try component(d, ref, field: f)
            let ea = try object(x, f, allowed: ["material", "visible"])
            var e = OptionEffect()
            if let m = ea.raw("material"), !m.isNull { e.materialId = try p.resolveMaterial(m, field: "\(f).material") }
            if let b = try ea.bool("visible") { e.visible = b }
            guard !e.isEmpty else { throw ToolError.invalid(f, "needs material or visible") }
            out[c.id] = e
        }
        return out
    }

    private static func object(_ item: JSONValue, _ f: String, allowed: Set<String>) throws -> Args {
        guard case .object(let raw) = item else { throw ToolError.invalid(f, "must be an object") }
        if let bad = raw.keys.first(where: { !allowed.contains($0) }) {
            throw ToolError.invalid("\(f).\(bad)", "unknown key; allowed: \(allowed.sorted().joined(separator: ", "))")
        }
        return Args(values: raw)
    }

    private static let optionsSchema = S.obj("Option selection {\"<group name or id>\": \"<choice name or id>\" or null for the group's default}. Groups come from furniture.define_option_group; scene.get_object lists availableOptions.")

    private static let poseSchema = S.obj("Pose overrides keyed by component name or id: {\"<component>\": {position?, rotation? (degrees x/y/z), size?, visible?}}.")

    // MARK: Output

    private static func definitionRow(_ x: FurnitureDefinition, placed: Int) -> JSONValue {
        .object(["id": J.id(x.id), "kind": "definition", "name": .string(x.name), "rev": .int(x.rev), "category": .string(x.category),
                 "size": J.size(x.size), "componentCount": .int(Int64(x.components.count)), "stateCount": .int(Int64(x.states.count)),
                 "builtin": .bool(x.builtin), "placedCount": .int(Int64(placed))])
    }

    private static func removedRows(_ p: Project, _ ids: [UUID]) -> JSONValue {
        .array(ids.map { .object(["id": J.id($0), "name": .string(p.displayName(of: $0))]) })
    }

    private static func configurationRows(_ p: Project, _ g: FurnitureGroup) -> JSONValue {
        .object([
            "groupId": J.id(g.id), "name": .string(g.name), "rev": .int(g.rev), "levelId": J.id(g.levelId),
            "activeConfigurationId": g.activeConfigurationId.map(J.id) ?? .null,
            "configurations": .array(g.configurations.map { c in
                .object(["id": J.id(c.id), "name": .string(c.name), "active": .bool(c.id == g.activeConfigurationId),
                         "memberCount": .int(Int64(c.poses.count)),
                         "visibleCount": .int(Int64(c.poses.values.filter(\.visible).count))])
            }),
        ])
    }

    private static func requireGroup(_ p: Project, _ a: Args) throws -> FurnitureGroup {
        let id = try a.requireUUID("groupId")
        guard let g = p.group(id) else {
            if p.kind(of: id) != nil { throw ToolError.invalid("groupId", "\(id.uuidString.lowercased()) is not a group") }
            throw ToolError.notFound("Group", id)
        }
        return g
    }

    // MARK: Tools

    @MainActor
    static func specs() -> [ToolSpec] {
        [
            .write("furniture.create_definition",
                   "Creates a reusable furniture design from primitive parts. Coordinates are local: origin = centre of the footprint on the floor, +X right, +Y back, +Z up. A component's `position` is the centre of its box. Optional states define alternative poses (e.g. folded/unfolded). If the project already has an identical own design (same name, size, parts, states; ids ignored) and no `id` or `forceNew` is given, that design is returned with `reused: true` and nothing is added. Other designs with the same name are listed in `similar`: to swap a placed model use furniture.replace_definition instead of leaving the old design behind.",
                   ["name": S.str("Design name."), "category": S.str("Category (default Custom)."),
                    "size": S.size("Nominal overall size."),
                    "components": S.arr("Parts.", items: S.obj("One part.", [
                        "name": S.str("Unique name within the design."),
                        "shape": S.str("Primitive.", values: PrimitiveShape.allCases.filter { $0 != .mesh }.map(\.rawValue)),
                        "position": S.p3("Centre of the part."), "size": S.size("Box size of the part."),
                        "rotation": S.obj("Degrees around x, y, z (default 0)."), "pivot": S.p3("Rotation pivot (default centre)."),
                        "material": .object(["description": "Material id or name."]), "visible": S.bool("Default true."),
                        "id": S.uuid("Optional id."),
                    ], required: ["name", "shape", "position", "size"])),
                    "states": S.arr("Named poses.", items: S.obj("One state.", ["name": S.str("State name."), "poses": poseSchema,
                                                                                "size": S.size("Overall size in this state.")], required: ["name"])),
                    "defaultState": S.str("Name of the state new instances start in."),
                    "tags": S.arr("Tags.", items: S.str("Tag.")), "id": S.uuid("Optional id."),
                    "forceNew": S.bool("Add the design even if an identical one exists (default false).")],
                   required: ["name", "size", "components"]) { p, _, a in
                let name = try a.requireNonEmptyString("name")
                let comps = try parseComponents(&p, try a.requireArray("components"))
                guard !comps.isEmpty else { throw ToolError.invalid("components", "needs at least one component") }
                var d = FurnitureDefinition(id: try a.uuid("id") ?? UUID(), name: name, category: try a.nonEmptyString("category") ?? "Custom",
                                            size: try positive(try a.requireSize3("size"), "size"), components: comps)
                d.tags = try a.stringList("tags") ?? []
                var stateIds: [String: UUID] = [:]
                for (i, item) in (try a.array("states") ?? []).enumerated() {
                    guard case .object(let raw) = item else { throw ToolError.invalid("states[\(i)]", "must be an object") }
                    let sa = Args(values: raw)
                    let sname = try sa.requireNonEmptyString("name")
                    guard stateIds[sname.lowercased()] == nil else { throw ToolError.invalid("states[\(i)].name", "duplicate state '\(sname)'") }
                    var st = FurnitureState(name: sname, poses: try parsePoses(sa, d))
                    if let s = try sa.size3("size") { st.size = try positive(s, "states[\(i)].size") }
                    d.states.append(st)
                    stateIds[sname.lowercased()] = st.id
                }
                if let def = try a.nonEmptyString("defaultState") {
                    guard let sid = stateIds[def.lowercased()] else { throw ToolError.invalid("defaultState", "'\(def)' is not one of the given states") }
                    d.defaultStateId = sid
                }
                var out: [String: JSONValue] = [:]
                if try a.uuid("id") == nil, !(try a.bool("forceNew") ?? false), let twin = p.ownTwin(of: d) {
                    // The same design is already there: hand out its ids (parts and states match by position).
                    d = twin
                    out["reused"] = true
                } else {
                    p.addDefinition(d)
                    let same = p.definitions(named: d.name).filter { $0.id != d.id }
                    if !same.isEmpty {
                        let counts = p.placedCounts()
                        out["similar"] = .array(same.map { .object(["id": J.id($0.id), "name": .string($0.name),
                                                                     "builtin": .bool($0.builtin), "placedCount": .int(Int64(counts[$0.id] ?? 0))]) })
                        out["hint"] = "Designs with this name already exist. To swap a placed model, use furniture.replace_definition (it moves the pieces and removes the old design); furniture.delete_definitions removes unused ones."
                    }
                }
                out["id"] = J.id(d.id)
                out["componentIds"] = .object(d.components.reduce(into: [:]) { $0[$1.name] = J.id($1.id) })
                out["stateIds"] = .object(d.states.reduce(into: [:]) { $0[$1.name] = J.id($1.id) })
                return .object(out)
            },
            .read("furniture.list_definitions", "Lists furniture designs of the project (paginated), including those inserted from the built-in catalog. `placedCount` is the number of pieces placed from a design; 0 means unused (see furniture.prune_unused_definitions).",
                  ["query": S.str("Case-insensitive name substring."), "category": S.str("Category (case-insensitive)."),
                   "builtin": S.bool("Only built-in (true) or only own (false) designs."),
                   "unused": S.bool("Only designs no piece is placed from (true) or only used ones (false)."),
                   "limit": S.limit, "cursor": S.cursor]) { env, a in
                let p = env.project
                let page = try PageRequest(a)
                let q = try a.string("query")?.lowercased(), cat = try a.string("category")?.lowercased(), builtin = try a.bool("builtin")
                let unused = try a.bool("unused")
                let counts = p.placedCounts()
                let hits = p.definitions.filter { d in
                    (q.map { d.name.lowercased().contains($0) } ?? true) && (cat.map { d.category.lowercased() == $0 } ?? true)
                        && (builtin.map { d.builtin == $0 } ?? true) && (unused.map { ((counts[d.id] ?? 0) == 0) == $0 } ?? true)
                }
                return page.result(hits, revision: p.revision) { definitionRow($0, placed: counts[$0.id] ?? 0) }
            },
            .write("furniture.create_instance", "Places a furniture design on a level. `position` is the footprint centre; z is the height of the underside above the floor. `allowsOverlap` exempts the piece from collision warnings (it also never blocks while dragging).",
                   ["definitionId": S.uuid("Design from furniture.list_definitions."), "levelId": S.uuid("Level; default the active level."),
                    "position": S.p3("Footprint centre."), "rotationDeg": S.num("Degrees counter-clockwise from above (default 0)."),
                    "name": S.str("Instance name (default: design name)."), "size": S.size("Custom exact size (default: design size)."),
                    "allowsOverlap": S.bool("true: the piece may overlap furniture, walls and openings without a collision warning (default false). Flat floor pieces (z <= 0, height <= 150 mm) never collide anyway."),
                    "options": optionsSchema,
                    "id": S.uuid("Optional id.")], required: ["definitionId", "position"]) { p, env, a in
                let def = try a.requireUUID("definitionId")
                guard p.definition(def) != nil else { throw ToolError.notFound("Definition", def) }
                let size = try a.size3("size").map { try positive($0, "size") }
                let allowsOverlap = try a.bool("allowsOverlap")
                let id = try p.addInstance(definitionId: def, levelId: try env.level(a, in: p), position: try a.requireP3("position"),
                                           rotationDeg: try a.double("rotationDeg") ?? 0, name: try a.nonEmptyString("name"),
                                           size: size, id: try a.uuid("id") ?? UUID())
                if let allowsOverlap, let k = p.instances.firstIndex(where: { $0.id == id }) { p.instances[k].allowsOverlap = allowsOverlap }
                if let o = a.raw("options"), !o.isNull { try applyOptions(&p, instance: id, o) }
                return .object(["id": J.id(id), "ids": J.ids([id])])
            },
            .write("furniture.update_instance",
                   "Changes one placed piece: name, exact position, rotation, custom size (null = design size), visibility, whether it may overlap (no collision warnings), per-component materials or the chosen options (colour, front, handle).",
                   ["id": S.uuid("Furniture id."), "name": S.str("New name."), "position": S.p3("New footprint centre (z optional, keeps the current height)."),
                    "rotationDeg": S.num("Absolute rotation in degrees."), "size": S.size("Custom size, or null for the design size."),
                    "visible": S.bool("Visibility."),
                    "allowsOverlap": S.bool("true: the piece may overlap furniture, walls and openings without a collision warning; false restores the warnings."),
                    "materials": S.obj("{\"<component name or id>\": material id/name, or null to restore the design's material}. Wins over an option colour given in the same call."),
                    "options": optionsSchema],
                   required: ["id"]) { p, _, a in
                let id = try a.requireUUID("id")
                guard let inst = p.instance(id) else { throw ToolError.notFound("Furniture", id) }
                let keys = ["name", "position", "rotationDeg", "size", "visible", "allowsOverlap", "materials", "options"]
                guard keys.contains(where: a.present) else { throw ToolError.invalid(nil, "Give at least one of: \(keys.joined(separator: ", "))") }
                let name = try a.nonEmptyString("name")
                let position = try a.p3("position", defaultZ: inst.position.z)
                let rotation = try a.double("rotationDeg")
                let size = try a.size3("size").map { try positive($0, "size") }
                let visible = try a.bool("visible")
                let allowsOverlap = try a.bool("allowsOverlap")
                var overrides: [UUID: UUID?] = [:]
                if let m = try a.object("materials") {
                    guard let d = p.definition(inst.definitionId) else { throw ToolError.notFound("Definition", inst.definitionId) }
                    for (ref, v) in m.values.sorted(by: { $0.key < $1.key }) {
                        let c = try component(d, ref, field: "materials.\(ref)")
                        overrides[c.id] = v.isNull ? .some(nil) : .some(try p.resolveMaterial(v, field: "materials.\(ref)"))
                    }
                }
                // Options first: choosing one clears overrides of the parts it colours, so explicit materials of this call win.
                if let o = a.raw("options"), !o.isNull { try applyOptions(&p, instance: id, o) }
                try p.updateInstance(id) { i in
                    if let name { i.name = name }
                    if let position { i.position = position }
                    if let rotation { i.rotationDeg = rotation }
                    if a.isNull("size") { i.size = nil } else if let size { i.size = size }
                    if let visible { i.visible = visible }
                    if let allowsOverlap { i.allowsOverlap = allowsOverlap }
                    for (c, m) in overrides { i.materialOverrides[c] = m }
                }
                return .object([:])
            },
            .write("furniture.define_state",
                   "Adds or replaces (same name) a named pose of a design, e.g. \"unfolded\". Instances switch with furniture.activate_state. An optional transition sets duration and easing of the animation into this state.",
                   ["definitionId": S.uuid("Design."), "name": S.str("State name."), "poses": poseSchema,
                    "size": S.size("Overall size in this state (default: derived)."), "makeDefault": S.bool("New instances start in this state."),
                    "transition": S.obj("Animation into this state.", [
                        "from": S.str("State name or id it starts from; omit/null = from the base pose."),
                        "durationMs": S.int("Duration, default 800."), "easing": S.str("Curve.", values: Easing.allCases.map(\.rawValue))])],
                   required: ["definitionId", "name"]) { p, _, a in
                let defId = try a.requireUUID("definitionId")
                guard let d = p.definition(defId) else { throw ToolError.notFound("Definition", defId) }
                var st = FurnitureState(name: try a.requireNonEmptyString("name"), poses: try parsePoses(a, d))
                if let s = try a.size3("size") { st.size = try positive(s, "size") }
                let sid = try p.defineState(definitionId: defId, st, makeDefault: try a.bool("makeDefault") ?? false)
                if let t = try a.object("transition") {
                    let from = try t.string("from")
                    var fromId: UUID?
                    if let from, let d2 = p.definition(defId) { fromId = try state(d2, from, field: "transition.from").id }
                    var track = AnimationTrack(fromStateId: fromId, toStateId: sid)
                    if let ms = try t.int("durationMs") {
                        guard (0...60_000).contains(ms) else { throw ToolError.invalid("transition.durationMs", "must be 0...60000") }
                        track.durationMs = Int(ms)
                    }
                    if let e = try t.enumValue("easing", Easing.self) { track.easing = e }
                    try p.addTrack(definitionId: defId, track)
                }
                return .object(["stateId": J.id(sid)])
            },
            .write("furniture.delete_state",
                   "Deletes a state of a design (by name or id) together with the animations from/to it. Placed furniture in that state returns to the design's default state; if it was the default, the first remaining state becomes the default.",
                   ["definitionId": S.uuid("Design."), "state": S.str("State name or id.")], required: ["definitionId", "state"]) { p, _, a in
                let defId = try a.requireUUID("definitionId")
                guard let d = p.definition(defId) else { throw ToolError.notFound("Definition", defId) }
                let st = try state(d, try a.requireString("state"), field: "state")
                try p.deleteState(definitionId: defId, stateId: st.id)
                return .object(["deletedStateId": J.id(st.id), "defaultStateId": p.definition(defId)?.defaultStateId.map(J.id) ?? .null])
            },
            .write("furniture.define_option_group",
                   "Adds or replaces (same name) an option group of a design, e.g. \"Colour\" or \"Door\": a set of choices, each changing the material and/or visibility of named parts. Placed pieces pick one choice per group (furniture.set_options), so one design covers every colour and front. Re-defining a group keeps the ids of choices with the same name, so placed pieces keep their pick. Options never change size or pose.",
                   ["definitionId": S.uuid("Design."), "name": S.str("Group name, unique within the design."),
                    "choices": S.arr("Choices, at most \(OptionGroup.maxChoices); the first is the default unless `defaultChoice` says otherwise.", items: S.obj("One choice.", [
                        "name": S.str("Choice name, unique within the group."),
                        "effects": S.obj("{\"<component name or id>\": {material?: material id/name, visible?: bool}}. visible false hides the part; true shows it again (never a part the design or its state hides)."),
                        "id": S.uuid("Optional id.")], required: ["name"])),
                    "defaultChoice": S.str("Choice name or id used by pieces that picked nothing (default: the first).")],
                   required: ["definitionId", "name", "choices"]) { p, _, a in
                let defId = try a.requireUUID("definitionId")
                guard let d = p.definition(defId) else { throw ToolError.notFound("Definition", defId) }
                let name = try a.requireNonEmptyString("name")
                let list = try a.requireArray("choices")
                guard !list.isEmpty else { throw ToolError.invalid("choices", "needs at least one choice") }
                var choices: [OptionChoice] = []
                for (i, item) in list.enumerated() {
                    let f = "choices[\(i)]"
                    let ca = try object(item, f, allowed: ["id", "name", "effects"])
                    var c = OptionChoice(id: try ca.uuid("id") ?? UUID(), name: try ca.requireNonEmptyString("name"))
                    if let e = ca.raw("effects"), !e.isNull { c.effects = try parseEffects(&p, e, definition: d, field: "\(f).effects") }
                    choices.append(c)
                }
                var g = OptionGroup(name: name, choices: choices)
                if let ref = try a.nonEmptyString("defaultChoice") {
                    guard let c = choices.first(where: { $0.id.uuidString.caseInsensitiveCompare(ref) == .orderedSame })
                            ?? choices.first(where: { $0.name.caseInsensitiveCompare(ref) == .orderedSame }) else {
                        throw ToolError.invalid("defaultChoice", "'\(ref)' is not one of the given choices")
                    }
                    g.defaultChoiceId = c.id
                }
                let gid = try p.defineOptionGroup(definitionId: defId, g)
                let stored = p.definition(defId)?.optionGroups.first { $0.id == gid }
                return .object(["groupId": J.id(gid),
                                "choiceIds": .object((stored?.choices ?? []).reduce(into: [:]) { $0[$1.name] = J.id($1.id) })])
            },
            .write("furniture.delete_option_group",
                   "Deletes an option group of a design (by name or id). Placed pieces forget their pick in it and show the design's own look for those parts.",
                   ["definitionId": S.uuid("Design."), "group": S.str("Group name or id.")], required: ["definitionId", "group"]) { p, _, a in
                let defId = try a.requireUUID("definitionId")
                guard let d = p.definition(defId) else { throw ToolError.notFound("Definition", defId) }
                let g = try optionGroup(d, try a.requireString("group"), field: "group")
                try p.deleteOptionGroup(definitionId: defId, groupId: g.id)
                return .object(["deletedGroupId": J.id(g.id)])
            },
            .write("furniture.set_options",
                   "Chooses options (colour, front, handle) on placed furniture. Group and choice are given by name or id; null returns a group to its default. Clears the pieces' own material overrides of the parts a chosen group colours. Pieces may be of different designs; every group must exist on every piece, else nothing changes.",
                   ["ids": S.uuids("Furniture ids."), "options": optionsSchema], required: ["ids", "options"]) { p, _, a in
                let ids = try a.requireUUIDList("ids")
                guard let o = a.raw("options"), o.objectValue?.isEmpty == false else { throw ToolError.invalid("options", "give at least one group") }
                for id in ids {
                    guard p.instance(id) != nil else { throw ToolError.notFound("Furniture", id) }
                    try applyOptions(&p, instance: id, o)
                }
                return .object(["ids": J.ids(ids)])
            },
            .write("furniture.set_animation",
                   "Sets the animation between two states of a design, replacing an existing one with the same from/to. `from` null = from any state (base pose).",
                   ["definitionId": S.uuid("Design."), "from": .object(["description": "State name or id it starts from; null = from any state."]),
                    "to": S.str("State name or id it ends in."), "durationMs": S.int("Duration 0...60000, default 800."),
                    "easing": S.str("Curve (default easeInOut).", values: Easing.allCases.map(\.rawValue))],
                   required: ["definitionId", "to"]) { p, _, a in
                let defId = try a.requireUUID("definitionId")
                guard let d = p.definition(defId) else { throw ToolError.notFound("Definition", defId) }
                let to = try state(d, try a.requireString("to"), field: "to").id
                let from = try a.string("from").map { try state(d, $0, field: "from").id }
                var ms = 800
                if let v = try a.int("durationMs") {
                    guard (0...60_000).contains(v) else { throw ToolError.invalid("durationMs", "must be 0...60000") }
                    ms = Int(v)
                }
                let easing = try a.enumValue("easing", Easing.self) ?? .easeInOut
                let id = try p.setAnimation(definitionId: defId, from: from, to: to, durationMs: ms, easing: easing)
                return .object(["trackId": J.id(id)])
            },
            .write("furniture.activate_state",
                   "Switches placed furniture to a named state of its design. `state` null returns to the base pose. All pieces must have a state of that name.",
                   ["ids": S.uuids("Furniture ids."), "state": .object(["description": "State name or id; null = base pose."])],
                   required: ["ids"]) { p, _, a in
                let ids = try a.requireUUIDList("ids")
                guard a.present("state") else { throw ToolError.missing("state") }
                let ref = try a.string("state")
                for id in ids {
                    guard let inst = p.instance(id) else {
                        if p.kind(of: id) != nil { throw ToolError.invalid("ids", "\(id.uuidString.lowercased()) is not furniture") }
                        throw ToolError.notFound("Furniture", id)
                    }
                    guard let ref else {
                        try p.activateState([id], stateId: nil)
                        continue
                    }
                    guard let d = p.definition(inst.definitionId) else { throw ToolError.notFound("Definition", inst.definitionId) }
                    try p.activateState([id], stateId: try state(d, ref, field: "state").id)
                }
                return .object(["ids": J.ids(ids)])
            },
            .write("furniture.save_configuration",
                   "Stores the current arrangement of a furniture group (positions, rotations, visibility, states of all members) as a named configuration and marks it active. An existing configuration of the same name is overwritten.",
                   ["groupId": S.uuid("Group."), "name": S.str("Configuration name.")], required: ["groupId", "name"]) { p, _, a in
                let g = try requireGroup(p, a)
                let id = try p.saveConfiguration(groupId: g.id, name: try a.requireNonEmptyString("name"))
                return .object(["configurationId": J.id(id), "groupId": J.id(g.id)])
            },
            .write("furniture.activate_configuration",
                   "Rearranges a group's members to a saved configuration (by name or id).",
                   ["groupId": S.uuid("Group."), "configuration": S.str("Configuration name or id.")], required: ["groupId", "configuration"]) { p, _, a in
                let g = try requireGroup(p, a)
                let cfg = try configuration(g, try a.requireString("configuration"), field: "configuration")
                try p.activateConfiguration(groupId: g.id, configurationId: cfg.id)
                return .object(["configurationId": J.id(cfg.id), "groupId": J.id(g.id), "name": .string(cfg.name)])
            },
            .write("furniture.update_configuration",
                   "Renames a saved configuration of a group, or duplicates it (copy named \"<name> copy\", numbered on a clash). Give `name` and/or `duplicate: true`; with both, the copy gets the new name.",
                   ["groupId": S.uuid("Group."), "configuration": S.str("Configuration name or id."),
                    "name": S.str("New name."), "duplicate": S.bool("Also create a copy.")], required: ["groupId", "configuration"]) { p, _, a in
                let g = try requireGroup(p, a)
                let cfg = try configuration(g, try a.requireString("configuration"), field: "configuration")
                let newName = try a.nonEmptyString("name")
                let dup = try a.bool("duplicate") ?? false
                guard newName != nil || dup else { throw ToolError.invalid(nil, "Give name and/or duplicate") }
                var o: [String: JSONValue] = ["groupId": J.id(g.id)]
                if dup {
                    let copy = try p.duplicateConfiguration(groupId: g.id, configurationId: cfg.id)
                    if let newName { try p.renameConfiguration(groupId: g.id, configurationId: copy, to: newName) }
                    o["configurationId"] = J.id(copy)
                    o["name"] = .string(p.group(g.id)?.configurations.first { $0.id == copy }?.name ?? "")
                } else if let newName {
                    try p.renameConfiguration(groupId: g.id, configurationId: cfg.id, to: newName)
                    o["configurationId"] = J.id(cfg.id)
                    o["name"] = .string(newName.trimmingCharacters(in: .whitespaces))
                }
                return .object(o)
            },
            .write("furniture.delete_configuration", "Deletes a saved configuration of a group (by name or id). The current arrangement stays as it is.",
                   ["groupId": S.uuid("Group."), "configuration": S.str("Configuration name or id.")], required: ["groupId", "configuration"]) { p, _, a in
                let g = try requireGroup(p, a)
                let cfg = try configuration(g, try a.requireString("configuration"), field: "configuration")
                try p.deleteConfiguration(groupId: g.id, configurationId: cfg.id)
                return .object(["configurationId": J.id(cfg.id), "groupId": J.id(g.id)])
            },
            .read("furniture.list_configurations", "Lists the saved configurations of one group, or of all groups when groupId is omitted.",
                  ["groupId": S.uuid("Only this group.")]) { env, a in
                let p = env.project
                let groups: [FurnitureGroup]
                if a.has("groupId") { groups = [try requireGroup(p, a)] } else { groups = p.groups }
                return .object(["groups": .array(groups.map { configurationRows(p, $0) }), "revision": .int(p.revision)])
            },
            .write("furniture.replace_definition",
                   "Swaps the model of placed furniture: every piece placed from design `fromId` (or only `instanceIds`) switches to design `toId` and keeps its position, rotation, size and name; its state, option choices and colours carry over to the state, option group and part of the same name (otherwise the default). Then the old design is deleted when nothing uses it any more (not if built-in or linked to a product), unless `removeOld` is false. Use this instead of creating a design and re-placing pieces, so no unused design stays behind.",
                   ["fromId": S.uuid("Design to replace."), "toId": S.uuid("Design to use instead."),
                    "instanceIds": S.uuids("Only switch these pieces (placed from fromId); default all pieces of fromId."),
                    "removeOld": S.bool("Delete the old design afterwards when unused (default true).")],
                   required: ["fromId", "toId"]) { p, _, a in
                let from = try a.requireUUID("fromId"), to = try a.requireUUID("toId")
                for (field, id) in [("fromId", from), ("toId", to)] where p.definition(id) == nil {
                    if p.kind(of: id) != nil { throw ToolError.invalid(field, "\(id.uuidString.lowercased()) is not a furniture design") }
                    throw ToolError.notFound("Definition", id)
                }
                let only = try a.uuidList("instanceIds")
                let r = try p.replaceDefinition([from], with: to, only: only, removeOld: try a.bool("removeOld") ?? true)
                return .object(["ids": J.ids(r.instanceIds), "replaced": .int(Int64(r.instanceIds.count)),
                                "removedDefinitions": .array(r.removedDefinitionIds.map { .object(["id": J.id($0)]) }),
                                "keptDefinitionIds": J.ids(r.keptDefinitionIds)])
            },
            .write("furniture.delete_definitions",
                   "Deletes furniture designs that no piece is placed from. All or nothing: a design with placed pieces or a built-in one fails the call and nothing changes; the error names every blocker. Placed furniture is never touched; a product linked to a deleted design stays (unlinked). One undo step.",
                   ["ids": S.uuids("Design ids from furniture.list_definitions (own designs only).")],
                   required: ["ids"]) { p, _, a in
                let ids = try a.requireUUIDList("ids")
                try SceneTools.requireUnreferenced(p, ids)
                let gone = try p.deleteDefinitions(ids)
                return .object(["deleted": J.ids(gone), "count": .int(Int64(gone.count))])
            },
            .action("furniture.prune_unused_definitions",
                    "Deletes every own furniture design that no piece is placed from and no product is linked to (built-in designs stay). `dryRun` defaults to TRUE: it only lists what would go; pass dryRun false to delete. One undo step.",
                    ["dryRun": S.bool("List only (default true). Pass false to delete.")]) { env, a in
                let dry = try a.bool("dryRun") ?? true
                let p = env.project
                let prunable = p.prunableDefinitions()
                let keep = Set(prunable.map(\.id))
                let linked = p.unusedDefinitions().filter { !keep.contains($0.id) }
                var extra: [String: JSONValue] = ["unusedLinkedKept": J.ids(linked.map(\.id))]
                if dry {
                    extra["wouldRemove"] = removedRows(p, prunable.map(\.id))
                    extra["count"] = .int(Int64(prunable.count))
                    extra["dryRun"] = true
                    extra["committed"] = false
                    extra["revision"] = .int(p.revision)
                    return .object(extra)
                }
                var removed: [UUID] = []
                var names: JSONValue = .null
                let result = try env.store.apply("Agent: prune unused definitions", options: CommandOptions(origin: .agent(env.clientId))) { q in
                    names = removedRows(q, prunable.map(\.id))
                    removed = try q.removeUnusedDefinitions()
                }
                extra["removed"] = names
                extra["count"] = .int(Int64(removed.count))
                return ToolRegistry.mutationJSON(committed: result.committed, revision: result.revision, changes: result.changes,
                                                 extra: .object(extra), dryRun: false, project: env.store.project)
            },
        ]
    }
}
