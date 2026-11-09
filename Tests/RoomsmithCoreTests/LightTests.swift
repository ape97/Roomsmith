import Foundation
import simd
import Testing
@testable import RoomsmithCore

// Sun maths, lighting commands with undo, persistence and the agent tools for lamps.

@MainActor
private final class LightContext: AgentAppContext {
    var selection: Set<UUID> = []
    var activeLevelId: UUID
    var fileURL: URL?
    var appVersion = "test"
    init(activeLevelId: UUID) { self.activeLevelId = activeLevelId }
    func saveForAgent() throws -> String { "/tmp/test.roomsmith" }
}

@MainActor
private struct LRig {
    let store: DocumentStore
    let registry: ToolRegistry
    var p: Project { store.project }
    var levelId: UUID { store.project.levels[0].id }

    init() {
        let project = Project.empty(name: "Light")
        store = DocumentStore(project: project)
        store.agentWriteEnabled = true
        registry = ToolRegistry(store: store, context: LightContext(activeLevelId: project.levels[0].id))
    }

    func call(_ tool: String, _ args: JSONValue = .object([:])) async -> AgentResponse {
        await registry.call(AgentRequest(id: 1, token: "t", clientId: "test", tool: tool, arguments: args))
    }

    func ok(_ tool: String, _ args: JSONValue = .object([:]), sourceLocation: SourceLocation = #_sourceLocation) async -> JSONValue {
        let r = await call(tool, args)
        #expect(r.ok, "\(tool) failed: \(r.error?.code ?? "?") \(r.error?.message ?? "")", sourceLocation: sourceLocation)
        return r.result ?? .null
    }

    /// A lamp design (a box with `lampCount` lamps) and one placed piece per entry in `positions`.
    @discardableResult
    func addLamps(lampCount: Int = 1, lumens: Int = 800, positions: [P3] = [P3(0, 0, 0)]) throws -> (def: UUID, pieces: [UUID]) {
        var d = FurnitureDefinition(id: UUID(), name: "Lamp", category: "Light", size: Size3(300, 300, 1600),
                                    components: [Component(name: "body", shape: .box, position: P3(0, 0, 800), size: Size3(300, 300, 1600))])
        for i in 0..<lampCount {
            var e = LightEmitter(name: "L\(i)", position: P3(0, 0, 1500))
            e.lumens = lumens
            d.lights.append(e)
        }
        var pieces = [UUID]()
        _ = try store.run("Add lamp") { p in
            p.addDefinition(d)
            for pos in positions { pieces.append(try p.addInstance(definitionId: d.id, levelId: levelId, position: pos)) }
        }
        return (d.id, pieces)
    }
}

@Suite struct SunPositionTests {
    @Test func noonAtEquinoxIsSouthAndHigh() {
        let s = SunPosition.compute(dayOfYear: 80, timeMinutes: 720, latitudeDeg: 50)
        #expect(abs(s.elevationDeg - 40) < 1.5)       // 90 - latitude at the equinox
        #expect(abs(s.azimuthDeg - 180) < 0.5)
    }

    @Test func midsummerNoonIsHigherThanMidwinterNoon() {
        let summer = SunPosition.compute(dayOfYear: 172, timeMinutes: 720, latitudeDeg: 50).elevationDeg
        let winter = SunPosition.compute(dayOfYear: 355, timeMinutes: 720, latitudeDeg: 50).elevationDeg
        #expect(abs(summer - 63.4) < 1.0)
        #expect(abs(winter - 16.6) < 1.0)
    }

    @Test func sunMovesEastToWestAndSetsAtMidnight() {
        let morning = SunPosition.compute(dayOfYear: 172, timeMinutes: 8 * 60, latitudeDeg: 50)
        let evening = SunPosition.compute(dayOfYear: 172, timeMinutes: 18 * 60, latitudeDeg: 50)
        #expect(morning.azimuthDeg < 180 && morning.azimuthDeg > 45)
        #expect(evening.azimuthDeg > 180)
        #expect(SunPosition.compute(dayOfYear: 172, timeMinutes: 0, latitudeDeg: 50).elevationDeg < 0)
    }

