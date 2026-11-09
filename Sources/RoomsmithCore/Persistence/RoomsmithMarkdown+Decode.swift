import Foundation

extension RoomsmithMarkdown {
    private static let knownSections: Set<String> = [
        "settings", "levels", "walls", "rooms", "openings", "dimensions", "materials", "assets", "backgrounds",
        "camera", "saved cameras", "definitions", "instances", "groups", "products",
    ]

    /// Decodes `project.md` text. Older schemas (1, 2) are migrated first (a note is added to the warnings).
    /// Throws `PersistenceError` with the 1-based line number for structural or value errors; unknown sections,
    /// tables, columns and keys only produce warnings.
    public static func decode(_ input: String) throws -> (project: Project, warnings: [String]) {
        let ctx = Ctx()
        let migrated = try ProjectMigration.migrate(input)
        ctx.warnings += migrated.notes.map { "migrated: \($0)" }
        let doc = try MDParser.parse(migrated.text, ctx)

        let front = Rd(bullets: doc.front, line: 1)
        ctx.unknown(front, known: ["format", "schema", "id", "name", "revision"], what: "front matter key")
        guard try front.str("format") == "roomsmith" else { throw front.fail("format", "front matter 'format' must be 'roomsmith'") }
        guard try front.int("schema", 0) == Project.currentSchemaVersion else {
            throw front.fail("schema", "unsupported schema '\(front.cells[front.cols["schema"] ?? 0])'")
        }
        var p = Project(name: try front.str("name"))
        p.id = try front.uuid("id")
        p.revision = try front.i64("revision", 0)

        var secs = [String: Section]()
        for s in doc.sections {
            let k = s.name.lowercased()
            if !knownSections.contains(k) { ctx.warn(s.line, "unknown section '\(s.name)' ignored") }
            else if secs[k] != nil { ctx.warn(s.line, "duplicate section '\(s.name)' ignored") }
            else { secs[k] = s }
        }

        if let s = secs["settings"] { p.settings = try settings(s, ctx) }
        p.levels = try ctx.rows(secs["levels"], known: ["id", "name", "elevation", "height", "visible", "locked", "rev"]) { r in
            var l = Level(id: try r.uuid("id"), name: try r.str("name"), elevation: try r.i64("elevation", 0), height: try r.i64("height", 2500))
            l.visible = try r.bool("visible", true); l.locked = try r.bool("locked", false); l.rev = try r.i64("rev", 0)
            return l
        }
        p.walls = try ctx.rows(secs["walls"], known: ["id", "level", "start", "end", "thickness", "height", "leftMaterial", "rightMaterial", "locked", "rev"]) { r in
            var w = Wall(id: try r.uuid("id"), levelId: try r.uuid("level"), start: try r.p2("start"), end: try r.p2("end"),
                         thickness: try r.i64("thickness", 115), height: try r.i64("height", 2500))
            w.leftMaterialId = try r.optUUID("leftMaterial"); w.rightMaterialId = try r.optUUID("rightMaterial")
            w.locked = try r.bool("locked", false); w.rev = try r.i64("rev", 0)
            return w
        }
        p.rooms = try ctx.rows(secs["rooms"], known: ["id", "level", "name", "points", "floorMaterial", "ceilingMaterial", "showFloor", "showCeiling", "rev"]) { r in
            var x = Room(id: try r.uuid("id"), levelId: try r.uuid("level"), name: try r.str("name"), points: try r.points("points"))
            x.floorMaterialId = try r.optUUID("floorMaterial"); x.ceilingMaterialId = try r.optUUID("ceilingMaterial")
            x.showFloor = try r.bool("showFloor", true); x.showCeiling = try r.bool("showCeiling", false); x.rev = try r.i64("rev", 0)
            return x
        }
        p.openings = try ctx.rows(secs["openings"], known: ["id", "wall", "kind", "name", "offset", "width", "height", "sill", "flipped", "inward", "frameMaterial", "style", "handle", "frameWidth", "mullionCols", "mullionRows", "glass", "rev"]) { r in
            var o = Opening(id: try r.uuid("id"), wallId: try r.uuid("wall"), kind: try r.enumv("kind"), name: try r.str("name", ""),
                            offset: try r.i64("offset"), width: try r.i64("width"), height: try r.i64("height"), sill: try r.i64("sill", 0))
            o.flipped = try r.bool("flipped", false); o.inward = try r.bool("inward", true)
            o.frameMaterialId = try r.optUUID("frameMaterial"); o.rev = try r.i64("rev", 0)
            // Files from before the detail columns keep the kind's default look.
            let style: OpeningStyle = try r.enumv("style", o.style)
            o.style = style.isValid(for: o.kind) ? style : OpeningStyle.defaultStyle(for: o.kind)
            o.handle = try r.enumv("handle", o.handle)
            // Hand-edited values outside the editable ranges are clamped so a file can never hold a mesh-breaking detail.
            o.frameWidth = min(max(try r.i64("frameWidth", o.frameWidth), 20), 150)
            o.mullionCols = min(max(try r.int("mullionCols", 0), 0), 6); o.mullionRows = min(max(try r.int("mullionRows", 0), 0), 6)
            o.glassType = try r.enumv("glass", o.glassType)
            return o
        }
        p.dimensions = try ctx.rows(secs["dimensions"], known: ["id", "level", "a", "b", "offset", "rev"]) { r in
            var d = Dimension(id: try r.uuid("id"), levelId: try r.uuid("level"), a: try r.p2("a"), b: try r.p2("b"), offset: try r.i64("offset", 300))
            d.rev = try r.i64("rev", 0)
            return d
        }
        p.materials = try ctx.rows(secs["materials"], known: ["id", "name", "color", "roughness", "metallic", "opacity", "texture", "textureTile", "preset", "finish", "pattern", "color2", "patternSize", "patternAngle", "grout", "clearcoat", "specular", "rev"]) { r in
            var m = Material(id: try r.uuid("id"), name: try r.str("name"), color: try r.color("color"),
                             roughness: try r.dbl("roughness", 0.7), metallic: try r.dbl("metallic", 0), opacity: try r.dbl("opacity", 1))
            m.textureAssetId = try r.optUUID("texture"); m.textureTile = try r.i64("textureTile", 1000); m.rev = try r.i64("rev", 0)
            m.preset = try r.optStr("preset"); m.finish = try r.enumv("finish", m.finish); m.pattern = try r.enumv("pattern", m.pattern)
            m.color2 = try r.optional("color2") { RGBColor(hex: $0) }
            func unit(_ v: Double) -> Double { v.isFinite ? min(max(v, 0), 1) : 0 }
            m.patternSize = min(max(try r.i64("patternSize", m.patternSize), sizeLimit.lowerBound), sizeLimit.upperBound)
            let angle = try r.dbl("patternAngle", 0); m.patternAngleDeg = angle.isFinite ? angle : 0
            m.grout = min(max(try r.i64("grout", m.grout), 0), 100)
            m.clearcoat = unit(try r.dbl("clearcoat", 0)); m.specular = unit(try r.dbl("specular", 0.5))
            return m
        }
        p.assets = try ctx.rows(secs["assets"], known: ["id", "kind", "storedName", "originalName", "sha256", "byteCount", "measuredSize", "importScale", "notes", "rev"]) { r in
            var a = ProjectAsset(id: try r.uuid("id"), kind: try r.enumv("kind"), storedName: try r.str("storedName"),
                                 originalName: try r.str("originalName", ""), sha256: try r.str("sha256", ""), byteCount: try r.i64("byteCount", 0))
            a.measuredSize = try r.optSize("measuredSize"); a.importScale = try r.dbl("importScale", 1)
            a.notes = try r.str("notes", ""); a.rev = try r.i64("rev", 0)
            return a
        }
        p.backgrounds = try ctx.rows(secs["backgrounds"], known: ["id", "level", "asset", "calibrationA", "calibrationB", "calibrationLength", "origin", "opacity", "visible", "rev"]) { r in
            var b = BackgroundImage(id: try r.uuid("id"), levelId: try r.uuid("level"), assetId: try r.uuid("asset"),
                                    calibrationA: try r.p2("calibrationA"), calibrationB: try r.p2("calibrationB"),
                                    calibrationLength: try r.i64("calibrationLength"), origin: try r.p2("origin"))
            b.opacity = try r.dbl("opacity", 0.5); b.visible = try r.bool("visible", true); b.rev = try r.i64("rev", 0)
            return b
        }
        if let s = secs["camera"] {
            let b = ctx.bullets(s, known: ["mode", "target", "distance", "yaw", "pitch", "fov"])
            p.camera = try cameraState(b)
        }
        p.cameras = try ctx.rows(secs["saved cameras"], known: ["id", "name", "mode", "target", "distance", "yaw", "pitch", "fov", "rev"]) { r in
            var c = SavedCamera(id: try r.uuid("id"), name: try r.str("name"), state: try cameraState(r))
            c.rev = try r.i64("rev", 0)
            return c
        }
        if let s = secs["definitions"] { p.definitions = try s.subs.map { try definition($0, ctx) } }
        p.instances = try ctx.rows(secs["instances"], known: ["id", "definition", "level", "name", "position", "rotation", "size", "materialOverrides", "state", "group", "product", "visible", "locked", "lightOn", "allowsOverlap", "options", "rev"]) { r in
            var i = FurnitureInstance(id: try r.uuid("id"), definitionId: try r.uuid("definition"), levelId: try r.uuid("level"),
                                      name: try r.str("name", ""), position: try r.p3("position"), rotationDeg: try r.dbl("rotation", 0))
            i.size = try r.optSize("size"); i.materialOverrides = try r.optMatMap("materialOverrides") ?? [:]
            i.stateId = try r.optUUID("state"); i.groupId = try r.optUUID("group"); i.productId = try r.optUUID("product")
            i.visible = try r.bool("visible", true); i.locked = try r.bool("locked", false)
            i.lightOn = try r.bool("lightOn", true); i.allowsOverlap = try r.bool("allowsOverlap", false)
            i.optionSelection = try r.matMap("options"); i.rev = try r.i64("rev", 0)
            return i
        }
        if let s = secs["groups"] { p.groups = try s.subs.map { try group($0, ctx) } }
        if let s = secs["products"] { p.products = try s.subs.map { try product($0, ctx) } }

        for (k, s) in secs { ctx.checkTables(s, expected: expectedTables(k)) }
        return (p, ctx.warnings)
    }

