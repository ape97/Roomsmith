import Foundation

/// Checks the invariants of a project after a command, limited to the objects the command touched.
/// Every command runs through it, so neither the UI nor an agent can commit an inconsistent document.
public enum Validator {
    public static func validate(_ p: Project, changes cs: ChangeSet) throws {
        let changed = Set(cs.objects.filter { $0.op != .removed }.map(\.id))
        let removedAny = cs.objects.contains { $0.op == .removed }
        if changed.isEmpty && !removedAny && !cs.settingsChanged && !cs.cameraChanged { return }

        // Always checked (not only for `.added`): a duplicate id is diffed as "modified", and the
        // Dictionary(uniqueKeysWithValues:) lookups below would trap on it.
        do {
            var seen = Set<UUID>()
            for id in p.allIds where !seen.insert(id).inserted {
                throw CommandError.invalid("Duplicate object id \(id.uuidString.lowercased())", ids: [id])
            }
        }
        if p.levels.isEmpty { throw CommandError.invalid("A project needs at least one level") }

        let levelIds = Set(p.levels.map(\.id))
        let wallsById = Dictionary(uniqueKeysWithValues: p.walls.map { ($0.id, $0) })
        let defsById = Dictionary(uniqueKeysWithValues: p.definitions.map { ($0.id, $0) })
        let materialIds = Set(p.materials.map(\.id))
        let groupIds = Set(p.groups.map(\.id))
        let instancesById = Dictionary(uniqueKeysWithValues: p.instances.map { ($0.id, $0) })

        func size(_ v: MM, _ what: String, _ id: UUID) throws {
            if !sizeLimit.contains(v) { throw CommandError.range("\(what) must be between \(sizeLimit.lowerBound) and \(sizeLimit.upperBound) mm", ids: [id]) }
        }
        func coord(_ ok: Bool, _ id: UUID) throws {
            if !ok { throw CommandError.range("Coordinates must stay within ±\(coordinateLimit) mm", ids: [id]) }
        }
        func level(_ lid: UUID, _ id: UUID) throws {
            if !levelIds.contains(lid) { throw CommandError(.notFound, "Level \(lid.uuidString.lowercased()) does not exist", ids: [id, lid]) }
        }
        func mat(_ mid: UUID?, _ id: UUID) throws {
            if let mid, !materialIds.contains(mid) { throw CommandError(.notFound, "Material \(mid.uuidString.lowercased()) does not exist", ids: [id, mid]) }
        }

        for l in p.levels where changed.contains(l.id) {
            try size(l.height, "Level height", l.id)
            try coord(l.elevation.magnitude <= coordinateLimit.magnitude, l.id)
            if l.name.trimmingCharacters(in: .whitespaces).isEmpty { throw CommandError.invalid("Level name must not be empty", ids: [l.id]) }
        }

        // Walls that changed, and walls whose openings changed, need the opening fit check.
        var wallsToCheck = Set<UUID>()
        for w in p.walls where changed.contains(w.id) {
            try level(w.levelId, w.id)
            try coord(w.start.isInRange && w.end.isInRange, w.id)
            if w.start == w.end { throw CommandError.invalid("A wall needs two different end points", ids: [w.id]) }
            try size(w.thickness, "Wall thickness", w.id)
            try size(w.height, "Wall height", w.id)
            try mat(w.leftMaterialId, w.id); try mat(w.rightMaterialId, w.id)
            wallsToCheck.insert(w.id)
        }
        for o in p.openings where changed.contains(o.id) {
            guard wallsById[o.wallId] != nil else { throw CommandError(.notFound, "Wall \(o.wallId.uuidString.lowercased()) does not exist", ids: [o.id, o.wallId]) }
            try mat(o.frameMaterialId, o.id)
            wallsToCheck.insert(o.wallId)
        }
        if removedAny {
            // Openings must not outlive their wall.
            for o in p.openings where wallsById[o.wallId] == nil {
                throw CommandError.invalid("Opening \(o.id.uuidString.lowercased()) refers to a deleted wall", ids: [o.id])
            }
        }
        for wid in wallsToCheck {
            guard let w = wallsById[wid] else { continue }
            try checkOpenings(of: w, in: p)
        }

        for r in p.rooms where changed.contains(r.id) {
            try level(r.levelId, r.id)
            if r.points.count < 3 { throw CommandError.invalid("A room needs at least 3 points", ids: [r.id]) }
            try coord(r.points.allSatisfy(\.isInRange), r.id)
            if !Geo.isSimplePolygon(r.points) { throw CommandError.invalid("The room outline must not cross itself", ids: [r.id]) }
            try mat(r.floorMaterialId, r.id); try mat(r.ceilingMaterialId, r.id)
        }
        for d in p.dimensions where changed.contains(d.id) {
            try level(d.levelId, d.id)
            try coord(d.a.isInRange && d.b.isInRange && d.offset.magnitude <= coordinateLimit.magnitude, d.id)
            if d.a == d.b { throw CommandError.invalid("A dimension needs two different points", ids: [d.id]) }
        }
        for m in p.materials where changed.contains(m.id) {
            if !(0...1).contains(m.roughness) || !(0...1).contains(m.metallic) || !(0...1).contains(m.opacity) {
                throw CommandError.range("Roughness, metallic and opacity must be between 0 and 1", ids: [m.id])
            }
            try size(m.textureTile, "Texture tile size", m.id)
        }
        for d in p.definitions where changed.contains(d.id) {
            try validateDefinition(d, materialIds: materialIds)
        }
        for i in p.instances where changed.contains(i.id) || (i.groupId.map { changed.contains($0) } ?? false) {
            try level(i.levelId, i.id)
            guard let def = defsById[i.definitionId] else { throw CommandError(.notFound, "Definition \(i.definitionId.uuidString.lowercased()) does not exist", ids: [i.id]) }
            try coord(i.position.isInRange, i.id)
            if let s = i.size, !s.isValid { throw CommandError.range("Size must be between \(sizeLimit.lowerBound) and \(sizeLimit.upperBound) mm per axis", ids: [i.id]) }
            if let sid = i.stateId, !def.states.contains(where: { $0.id == sid }) { throw CommandError(.notFound, "State \(sid.uuidString.lowercased()) does not belong to \(def.name)", ids: [i.id]) }
            for (gid, chid) in i.optionSelection {
                guard let g = def.optionGroups.first(where: { $0.id == gid }) else {
                    throw CommandError(.notFound, "Option group \(gid.uuidString.lowercased()) does not belong to \(def.name)", ids: [i.id])
                }
                if !g.choices.contains(where: { $0.id == chid }) {
                    throw CommandError(.notFound, "Choice \(chid.uuidString.lowercased()) does not belong to option group \(g.name)", ids: [i.id])
                }
            }
            if let gid = i.groupId, !groupIds.contains(gid) { throw CommandError(.notFound, "Group \(gid.uuidString.lowercased()) does not exist", ids: [i.id]) }
            for (cid, mid) in i.materialOverrides {
                if !def.components.contains(where: { $0.id == cid }) { throw CommandError(.notFound, "Component \(cid.uuidString.lowercased()) does not exist in \(def.name)", ids: [i.id]) }
                try mat(mid, i.id)
            }
            if !(0..<360).contains(i.rotationDeg) { throw CommandError.range("Rotation must be normalised to [0, 360)", ids: [i.id]) }
        }
        for g in p.groups where changed.contains(g.id) || removedAny {
            try level(g.levelId, g.id)
            if g.memberIds.isEmpty { throw CommandError.invalid("A group needs at least one member", ids: [g.id]) }
            for m in g.memberIds {
                guard let inst = instancesById[m] else { throw CommandError(.notFound, "Group member \(m.uuidString.lowercased()) does not exist", ids: [g.id, m]) }
                if inst.groupId != g.id { throw CommandError.invalid("Member \(m.uuidString.lowercased()) is not linked to its group", ids: [g.id, m]) }
            }
            for c in g.configurations {
                for mid in c.poses.keys where !g.memberIds.contains(mid) {
                    throw CommandError.invalid("Configuration \(c.name) refers to a non-member", ids: [g.id, mid])
                }
            }
            if let a = g.activeConfigurationId, !g.configurations.contains(where: { $0.id == a }) {
                throw CommandError(.notFound, "Active configuration does not exist", ids: [g.id])
            }
            try coord(g.origin.isInRange, g.id)
        }
        for pr in p.products where changed.contains(pr.id) {
            if pr.name.trimmingCharacters(in: .whitespaces).isEmpty { throw CommandError.invalid("Product name must not be empty", ids: [pr.id]) }
            for l in pr.links where !l.isValid { throw CommandError.invalid("Only http(s) links are allowed: \(l.url)", ids: [pr.id]) }
            if let d = pr.dimensions, !d.isValid { throw CommandError.range("Product dimensions out of range", ids: [pr.id]) }
            if let price = pr.priceMinor, price < 0 { throw CommandError.range("Price must not be negative", ids: [pr.id]) }
        }
        for b in p.backgrounds where changed.contains(b.id) {
            try level(b.levelId, b.id)
            if b.calibrationA == b.calibrationB { throw CommandError.invalid("Calibration points must differ", ids: [b.id]) }
            try size(b.calibrationLength, "Calibration length", b.id)
        }
        if cs.settingsChanged {
            let s = p.settings
            if s.snap.grid < 1 || s.snap.grid > 10_000 { throw CommandError.range("Grid must be between 1 and 10000 mm") }
            if s.snap.tolerance < 0 || s.snap.tolerance > 10_000 { throw CommandError.range("Snap tolerance must be between 0 and 10000 mm") }
            if !(s.snap.angleStep > 0 && s.snap.angleStep <= 180) { throw CommandError.range("Angle step must be in (0, 180]") }
            if !sizeLimit.contains(s.defaultWallThickness) || !sizeLimit.contains(s.defaultWallHeight) { throw CommandError.range("Default wall size out of range") }
            if !s.lighting.isValid { throw CommandError.range("Lighting out of range: north ±360°, day 1…366, time 0…1439 min, latitude ±66°, exposure ±3 EV") }
        }
        if cs.cameraChanged { try validateCamera(p.camera) }
    }

