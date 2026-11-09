import Foundation

// MARK: - material.*

/// Own materials (colour, roughness, metallic, opacity). Textures come from the app's asset import and are not set here.
enum MaterialTools {
    private static func row(_ m: Material) -> JSONValue {
        .object(["id": J.id(m.id), "name": .string(m.name), "color": .string(m.color.hex), "roughness": .number(m.roughness),
                 "metallic": .number(m.metallic), "opacity": .number(m.opacity), "textureTileMm": .int(m.textureTile), "rev": .int(m.rev),
                 "preset": m.preset.map { .string($0) } ?? .null, "finish": .string(m.finish.rawValue), "pattern": .string(m.pattern.rawValue),
                 "color2": m.color2.map { .string($0.hex) } ?? .null, "patternSizeMm": .int(m.patternSize),
                 "patternAngleDeg": .number(m.patternAngleDeg), "groutMm": .int(m.grout), "clearcoat": .number(m.clearcoat),
                 "specular": .number(m.specular)])
    }

    private static func unit(_ a: Args, _ key: String) throws -> Double? {
        guard let v = try a.double(key) else { return nil }
        guard v.isFinite, (0...1).contains(v) else { throw ToolError.invalid(key, "must be between 0 and 1") }
        return v
    }

    private static func color(_ a: Args) throws -> RGBColor? {
        guard let s = try a.string("color") else { return nil }
        guard let c = RGBColor(hex: s) else { throw ToolError.invalid("color", "must be a hex colour like #B08D57") }
        return c
    }

    private static func tile(_ a: Args) throws -> MM? {
        guard let t = try a.mm("textureTileMm") else { return nil }
        guard sizeLimit.contains(t) else { throw ToolError.invalid("textureTileMm", "must be between \(sizeLimit.lowerBound) and \(sizeLimit.upperBound) mm") }
        return t
    }