    private static func expectedTables(_ section: String) -> Set<String> {
        switch section {
        case "settings", "camera": []
        case "definitions", "groups", "products": []      // tables live in the ### blocks (checked there)
        default: [""]
        }
    }

    // MARK: Pieces

    private static func settings(_ s: Section, _ ctx: Ctx) throws -> ProjectSettings {
        let b = ctx.bullets(s, known: ["displayUnit", "snap.enabled", "snap.grid", "snap.tolerance", "snap.toWalls", "snap.toObjects",
                                       "snap.toGrid", "snap.angleStep", "collisionWarnings", "defaultWallThickness", "defaultWallHeight",
                                       "lighting.northDeg", "lighting.dayOfYear", "lighting.timeMinutes", "lighting.latitudeDeg",
                                       "lighting.mood", "lighting.shadows", "lighting.exposure"])
        var st = ProjectSettings()
        st.displayUnit = try b.enumv("displayUnit", LengthUnit.cm)
        st.snap.enabled = try b.bool("snap.enabled", true)
        st.snap.grid = try b.i64("snap.grid", 10)
        st.snap.tolerance = try b.i64("snap.tolerance", 80)
        st.snap.toWalls = try b.bool("snap.toWalls", true)
        st.snap.toObjects = try b.bool("snap.toObjects", true)
        st.snap.toGrid = try b.bool("snap.toGrid", true)
        st.snap.angleStep = try b.dbl("snap.angleStep", 15)
        st.collisionWarnings = try b.bool("collisionWarnings", true)
        st.defaultWallThickness = try b.i64("defaultWallThickness", 115)
        st.defaultWallHeight = try b.i64("defaultWallHeight", 2500)
        let ld = LightingSettings()
        st.lighting.northDeg = try b.dbl("lighting.northDeg", ld.northDeg)
        st.lighting.dayOfYear = try b.int("lighting.dayOfYear", ld.dayOfYear)
        st.lighting.timeMinutes = try b.int("lighting.timeMinutes", ld.timeMinutes)
        st.lighting.latitudeDeg = try b.dbl("lighting.latitudeDeg", ld.latitudeDeg)
        st.lighting.mood = try b.enumv("lighting.mood", ld.mood)
        st.lighting.shadows = try b.bool("lighting.shadows", ld.shadows)
        st.lighting.exposure = try b.dbl("lighting.exposure", ld.exposure)
        st.lighting = st.lighting.sanitized()
        return st
    }

