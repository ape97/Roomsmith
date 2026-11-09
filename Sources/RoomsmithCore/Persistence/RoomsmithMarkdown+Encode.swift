import Foundation

/// The Roomsmith Markdown project format: `project.md` text ⇄ `Project`.
public enum RoomsmithMarkdown {
    /// Encodes the whole project. Output is deterministic (dictionaries are sorted by id).
    public static func encode(_ p: Project) -> String {
        var w = MDWriter()
        w.out.reserveCapacity(4096 + 200 * (p.walls.count + p.instances.count))
        w.out += "---\nformat: roomsmith\nschema: \(Project.currentSchemaVersion)\nid: \(MD.f(p.id))\n"
        w.out += "name: \(MD.esc(p.name))\nrevision: \(p.revision)\n---\n# \(MD.esc(p.name))\n\n"

        w.settings(p.settings)

        w.section("Levels", ["id", "name", "elevation", "height", "visible", "locked", "rev"])
        for l in p.levels {
            w.row([MD.f(l.id), MD.esc(l.name), "\(l.elevation)", "\(l.height)", MD.f(l.visible), MD.f(l.locked), "\(l.rev)"])
        }
        w.blank()

        w.section("Walls", ["id", "level", "start", "end", "thickness", "height", "leftMaterial", "rightMaterial", "locked", "rev"])
        for x in p.walls {
            w.row([MD.f(x.id), MD.f(x.levelId), MD.f(x.start), MD.f(x.end), "\(x.thickness)", "\(x.height)",
                   MD.f(x.leftMaterialId), MD.f(x.rightMaterialId), MD.f(x.locked), "\(x.rev)"])
        }
        w.blank()

        w.section("Rooms", ["id", "level", "name", "points", "floorMaterial", "ceilingMaterial", "showFloor", "showCeiling", "rev"])
        for r in p.rooms {
            w.row([MD.f(r.id), MD.f(r.levelId), MD.esc(r.name), r.points.map { MD.f($0) }.joined(separator: "; "),
                   MD.f(r.floorMaterialId), MD.f(r.ceilingMaterialId), MD.f(r.showFloor), MD.f(r.showCeiling), "\(r.rev)"])
        }
        w.blank()

        w.section("Openings", ["id", "wall", "kind", "name", "offset", "width", "height", "sill", "flipped", "inward", "frameMaterial", "style", "handle", "frameWidth", "mullionCols", "mullionRows", "glass", "rev"])
        for o in p.openings {
            w.row([MD.f(o.id), MD.f(o.wallId), o.kind.rawValue, MD.esc(o.name), "\(o.offset)", "\(o.width)", "\(o.height)",
                   "\(o.sill)", MD.f(o.flipped), MD.f(o.inward), MD.f(o.frameMaterialId), o.style.rawValue, o.handle.rawValue,
                   "\(o.frameWidth)", "\(o.mullionCols)", "\(o.mullionRows)", o.glassType.rawValue, "\(o.rev)"])
        }
        w.blank()

        w.section("Dimensions", ["id", "level", "a", "b", "offset", "rev"])
        for d in p.dimensions {
            w.row([MD.f(d.id), MD.f(d.levelId), MD.f(d.a), MD.f(d.b), "\(d.offset)", "\(d.rev)"])
        }
        w.blank()

        w.section("Materials", ["id", "name", "color", "roughness", "metallic", "opacity", "texture", "textureTile", "preset", "finish", "pattern", "color2", "patternSize", "patternAngle", "grout", "clearcoat", "specular", "rev"])
        for m in p.materials {
            w.row([MD.f(m.id), MD.esc(m.name), m.color.hex, MD.f(m.roughness), MD.f(m.metallic), MD.f(m.opacity),
                   MD.f(m.textureAssetId), "\(m.textureTile)", MD.opt(m.preset), m.finish.rawValue, m.pattern.rawValue,
                   m.color2?.hex ?? "-", "\(m.patternSize)", MD.f(m.patternAngleDeg), "\(m.grout)", MD.f(m.clearcoat),
                   MD.f(m.specular), "\(m.rev)"])
        }
        w.blank()

        w.section("Assets", ["id", "kind", "storedName", "originalName", "sha256", "byteCount", "measuredSize", "importScale", "notes", "rev"])
        for a in p.assets {
            w.row([MD.f(a.id), a.kind.rawValue, MD.esc(a.storedName), MD.esc(a.originalName), a.sha256, "\(a.byteCount)",
                   MD.f(a.measuredSize), MD.f(a.importScale), MD.esc(a.notes), "\(a.rev)"])
        }
        w.blank()

        w.section("Backgrounds", ["id", "level", "asset", "calibrationA", "calibrationB", "calibrationLength", "origin", "opacity", "visible", "rev"])
        for b in p.backgrounds {
            w.row([MD.f(b.id), MD.f(b.levelId), MD.f(b.assetId), MD.f(b.calibrationA), MD.f(b.calibrationB),
                   "\(b.calibrationLength)", MD.f(b.origin), MD.f(b.opacity), MD.f(b.visible), "\(b.rev)"])
        }
        w.blank()

        w.out += "## Camera\n\n"
        w.cameraBullets(p.camera)
        w.blank()

        w.section("Saved cameras", ["id", "name", "mode", "target", "distance", "yaw", "pitch", "fov", "rev"])
        for c in p.cameras {
            let s = c.state
            w.row([MD.f(c.id), MD.esc(c.name), s.mode.rawValue, MD.f(s.target), "\(s.distance)", MD.f(s.yawDeg),
                   MD.f(s.pitchDeg), MD.f(s.fovDeg), "\(c.rev)"])
        }
        w.blank()

        w.out += "## Definitions\n\n"
        for d in p.definitions { w.definition(d) }

        w.section("Instances", ["id", "definition", "level", "name", "position", "rotation", "size", "materialOverrides",
                                "state", "group", "product", "visible", "locked", "lightOn", "allowsOverlap", "options", "rev"])
        for i in p.instances {
            w.row([MD.f(i.id), MD.f(i.definitionId), MD.f(i.levelId), MD.esc(i.name), MD.f(i.position), MD.f(i.rotationDeg),
                   MD.f(i.size), MD.matMap(i.materialOverrides), MD.f(i.stateId), MD.f(i.groupId), MD.f(i.productId),
                   MD.f(i.visible), MD.f(i.locked), MD.f(i.lightOn), MD.f(i.allowsOverlap), MD.matMap(i.optionSelection), "\(i.rev)"])
        }
        w.blank()

        w.out += "## Groups\n\n"
        for g in p.groups { w.group(g) }

        w.out += "## Products\n\n"
        for x in p.products { w.product(x) }
        return w.out
    }