    private static func requireFreeName(_ p: Project, _ name: String, except: UUID?) throws {
        if p.materials.contains(where: { $0.id != except && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw ToolError.invalid("name", "a material named '\(name)' already exists (names are matched case-insensitively)")
        }
    }

    private static let props: [String: JSONValue] = [
        "color": S.str("Hex colour #RRGGBB."), "roughness": S.num("0 = mirror ... 1 = matte (default 0.7)."),
        "metallic": S.num("0...1 (default 0)."), "opacity": S.num("0 = invisible ... 1 = solid (default 1)."),
        "textureTileMm": S.int("Real-world size of one texture tile, 1...100000 mm (default 1000)."),
        "finish": S.str("Surface finish (default matte).", values: MaterialFinish.allCases.map(\.rawValue)),
        "pattern": S.str("Procedural pattern generated from the colours (default none; an imported image texture wins over it).",
                         values: MaterialPattern.allCases.map(\.rawValue)),
        "color2": S.str("Second pattern colour #RRGGBB (stripes, grid lines, tile joints, wood grain); default a darker shade of color. On update, null or \"\" removes it."),
        "patternSizeMm": S.int("Size of one pattern cell (stripe pair, tile, plank, thread), 1...100000 mm (default 100)."),
        "patternAngleDeg": S.num("Rotation of the pattern in degrees."),
        "groutMm": S.int("Joint width of tiles, grid lines and planks, 0...100 mm (default 3)."),
        "clearcoat": S.num("Clear lacquer layer 0...1 (default 0)."),
        "specular": S.num("Highlight strength 0...1 (default 0.5)."),
    ]

    private static func extras(_ a: Args) throws -> (finish: MaterialFinish?, pattern: MaterialPattern?, color2: RGBColor?, size: MM?,
                                                      angle: Double?, grout: MM?, coat: Double?, spec: Double?) {
        var c2: RGBColor?
        if let s = try a.string("color2"), !s.isEmpty {
            guard let c = RGBColor(hex: s) else { throw ToolError.invalid("color2", "must be a hex colour like #B08D57") }
            c2 = c
        }
        var size = try a.mm("patternSizeMm")
        if let v = size { guard sizeLimit.contains(v) else { throw ToolError.invalid("patternSizeMm", "must be between \(sizeLimit.lowerBound) and \(sizeLimit.upperBound) mm") }; size = v }
        var grout = try a.mm("groutMm")
        if let g = grout { guard (0...100).contains(g) else { throw ToolError.invalid("groutMm", "must be between 0 and 100 mm") }; grout = g }
        var angle = try a.double("patternAngleDeg")
        if let v = angle {
            guard v.isFinite, abs(v) <= 36000 else { throw ToolError.invalid("patternAngleDeg", "must be a finite angle in degrees") }
            angle = Angle.normalized(v)
        }
        return (try a.enumValue("finish", MaterialFinish.self), try a.enumValue("pattern", MaterialPattern.self), c2, size, angle, grout,
                try unit(a, "clearcoat"), try unit(a, "specular"))
    }

    /// `color2: null` or `""` on an update removes the second colour (back to the derived darker shade).
    private static func clearsColor2(_ a: Args) -> Bool { a.isNull("color2") || a.values["color2"]?.stringValue == "" }

    private static func applyExtras(_ m: inout Material, _ e: (finish: MaterialFinish?, pattern: MaterialPattern?, color2: RGBColor?, size: MM?,
                                                              angle: Double?, grout: MM?, coat: Double?, spec: Double?)) {
        if let v = e.finish { m.finish = v }
        if let v = e.pattern { m.pattern = v }
        if let v = e.color2 { m.color2 = v }
        if let v = e.size { m.patternSize = v }
        if let v = e.angle { m.patternAngleDeg = v }
        if let v = e.grout { m.grout = v }
        if let v = e.coat { m.clearcoat = v }
        if let v = e.spec { m.specular = v }
    }

    @MainActor
    static func specs() -> [ToolSpec] {
        [
            .write("material.create", "Creates a material with a unique name. Use the name or id wherever a material is expected (walls, rooms, furniture parts).",
                   props.merging(["name": S.str("Unique material name."), "id": S.uuid("Optional id.")]) { a, _ in a },
                   required: ["name", "color"]) { p, _, a in
                let name = try a.requireNonEmptyString("name")
                try requireFreeName(p, name, except: nil)
                guard let c = try color(a) else { throw ToolError.missing("color") }
                var m = Material(id: try a.uuid("id") ?? UUID(), name: name, color: c)
                if let v = try unit(a, "roughness") { m.roughness = v }
                if let v = try unit(a, "metallic") { m.metallic = v }
                if let v = try unit(a, "opacity") { m.opacity = v }
                if let v = try tile(a) { m.textureTile = v }
                applyExtras(&m, try extras(a))
                if p.material(m.id) != nil { throw ToolError.invalid("id", "already in use") }
                let id = p.addMaterial(m)
                return .object(["id": J.id(id), "ids": J.ids([id])])
            },
            .write("material.update", "Changes a material; every object that uses it follows. Only the given keys change.",
                   props.merging(["id": S.uuid("Material id."), "name": S.str("New unique name.")]) { a, _ in a },
                   required: ["id"]) { p, _, a in
                let id = try a.requireUUID("id")
                guard p.material(id) != nil else {
                    if p.kind(of: id) != nil { throw ToolError.invalid("id", "\(id.uuidString.lowercased()) is not a material") }
                    throw ToolError.notFound("Material", id)
                }
                let keys = ["name", "color", "roughness", "metallic", "opacity", "textureTileMm", "finish", "pattern", "color2", "patternSizeMm",
                            "patternAngleDeg", "groutMm", "clearcoat", "specular"]
                guard keys.contains(where: a.present) else { throw ToolError.invalid(nil, "Give at least one of: \(keys.joined(separator: ", "))") }
                let name = try a.nonEmptyString("name")
                if let name { try requireFreeName(p, name, except: id) }
                let c = try color(a), r = try unit(a, "roughness"), me = try unit(a, "metallic"), o = try unit(a, "opacity"), t = try tile(a)
                let ex = try extras(a)
                let clearColor2 = clearsColor2(a)
                try p.updateMaterial(id) { m in
                    if let name { m.name = name }
                    if let c { m.color = c }
                    if let r { m.roughness = r }
                    if let me { m.metallic = me }
                    if let o { m.opacity = o }
                    if let t { m.textureTile = t }
                    applyExtras(&m, ex)
                    if clearColor2 { m.color2 = nil }
                }
                guard let m = p.material(id) else { throw ToolError.notFound("Material", id) }
                return row(m)
            },
            .write("material.apply_preset",
                   "Applies a built-in material preset (see material.list_presets) to a material: roughness, finish, pattern and gloss are replaced; the colour stays unless the preset has one. An imported image texture is removed. Undoable.",
                   ["id": S.uuid("Material id."), "preset": S.str("Preset id or name (case-insensitive), see material.list_presets.")],
                   required: ["id", "preset"]) { p, _, a in
                let id = try a.requireUUID("id")
                guard p.material(id) != nil else {
                    if p.kind(of: id) != nil { throw ToolError.invalid("id", "\(id.uuidString.lowercased()) is not a material") }
                    throw ToolError.notFound("Material", id)
                }
                try p.applyMaterialPreset(id, preset: try a.requireNonEmptyString("preset"))
                guard let m = p.material(id) else { throw ToolError.notFound("Material", id) }
                return row(m)
            },
            .read("material.list_presets", "Lists the built-in material presets: id, name, group (paint, wallpaper, tiles, wood, fabric, leather, metal, glass, plastic) and the look they set.") { _, _ in
                .object(["presets": .array(MaterialPresets.all.map { pr in
                    .object(["id": .string(pr.id), "name": .string(pr.name), "group": .string(pr.group),
                             "color": pr.color.map { .string($0.hex) } ?? .null, "finish": .string(pr.finish.rawValue),
                             "pattern": .string(pr.pattern.rawValue), "roughness": .number(pr.roughness), "metallic": .number(pr.metallic),
                             "opacity": .number(pr.opacity)])
                })])
            },
        ]
    }
}