    private static func cameraState(_ r: Rd) throws -> CameraState {
        let d = CameraState.default
        return CameraState(mode: try r.enumv("mode", d.mode), target: try r.value("target", d.target, MD.p3),
                           distance: try r.i64("distance", d.distance), yawDeg: try r.dbl("yaw", d.yawDeg),
                           pitchDeg: try r.dbl("pitch", d.pitchDeg), fovDeg: try r.dbl("fov", d.fovDeg))
    }

    /// `### <uuid> · <name>` heading → (id, name).
    private static func heading(_ s: Section) throws -> (UUID, String) {
        let parts = s.name.components(separatedBy: " · ")
        guard let id = UUID(uuidString: parts[0].trimmingCharacters(in: .whitespaces)) else {
            throw PersistenceError("heading must start with a UUID: '### <uuid> · <name>'", line: s.line)
        }
        return (id, MD.unesc(parts.dropFirst().joined(separator: " · ")))
    }

    private static func pose(_ r: Rd) throws -> ComponentPose {
        ComponentPose(position: try r.optP3("position"), rotation: try r.optR3("rotation"),
                      size: try r.optSize("size"), visible: try r.optBool("visible"))
    }

    private static func definition(_ s: Section, _ ctx: Ctx) throws -> FurnitureDefinition {
        let (id, headName) = try heading(s)
        let b = ctx.bullets(s, known: ["name", "category", "size", "defaultState", "product", "builtin", "catalogKey", "tags", "rev"])
        let comps = try ctx.rows(s, title: "Components", known: ["id", "name", "shape", "position", "size", "rotation", "pivot", "material", "mesh", "visible"]) { r in
            var c = Component(id: try r.uuid("id"), name: try r.str("name"), shape: try r.enumv("shape"), position: try r.p3("position"),
                              size: try r.size("size"), rotation: try r.r3("rotation", .zero), pivot: try r.optP3("pivot"),
                              materialId: try r.optUUID("material"))
            c.meshAssetId = try r.optUUID("mesh"); c.visible = try r.bool("visible", true)
            return c
        }
        var d = FurnitureDefinition(id: id, name: try b.str("name", headName), category: try b.str("category", ""),
                                    size: try b.size("size"), components: comps)
        d.defaultStateId = try b.optUUID("defaultState"); d.productId = try b.optUUID("product")
        d.builtin = try b.bool("builtin", false); d.catalogKey = try b.optStr("catalogKey")
        d.tags = try b.strings("tags"); d.rev = try b.i64("rev", 0)

        d.lights = try ctx.rows(s, title: "Lights", known: ["id", "name", "kind", "position", "yaw", "pitch", "cone", "kelvin", "color", "lumens", "range"]) { r in
            var e = LightEmitter(id: try r.uuid("id"), name: try r.str("name", "Lamp"), kind: try r.enumv("kind", LightKind.point),
                                 position: try r.p3("position"))
            e.yawDeg = try r.dbl("yaw", 0); e.pitchDeg = try r.dbl("pitch", -90); e.coneDeg = try r.dbl("cone", 80)
            e.kelvin = try r.int("kelvin", 2700); e.color = try r.optional("color") { RGBColor(hex: $0) }
            e.lumens = try r.int("lumens", 800); e.rangeMm = try r.i64("range", 5000)
            return e
        }
        d.lights = LightEmitter.sanitize(d.lights)

        var stateIndex = [UUID: Int]()
        for r in ctx.tableRows(s, title: "States", known: ["id", "name", "component", "position", "rotation", "size", "visible"]) {
            let sid = try r.uuid("id")
            if r.isNil("component") {
                guard stateIndex[sid] == nil else { throw r.fail("id", "duplicate state header row") }
                stateIndex[sid] = d.states.count
                d.states.append(FurnitureState(id: sid, name: try r.str("name", ""), size: try r.optSize("size")))
            } else {
                guard let i = stateIndex[sid] else { throw r.fail("id", "state override row appears before its header row (component '-')") }
                d.states[i].poses[try r.uuid("component")] = try pose(r)
            }
        }

        var groupIndex = [UUID: Int]()
        var choiceIndex = [UUID: (group: Int, choice: Int)]()
        for r in ctx.tableRows(s, title: "Options", known: ["group", "choice", "name", "default", "component", "material", "visible"]) {
            let gid = try r.uuid("group")
            if r.isNil("choice") {
                guard groupIndex[gid] == nil else { throw r.fail("group", "duplicate option group header row") }
                groupIndex[gid] = d.optionGroups.count
                d.optionGroups.append(OptionGroup(id: gid, name: try r.str("name", ""), choices: [], defaultChoiceId: try r.optUUID("default")))
            } else {
                guard let gi = groupIndex[gid] else { throw r.fail("group", "option row appears before its group header row (choice '-')") }
                let cid = try r.uuid("choice")
                if r.isNil("component") {
                    guard choiceIndex[cid] == nil else { throw r.fail("choice", "duplicate option choice header row") }
                    choiceIndex[cid] = (gi, d.optionGroups[gi].choices.count)
                    d.optionGroups[gi].choices.append(OptionChoice(id: cid, name: try r.str("name", "")))
                } else {
                    guard let ix = choiceIndex[cid], ix.group == gi else { throw r.fail("choice", "effect row appears before its choice header row (component '-')") }
                    d.optionGroups[gi].choices[ix.choice].effects[try r.uuid("component")] =
                        OptionEffect(materialId: try r.optUUID("material"), visible: try r.optBool("visible"))
                }
            }
        }

        var trackIndex = [UUID: Int]()
        for r in ctx.tableRows(s, title: "Tracks", known: ["id", "from", "to", "durationMs", "easing"]) {
            let t = AnimationTrack(id: try r.uuid("id"), fromStateId: try r.optUUID("from"), toStateId: try r.uuid("to"),
                                   durationMs: try r.int("durationMs", 800), easing: try r.enumv("easing", Easing.easeInOut))
            trackIndex[t.id] = d.tracks.count
            d.tracks.append(t)
        }
        var frames = [[Int: AnimationTrack.Keyframe]](repeating: [:], count: d.tracks.count)
        for r in ctx.tableRows(s, title: "Keyframes", known: ["track", "key", "t", "component", "position", "rotation", "size", "visible"]) {
            guard let ti = trackIndex[try r.uuid("track")] else { throw r.fail("track", "keyframe refers to an unknown track") }
            let key = try r.int("key", 0)
            if r.isNil("component") {
                guard frames[ti][key] == nil else { throw r.fail("key", "duplicate keyframe header row") }
                frames[ti][key] = AnimationTrack.Keyframe(t: try r.dbl("t"), poses: [:])
            } else {
                guard frames[ti][key] != nil else { throw r.fail("key", "keyframe override row appears before its header row (component '-')") }
                frames[ti][key]!.poses[try r.uuid("component")] = try pose(r)
            }
        }
        for i in d.tracks.indices { d.tracks[i].keyframes = frames[i].keys.sorted().map { frames[i][$0]! } }
        ctx.checkTables(s, expected: ["Components", "Lights", "States", "Options", "Tracks", "Keyframes"])
        return d
    }

