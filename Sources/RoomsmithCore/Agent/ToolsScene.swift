import Foundation

// MARK: - Rows (list rows, details, snapshot lines)

enum Rows {
    struct Entry {
        let kind: ObjectKind
        let id: UUID
    }

    /// Kinds `scene.list_objects` can return.
    static let listable: [ObjectKind] = [.level, .wall, .room, .opening, .dimension, .furniture, .group, .material, .definition, .product]
    /// Default kinds of lists and the snapshot: the things that make up the floor plan.
    static let snapshotKinds: [ObjectKind] = [.level, .wall, .room, .opening, .dimension, .furniture, .group]

    static func ids(_ p: Project, _ kind: ObjectKind) -> [UUID] {
        switch kind {
        case .level: p.levels.map(\.id)
        case .wall: p.walls.map(\.id)
        case .room: p.rooms.map(\.id)
        case .opening: p.openings.map(\.id)
        case .dimension: p.dimensions.map(\.id)
        case .furniture: p.instances.map(\.id)
        case .group: p.groups.map(\.id)
        case .material: p.materials.map(\.id)
        case .definition: p.definitions.map(\.id)
        case .product: p.products.map(\.id)
        default: []
        }
    }

    /// Entries in kind order, then array order (stable across calls as long as the project does not change).
    static func entries(_ p: Project, kinds: [ObjectKind], levelId: UUID? = nil, query: String? = nil,
                        category: String? = nil, roomId: UUID? = nil) -> [Entry] {
        let q = query?.lowercased()
        let cat = category?.lowercased()
        let room = roomId.flatMap { p.room($0) }
        var out: [Entry] = []
        for kind in kinds {
            for id in ids(p, kind) {
                if let levelId, p.levelId(of: id) != levelId { continue }
                if let q, !p.displayName(of: id).lowercased().contains(q) { continue }
                if let cat, categoryOf(p, id, kind)?.lowercased() != cat { continue }
                if let room {
                    guard let pos = position(p, id, kind), p.levelId(of: id) == room.levelId, Geo.contains(room.points, pos) else { continue }
                }
                out.append(Entry(kind: kind, id: id))
            }
        }
        return out
    }

    static func categoryOf(_ p: Project, _ id: UUID, _ kind: ObjectKind) -> String? {
        switch kind {
        case .furniture: p.instance(id).flatMap { p.definition($0.definitionId)?.category }
        case .definition: p.definition(id)?.category
        case .product: p.product(id)?.category
        default: nil
        }
    }

    /// Floor-plan position used for room filtering (furniture and groups only).
    static func position(_ p: Project, _ id: UUID, _ kind: ObjectKind) -> P2? {
        switch kind {
        case .furniture: p.instance(id)?.position.xy
        case .group: p.group(id)?.origin.xy
        default: nil
        }
    }