    /// Default-valued `## Settings` block, used by the schema 1 → 2 migration.
    static func settingsBlock(_ s: ProjectSettings) -> String {
        var w = MDWriter()
        w.settings(s)
        return w.out
    }
}

struct MDWriter {
    var out = ""

    mutating func blank() { out += "\n" }

    mutating func row(_ cells: [String]) {
        out += "| "
        out += cells.joined(separator: " | ")
        out += " |\n"
    }

    mutating func header(_ cols: [String]) {
        row(cols)
        out += "|" + cols.map { _ in "---" }.joined(separator: "|") + "|\n"
    }

    mutating func section(_ name: String, _ cols: [String]) {
        out += "## \(name)\n\n"
        header(cols)
    }

    mutating func table(_ title: String, _ cols: [String]) {
        out += "#### \(title)\n\n"
        header(cols)
        // rows follow; caller adds a blank line afterwards
    }

    mutating func bullet(_ key: String, _ raw: String) {
        out += "- \(MD.esc(key, also: 0x3A)): \(raw)\n"
    }

    mutating func settings(_ s: ProjectSettings) {
        out += "## Settings\n\n"
        bullet("displayUnit", s.displayUnit.rawValue)
        bullet("snap.enabled", MD.f(s.snap.enabled))
        bullet("snap.grid", "\(s.snap.grid)")
        bullet("snap.tolerance", "\(s.snap.tolerance)")
        bullet("snap.toWalls", MD.f(s.snap.toWalls))
        bullet("snap.toObjects", MD.f(s.snap.toObjects))
        bullet("snap.toGrid", MD.f(s.snap.toGrid))
        bullet("snap.angleStep", MD.f(s.snap.angleStep))
        bullet("collisionWarnings", MD.f(s.collisionWarnings))
        bullet("defaultWallThickness", "\(s.defaultWallThickness)")
        bullet("defaultWallHeight", "\(s.defaultWallHeight)")
        let l = s.lighting
        bullet("lighting.northDeg", MD.f(l.northDeg))
        bullet("lighting.dayOfYear", "\(l.dayOfYear)")
        bullet("lighting.timeMinutes", "\(l.timeMinutes)")
        bullet("lighting.latitudeDeg", MD.f(l.latitudeDeg))
        bullet("lighting.mood", l.mood.rawValue)
        bullet("lighting.shadows", MD.f(l.shadows))
        bullet("lighting.exposure", MD.f(l.exposure))
        blank()
    }