    private static func group(_ s: Section, _ ctx: Ctx) throws -> FurnitureGroup {
        let (id, headName) = try heading(s)
        let b = ctx.bullets(s, known: ["name", "level", "origin", "rotation", "members", "activeConfiguration", "product", "locked", "rev"])
        var g = FurnitureGroup(id: id, name: try b.str("name", headName), levelId: try b.uuid("level"),
                               origin: try b.p3("origin"), memberIds: try b.uuids("members"))
        g.rotationDeg = try b.dbl("rotation", 0); g.activeConfigurationId = try b.optUUID("activeConfiguration")
        g.productId = try b.optUUID("product"); g.locked = try b.bool("locked", false); g.rev = try b.i64("rev", 0)

        var index = [UUID: Int]()
        for r in ctx.tableRows(s, title: "Configurations", known: ["id", "name", "member", "local", "rotation", "visible", "state", "materialOverrides"]) {
            let cid = try r.uuid("id")
            if r.isNil("member") {
                guard index[cid] == nil else { throw r.fail("id", "duplicate configuration header row") }
                index[cid] = g.configurations.count
                g.configurations.append(GroupConfiguration(id: cid, name: try r.str("name", ""), poses: [:]))
            } else {
                guard let i = index[cid] else { throw r.fail("id", "member row appears before its configuration header row (member '-')") }
                g.configurations[i].poses[try r.uuid("member")] = MemberPose(
                    local: try r.p3("local"), rotationDeg: try r.dbl("rotation", 0), visible: try r.bool("visible", true),
                    stateId: try r.optUUID("state"), materialOverrides: try r.optMatMap("materialOverrides"))
            }
        }
        ctx.checkTables(s, expected: ["Configurations"])
        return g
    }