    /// `{id, kind, name, rev, levelId, ...short geometry}`. `includeRev` is false while an edit is still running
    /// (revisions are stamped after the diff).
    static func row(_ p: Project, _ e: Entry, includeRev: Bool = true) -> JSONValue {
        var o: [String: JSONValue] = ["id": J.id(e.id), "kind": .string(e.kind.rawValue), "name": .string(p.displayName(of: e.id))]
        if includeRev, let r = p.rev(of: e.id) { o["rev"] = .int(r) }
        if let l = p.levelId(of: e.id) { o["levelId"] = J.id(l) }
        switch e.kind {
        case .level:
            if let x = p.level(e.id) {
                o["elevationMm"] = .int(x.elevation); o["heightMm"] = .int(x.height)
                o["visible"] = .bool(x.visible); o["locked"] = .bool(x.locked)
            }
        case .wall:
            if let x = p.wall(e.id) {
                o["start"] = J.p2(x.start); o["end"] = J.p2(x.end)
                o["lengthMm"] = J.mm(p.wallLength(x))
                o["thicknessMm"] = .int(x.thickness); o["heightMm"] = .int(x.height); o["locked"] = .bool(x.locked)
            }
        case .room:
            if let x = p.room(e.id) {
                o["pointCount"] = .int(Int64(x.points.count))
                o["areaM2"] = .number((Geo.area(x.points) / 10_000).rounded() / 100)
                o["points"] = .array(x.points.map(J.p2))
            }
        case .opening:
            if let x = p.opening(e.id) {
                o["type"] = .string(x.kind.rawValue); o["wallId"] = J.id(x.wallId)
                o["offsetMm"] = .int(x.offset); o["widthMm"] = .int(x.width)
                o["heightMm"] = .int(x.height); o["sillMm"] = .int(x.sill)
            }
        case .dimension:
            if let x = p.dimension(e.id) {
                o["a"] = J.p2(x.a); o["b"] = J.p2(x.b); o["lengthMm"] = J.mm(Geo.distance(x.a, x.b))
            }
        case .furniture:
            if let x = p.instance(e.id) {
                o["definitionId"] = J.id(x.definitionId)
                if let d = p.definition(x.definitionId) {
                    o["definition"] = .string(d.name); o["category"] = .string(d.category)
                    o["size"] = J.size(FurnitureResolver.size(of: x, definition: d))
                }
                o["position"] = J.p3(x.position); o["rotationDeg"] = .number(x.rotationDeg)
                if let room = p.roomName(at: x.position.xy, level: x.levelId) { o["room"] = .string(room) }
                if let g = x.groupId { o["groupId"] = J.id(g) }
                o["locked"] = .bool(x.locked); o["visible"] = .bool(x.visible)
                o["allowsOverlap"] = .bool(x.allowsOverlap)
            }
        case .group:
            if let x = p.group(e.id) {
                o["memberCount"] = .int(Int64(x.memberIds.count)); o["origin"] = J.p3(x.origin)
                o["rotationDeg"] = .number(x.rotationDeg); o["locked"] = .bool(x.locked)
                o["configurationCount"] = .int(Int64(x.configurations.count))
                if let c = x.activeConfigurationId, let cfg = x.configurations.first(where: { $0.id == c }) {
                    o["activeConfiguration"] = .string(cfg.name)
                }
            }
        case .material:
            if let x = p.material(e.id) { o["color"] = .string(x.color.hex) }
        case .definition:
            if let x = p.definition(e.id) {
                o["category"] = .string(x.category); o["size"] = J.size(x.size)
                o["componentCount"] = .int(Int64(x.components.count)); o["stateCount"] = .int(Int64(x.states.count))
                o["builtin"] = .bool(x.builtin)
            }
        case .product:
            if let x = p.product(e.id) {
                o["category"] = .string(x.category); o["status"] = .string(x.status.rawValue)
                if let price = x.priceMinor { o["priceMinor"] = .int(price); o["currency"] = .string(x.currency) }
            }
        default: break
        }
        return .object(o)
    }

    /// One text line for the scene snapshot: `kind id "name" rev=N key=value ...`.
    static func line(_ row: JSONValue) -> String {
        guard let o = row.objectValue else { return "" }
        var s = "\(o["kind"]?.stringValue ?? "?") \(o["id"]?.stringValue ?? "?") \"\(o["name"]?.stringValue ?? "")\""
        if let r = o["rev"]?.int64Value { s += " rev=\(r)" }
        for k in o.keys.sorted() where !["id", "kind", "name", "rev"].contains(k) {
            if k == "points" { continue }
            s += " \(k)=\(compact(o[k]!))"
        }
        return s
    }

    private static func compact(_ v: JSONValue) -> String {
        if let s = v.stringValue { return s.contains(" ") ? "\"\(s)\"" : s }
        if let x = v["x"]?.int64Value, let y = v["y"]?.int64Value {
            if let z = v["z"]?.int64Value { return "(\(x),\(y),\(z))" }
            return "(\(x),\(y))"
        }
        if let w = v["width"]?.int64Value, let d = v["depth"]?.int64Value, let h = v["height"]?.int64Value { return "\(w)x\(d)x\(h)" }
        return v.jsonString()
    }

    // MARK: Detail

    private static func pose(_ id: UUID, _ pose: ComponentPose) -> JSONValue {
        var o: [String: JSONValue] = ["componentId": J.id(id)]
        if let x = pose.position { o["position"] = J.p3(x) }
        if let x = pose.rotation { o["rotation"] = J.r3(x) }
        if let x = pose.size { o["size"] = J.size(x) }
        if let x = pose.visible { o["visible"] = .bool(x) }
        return .object(o)
    }