    mutating func cameraBullets(_ c: CameraState) {
        bullet("mode", c.mode.rawValue)
        bullet("target", MD.f(c.target))
        bullet("distance", "\(c.distance)")
        bullet("yaw", MD.f(c.yawDeg))
        bullet("pitch", MD.f(c.pitchDeg))
        bullet("fov", MD.f(c.fovDeg))
    }

    private static func sortedKeys(_ m: [UUID: some Any]) -> [UUID] {
        m.keys.sorted { $0.uuidString < $1.uuidString }
    }

    private func poseCells(_ p: ComponentPose) -> [String] {
        [MD.f(p.position), MD.f(p.rotation), MD.f(p.size), MD.f(p.visible)]
    }

    mutating func definition(_ d: FurnitureDefinition) {
        out += "### \(MD.f(d.id)) · \(MD.esc(d.name))\n\n"
        bullet("name", MD.esc(d.name))
        bullet("category", MD.esc(d.category))
        bullet("size", MD.f(d.size))
        bullet("defaultState", MD.f(d.defaultStateId))
        bullet("product", MD.f(d.productId))
        bullet("builtin", MD.f(d.builtin))
        bullet("catalogKey", MD.opt(d.catalogKey))
        bullet("tags", MD.list(d.tags))
        bullet("rev", "\(d.rev)")
        blank()

        table("Components", ["id", "name", "shape", "position", "size", "rotation", "pivot", "material", "mesh", "visible"])
        for c in d.components {
            row([MD.f(c.id), MD.esc(c.name), c.shape.rawValue, MD.f(c.position), MD.f(c.size), MD.f(c.rotation),
                 MD.f(c.pivot), MD.f(c.materialId), MD.f(c.meshAssetId), MD.f(c.visible)])
        }
        blank()

        if !d.lights.isEmpty {
            table("Lights", ["id", "name", "kind", "position", "yaw", "pitch", "cone", "kelvin", "color", "lumens", "range"])
            for e in d.lights {
                row([MD.f(e.id), MD.esc(e.name), e.kind.rawValue, MD.f(e.position), MD.f(e.yawDeg), MD.f(e.pitchDeg),
                     MD.f(e.coneDeg), "\(e.kelvin)", e.color?.hex ?? "-", "\(e.lumens)", "\(e.rangeMm)"])
            }
            blank()
        }

        // One header row per state (component "-", carries name and state size) + one row per component override.
        table("States", ["id", "name", "component", "position", "rotation", "size", "visible"])
        for s in d.states {
            row([MD.f(s.id), MD.esc(s.name), "-", "-", "-", MD.f(s.size), "-"])
            for k in Self.sortedKeys(s.poses) {
                row([MD.f(s.id), "-", MD.f(k)] + poseCells(s.poses[k]!))
            }
        }
        blank()

        // Option groups: a header row per group (choice "-", carries name and default choice), a header row per choice
        // (component "-", carries name) and one row per component effect. Written only when the design has groups.
        if !d.optionGroups.isEmpty {
            table("Options", ["group", "choice", "name", "default", "component", "material", "visible"])
            for g in d.optionGroups {
                row([MD.f(g.id), "-", MD.esc(g.name), MD.f(g.defaultChoiceId), "-", "-", "-"])
                for c in g.choices {
                    row([MD.f(g.id), MD.f(c.id), MD.esc(c.name), "-", "-", "-", "-"])
                    for k in Self.sortedKeys(c.effects) {
                        let e = c.effects[k]!
                        row([MD.f(g.id), MD.f(c.id), "-", "-", MD.f(k), MD.f(e.materialId), MD.f(e.visible)])
                    }
                }
            }
            blank()
        }

        table("Tracks", ["id", "from", "to", "durationMs", "easing"])
        for t in d.tracks {
            row([MD.f(t.id), MD.f(t.fromStateId), MD.f(t.toStateId), "\(t.durationMs)", t.easing.rawValue])
        }
        blank()

        // Keyframe header row (component "-", carries t) + one row per component override; `key` = keyframe index.
        table("Keyframes", ["track", "key", "t", "component", "position", "rotation", "size", "visible"])
        for t in d.tracks {
            for (i, k) in t.keyframes.enumerated() {
                row([MD.f(t.id), "\(i)", MD.f(k.t), "-", "-", "-", "-", "-"])
                for c in Self.sortedKeys(k.poses) {
                    row([MD.f(t.id), "\(i)", "-", MD.f(c)] + poseCells(k.poses[c]!))
                }
            }
        }
        blank()
    }