    private static func product(_ s: Section, _ ctx: Ctx) throws -> CatalogProduct {
        let (id, headName) = try heading(s)
        let b = ctx.bullets(s, known: ["name", "category", "description", "notes", "manufacturer", "model", "articleNumber", "priceMinor",
                                       "currency", "priceDate", "dimensions", "weightGrams", "material", "color", "files", "images", "tags",
                                       "status", "variants", "rooms", "definition", "rev"], prefix: "custom.")
        var x = CatalogProduct(id: id, name: try b.str("name", headName))
        x.category = try b.str("category", ""); x.description = try b.str("description", ""); x.notes = try b.str("notes", "")
        x.manufacturer = try b.str("manufacturer", ""); x.model = try b.str("model", ""); x.articleNumber = try b.str("articleNumber", "")
        x.priceMinor = try b.optI64("priceMinor"); x.currency = try b.str("currency", "EUR"); x.priceDate = try b.optStr("priceDate")
        x.dimensions = try b.optSize("dimensions"); x.weightGrams = try b.optI64("weightGrams")
        x.materialText = try b.str("material", ""); x.colorText = try b.str("color", "")
        x.fileAssetIds = try b.uuids("files"); x.imageAssetIds = try b.uuids("images"); x.tags = try b.strings("tags")
        x.status = try b.enumv("status", PurchaseStatus.idea); x.variants = try b.strings("variants"); x.roomIds = try b.uuids("rooms")
        x.definitionId = try b.optUUID("definition"); x.rev = try b.i64("rev", 0)
        for (k, i) in b.cols where k.hasPrefix("custom.") { x.custom[String(k.dropFirst(7))] = MD.unesc(b.cells[i]) }
        x.links = try ctx.rows(s, title: "Links", known: ["id", "title", "url"]) { r in
            ProductLink(id: try r.uuid("id"), title: try r.str("title", ""), url: try r.str("url", ""))
        }
        ctx.checkTables(s, expected: ["Links"])
        return x
    }
}