    static func stateJSON(_ s: FurnitureState) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": J.id(s.id), "name": .string(s.name),
            "poses": .array(s.poses.sorted { $0.key.uuidString < $1.key.uuidString }.map { pose($0.key, $0.value) }),
        ]
        if let sz = s.size { o["size"] = J.size(sz) }
        return .object(o)
    }

    /// An option group with its choices and the effect of each choice.
    static func optionGroupJSON(_ g: OptionGroup) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": J.id(g.id), "name": .string(g.name),
            "choices": .array(g.choices.map { c in
                .object(["id": J.id(c.id), "name": .string(c.name),
                         "effects": .array(c.effects.sorted { $0.key.uuidString < $1.key.uuidString }.map { k, e in
                             var x: [String: JSONValue] = ["componentId": J.id(k)]
                             if let m = e.materialId { x["materialId"] = J.id(m) }
                             if let v = e.visible { x["visible"] = .bool(v) }
                             return .object(x)
                         })])
            }),
        ]
        if let d = g.defaultChoiceId { o["defaultChoiceId"] = J.id(d) }
        return .object(o)
    }

    static func componentJSON(_ c: Component) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": J.id(c.id), "name": .string(c.name), "shape": .string(c.shape.rawValue),
            "position": J.p3(c.position), "size": J.size(c.size), "rotation": J.r3(c.rotation), "visible": .bool(c.visible),
        ]
        if let m = c.materialId { o["materialId"] = J.id(m) }
        return .object(o)
    }

    static func memberPoseJSON(_ id: UUID, _ m: MemberPose) -> JSONValue {
        var o: [String: JSONValue] = ["memberId": J.id(id), "local": J.p3(m.local), "rotationDeg": .number(m.rotationDeg), "visible": .bool(m.visible)]
        if let s = m.stateId { o["stateId"] = J.id(s) }
        return .object(o)
    }

    /// Full detail of one object.
    static func detail(_ p: Project, _ id: UUID) throws -> JSONValue {
        let kind = try p.requireKind(id)
        var o = (row(p, Entry(kind: kind, id: id)).objectValue) ?? [:]
        switch kind {
        case .furniture:
            guard let x = p.instance(id) else { break }
            o["stateId"] = x.stateId.map(J.id) ?? .null
            if let d = p.definition(x.definitionId) {
                let rect = FurnitureResolver.footprint(of: x, definition: d)
                let b = rect.bounds
                o["footprint"] = .object([
                    "center": J.p2(x.position.xy), "rotationDeg": .number(x.rotationDeg),
                    "bboxMin": J.v2(b.min), "bboxMax": J.v2(b.max),
                    "corners": .array(rect.corners.map(J.v2)),
                ])
                if let sid = x.stateId, let st = d.states.first(where: { $0.id == sid }) {
                    o["state"] = .object(["id": J.id(sid), "name": .string(st.name)])
                } else if let def = d.defaultStateId, let st = d.states.first(where: { $0.id == def }) {
                    o["state"] = .object(["id": J.id(def), "name": .string(st.name), "isDefault": true])
                }
                o["availableStates"] = .array(d.states.map { .object(["id": J.id($0.id), "name": .string($0.name)]) })
                if !d.optionGroups.isEmpty {
                    // Each group with its choices and the one in force (the piece's pick, else the default).
                    o["availableOptions"] = .array(d.optionGroups.map { g in
                        var gj = optionGroupJSON(g).objectValue ?? [:]
                        gj["choices"] = .array(g.choices.map { .object(["id": J.id($0.id), "name": .string($0.name)]) })
                        if let c = g.effectiveChoice(selected: x.optionSelection[g.id]) {
                            gj["selectedChoiceId"] = J.id(c.id)
                            gj["selectedChoice"] = .string(c.name)
                        }
                        return .object(gj)
                    })
                    o["options"] = .object(d.optionGroups.reduce(into: [:]) { acc, g in
                        if let c = g.effectiveChoice(selected: x.optionSelection[g.id]) { acc[g.name] = .string(c.name) }
                    })
                }
            }
            if let customSize = x.size { o["customSize"] = J.size(customSize) }
            o["materialOverrides"] = .object(x.materialOverrides.reduce(into: [:]) { $0[$1.key.uuidString.lowercased()] = J.id($1.value) })
            if let g = x.groupId, let grp = p.group(g) { o["group"] = .object(["id": J.id(g), "name": .string(grp.name)]) }
            if let pid = x.productId ?? p.definition(x.definitionId)?.productId, let prod = p.product(pid) {
                o["product"] = .object(["id": J.id(pid), "name": .string(prod.name), "category": .string(prod.category),
                                        "status": .string(prod.status.rawValue)])
            }
        case .group:
            guard let x = p.group(id) else { break }
            o["memberIds"] = J.ids(x.memberIds)
            o["members"] = .array(x.memberIds.map { .object(["id": J.id($0), "name": .string(p.displayName(of: $0))]) })
            o["activeConfigurationId"] = x.activeConfigurationId.map(J.id) ?? .null
            o["configurations"] = .array(x.configurations.map { c in
                .object(["id": J.id(c.id), "name": .string(c.name),
                         "poses": .array(c.poses.sorted { $0.key.uuidString < $1.key.uuidString }.map { memberPoseJSON($0.key, $0.value) })])
            })
            if let pid = x.productId { o["productId"] = J.id(pid) }
        case .definition:
            guard let x = p.definition(id) else { break }
            o["components"] = .array(x.components.map(componentJSON))
            o["states"] = .array(x.states.map(stateJSON))
            if !x.optionGroups.isEmpty { o["optionGroups"] = .array(x.optionGroups.map(optionGroupJSON)) }
            o["defaultStateId"] = x.defaultStateId.map(J.id) ?? .null
            o["tags"] = .array(x.tags.map { .string($0) })
            if let k = x.catalogKey { o["catalogKey"] = .string(k) }
            if let pid = x.productId { o["productId"] = J.id(pid) }
            o["trackCount"] = .int(Int64(x.tracks.count))
        case .level: merge(&o, J.encode(p.level(id)))
        case .wall: merge(&o, J.encode(p.wall(id)))
        case .room: merge(&o, J.encode(p.room(id)))
        case .opening: merge(&o, J.encode(p.opening(id)))
        case .dimension: merge(&o, J.encode(p.dimension(id)))
        case .material: merge(&o, J.encode(p.material(id)))
        case .product: merge(&o, J.encode(p.product(id)))
        case .camera: merge(&o, J.encode(p.savedCamera(id)))
        case .asset: merge(&o, J.encode(p.asset(id)))
        case .background: merge(&o, J.encode(p.background(id)))
        }
        o["kind"] = .string(kind.rawValue)
        o["projectRevision"] = .int(p.revision)
        return .object(o)
    }

    private static func merge(_ o: inout [String: JSONValue], _ extra: JSONValue) {
        for (k, v) in extra.objectValue ?? [:] where o[k] == nil { o[k] = v }
    }
}