    public static func validateCamera(_ c: CameraState) throws {
        if !c.target.isInRange { throw CommandError.range("Camera target out of range") }
        if c.distance < 10 || c.distance > 1_000_000 { throw CommandError.range("Camera distance must be between 10 and 1000000 mm") }
        if !(10...120).contains(c.fovDeg) { throw CommandError.range("Field of view must be between 10° and 120°") }
        if !(-90...90).contains(c.pitchDeg) { throw CommandError.range("Pitch must be between -90° and 90°") }
        if !c.yawDeg.isFinite { throw CommandError.range("Yaw must be finite") }
    }

    public static func validateDefinition(_ d: FurnitureDefinition, materialIds: Set<UUID>) throws {
        if !d.size.isValid { throw CommandError.range("Definition size out of range", ids: [d.id]) }
        if d.name.trimmingCharacters(in: .whitespaces).isEmpty { throw CommandError.invalid("Definition name must not be empty", ids: [d.id]) }
        if d.components.isEmpty { throw CommandError.invalid("A furniture definition needs at least one component", ids: [d.id]) }
        var cids = Set<UUID>()
        for c in d.components {
            if !cids.insert(c.id).inserted { throw CommandError.invalid("Duplicate component id in \(d.name)", ids: [d.id, c.id]) }
            if !c.size.isValid { throw CommandError.range("Component \(c.name) has an invalid size", ids: [d.id, c.id]) }
            if !c.position.isInRange { throw CommandError.range("Component \(c.name) is out of range", ids: [d.id, c.id]) }
            if c.shape == .mesh && c.meshAssetId == nil { throw CommandError.invalid("Mesh component \(c.name) needs a mesh asset", ids: [d.id, c.id]) }
            if let m = c.materialId, !materialIds.contains(m) { throw CommandError(.notFound, "Material of component \(c.name) does not exist", ids: [d.id, c.id]) }
        }
        var sids = Set<UUID>()
        for s in d.states {
            if !sids.insert(s.id).inserted { throw CommandError.invalid("Duplicate state id in \(d.name)", ids: [d.id, s.id]) }
            for (cid, pose) in s.poses {
                if !cids.contains(cid) { throw CommandError(.notFound, "State \(s.name) refers to an unknown component", ids: [d.id, cid]) }
                if let sz = pose.size, !sz.isValid { throw CommandError.range("State \(s.name) has an invalid component size", ids: [d.id, cid]) }
            }
            if let sz = s.size, !sz.isValid { throw CommandError.range("State \(s.name) has an invalid size", ids: [d.id, s.id]) }
        }
        if let ds = d.defaultStateId, !sids.contains(ds) { throw CommandError(.notFound, "Default state does not exist", ids: [d.id]) }
        for t in d.tracks {
            if !sids.contains(t.toStateId) || (t.fromStateId.map { !sids.contains($0) } ?? false) {
                throw CommandError(.notFound, "Animation track refers to an unknown state", ids: [d.id, t.id])
            }
            if t.durationMs < 0 || t.durationMs > 60_000 { throw CommandError.range("Animation duration must be 0…60000 ms", ids: [d.id, t.id]) }
            for k in t.keyframes where !(0...1).contains(k.t) { throw CommandError.range("Keyframe time must be 0…1", ids: [d.id, t.id]) }
        }
        try validateOptionGroups(d, componentIds: cids, materialIds: materialIds)
        if d.lights.count > LightEmitter.maxPerDefinition {
            throw CommandError.range("A design can have at most \(LightEmitter.maxPerDefinition) lamps", ids: [d.id])
        }
        var lids = Set<UUID>()
        for e in d.lights {
            if !lids.insert(e.id).inserted { throw CommandError.invalid("Duplicate lamp id in \(d.name)", ids: [d.id, e.id]) }
            if !e.position.isInRange { throw CommandError.range("Lamp \(e.name) is out of range", ids: [d.id, e.id]) }
            if !e.isValid { throw CommandError.range("Lamp \(e.name): lumens 1…100000, kelvin 1500…12000, cone 10…150°, range 200…30000 mm, pitch ±90°", ids: [d.id, e.id]) }
        }
    }