extension Ctx {
    func unknown(_ r: Rd, known: Set<String>, prefix: String? = nil, what: String) {
        for (k, i) in r.cols.sorted(by: { $0.value < $1.value }) where !known.contains(k) && !(prefix.map(k.hasPrefix) ?? false) {
            warn(r.lineOf(i), "unknown \(what) '\(k)' ignored")
        }
    }

    func bullets(_ s: Section, known: Set<String>, prefix: String? = nil) -> Rd {
        let r = Rd(bullets: s.bullets, line: s.line)
        unknown(r, known: known, prefix: prefix, what: "key")
        return r
    }

    func tableRows(_ s: Section?, title: String = "", known: Set<String>) -> [Rd] {
        guard let s, let t = s.tables.first(where: { $0.title == title }) else { return [] }
        for c in t.columns where !known.contains(c) { warn(t.line, "unknown column '\(c)' ignored") }
        return t.rows.map { Rd(table: t, row: $0) }
    }

    func rows<T>(_ s: Section?, title: String = "", known: Set<String>, _ make: (Rd) throws -> T) throws -> [T] {
        let rs = tableRows(s, title: title, known: known)
        var out = [T]()
        out.reserveCapacity(rs.count)
        for r in rs { out.append(try make(r)) }
        return out
    }

    func checkTables(_ s: Section, expected: Set<String>) {
        for t in s.tables where !expected.contains(t.title) { warn(t.line, "unknown table '\(t.title)' ignored") }
    }
}