// MARK: - scene.*

enum SceneTools {
    static let createKinds: [String: String] = [
        "wall": "geometry.create_wall", "room": "geometry.create_room", "opening": "geometry.add_opening",
        "dimension": "geometry.create_dimension", "level": "geometry.create_level",
        "furniture": "furniture.create_instance", "product": "catalog.create_product", "group": "scene.group_objects",
    ]

    /// Rows of the requested objects in their state inside a running edit.
    static func rowsAfter(_ p: Project, _ ids: [UUID]) -> JSONValue {
        .array(ids.compactMap { id in p.kind(of: id).map { Rows.row(p, Rows.Entry(kind: $0, id: id), includeRev: false) } })
    }

    /// Refuses to delete a material, product or furniture definition that is still used; the error lists the users.
    static func requireUnreferenced(_ p: Project, _ ids: [UUID]) throws {
        var blockers: [JSONValue] = []
        var text: [String] = []
        let doomed = p.deletionSet(ids)
        for id in ids {
            let refs = p.references(to: id).filter { !doomed.contains($0.id) } // users deleted in the same call do not block
            guard !refs.isEmpty else { continue }
            let kind = p.kind(of: id)?.rawValue ?? "object"
            text.append("\(kind) '\(p.displayName(of: id))' is still used by \(refs.count) place(s)")
            blockers.append(.object([
                "id": J.id(id), "name": .string(p.displayName(of: id)), "kind": .string(kind),
                "references": .array(refs.map { .object(["id": J.id($0.id), "kind": .string($0.kind.rawValue),
                                                         "name": .string($0.name), "role": .string($0.role)]) }),
            ]))
        }
        guard !blockers.isEmpty else { return }
        throw AgentError(code: AgentError.invalidArgument,
                         message: "Cannot delete: \(text.joined(separator: "; ")). Remove or replace the references first.",
                         details: .object(["referenced": .array(blockers)]))
    }