    @Test func directionFollowsNorthAngle() {
        // Noon: sun in the south. North = +Y (0 deg): the sun is towards -Y; rotating north by 90 deg counter-clockwise puts north at -X, so south at +X.
        let noon = SunPosition.compute(dayOfYear: 80, timeMinutes: 720, latitudeDeg: 50)
        let d0 = noon.directionToSun(northDeg: 0)
        #expect(d0.y < -0.5 && abs(d0.x) < 0.01 && d0.z > 0.5)
        let d90 = noon.directionToSun(northDeg: 90)
        #expect(d90.x > 0.5 && abs(d90.y) < 0.01)
        #expect(abs(length(d0) - 1) < 1e-9)
        // Morning sun comes from the east (+X) when north is +Y.
        let morning = SunPosition.compute(dayOfYear: 172, timeMinutes: 8 * 60, latitudeDeg: 50).directionToSun(northDeg: 0)
        #expect(morning.x > 0)
    }

    @Test func moodsShapeTheLook() {
        var s = LightingSettings()
        s.timeMinutes = 13 * 60
        let day = SunSkyLook(s)
        #expect(day.sunIntensity > 0.8 && day.sunShadows)
        s.mood = .overcast
        let grey = SunSkyLook(s)
        #expect(grey.sunIntensity < 0.2 && !grey.sunShadows)
        s.mood = .night
        let night = SunSkyLook(s)
        #expect(night.sunIntensity == 0 && !night.sunShadows && night.ambient < day.ambient)
        s.mood = .daylight; s.shadows = false
        #expect(!SunSkyLook(s).sunShadows)
        s.shadows = true; s.timeMinutes = 0
        #expect(SunSkyLook(s).sunIntensity == 0)
        #expect(Kelvin.rgb(2700).x > Kelvin.rgb(2700).z)   // warm: more red than blue
    }
}

@MainActor
@Suite struct LightingCommandTests {
    @Test func settingsChangeIsOneUndoStep() throws {
        let store = DocumentStore(project: Project.empty(name: "L"))
        _ = try store.run("Light") { p in p.updateLighting { $0.northDeg = 45; $0.timeMinutes = 600 } }
        #expect(store.project.settings.lighting.northDeg == 45)
        _ = try store.undo()
        #expect(store.project.settings.lighting == LightingSettings())
        _ = try store.redo()
        #expect(store.project.settings.lighting.timeMinutes == 600)
    }

    @Test func moodCanSetTheTime() throws {
        let store = DocumentStore(project: Project.empty(name: "L"))
        _ = try store.run("Mood") { $0.applyMood(.night, setTime: true) }
        #expect(store.project.settings.lighting.mood == .night)
        #expect(store.project.settings.lighting.timeMinutes == LightMood.night.suggestedTimeMinutes)
        _ = try store.run("Mood") { $0.applyMood(.evening, setTime: false) }
        #expect(store.project.settings.lighting.timeMinutes == LightMood.night.suggestedTimeMinutes)
    }

    @Test func outOfRangeIsRejectedAndLeavesTheDocumentAlone() throws {
        let store = DocumentStore(project: Project.empty(name: "L"))
        #expect(throws: (any Error).self) { _ = try store.run("Bad") { $0.updateLighting { $0.timeMinutes = 5000 } } }
        #expect(throws: (any Error).self) { _ = try store.run("Bad") { $0.updateLighting { $0.exposure = 9 } } }
        #expect(store.project.settings.lighting == LightingSettings())
    }

    @Test func emittersAndSwitchHaveUndo() throws {
        let rig = LRig()
        let (def, pieces) = try rig.addLamps()
        let extra = LightEmitter(name: "Spot", kind: .spot, position: P3(0, 0, 1000))
        _ = try rig.store.run("Add emitter") { try $0.setEmitter(extra, in: def) }
        #expect(rig.p.definition(def)?.lights.count == 2)
        _ = try rig.store.run("Switch") { try $0.setLightOn(false, instance: pieces[0]) }
        #expect(rig.p.instance(pieces[0])?.lightOn == false)
        _ = try rig.store.undo()
        #expect(rig.p.instance(pieces[0])?.lightOn == true)
        _ = try rig.store.run("Remove") { try $0.removeEmitter(extra.id, from: def) }
        #expect(rig.p.definition(def)?.lights.count == 1)
        _ = try rig.store.undo()
        #expect(rig.p.definition(def)?.lights.count == 2)
    }