    static func validateOptionGroups(_ d: FurnitureDefinition, componentIds cids: Set<UUID>, materialIds: Set<UUID>) throws {
        if d.optionGroups.count > OptionGroup.maxPerDefinition {
            throw CommandError.range("A design can have at most \(OptionGroup.maxPerDefinition) option groups", ids: [d.id])
        }
        var gids = Set<UUID>(), gnames = Set<String>()
        for g in d.optionGroups {
            if !gids.insert(g.id).inserted { throw CommandError.invalid("Duplicate option group id in \(d.name)", ids: [d.id, g.id]) }
            let gname = g.name.trimmingCharacters(in: .whitespaces)
            if gname.isEmpty { throw CommandError.invalid("Option group name must not be empty", ids: [d.id, g.id]) }
            if !gnames.insert(gname.lowercased()).inserted { throw CommandError.invalid("Duplicate option group name '\(gname)' in \(d.name)", ids: [d.id, g.id]) }
            if g.choices.isEmpty { throw CommandError.invalid("Option group \(g.name) needs at least one choice", ids: [d.id, g.id]) }
            if g.choices.count > OptionGroup.maxChoices { throw CommandError.range("Option group \(g.name) can have at most \(OptionGroup.maxChoices) choices", ids: [d.id, g.id]) }
            var chids = Set<UUID>(), chnames = Set<String>()
            for ch in g.choices {
                if !chids.insert(ch.id).inserted { throw CommandError.invalid("Duplicate choice id in option group \(g.name)", ids: [d.id, ch.id]) }
                let cname = ch.name.trimmingCharacters(in: .whitespaces)
                if cname.isEmpty { throw CommandError.invalid("Choice name must not be empty", ids: [d.id, ch.id]) }
                if !chnames.insert(cname.lowercased()).inserted { throw CommandError.invalid("Duplicate choice name '\(cname)' in option group \(g.name)", ids: [d.id, ch.id]) }
                for (cid, e) in ch.effects {
                    if !cids.contains(cid) { throw CommandError(.notFound, "Choice \(ch.name) refers to an unknown component", ids: [d.id, cid]) }
                    if let m = e.materialId, !materialIds.contains(m) { throw CommandError(.notFound, "Material of choice \(ch.name) does not exist", ids: [d.id, m]) }
                }
            }
            if let dc = g.defaultChoiceId, !chids.contains(dc) { throw CommandError(.notFound, "Default choice of option group \(g.name) does not exist", ids: [d.id, g.id]) }
        }
    }