    @MainActor
    static func specs() -> [ToolSpec] {
        var create = ToolSpec.write(
            "scene.create_object",
            "Creates one object. `kind` selects the creating tool (wall, room, opening, dimension, level, furniture, product, group); all other arguments are the arguments of that tool (geometry.create_wall, geometry.create_room, geometry.add_opening, geometry.create_dimension, geometry.create_level, furniture.create_instance, catalog.create_product, scene.group_objects).",
            ["kind": S.str("What to create.", values: createKinds.keys.sorted())], required: ["kind"]) { p, env, a in
            let kind = try a.requireString("kind")
            guard let tool = createKinds[kind] else {
                throw ToolError.invalid("kind", "must be one of: \(createKinds.keys.sorted().joined(separator: ", "))")
            }
            var inner = a.values
            for k in ["kind"] + Array(ToolSpec.commonKeys) { inner[k] = nil }
            return try env.registry.runInner(tool, .object(inner), &p, env, allowObjectRevisions: false)
        }
        create.openArguments = true

        return [
            .read("scene.list_objects",
                  "Lists objects (paginated): rows with id, kind, name, rev, levelId and short geometry. Default kinds: level, wall, room, opening, dimension, furniture, group.",
                  ["kind": S.str("One kind, or omit for the floor-plan kinds.", values: Rows.listable.map(\.rawValue)),
                   "levelId": S.uuid("Only objects on this level."),
                   "query": S.str("Case-insensitive substring of the name."),
                   "category": S.str("Furniture/definition/product category, e.g. \"sofa\" (exact, case-insensitive)."),
                   "roomId": S.uuid("Only furniture and groups whose position lies inside this room."),
                   "limit": S.limit, "cursor": S.cursor]) { env, a in
                let p = env.project
                let page = try PageRequest(a)
                var kinds = Rows.snapshotKinds
                if let k = try a.enumValue("kind", ObjectKind.self) {
                    guard Rows.listable.contains(k) else {
                        throw ToolError.invalid("kind", "must be one of: \(Rows.listable.map(\.rawValue).joined(separator: ", "))")
                    }
                    kinds = [k]
                }
                let level = try a.uuid("levelId")
                if let level, p.level(level) == nil { throw ToolError.notFound("Level", level) }
                let room = try a.uuid("roomId")
                if let room, p.room(room) == nil { throw ToolError.notFound("Room", room) }
                let entries = Rows.entries(p, kinds: kinds, levelId: level, query: try a.string("query"),
                                           category: try a.string("category"), roomId: room)
                return page.result(entries, revision: p.revision) { Rows.row(p, $0) }
            },
            .read("scene.get_object", "Full detail of one object: rev, geometry, footprint bounding box, state, group, product, definition components/states.",
                  ["id": S.uuid("Object id.")], required: ["id"]) { env, a in
                try Rows.detail(env.project, try a.requireUUID("id"))
            },
            .action("scene.select_objects",
                    "Reads or changes the selection shown in the app (does not change the document, but needs write access unless mode is get without levelId). Modes: replace (default), add, remove, clear, get.",
                    ["ids": S.arr("Object ids.", items: ["type": "string"]),
                     "mode": S.str("How to apply `ids`.", values: ["replace", "add", "remove", "clear", "get"]),
                     "levelId": S.uuid("Also make this level the active one.")]) { env, a in
                let p = env.project
                let mode = try a.string("mode") ?? "replace"
                guard ["replace", "add", "remove", "clear", "get"].contains(mode) else {
                    throw ToolError.invalid("mode", "must be one of: replace, add, remove, clear, get")
                }
                // Changes what the user sees (selection, active level), so a read-only agent must not do it; plain `get` is a read.
                if mode != "get" || a.has("levelId") { try env.requireWriteAccess("scene.select_objects changes what the user sees") }
                let ids = try a.uuidList("ids") ?? []
                if mode == "replace" || mode == "add" { try p.requireAll(ids) }
                if (mode == "add" || mode == "remove") && ids.isEmpty { throw ToolError.missing("ids") }
                if let level = try a.uuid("levelId") {
                    guard p.level(level) != nil else { throw ToolError.notFound("Level", level) }
                    env.context.activeLevelId = level
                }
                var next = env.context.selection
                switch mode {
                case "replace": next = Set(ids)
                case "add": next.formUnion(ids)
                case "remove": next.subtract(ids)
                case "clear": next = []
                default: break
                }
                env.context.setSelectionByAgent(next)
                return .object(["selection": J.ids(env.context.selection.sorted { $0.uuidString < $1.uuidString }),
                                "activeLevelId": J.id(env.context.activeLevelId)])
            },
            create,
            .write("scene.move_objects",
                   "Moves objects exactly (no snapping), either by `delta` or, for one object, to the absolute position `to`. Groups move with all members; a lone opening slides along its wall (delta.x along the wall). Millimetres, x east, y north.",
                   ["ids": S.uuids("Objects to move."),
                    "delta": S.p3("Offset to add."), "to": S.p3("New absolute position of the single object (z optional: keeps the current height).")],
                   required: ["ids"]) { p, _, a in
                let ids = try a.requireUUIDList("ids")
                try p.requireAll(ids)
                let delta = try a.p3("delta"), toRaw = a.raw("to")
                guard (delta == nil) != (toRaw == nil) else { throw ToolError.invalid(nil, "Give exactly one of `delta` or `to`") }
                if let delta {
                    try p.moveObjects(ids, by: delta)
                } else if let toRaw {
                    guard ids.count == 1 else { throw ToolError.invalid("ids", "`to` needs exactly one id") }
                    var to = try Args.parseP3(toRaw, "to")
                    if toRaw["z"].map({ $0.isNull }) ?? true { to.z = p.instance(ids[0])?.position.z ?? 0 }
                    try p.moveObject(ids[0], to: to)
                }
                return .object(["objects": rowsAfter(p, ids)])
            },
            .write("scene.rotate_objects",
                   "Rotates objects counter-clockwise by `degrees` around their common centre or the given pivot (millimetres).",
                   ["ids": S.uuids("Objects to rotate."), "degrees": S.num("Angle to add, counter-clockwise."),
                    "pivot": S.p2("Rotation centre; default: centre of the objects.")], required: ["ids", "degrees"]) { p, _, a in
                let ids = try a.requireUUIDList("ids")
                try p.requireAll(ids)
                try p.rotateObjects(ids, by: try a.requireDouble("degrees"), pivot: try a.p2("pivot"))
                return .object(["objects": rowsAfter(p, ids)])
            },
            .write("scene.set_material",
                   "Sets or clears a material. Slots: wallLeft, wallRight, wallBoth, roomFloor, roomCeiling, openingFrame, allComponents (furniture), component:<componentId>.",
                   ["ids": S.uuids("Objects to change."), "slot": S.str("Where to apply the material."),
                    "material": .object(["description": "Material id or exact name (e.g. from scene.list_objects kind=material); null removes the material."])],
                   required: ["ids", "slot"]) { p, _, a in
                let ids = try a.requireUUIDList("ids")
                try p.requireAll(ids)
                let slotName = try a.requireString("slot")
                guard let slot = MaterialSlot(string: slotName) else {
                    throw ToolError.invalid("slot", "unknown slot '\(slotName)'. Use wallLeft, wallRight, wallBoth, roomFloor, roomCeiling, openingFrame, allComponents or component:<uuid>")
                }
                guard a.present("material") else { throw ToolError.missing("material") }
                let material = try a.raw("material").map { try p.resolveMaterial($0, field: "material") }
                try p.setMaterial(ids, slot: slot, materialId: material)
                return .object(["materialId": material.map(J.id) ?? .null])
            },
            .write("scene.group_objects", "Groups furniture into a named group that moves as one.",
                   ["ids": S.uuids("Furniture to group."), "name": S.str("Group name."),
                    "id": S.uuid("Optional id for the new group (lets later batch steps refer to it).")], required: ["ids", "name"]) { p, _, a in
                let ids = try a.requireUUIDList("ids")
                try p.requireAll(ids)
                let gid = try p.groupObjects(ids, name: try a.requireNonEmptyString("name"), id: try a.uuid("id") ?? UUID())
                return .object(["id": J.id(gid), "groupId": J.id(gid)])
            },
            .write("scene.ungroup_objects", "Dissolves groups; the members stay where they are.",
                   ["ids": S.uuids("Group ids.")], required: ["ids"]) { p, _, a in
                let ids = try a.requireUUIDList("ids")
                try p.requireAll(ids)
                var released: [UUID] = []
                for gid in ids {
                    guard p.group(gid) != nil else { throw ToolError.invalid("ids", "\(gid.uuidString.lowercased()) is not a group") }
                    released += try p.ungroup(gid)
                }
                return .object(["released": J.ids(released)])
            },
            .write("scene.delete_objects", "Deletes objects (walls take their openings with them; deleting a group removes its members).",
                   ["ids": S.uuids("Objects to delete.")], required: ["ids"]) { p, _, a in
                let ids = try a.requireUUIDList("ids")
                try p.requireAll(ids)
                try requireUnreferenced(p, ids)
                return .object(["deleted": J.ids(try p.deleteObjects(ids))])
            },
            .write("scene.rename_object",
                   "Renames an object: level, room, opening, furniture, group, material, furniture definition, product or saved camera. Walls, dimensions, backgrounds and assets have no name.",
                   ["id": S.uuid("Object id."), "name": S.str("New name.")], required: ["id", "name"]) { p, _, a in
                let id = try a.requireUUID("id")
                try p.requireAll([id])
                try p.renameObject(id, to: try a.requireNonEmptyString("name"))
                return .object(["id": J.id(id), "name": .string(p.displayName(of: id))])
            },
            .write("scene.align_objects",
                   "Aligns objects to a common edge or centre line: left = smallest x, right = largest x, top = largest y (north), bottom = smallest y, centerX/centerY = middle of the common bounds (rounded to whole mm). Furniture uses its rotated footprint, groups their members. Openings, levels and backgrounds are ignored; at least two objects must remain. One undo step.",
                   ["ids": S.uuids("Objects to align (at least 2)."),
                    "edge": S.str("Edge or centre line.", values: AlignEdge.allCases.map(\.rawValue))],
                   required: ["ids", "edge"]) { p, _, a in
                let ids = try a.requireUUIDList("ids")
                try p.requireAll(ids)
                guard let edge = try a.enumValue("edge", AlignEdge.self) else { throw ToolError.missing("edge") }
                let moved = try p.alignObjects(ids, edge: edge)
                return .object(["moved": J.ids(moved), "ids": J.ids(p.alignTargets(ids))])
            },
            .write("scene.duplicate_objects", "Duplicates objects; the copies are offset (default x 500, y 500). Returns idMap {old: new}.",
                   ["ids": S.uuids("Objects to duplicate."), "offset": S.p3("Offset of the copies.")], required: ["ids"]) { p, _, a in
                let ids = try a.requireUUIDList("ids")
                try p.requireAll(ids)
                let map = try p.duplicateObjects(ids, offset: try a.p3("offset") ?? P3(500, 500, 0))
                return .object(["idMap": .object(map.reduce(into: [:]) { $0[$1.key.uuidString.lowercased()] = J.id($1.value) })])
            },
            .write("scene.set_locked", "Locks or unlocks objects. Locked objects cannot be edited until unlocked.",
                   ["ids": S.uuids("Objects."), "locked": S.bool("true locks.")], required: ["ids", "locked"]) { p, _, a in
                let ids = try a.requireUUIDList("ids")
                try p.requireAll(ids)
                try p.setLocked(ids, try a.requireBool("locked"))
                return .object([:])
            },
            .write("scene.set_visible", "Shows or hides objects.",
                   ["ids": S.uuids("Objects."), "visible": S.bool("true shows.")], required: ["ids", "visible"]) { p, _, a in
                let ids = try a.requireUUIDList("ids")
                try p.requireAll(ids)
                try p.setVisible(ids, try a.requireBool("visible"))
                return .object([:])
            },
            .read("scene.check_collisions",
                  "Collision warnings of one level: furniture overlapping furniture or walls, blocked openings, furniture outside rooms. Depths in mm.",
                  ["levelId": S.uuid("Level; default the active level."),
                   "ids": S.uuids("Only issues involving these objects."), "limit": S.limit, "cursor": S.cursor]) { env, a in
                let p = env.project
                let page = try PageRequest(a)
                let level = try a.uuid("levelId") ?? env.context.activeLevelId
                guard p.level(level) != nil else { throw ToolError.notFound("Level", level) }
                let only = try a.uuidList("ids").map(Set.init)
                let issues = CollisionChecker.check(p, levelId: level, only: only)
                return page.result(issues, revision: p.revision, { i in
                    var o: [String: JSONValue] = [
                        "type": .string(i.kind.rawValue), "depthMm": J.mm(i.depth),
                        "a": .object(["id": J.id(i.a), "name": .string(p.displayName(of: i.a))]),
                    ]
                    if let b = i.b { o["b"] = .object(["id": J.id(b), "name": .string(p.displayName(of: b))]) }
                    return .object(o)
                }, extra: ["levelId": J.id(level)])
            },
        ]
    }
}