    @Test func invalidEmitterIsRejected() throws {
        let rig = LRig()
        let (def, _) = try rig.addLamps()
        var bad = LightEmitter(name: "Bad", position: P3(0, 0, 100))
        bad.lumens = 0
        #expect(throws: (any Error).self) { _ = try rig.store.run("Bad") { try $0.setEmitter(bad, in: def) } }
        #expect(rig.p.definition(def)?.lights.count == 1)
    }
}

@MainActor
@Suite struct LampVisibilityTests {
    @Test func onlyDesignsWithEmittersCountAsLamps() throws {
        let rig = LRig()
        let (lampDef, lamps) = try rig.addLamps()
        let plain = FurnitureDefinition(id: UUID(), name: "Box", category: "t", size: Size3(500, 500, 500),
                                        components: [Component(name: "c", shape: .box, position: P3(0, 0, 250), size: Size3(500, 500, 500))])
        var boxId = UUID()
        _ = try rig.store.run("Box") { p in
            p.addDefinition(plain)
            boxId = try p.addInstance(definitionId: plain.id, levelId: rig.levelId, position: P3(2000, 0, 0))
        }
        let lampPiece = try #require(rig.p.instance(lamps[0]))
        let boxPiece = try #require(rig.p.instance(boxId))
        #expect(rig.p.definition(lampDef)?.isLamp == true)
        #expect(rig.p.definition(plain.id)?.isLamp == false)
        #expect(rig.p.lampDefinitionIds == [lampDef])
        #expect(rig.p.isInstanceShown(lampPiece, showLamps: true))
        #expect(!rig.p.isInstanceShown(lampPiece, showLamps: false))
        #expect(rig.p.isInstanceShown(boxPiece, showLamps: false))
    }

    @Test func lampFurnitureWithoutLightIsHiddenToo() {
        func def(_ name: String, _ category: String, tags: [String] = []) -> FurnitureDefinition {
            var d = FurnitureDefinition(id: UUID(), name: name, category: category, size: Size3(300, 300, 450),
                                        components: [Component(name: "c", shape: .box, position: P3(0, 0, 225), size: Size3(300, 300, 450))])
            d.tags = tags
            return d
        }
        var p = Project.empty(name: "NoLight")
        let lvl = p.levels[0].id
        let byCategory = def("Thing", "Lighting")
        let byTag = def("Thing", "Decor", tags: ["Light"])
        let byName = def("Tischlampe", "Living")
        let byCatalog = def("Table lamp", "Decor", tags: ["lamp", "table lamp"])
        let plain = def("Skylight panel", "Living", tags: ["window"])
        var withLight = def("Spot", "Living")
        withLight.lights = [LightEmitter(position: P3(0, 0, 400))]
        p.definitions = [byCategory, byTag, byName, byCatalog, plain, withLight]
        p.instances = p.definitions.enumerated().map {
            FurnitureInstance(definitionId: $1.id, levelId: lvl, name: $1.name, position: P3(Int64($0) * 1000, 0, 0))
        }
        for d in [byCategory, byTag, byName, byCatalog, withLight] { #expect(p.definition(d.id)?.isLamp == true, "\(d.name)") }
        #expect(p.definition(plain.id)?.isLamp == false)
        #expect(def("Deckenleuchte", "Living").isLamp)
        #expect(!def("Sideboard", "Living", tags: ["oak"]).isLamp)
        let shown = p.instances.filter { p.isInstanceShown($0, showLamps: false) }
        #expect(shown.map(\.definitionId) == [plain.id])
        #expect(p.instances.allSatisfy { p.isInstanceShown($0, showLamps: true) })
        // Dragging a piece: hidden lamps are no obstacle, shown ones are.
        let mover = FurnitureInstance(definitionId: plain.id, levelId: lvl, name: "m", position: P3(0, 3000, 0))
        p.instances.append(mover)
        let all = MoveContact.obstacles(project: p, levelId: lvl, excluding: [mover.id], toWalls: true, toObjects: true)
        let noLamps = MoveContact.obstacles(project: p, levelId: lvl, excluding: [mover.id], toWalls: true, toObjects: true, showLamps: false)
        #expect(all.compactMap(\.id).count == 6)
        #expect(noLamps.compactMap(\.id).count == 1)
    }

    @Test func unknownDesignCountsAsPlainFurniture() {
        let p = Project.empty(name: "U")
        let orphan = FurnitureInstance(definitionId: UUID(), levelId: p.levels[0].id, name: "x", position: P3(0, 0, 0))
        #expect(p.isInstanceShown(orphan, showLamps: false))
    }

    @Test func hidingLampPiecesLeavesTheirLightUntouched() throws {
        let rig = LRig()
        try rig.addLamps(positions: [P3(0, 0, 0), P3(1500, 0, 0)])
        // The filter works on the view only: the light rig reads the document and never the "Lamps" switch.
        let before = LightRig.collect(rig.p)
        #expect(before.active.count == 2)
        #expect(rig.p.instances.allSatisfy { !rig.p.isInstanceShown($0, showLamps: false) })
        #expect(LightRig.collect(rig.p).active == before.active)
    }
}

@MainActor
@Suite struct LightRigTests {
    @Test func capsAtEightAndKeepsTheStrongest() throws {
        let rig = LRig()
        // 12 pieces of one weak lamp plus one strong lamp.
        try rig.addLamps(lumens: 100, positions: (0..<12).map { P3(Int64($0) * 500, 0, 0) })
        let (_, strong) = try rig.addLamps(lumens: 5000, positions: [P3(0, 3000, 0)])
        let r = LightRig.collect(rig.p)
        #expect(r.active.count == LightRig.maxActive)
        #expect(r.skipped == 13 - LightRig.maxActive)
        #expect(r.active[0].instanceId == strong[0])
        #expect(r.active == LightRig.collect(rig.p).active)   // deterministic
    }

