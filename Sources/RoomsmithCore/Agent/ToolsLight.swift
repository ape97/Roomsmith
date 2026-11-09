import Foundation

// MARK: - light.*

/// Sun, sky and lamps. Lamps are `LightEmitter`s of a furniture design, switched per placed piece. Everything is document state with undo.
enum LightTools {
    private static func lightingJSON(_ s: LightingSettings) -> JSONValue {
        let sun = SunPosition.compute(s)
        let look = SunSkyLook(s)
        return .object([
            "northDeg": .number(s.northDeg), "dayOfYear": .int(Int64(s.dayOfYear)), "timeMinutes": .int(Int64(s.timeMinutes)),
            "time": .string(s.timeText), "latitudeDeg": .number(s.latitudeDeg), "mood": .string(s.mood.rawValue),
            "shadows": .bool(s.shadows), "exposure": .number(s.exposure),
            "sun": .object(["azimuthDeg": .number(sun.azimuthDeg), "elevationDeg": .number(sun.elevationDeg),
                            "strength": .number(look.sunIntensity), "castsShadows": .bool(look.sunShadows)]),
        ])
    }

    private static func emitterJSON(_ e: LightEmitter) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": J.id(e.id), "name": .string(e.name), "kind": .string(e.kind.rawValue), "positionMm": J.p3(e.position),
            "kelvin": .int(Int64(e.kelvin)), "lumens": .int(Int64(e.lumens)), "rangeMm": .int(e.rangeMm),
        ]
        if e.kind == .spot { o["yawDeg"] = .number(e.yawDeg); o["pitchDeg"] = .number(e.pitchDeg); o["coneDeg"] = .number(e.coneDeg) }
        if let c = e.color { o["color"] = .string(c.hex) }
        return .object(o)
    }

    private static func requireDefinition(_ p: Project, _ a: Args) throws -> FurnitureDefinition {
        let id = try a.requireUUID("definitionId")
        guard let d = p.definition(id) else {
            if p.kind(of: id) != nil { throw ToolError.invalid("definitionId", "\(id.uuidString.lowercased()) is not a furniture design") }
            throw ToolError.notFound("Definition", id)
        }
        return d
    }

    private static func ranged<T: Comparable>(_ v: T?, _ r: ClosedRange<T>, _ key: String, _ hint: String) throws -> T? {
        guard let v else { return nil }
        guard r.contains(v) else { throw ToolError.invalid(key, "must be \(hint)") }
        return v
    }

    @MainActor
    static func specs() -> [ToolSpec] {
        [
            .read("light.get",
                  "Sun, sky and lamps. Returns the lighting settings with the computed sun, every design that has lamps, which placed pieces have them switched on, and how many lamps actually render (at most \(LightRig.maxActive); the strongest win, `skipped` counts the rest).") { env, _ in
                let p = env.project
                let defs = p.definitions.filter { !$0.lights.isEmpty }
                let rig = LightRig.collect(p)
                let pieces = p.instances.compactMap { i -> JSONValue? in
                    guard let d = p.definition(i.definitionId), !d.lights.isEmpty else { return nil }
                    return .object(["id": J.id(i.id), "name": .string(i.name), "definitionId": J.id(d.id), "lightOn": .bool(i.lightOn)])
                }
                return .object([
                    "lighting": lightingJSON(p.settings.lighting),
                    "designs": .array(defs.map { d in .object(["id": J.id(d.id), "name": .string(d.name), "lights": .array(d.lights.map(emitterJSON))]) }),
                    "pieces": .array(pieces),
                    "activeLamps": .int(Int64(rig.active.count)), "skipped": .int(Int64(rig.skipped)), "maxActive": .int(Int64(LightRig.maxActive)),
                    "moods": .array(LightMood.allCases.map { .string($0.rawValue) }),
                ])
            },
            .write("light.set",
                   "Changes sun and sky; only the given keys change. North: degrees counter-clockwise from plan +Y (0 = north is +Y, east is +X). Time is local solar time. `applyMoodTime` also moves the time to the mood's suggested time (daylight 13:00, evening 19:30, night 23:30, overcast 12:00).",
                   ["northDeg": S.num("Direction of north in the plan, -360...360."), "dayOfYear": S.int("1...366 (21 June = 172)."),
                    "timeMinutes": S.int("Minutes after midnight, 0...1439."), "latitudeDeg": S.num("-66...66, positive = north."),
                    "mood": S.str("Atmosphere preset.", values: LightMood.allCases.map(\.rawValue)),
                    "applyMoodTime": S.bool("With `mood`: also set the time of day to the mood's suggested time (default false)."),
                    "shadows": S.bool("Sun shadows on/off."), "exposure": S.num("Exposure in EV stops, -3...3.")]) { p, _, a in
                let keys = ["northDeg", "dayOfYear", "timeMinutes", "latitudeDeg", "mood", "shadows", "exposure"]
                guard keys.contains(where: a.has) else { throw ToolError.invalid(nil, "Give at least one of: \(keys.joined(separator: ", "))") }
                let north = try ranged(try a.double("northDeg"), LightingSettings.northRange, "northDeg", "between -360 and 360")
                let day = try ranged(try a.int("dayOfYear").map(Int.init), LightingSettings.dayRange, "dayOfYear", "between 1 and 366")
                let time = try ranged(try a.int("timeMinutes").map(Int.init), LightingSettings.timeRange, "timeMinutes", "between 0 and 1439")
                let lat = try ranged(try a.double("latitudeDeg"), LightingSettings.latitudeRange, "latitudeDeg", "between -66 and 66")
                let exposure = try ranged(try a.double("exposure"), LightingSettings.exposureRange, "exposure", "between -3 and 3")
                let mood = try a.enumValue("mood", LightMood.self), shadows = try a.bool("shadows")
                let applyTime = try a.bool("applyMoodTime") ?? false
                if let mood { p.applyMood(mood, setTime: applyTime) }
                p.updateLighting { l in
                    if let north { l.northDeg = north }
                    if let day { l.dayOfYear = day }
                    if let time { l.timeMinutes = time }
                    if let lat { l.latitudeDeg = lat }
                    if let shadows { l.shadows = shadows }
                    if let exposure { l.exposure = exposure }
                }
                return .object(["lighting": lightingJSON(p.settings.lighting)])
            },
            .write("light.set_emitter",
                   "Adds a lamp to a furniture design, or changes one (give `emitterId`). A design has at most \(LightEmitter.maxPerDefinition) lamps. Position is in the design's space in mm (origin at the footprint centre on the floor). Spot aim: yawDeg counter-clockwise from +X, pitchDeg -90 = straight down. All placed pieces of the design follow.",
                   ["definitionId": S.uuid("Furniture design id."), "emitterId": S.uuid("Existing lamp to change; omit to add a new one."),
                    "name": S.str("Lamp name."), "kind": S.str("`point` or `spot`.", values: LightKind.allCases.map(\.rawValue)),
                    "positionMm": .object(["type": "object", "description": "Lamp position {x,y,z} in mm in the design's space."]),
                    "yawDeg": S.num("Spot aim, degrees."), "pitchDeg": S.num("Spot aim, -90...90."),
                    "coneDeg": S.num("Full cone angle of a spot, 10...150."), "kelvin": S.int("Colour temperature, 1500...12000."),
                    "color": S.str("Hex colour #RRGGBB; overrides kelvin. Send null to go back to kelvin."),
                    "lumens": S.int("Brightness, 1...100000 (a 60 W bulb is about 800)."), "rangeMm": S.int("Reach in mm, 200...30000.")],
                   required: ["definitionId"]) { p, _, a in
                let d = try requireDefinition(p, a)
                let existing = try a.uuid("emitterId")
                var e: LightEmitter
                if let existing {
                    guard let cur = d.lights.first(where: { $0.id == existing }) else { throw ToolError.notFound("Lamp", existing) }
                    e = cur
                } else {
                    guard d.lights.count < LightEmitter.maxPerDefinition else {
                        throw ToolError.invalid("definitionId", "a design can have at most \(LightEmitter.maxPerDefinition) lamps")
                    }
                    let pos = try a.p3("positionMm") ?? P3(0, 0, max(d.size.height - 100, 0))
                    e = LightEmitter(name: "Lamp", position: pos)
                }
                if let pos = try a.p3("positionMm") { e.position = pos }
                if let n = try a.nonEmptyString("name") { e.name = n }
                if let k = try a.enumValue("kind", LightKind.self) { e.kind = k }
                if let v = try a.double("yawDeg") { e.yawDeg = v }
                if let v = try ranged(try a.double("pitchDeg"), LightEmitter.pitchRange, "pitchDeg", "between -90 and 90") { e.pitchDeg = v }
                if let v = try ranged(try a.double("coneDeg"), LightEmitter.coneRange, "coneDeg", "between 10 and 150") { e.coneDeg = v }
                if let v = try ranged(try a.int("kelvin").map(Int.init), LightEmitter.kelvinRange, "kelvin", "between 1500 and 12000") { e.kelvin = v }
                if let v = try ranged(try a.int("lumens").map(Int.init), LightEmitter.lumensRange, "lumens", "between 1 and 100000") { e.lumens = v }
                if let v = try ranged(try a.mm("rangeMm"), LightEmitter.rangeMmLimit, "rangeMm", "between 200 and 30000") { e.rangeMm = v }
                if a.isNull("color") { e.color = nil } else if let s = try a.string("color") {
                    guard let c = RGBColor(hex: s) else { throw ToolError.invalid("color", "must be a hex colour like #FFE0B0") }
                    e.color = c
                }
                try p.setEmitter(e, in: d.id)
                return .object(["id": J.id(e.id), "ids": J.ids([d.id]), "emitter": emitterJSON(e)])
            },
            .write("light.remove_emitter", "Removes a lamp from a furniture design.",
                   ["definitionId": S.uuid("Furniture design id."), "emitterId": S.uuid("Lamp id.")],
                   required: ["definitionId", "emitterId"]) { p, _, a in
                let d = try requireDefinition(p, a)
                try p.removeEmitter(try a.requireUUID("emitterId"), from: d.id)
                return .object(["ids": J.ids([d.id])])
            },
            .write("light.toggle",
                   "Switches the lamps of a placed piece on or off (works on locked pieces too). Without `on` the state flips.",
                   ["id": S.uuid("Placed furniture id."), "on": S.bool("Target state; omit to flip.")], required: ["id"]) { p, _, a in
                let id = try a.requireUUID("id")
                guard let inst = p.instance(id) else {
                    if p.kind(of: id) != nil { throw ToolError.invalid("id", "\(id.uuidString.lowercased()) is not a placed piece of furniture") }
                    throw ToolError.notFound("Furniture", id)
                }
                guard p.definition(inst.definitionId)?.lights.isEmpty == false else {
                    throw ToolError.invalid("id", "this piece has no lamps; add one with light.set_emitter")
                }
                let on = try a.bool("on") ?? !inst.lightOn
                try p.setLightOn(on, instance: id)
                return .object(["id": J.id(id), "ids": J.ids([id]), "lightOn": .bool(on)])
            },
        ]
    }
}