    mutating func group(_ g: FurnitureGroup) {
        out += "### \(MD.f(g.id)) · \(MD.esc(g.name))\n\n"
        bullet("name", MD.esc(g.name))
        bullet("level", MD.f(g.levelId))
        bullet("origin", MD.f(g.origin))
        bullet("rotation", MD.f(g.rotationDeg))
        bullet("members", MD.uuids(g.memberIds))
        bullet("activeConfiguration", MD.f(g.activeConfigurationId))
        bullet("product", MD.f(g.productId))
        bullet("locked", MD.f(g.locked))
        bullet("rev", "\(g.rev)")
        blank()
        // Header row per configuration (member "-", carries name) + one row per member pose.
        table("Configurations", ["id", "name", "member", "local", "rotation", "visible", "state", "materialOverrides"])
        for c in g.configurations {
            row([MD.f(c.id), MD.esc(c.name), "-", "-", "-", "-", "-", "-"])
            for k in Self.sortedKeys(c.poses) {
                let p = c.poses[k]!
                row([MD.f(c.id), "-", MD.f(k), MD.f(p.local), MD.f(p.rotationDeg), MD.f(p.visible),
                     MD.f(p.stateId), MD.matMap(p.materialOverrides)])
            }
        }
        blank()
    }

    mutating func product(_ x: CatalogProduct) {
        out += "### \(MD.f(x.id)) · \(MD.esc(x.name))\n\n"
        bullet("name", MD.esc(x.name))
        bullet("category", MD.esc(x.category))
        bullet("description", MD.esc(x.description))
        bullet("notes", MD.esc(x.notes))
        bullet("manufacturer", MD.esc(x.manufacturer))
        bullet("model", MD.esc(x.model))
        bullet("articleNumber", MD.esc(x.articleNumber))
        bullet("priceMinor", MD.f(x.priceMinor))
        bullet("currency", MD.esc(x.currency))
        bullet("priceDate", MD.opt(x.priceDate))
        bullet("dimensions", MD.f(x.dimensions))
        bullet("weightGrams", MD.f(x.weightGrams))
        bullet("material", MD.esc(x.materialText))
        bullet("color", MD.esc(x.colorText))
        bullet("files", MD.uuids(x.fileAssetIds))
        bullet("images", MD.uuids(x.imageAssetIds))
        bullet("tags", MD.list(x.tags))
        bullet("status", x.status.rawValue)
        bullet("variants", MD.list(x.variants))
        bullet("rooms", MD.uuids(x.roomIds))
        bullet("definition", MD.f(x.definitionId))
        bullet("rev", "\(x.rev)")
        for k in x.custom.keys.sorted() { bullet("custom.\(k)", MD.esc(x.custom[k]!)) }
        blank()
        table("Links", ["id", "title", "url"])
        for l in x.links { row([MD.f(l.id), MD.esc(l.title), MD.esc(l.url)]) }
        blank()
    }
}