    @Test func offHiddenAndHiddenLevelsDoNotShine() throws {
        let rig = LRig()
        let (_, pieces) = try rig.addLamps(positions: [P3(0, 0, 0), P3(1000, 0, 0), P3(2000, 0, 0)])
        _ = try rig.store.run("Edit") { p in
            try p.setLightOn(false, instance: pieces[0])
            try p.updateInstance(pieces[1]) { $0.visible = false }
        }
        #expect(LightRig.collect(rig.p).active.count == 1)
        #expect(LightRig.collect(rig.p, levelVisible: { _ in false }).active.isEmpty)
    }

    @Test func lampPositionFollowsPieceAndRotation() throws {
        let rig = LRig()
        let (def, pieces) = try rig.addLamps(positions: [P3(1000, 2000, 100)])
        _ = try rig.store.run("Spot") { p in
            var e = LightEmitter(name: "S", kind: .spot, position: P3(200, 0, 1500))
            e.yawDeg = 0; e.pitchDeg = 0
            try p.setEmitter(e, in: def)
            try p.updateInstance(pieces[0]) { $0.rotationDeg = 90 }
        }
        let spot = LightRig.collect(rig.p).active.first { $0.kind == .spot }
        #expect(spot != nil)
        #expect(abs((spot?.position.x ?? 0) - 1000) < 1e-6 && abs((spot?.position.y ?? 0) - 2200) < 1e-6)
        #expect(abs((spot?.position.z ?? 0) - 1600) < 1e-6)
        #expect(abs((spot?.direction.y ?? 0) - 1) < 1e-9)   // +X turned by 90 degrees
    }
}

@MainActor
@Suite struct LightPersistenceTests {
    @Test func roundTripKeepsLightingAndLamps() throws {
        let rig = LRig()
        let (def, pieces) = try rig.addLamps()
        _ = try rig.store.run("All") { p in
            p.updateLighting { $0.northDeg = 33.5; $0.dayOfYear = 100; $0.timeMinutes = 1111; $0.latitudeDeg = -12.5
                $0.mood = .evening; $0.shadows = false; $0.exposure = 1.25 }
            var e = LightEmitter(name: "Reading | spot", kind: .spot, position: P3(10, -20, 900))
            e.yawDeg = 12; e.pitchDeg = -45; e.coneDeg = 60; e.kelvin = 3500; e.color = RGBColor(hex: "#FFE0B0"); e.lumens = 450; e.rangeMm = 3200
            try p.setEmitter(e, in: def)
            try p.setLightOn(false, instance: pieces[0])
        }
        let text = RoomsmithMarkdown.encode(rig.p)
        let (back, warnings) = try RoomsmithMarkdown.decode(text)
        #expect(warnings.isEmpty)
        #expect(back.settings.lighting == rig.p.settings.lighting)
        #expect(back.definition(def)?.lights == rig.p.definition(def)?.lights)
        #expect(back.instance(pieces[0])?.lightOn == false)
        #expect(RoomsmithMarkdown.encode(back) == text)
    }