    /// Openings must fit inside their wall (along the axis and in height) and must not overlap each other.
    public static func checkOpenings(of w: Wall, in p: Project) throws {
        let len = p.wallLength(w)
        let list = p.openings.filter { $0.wallId == w.id }.sorted { $0.offset < $1.offset }
        var lastEnd = -Double.infinity
        var lastId: UUID?
        for o in list {
            if o.width < 1 || o.height < 1 { throw CommandError.range("Opening width and height must be at least 1 mm", ids: [o.id]) }
            if o.sill < 0 { throw CommandError.range("Sill height must not be negative", ids: [o.id]) }
            if !Project.frameWidthRange.contains(o.frameWidth) || !Project.mullionRange.contains(o.mullionCols) || !Project.mullionRange.contains(o.mullionRows) {
                throw CommandError.range("Frame width must be 20 to 150 mm and bar counts 0 to 6", ids: [o.id])
            }
            let a = Double(o.offset) - Double(o.width) / 2, b = Double(o.offset) + Double(o.width) / 2
            if a < -1e-9 || b > len + 1e-9 {
                throw CommandError.range("\(o.kind.rawValue.capitalized) does not fit into the wall (wall length \(Int(len.rounded())) mm)", ids: [o.id, w.id])
            }
            if o.sill + o.height > w.height {
                throw CommandError.range("\(o.kind.rawValue.capitalized) is higher than the wall (\(w.height) mm)", ids: [o.id, w.id])
            }
            if a < lastEnd - 1e-9, let lastId { throw CommandError.invalid("Openings overlap", ids: [lastId, o.id]) }
            lastEnd = b; lastId = o.id
        }
    }
}