    @Test func oldFilesWithoutLightDataTakeDefaults() throws {
        let text = RoomsmithMarkdown.encode(Project.empty(name: "Old"))
            .split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("- lighting.") }.joined(separator: "\n")
        let (p, warnings) = try RoomsmithMarkdown.decode(text)
        #expect(warnings.isEmpty)
        #expect(p.settings.lighting == LightingSettings())
    }
}

@MainActor
@Suite struct LightToolTests {
    @Test func getSetAndUndo() async throws {
        let rig = LRig()
        let before = await rig.ok("light.get")
        #expect(before["lighting"]?["mood"]?.stringValue == "daylight")
        let set = await rig.ok("light.set", ["northDeg": 90, "mood": "night", "applyMoodTime": true, "shadows": false])
        #expect(set["lighting"]?["mood"]?.stringValue == "night")
        #expect(rig.p.settings.lighting.timeMinutes == LightMood.night.suggestedTimeMinutes)
        #expect(rig.p.settings.lighting.shadows == false)
        _ = await rig.ok("history.undo")
        #expect(rig.p.settings.lighting == LightingSettings())
    }

    @Test func rangeErrorsAndMissingKeys() async throws {
        let rig = LRig()
        #expect(await rig.call("light.set", ["timeMinutes": 2000]).ok == false)
        #expect(await rig.call("light.set", ["mood": "disco"]).ok == false)
        #expect(await rig.call("light.set").ok == false)
        #expect(rig.p.settings.lighting == LightingSettings())
    }

    @Test func emitterLifecycleAndToggle() async throws {
        let rig = LRig()
        let (def, pieces) = try rig.addLamps(lampCount: 0)
        // The test design has no lamp yet: toggling must say so.
        #expect(await rig.call("light.toggle", ["id": .string(pieces[0].uuidString)]).ok == false)
        let added = await rig.ok("light.set_emitter", ["definitionId": .string(def.uuidString), "name": "Ceiling", "lumens": 1200, "kelvin": 3000,
                                                      "positionMm": ["x": 0, "y": 0, "z": 1500]])
        let eid = added["id"]?.stringValue ?? ""
        #expect(rig.p.definition(def)?.lights.first?.lumens == 1200)
        _ = await rig.ok("light.set_emitter", ["definitionId": .string(def.uuidString), "emitterId": .string(eid), "kind": "spot", "coneDeg": 45])
        #expect(rig.p.definition(def)?.lights.first?.kind == .spot)
        #expect(rig.p.definition(def)?.lights.count == 1)
        #expect(await rig.call("light.set_emitter", ["definitionId": .string(def.uuidString), "emitterId": .string(eid), "lumens": 0]).ok == false)

        let off = await rig.ok("light.toggle", ["id": .string(pieces[0].uuidString)])
        #expect(off["lightOn"]?.boolValue == false)
        #expect(rig.p.instance(pieces[0])?.lightOn == false)
        let info = await rig.ok("light.get")
        #expect(info["activeLamps"]?.int64Value == 0)
        _ = await rig.ok("light.toggle", ["id": .string(pieces[0].uuidString), "on": true])
        #expect((await rig.ok("light.get"))["activeLamps"]?.int64Value == 1)

        _ = await rig.ok("light.remove_emitter", ["definitionId": .string(def.uuidString), "emitterId": .string(eid)])
        #expect(rig.p.definition(def)?.lights.isEmpty == true)
    }

    @Test func designHoldsAtMostEightLamps() async throws {
        let rig = LRig()
        let (def, _) = try rig.addLamps(lampCount: LightEmitter.maxPerDefinition)
        #expect(await rig.call("light.set_emitter", ["definitionId": .string(def.uuidString)]).ok == false)
        #expect(rig.p.definition(def)?.lights.count == LightEmitter.maxPerDefinition)
    }
}

@MainActor
@Suite struct LightValidationTests {
    private func design(_ lamps: [LightEmitter]) -> FurnitureDefinition {
        var d = FurnitureDefinition(id: UUID(), name: "Lamp", category: "Light", size: Size3(300, 300, 1600),
                                    components: [Component(name: "body", shape: .box, position: P3(0, 0, 800), size: Size3(300, 300, 1600))])
        d.lights = lamps
        return d
    }

    private func rejects(_ lamps: [LightEmitter], sourceLocation: SourceLocation = #_sourceLocation) {
        let rig = LRig()
        let d = design(lamps)
        #expect(throws: (any Error).self, sourceLocation: sourceLocation) { _ = try rig.store.run("Add") { $0.addDefinition(d) } }
        #expect(rig.p.definition(d.id) == nil, sourceLocation: sourceLocation)
    }

    @Test func moreThanEightLampsAreRejected() {
        rejects((0..<9).map { LightEmitter(name: "L\($0)", position: P3(0, 0, 100)) })
    }

    @Test func duplicateLampIdIsRejected() {
        let a = LightEmitter(name: "A", position: P3(0, 0, 100))
        var b = LightEmitter(name: "B", position: P3(0, 0, 100))
        b.id = a.id
        rejects([a, b])
    }

    @Test func lampOutsideTheCoordinateRangeIsRejected() {
        rejects([LightEmitter(name: "Far", position: P3(Int64.max / 4, 0, 0))])
    }

    @Test func emptyLampNameIsRejected() {
        rejects([LightEmitter(name: "  ", position: P3(0, 0, 100))])
    }

    @Test func settingEmitterBeyondTheCapIsRejected() throws {
        let rig = LRig()
        let (def, _) = try rig.addLamps(lampCount: 8)
        let extra = LightEmitter(name: "Ninth", position: P3(0, 0, 100))
        #expect(throws: (any Error).self) { _ = try rig.store.run("Ninth") { try $0.setEmitter(extra, in: def) } }
        #expect(rig.p.definition(def)?.lights.count == 8)
    }
}

@MainActor
@Suite struct LightSanitizingTests {
    @Test func hostileFileIsClampedOnDecode() throws {
        let rig = LRig()
        let (def, _) = try rig.addLamps()
        var p = rig.p
        p.settings.lighting.timeMinutes = 9999
        p.settings.lighting.dayOfYear = 0
        p.settings.lighting.northDeg = .nan
        p.settings.lighting.latitudeDeg = 500
        p.settings.lighting.exposure = .infinity
        let shared = UUID()
        var lamps: [LightEmitter] = (0..<9).map { LightEmitter(name: "L\($0)", position: P3(0, 0, 100)) }
        lamps[0].lumens = 0
        lamps[1].coneDeg = .nan
        lamps[2].pitchDeg = 400
        lamps[3].id = shared; lamps[4].id = shared
        lamps[5].kelvin = 99; lamps[6].rangeMm = 1; lamps[7].lumens = 9_999_999
        let i = try #require(p.definitions.firstIndex { $0.id == def })
        p.definitions[i].lights = lamps
        let (back, _) = try RoomsmithMarkdown.decode(RoomsmithMarkdown.encode(p))
        let l = back.settings.lighting
        #expect(l.timeMinutes == 1439 && l.dayOfYear == 1 && l.latitudeDeg == 66)
        #expect(l.northDeg == 0 && l.exposure == 0)
        let got = try #require(back.definition(def)).lights
        #expect(got.count == LightEmitter.maxPerDefinition)
        let valid = got.allSatisfy { $0.isValid }
        #expect(valid)
        #expect(Set(got.map(\.id)).count == got.count)
        #expect(got[0].lumens == 1 && got[1].coneDeg == 80 && got[2].pitchDeg == 90)
        #expect(got[5].kelvin == 1500 && got[6].rangeMm == 200 && got[7].lumens == 100_000)
    }
}

@Suite struct LampSlotPlanTests {
    @Test func typeChangeInTheMiddleCreatesAFreshEntity() {
        #expect(LampSlotPlan.plan(current: [.point, .point], wanted: [.spot, .point]) == [.create, .keep])
        #expect(LampSlotPlan.plan(current: [.point], wanted: [.point, .spot]) == [.keep, .create])
        #expect(LampSlotPlan.plan(current: [.spot, .point], wanted: [.spot]) == [.keep])
        #expect(LampSlotPlan.plan(current: [], wanted: [.point]) == [.create])
    }
}
