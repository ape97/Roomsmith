import Foundation
import Testing
@testable import RoomsmithCore
@testable import RoomsmithIPC

// Agent/UI parity tools: rename, align, level/dimension edits, state and configuration upkeep, guarded deletes,
// room from walls and file exports.

@MainActor
private final class ParityContext: AgentAppContext {
    var selection: Set<UUID> = []
    var activeLevelId: UUID
    var fileURL: URL?
    var appVersion = "test"
    init(activeLevelId: UUID) { self.activeLevelId = activeLevelId }
    func saveForAgent() throws -> String { fileURL?.path ?? "/tmp/test.roomsmith" }
}

@MainActor
private struct PRig {
    let store: DocumentStore
    let context: ParityContext
    let registry: ToolRegistry
    var levelId: UUID { store.project.levels[0].id }
    var p: Project { store.project }

    init(write: Bool = true) {
        let project = Project.empty(name: "Parity")
        store = DocumentStore(project: project)
        store.agentWriteEnabled = write
        context = ParityContext(activeLevelId: project.levels[0].id)
        registry = ToolRegistry(store: store, context: context)
    }

    @discardableResult
    func call(_ tool: String, _ args: JSONValue = .object([:])) async -> AgentResponse {
        await registry.call(AgentRequest(id: 1, token: "t", clientId: "test", tool: tool, arguments: args))
    }

    func ok(_ tool: String, _ args: JSONValue = .object([:]), sourceLocation: SourceLocation = #_sourceLocation) async -> JSONValue {
        let r = await call(tool, args)
        #expect(r.ok, "\(tool) failed: \(r.error?.code ?? "?") \(r.error?.message ?? "")", sourceLocation: sourceLocation)
        return r.result ?? .null
    }

    func error(_ tool: String, _ args: JSONValue = .object([:])) async -> AgentError? {
        let r = await call(tool, args)
        return r.ok ? nil : r.error
    }

    func id(_ tool: String, _ args: JSONValue) async -> String { await ok(tool, args)["id"]?.stringValue ?? "" }
}

private func xy(_ x: Int, _ y: Int) -> JSONValue { ["x": .int(Int64(x)), "y": .int(Int64(y))] }
private func xyz(_ x: Int, _ y: Int, _ z: Int = 0) -> JSONValue { ["x": .int(Int64(x)), "y": .int(Int64(y)), "z": .int(Int64(z))] }

private func box(_ name: String = "Box", w: Int = 1000, d: Int = 500) -> JSONValue {
    [
        "defaultState": "open",
        "name": .string(name), "category": "Test",
        "size": ["width": .int(Int64(w)), "depth": .int(Int64(d)), "height": 800],
        "components": [["name": "body", "shape": "box", "position": xyz(0, 0, 400),
                        "size": ["width": .int(Int64(w)), "depth": .int(Int64(d)), "height": 800]]],
        "states": [["name": "open", "poses": ["body": ["position": xyz(0, 0, 450)]]],
                   ["name": "closed", "poses": ["body": ["position": xyz(0, 0, 400)]]]],
    ]
}

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rs-parity-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - Rename, settings, level, dimension

@MainActor
struct ParityEditTests {
    @Test func renameObjectCoversNamedKinds() async throws {
        let rig = PRig()
        let lvl = rig.levelId
        let room = await rig.id("geometry.create_room", ["name": "Old", "points": [xy(0, 0), xy(3000, 0), xy(3000, 3000)]])
        let mat = Material(name: "Paint", color: RGBColor(10, 20, 30))
        _ = try rig.store.run("Mat") { $0.addMaterial(mat) }
        let cam = await rig.id("camera.save", ["name": "View"])
        let wall = await rig.id("geometry.create_wall", ["start": xy(0, 0), "end": xy(1000, 0)])

        for (id, name) in [(lvl.uuidString.lowercased(), "Ground"), (room, "Kitchen"), (mat.id.uuidString.lowercased(), "Blue paint"), (cam, "Front")] {
            let r = await rig.ok("scene.rename_object", ["id": .string(id), "name": .string("  \(name) ")])
            #expect(r["name"]?.stringValue == name)
        }
        #expect(rig.p.level(lvl)?.name == "Ground")
        #expect(rig.p.rooms.first?.name == "Kitchen")
        #expect(rig.p.materials.first { $0.id == mat.id }?.name == "Blue paint")
        #expect(rig.p.cameras.first?.name == "Front")
        #expect((await rig.error("scene.rename_object", ["id": .string(wall), "name": "x"]))?.code == AgentError.invalidArgument)
        #expect((await rig.error("scene.rename_object", ["id": .string(room), "name": "   "]))?.code == AgentError.invalidArgument)
        #expect((await rig.error("scene.rename_object", ["id": .string(UUID().uuidString.lowercased()), "name": "x"]))?.code == AgentError.notFound)
    }

    @Test func renameFurnitureIsOneUndoStepAndRespectsLocks() async throws {
        let rig = PRig()
        let def = await rig.id("furniture.create_definition", box())
        let inst = await rig.id("furniture.create_instance", ["definitionId": .string(def), "position": xyz(1000, 1000)])
        let depth = rig.store.undoDepth
        _ = await rig.ok("scene.rename_object", ["id": .string(inst), "name": "Sideboard"])
        #expect(rig.store.undoDepth == depth + 1)
        #expect(rig.p.instance(UUID(uuidString: inst)!)?.name == "Sideboard")
        _ = await rig.ok("scene.set_locked", ["ids": [.string(inst)], "locked": true])
        #expect((await rig.error("scene.rename_object", ["id": .string(inst), "name": "Again"]))?.code == AgentError.locked)
        _ = await rig.ok("history.undo")
    }

    @Test func projectNameThroughUpdateSettings() async {
        let rig = PRig()
        let r = await rig.ok("project.update_settings", ["name": "  Villa Nord "])
        #expect(r["name"]?.stringValue == "Villa Nord")
        #expect(rig.p.name == "Villa Nord")
        #expect((await rig.error("project.update_settings", ["name": " "]))?.code == AgentError.invalidArgument)
        #expect((await rig.error("project.update_settings", [:]))?.code == AgentError.invalidArgument)
        _ = await rig.ok("history.undo")
        #expect(rig.p.name == "Parity")
    }

    @Test func updateLevelAndDimension() async {
        let rig = PRig()
        let up = await rig.id("geometry.create_level", ["name": "Up"])
        _ = await rig.ok("geometry.update_level", ["id": .string(up), "name": "Attic", "elevationMm": 2700, "heightMm": 2200, "visible": false])
        let l = rig.p.level(UUID(uuidString: up)!)
        #expect(l?.name == "Attic")
        #expect(l?.elevation == 2700)
        #expect(l?.height == 2200)
        #expect(l?.visible == false)
        _ = await rig.ok("geometry.update_level", ["id": .string(up), "locked": true])
        #expect(rig.p.level(UUID(uuidString: up)!)?.locked == true)
        #expect((await rig.error("geometry.update_level", ["id": .string(up)]))?.code == AgentError.invalidArgument)
        #expect((await rig.error("geometry.update_level", ["id": .string(UUID().uuidString.lowercased()), "name": "x"]))?.code == AgentError.notFound)

        let dim = await rig.id("geometry.create_dimension", ["a": xy(0, 0), "b": xy(1000, 0)])
        _ = await rig.ok("geometry.update_dimension", ["id": .string(dim), "b": xy(2500, 0), "offsetMm": 450])
        let d = rig.p.dimension(UUID(uuidString: dim)!)
        #expect(d?.a == P2(0, 0))
        #expect(d?.b == P2(2500, 0))
        #expect(d?.offset == 450)
        #expect((await rig.error("geometry.update_dimension", ["id": .string(dim)]))?.code == AgentError.invalidArgument)
    }
}

// MARK: - Align

@MainActor
struct ParityAlignTests {
    private func setup() async -> (PRig, [String]) {
        let rig = PRig()
        let a = await rig.id("furniture.create_definition", box("A", w: 1000, d: 500))
        let b = await rig.id("furniture.create_definition", box("B", w: 600, d: 400))
        let i1 = await rig.id("furniture.create_instance", ["definitionId": .string(a), "position": xyz(1000, 1000)])
        let i2 = await rig.id("furniture.create_instance", ["definitionId": .string(b), "position": xyz(3000, 2500)])
        return (rig, [i1, i2])
    }

    private func bounds(_ rig: PRig, _ id: String) -> (lo: P2, hi: P2) {
        rig.p.alignBounds(UUID(uuidString: id)!)!
    }

    @Test func edgesAreMillimetreExact() async {
        for (edge, check) in [
            ("left", { (a: (lo: P2, hi: P2), b: (lo: P2, hi: P2)) in a.lo.x == b.lo.x && a.lo.x == 500 }),
            ("right", { a, b in a.hi.x == b.hi.x && a.hi.x == 3300 }),
            ("top", { a, b in a.hi.y == b.hi.y && a.hi.y == 2700 }),
            ("bottom", { a, b in a.lo.y == b.lo.y && a.lo.y == 750 }),
        ] as [(String, ((lo: P2, hi: P2), (lo: P2, hi: P2)) -> Bool)] {
            let (rig, ids) = await setup()
            let depth = rig.store.undoDepth
            _ = await rig.ok("scene.align_objects", ["ids": .array(ids.map { .string($0) }), "edge": .string(edge)])
            #expect(rig.store.undoDepth == depth + 1, "\(edge): one undo step")
            #expect(check(bounds(rig, ids[0]), bounds(rig, ids[1])), "\(edge)")
        }
    }

    @Test func centresUseCommonBoundsAndRoundToWholeMm() async {
        let (rig, ids) = await setup()
        // x extents: 500...1500 and 2700...3300 -> common 500...3300, centre 1900.
        _ = await rig.ok("scene.align_objects", ["ids": .array(ids.map { .string($0) }), "edge": "centerX"])
        let b1 = bounds(rig, ids[0]), b2 = bounds(rig, ids[1])
        #expect(b1.lo.x + b1.hi.x == 3800 && b2.lo.x + b2.hi.x == 3800)
        // y extents: 750...1250 and 2300...2700 -> centre 1725.
        _ = await rig.ok("scene.align_objects", ["ids": .array(ids.map { .string($0) }), "edge": "centerY"])
        let c1 = bounds(rig, ids[0]), c2 = bounds(rig, ids[1])
        #expect(c1.lo.y + c1.hi.y == 3450 && c2.lo.y + c2.hi.y == 3450)
    }

    @Test func needsTwoTargetsAndIgnoresGroupMembersAndOpenings() async {
        let (rig, ids) = await setup()
        #expect((await rig.error("scene.align_objects", ["ids": [.string(ids[0])], "edge": "left"]))?.code == AgentError.invalidArgument)
        #expect((await rig.error("scene.align_objects", ["ids": .array(ids.map { .string($0) }), "edge": "middle"]))?.code == AgentError.invalidArgument)
        let grp = await rig.ok("scene.group_objects", ["ids": .array(ids.map { .string($0) }), "name": "G"])
        let gid = grp["id"]?.stringValue ?? grp["groupId"]?.stringValue ?? ""
        // Group plus its own members: members are skipped, one target left -> error.
        let e = await rig.error("scene.align_objects", ["ids": .array(([gid] + ids).map { .string($0) }), "edge": "left"])
        #expect(e?.code == AgentError.invalidArgument)
    }

    @Test func lockedObjectBlocksAlignmentWithoutPartialMove() async {
        let (rig, ids) = await setup()
        _ = await rig.ok("scene.set_locked", ["ids": [.string(ids[1])], "locked": true])
        let before = rig.p
        #expect((await rig.error("scene.align_objects", ["ids": .array(ids.map { .string($0) }), "edge": "left"]))?.code == AgentError.locked)
        #expect(rig.p.instances == before.instances)
    }
}

// MARK: - States, animation, configurations

@MainActor
struct ParityFurnitureTests {
    @Test func deleteStateCleansTracksDefaultAndInstances() async {
        let rig = PRig()
        let def = await rig.id("furniture.create_definition", box())
        let did = UUID(uuidString: def)!
        let inst = await rig.id("furniture.create_instance", ["definitionId": .string(def), "position": xyz(1000, 1000)])
        _ = await rig.ok("furniture.set_animation", ["definitionId": .string(def), "from": "open", "to": "closed", "durationMs": 1200, "easing": "linear"])
        _ = await rig.ok("furniture.activate_state", ["ids": [.string(inst)], "state": "open"])
        let d0 = rig.p.definition(did)!
        let open = d0.states.first { $0.name == "open" }!.id
        let closed = d0.states.first { $0.name == "closed" }!.id
        #expect(d0.defaultStateId == open, "first state is the default")
        #expect(d0.tracks.count == 1 && d0.tracks[0].durationMs == 1200 && d0.tracks[0].easing == .linear)

        let r = await rig.ok("furniture.delete_state", ["definitionId": .string(def), "state": "open"])
        #expect(r["defaultStateId"]?.stringValue == closed.uuidString.lowercased())
        let d1 = rig.p.definition(did)!
        #expect(d1.states.map(\.name) == ["closed"])
        #expect(d1.tracks.isEmpty, "tracks from/to the deleted state go")
        #expect(d1.defaultStateId == closed)
        #expect(rig.p.instance(UUID(uuidString: inst)!)?.stateId == closed, "instances fall back to the default state")
        #expect((await rig.error("furniture.delete_state", ["definitionId": .string(def), "state": "open"]))?.code == AgentError.notFound)
    }

    @Test func setAnimationReplacesAndValidates() async {
        let rig = PRig()
        let def = await rig.id("furniture.create_definition", box())
        let did = UUID(uuidString: def)!
        _ = await rig.ok("furniture.set_animation", ["definitionId": .string(def), "from": "open", "to": "closed"])
        _ = await rig.ok("furniture.set_animation", ["definitionId": .string(def), "from": "open", "to": "closed", "durationMs": 300])
        _ = await rig.ok("furniture.set_animation", ["definitionId": .string(def), "from": .null, "to": "open"])
        let tracks = rig.p.definition(did)!.tracks
        #expect(tracks.count == 2)
        #expect(tracks.first { $0.fromStateId != nil }?.durationMs == 300)
        #expect(tracks.first { $0.fromStateId == nil } != nil)
        #expect((await rig.error("furniture.set_animation", ["definitionId": .string(def), "to": "open", "durationMs": 70000]))?.code == AgentError.invalidArgument)
        #expect((await rig.error("furniture.set_animation", ["definitionId": .string(def), "to": "nope"]))?.code == AgentError.notFound)
        #expect((await rig.error("furniture.set_animation", ["definitionId": .string(def), "from": "open", "to": "open"]))?.code == AgentError.invalidArgument)
    }

    @Test func renameAndDuplicateConfiguration() async {
        let rig = PRig()
        let def = await rig.id("furniture.create_definition", box())
        let i1 = await rig.id("furniture.create_instance", ["definitionId": .string(def), "position": xyz(1000, 1000)])
        let i2 = await rig.id("furniture.create_instance", ["definitionId": .string(def), "position": xyz(3000, 1000)])
        let grp = await rig.ok("scene.group_objects", ["ids": [.string(i1), .string(i2)], "name": "Set"])
        let gid = grp["id"]?.stringValue ?? grp["groupId"]?.stringValue ?? ""
        _ = await rig.ok("furniture.save_configuration", ["groupId": .string(gid), "name": "Day"])
        let g = UUID(uuidString: gid)!

        let dup = await rig.ok("furniture.update_configuration", ["groupId": .string(gid), "configuration": "day", "duplicate": true])
        #expect(dup["name"]?.stringValue == "Day copy")
        let dup2 = await rig.ok("furniture.update_configuration", ["groupId": .string(gid), "configuration": "Day", "duplicate": true])
        #expect(dup2["name"]?.stringValue == "Day copy 2")
        let cfgs = rig.p.group(g)!.configurations
        #expect(cfgs.count == 3)
        #expect(cfgs[0].poses == cfgs[1].poses, "copy keeps the poses")

        _ = await rig.ok("furniture.update_configuration", ["groupId": .string(gid), "configuration": "Day copy", "name": "Night"])
        #expect(rig.p.group(g)!.configurations.map(\.name) == ["Day", "Night", "Day copy 2"])
        #expect((await rig.error("furniture.update_configuration", ["groupId": .string(gid), "configuration": "Night", "name": "day"]))?.code == AgentError.invalidArgument)
        #expect((await rig.error("furniture.update_configuration", ["groupId": .string(gid), "configuration": "Night"]))?.code == AgentError.invalidArgument)
        let both = await rig.ok("furniture.update_configuration", ["groupId": .string(gid), "configuration": "Night", "name": "Evening", "duplicate": true])
        #expect(both["name"]?.stringValue == "Evening")
        #expect(rig.p.group(g)!.configurations.map(\.name).contains("Night"))
    }
}

// MARK: - Guarded deletes

@MainActor
struct ParityDeleteTests {
    @Test func materialInUseIsRefusedWithReferences() async throws {
        let rig = PRig()
        let mat = Material(name: "Paint", color: RGBColor(1, 2, 3))
        _ = try rig.store.run("Mat") { $0.addMaterial(mat) }
        let wall = await rig.id("geometry.create_wall", ["start": xy(0, 0), "end": xy(2000, 0)])
        _ = await rig.ok("scene.set_material", ["ids": [.string(wall)], "slot": "wallLeft", "material": .string(mat.id.uuidString.lowercased())])
        let before = rig.p
        let e = await rig.error("scene.delete_objects", ["ids": [.string(mat.id.uuidString.lowercased())]])
        #expect(e?.code == AgentError.invalidArgument)
        let refs = e?.details?["referenced"]?.arrayValue?.first?["references"]?.arrayValue
        #expect(refs?.first?["id"]?.stringValue == wall)
        #expect(refs?.first?["role"]?.stringValue == "left material")
        #expect(rig.p == before, "nothing deleted")
        // Free the material, then deleting works.
        _ = await rig.ok("scene.set_material", ["ids": [.string(wall)], "slot": "wallLeft", "material": .null])
        _ = await rig.ok("scene.delete_objects", ["ids": [.string(mat.id.uuidString.lowercased())]])
        #expect(rig.p.material(mat.id) == nil)
    }

    @Test func productAndDefinitionInUseAreRefused() async {
        let rig = PRig()
        let def = await rig.id("furniture.create_definition", box())
        let inst = await rig.id("furniture.create_instance", ["definitionId": .string(def), "position": xyz(1000, 1000)])
        let prod = await rig.id("catalog.create_product", ["name": "Shelf"])
        _ = await rig.ok("catalog.link_product", ["productId": .string(prod), "objectId": .string(inst)])

        let eProd = await rig.error("scene.delete_objects", ["ids": [.string(prod)]])
        #expect(eProd?.code == AgentError.invalidArgument)
        #expect(eProd?.details?["referenced"]?.arrayValue?.first?["references"]?.arrayValue?.first?["id"]?.stringValue == inst)
        let eDef = await rig.error("scene.delete_objects", ["ids": [.string(def)]])
        #expect(eDef?.code == AgentError.invalidArgument)
        #expect(eDef?.details?["referenced"]?.arrayValue?.first?["references"]?.arrayValue?.first?["id"]?.stringValue == inst)

        // Deleting the user in the same call lifts the block.
        _ = await rig.ok("scene.delete_objects", ["ids": [.string(inst), .string(def)]])
        #expect(rig.p.definitions.contains { $0.id == UUID(uuidString: def)! } == false)
        _ = await rig.ok("scene.delete_objects", ["ids": [.string(prod)]])
        #expect(rig.p.products.isEmpty)
    }

    @Test func savedCameraCanBeDeleted() async {
        let rig = PRig()
        let cam = await rig.id("camera.save", ["name": "V"])
        _ = await rig.ok("scene.delete_objects", ["ids": [.string(cam)]])
        #expect(rig.p.cameras.isEmpty)
    }
}

// MARK: - Room from walls

@MainActor
struct ParityRoomTests {
    @Test func closedRectangleGivesInsetRoom() async {
        let rig = PRig()
        _ = await rig.ok("geometry.create_wall", ["points": [xy(0, 0), xy(4000, 0), xy(4000, 3000), xy(0, 3000)], "closed": true, "thicknessMm": 200])
        let r = await rig.ok("geometry.create_room_from_walls", ["point": xy(2000, 1500), "name": "Hall"])
        let room = rig.p.room(UUID(uuidString: r["id"]?.stringValue ?? "")!)
        #expect(room?.name == "Hall")
        #expect(Set(room?.points ?? []) == [P2(100, 100), P2(3900, 100), P2(3900, 2900), P2(100, 2900)])
        let r2 = await rig.ok("geometry.create_room_from_walls", ["point": xy(2000, 1500)])
        #expect(rig.p.room(UUID(uuidString: r2["id"]?.stringValue ?? "")!)?.name == "Room 2")
        #expect((await rig.error("geometry.create_room_from_walls", ["point": xy(9000, 9000)]))?.code == AgentError.invalidArgument)
    }

    @Test func openPolygonIsAnError() async {
        let rig = PRig()
        _ = await rig.ok("geometry.create_wall", ["points": [xy(0, 0), xy(4000, 0), xy(4000, 3000), xy(0, 3000)], "closed": false])
        let before = rig.p
        let e = await rig.error("geometry.create_room_from_walls", ["point": xy(2000, 1500)])
        #expect(e?.code == AgentError.invalidArgument)
        #expect(rig.p.rooms.isEmpty && rig.p == before)
        #expect((await rig.error("geometry.create_room_from_walls", ["point": xy(1, 1), "levelId": .string(UUID().uuidString.lowercased())]))?.code == AgentError.notFound)
    }

    @Test func roomFinderPicksSmallestFaceWithTJunction() {
        func wall(_ s: P2, _ e: P2) -> Wall { Wall(levelId: UUID(), start: s, end: e, thickness: 100, height: 2500) }
        // 4000 x 3000 box split by a partition ending in the middle of the top and bottom walls.
        let walls = [wall(P2(0, 0), P2(4000, 0)), wall(P2(4000, 0), P2(4000, 3000)), wall(P2(4000, 3000), P2(0, 3000)),
                     wall(P2(0, 3000), P2(0, 0)), wall(P2(2000, 0), P2(2000, 3000))]
        let left = RoomFinder.face(containing: V2(1000, 1500), walls: walls)
        #expect(Set(left ?? []) == [P2(50, 50), P2(1950, 50), P2(1950, 2950), P2(50, 2950)])
        #expect(RoomFinder.face(containing: V2(-500, 1500), walls: walls) == nil)
    }
}

// MARK: - Exports

@MainActor
struct ParityExportTests {
    private func rectWalls(_ rig: PRig, w: Int = 4000, h: Int = 3000) async {
        _ = await rig.ok("geometry.create_wall", ["points": [xy(0, 0), xy(w, 0), xy(w, h), xy(0, h)], "closed": true])
    }

    @Test func svgMatchesDialogLayoutAndReportsScale() async throws {
        let rig = PRig()
        await rectWalls(rig)
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("plan.svg").path
        let r = await rig.ok("export.plan", ["format": "svg", "path": .string(path), "paper": "A3", "orientation": "landscape", "scale": 50])
        #expect(r["scale"]?.int64Value == 50)
        #expect(r["pageWidthMm"]?.doubleValue == 420)
        #expect(r["pageHeightMm"]?.doubleValue == 297)
        let layout = PlanExport.layout(rig.p, levelId: rig.levelId, unit: rig.p.settings.displayUnit, scale: .ratio(50), paper: .a3, orientation: .landscape)
        let expected = PlanExport.svg(rig.p, options: PlanExport.options(for: layout, paper: .a3, levelId: rig.levelId, unit: rig.p.settings.displayUnit))
        #expect(try String(contentsOfFile: path, encoding: .utf8) == expected, "same bytes as the Export dialog's code path")
        #expect(expected.contains("420mm") || expected.contains("420"))
    }

    @Test func pdfAndFitScale() async throws {
        let rig = PRig()
        await rectWalls(rig)
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("plan.pdf").path
        let r = await rig.ok("export.plan", ["format": "pdf", "path": .string(path), "paper": "A4", "scale": "fit"])
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(data.starts(with: Data("%PDF".utf8)))
        let scale = Int(r["scale"]?.int64Value ?? 0)
        let layout = PlanExport.layout(rig.p, levelId: rig.levelId, unit: rig.p.settings.displayUnit, scale: .fit, paper: .a4, orientation: .auto)
        #expect(layout.fits && scale == layout.scale)
    }

    @Test func tooLargePlanFailsWithRequiredSizeAndWritesNothing() async throws {
        let rig = PRig()
        await rectWalls(rig, w: 20000, h: 12000)
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("big.svg").path
        let e = await rig.error("export.plan", ["format": "svg", "path": .string(path), "paper": "A4", "scale": 20])
        #expect(e?.code == AgentError.outOfRange)
        #expect((e?.details?["requiredWidthMm"]?.int64Value ?? 0) > 297 || (e?.details?["requiredHeightMm"]?.int64Value ?? 0) > 297)
        #expect(e?.details?["suggestedPaper"]?.stringValue != nil)
        #expect(e?.message.contains("never shrunk") == true)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func pathRulesAndWriteLock() async throws {
        let rig = PRig()
        await rectWalls(rig)
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ok = dir.appendingPathComponent("a.svg").path
        func plan(_ path: String, _ extra: [String: JSONValue] = [:]) async -> AgentError? {
            await rig.error("export.plan", .object(["format": "svg", "path": .string(path)].merging(extra) { _, n in n }))
        }
        #expect((await plan("relative/a.svg"))?.code == AgentError.invalidArgument)
        #expect((await plan(dir.appendingPathComponent("a.pdf").path))?.code == AgentError.invalidArgument)
        #expect((await plan(dir.appendingPathComponent("nope/a.svg").path))?.code == AgentError.invalidArgument)
        #expect((await plan(ok, ["paper": "B7"]))?.code == AgentError.invalidArgument)
        #expect((await plan(ok, ["scale": 0]))?.code == AgentError.invalidArgument)
        #expect((await rig.error("export.plan", ["format": "png", "path": .string(dir.appendingPathComponent("a.png").path)]))?.code == AgentError.invalidArgument)
        #expect((await rig.error("export.plan", ["format": "tiff", "path": .string(ok)]))?.code == AgentError.invalidArgument)

        _ = await rig.ok("export.plan", ["format": "svg", "path": .string(ok)])
        let first = try Data(contentsOf: URL(fileURLWithPath: ok))
        let clash = await plan(ok)
        #expect(clash?.code == AgentError.invalidArgument && clash?.message.contains("overwrite") == true)
        try Data("old".utf8).write(to: URL(fileURLWithPath: ok))
        _ = await rig.ok("export.plan", ["format": "svg", "path": .string(ok), "overwrite": true])
        #expect(try Data(contentsOf: URL(fileURLWithPath: ok)) == first)

        // Into the project package, directly or through a symlink.
        let pkg = dir.appendingPathComponent("home.roomsmith")
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        rig.context.fileURL = pkg
        #expect((await plan(pkg.appendingPathComponent("plan.svg").path))?.code == AgentError.invalidArgument)
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: pkg)
        #expect((await plan(link.appendingPathComponent("plan.svg").path))?.code == AgentError.invalidArgument)
        #expect(!FileManager.default.fileExists(atPath: pkg.appendingPathComponent("plan.svg").path))
        // Any other package, too.
        let other = dir.appendingPathComponent("other.roomsmith")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        #expect((await plan(other.appendingPathComponent("p.svg").path))?.code == AgentError.invalidArgument)

        rig.store.agentWriteEnabled = false
        #expect((await plan(dir.appendingPathComponent("b.svg").path))?.code == AgentError.writeLocked)
    }

    @Test func allLevelsWritesOneFileEachAndRefusesExisting() async throws {
        let rig = PRig()
        await rectWalls(rig)
        let up = await rig.id("geometry.create_level", ["name": "Up/stairs"])
        _ = await rig.ok("geometry.create_wall", ["levelId": .string(up), "points": [xy(0, 0), xy(3000, 0), xy(3000, 2000), xy(0, 2000)], "closed": true])
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("house.svg").path
        let r = await rig.ok("export.plan", ["format": "svg", "path": .string(path), "allLevels": true, "scale": 100])
        let files = r["files"]?.arrayValue ?? []
        #expect(files.count == 2)
        for f in files { #expect(FileManager.default.fileExists(atPath: f["path"]?.stringValue ?? "")) }
        #expect(files.contains { ($0["path"]?.stringValue ?? "").hasSuffix("house-Up_stairs.svg") })
        #expect((await rig.error("export.plan", ["format": "svg", "path": .string(path), "allLevels": true]))?.code == AgentError.invalidArgument)
        #expect((await rig.error("export.plan", ["format": "svg", "path": .string(path), "allLevels": true, "levelId": .string(up), "overwrite": true]))?.code == AgentError.invalidArgument)
    }

    @Test func objWritesMtlAndRewritesReference() async throws {
        let rig = PRig()
        await rectWalls(rig)
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("model.obj").path
        let r = await rig.ok("export.obj", ["path": .string(path)])
        let mtl = dir.appendingPathComponent("model.mtl").path
        #expect(r["mtlPath"]?.stringValue == mtl)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text.contains("mtllib model.mtl") && !text.contains("scene.mtl"))
        #expect(text.contains("\nv "))
        #expect(FileManager.default.fileExists(atPath: mtl))
        #expect(text == SceneExport.obj(rig.p, levelId: rig.levelId).obj.replacingOccurrences(of: "mtllib scene.mtl", with: "mtllib model.mtl"))

        #expect((await rig.error("export.obj", ["path": .string(path)]))?.code == AgentError.invalidArgument)
        try FileManager.default.removeItem(atPath: path)
        #expect((await rig.error("export.obj", ["path": .string(path)]))?.code == AgentError.invalidArgument, "existing .mtl blocks too")
        _ = await rig.ok("export.obj", ["path": .string(path), "overwrite": true, "allVisible": true])
        #expect((await rig.error("export.obj", ["path": .string(dir.appendingPathComponent("m.stl").path)]))?.code == AgentError.invalidArgument)
        #expect((await rig.error("export.obj", ["path": .string(path), "allVisible": true, "levelId": .string(rig.levelId.uuidString.lowercased())]))?.code == AgentError.invalidArgument)
        rig.store.agentWriteEnabled = false
        #expect((await rig.error("export.obj", ["path": .string(dir.appendingPathComponent("z.obj").path)]))?.code == AgentError.writeLocked)
    }
}

// MARK: - Delete reference rules (transitive, all reference places)

@MainActor
struct ParityDeleteReferenceTests {
    private func sid(_ id: UUID) -> JSONValue { .string(id.uuidString.lowercased()) }

    private func refused(_ rig: PRig, _ target: UUID, role: String, by user: UUID? = nil,
                         sourceLocation: SourceLocation = #_sourceLocation) async {
        let before = rig.p
        let e = await rig.error("scene.delete_objects", ["ids": [sid(target)]])
        #expect(e?.code == AgentError.invalidArgument, sourceLocation: sourceLocation)
        let refs = e?.details?["referenced"]?.arrayValue?.first?["references"]?.arrayValue ?? []
        #expect(refs.contains { $0["role"]?.stringValue == role }, "role \(role) in \(refs)", sourceLocation: sourceLocation)
        if let user { #expect(refs.contains { $0["id"]?.stringValue == user.uuidString.lowercased() }, sourceLocation: sourceLocation) }
        #expect(rig.p == before, "nothing deleted", sourceLocation: sourceLocation)
    }

    @Test func levelAndItsMaterialDeleteTogether() async throws {
        let rig = PRig()
        let mat = Material(name: "Paint", color: RGBColor(1, 2, 3))
        _ = try rig.store.run("Mat") { $0.addMaterial(mat) }
        let up = await rig.id("geometry.create_level", ["name": "Up"])
        let wall = await rig.id("geometry.create_wall", ["levelId": .string(up), "start": xy(0, 0), "end": xy(2000, 0)])
        _ = await rig.ok("scene.set_material", ["ids": [.string(wall)], "slot": "wallLeft", "material": sid(mat.id)])
        await refused(rig, mat.id, role: "left material", by: UUID(uuidString: wall))
        _ = await rig.ok("scene.delete_objects", ["ids": [.string(up), sid(mat.id)]])
        #expect(rig.p.material(mat.id) == nil && rig.p.walls.isEmpty)
        #expect(rig.p.level(UUID(uuidString: up)!) == nil)
    }

    @Test func groupAndMemberDefinitionDeleteTogether() async throws {
        let rig = PRig()
        let def = await rig.id("furniture.create_definition", box())
        let a = await rig.id("furniture.create_instance", ["definitionId": .string(def), "position": xyz(1000, 1000)])
        let b = await rig.id("furniture.create_instance", ["definitionId": .string(def), "position": xyz(3000, 1000)])
        let g = await rig.ok("scene.group_objects", ["ids": [.string(a), .string(b)], "name": "G"])
        let gid = g["id"]?.stringValue ?? g["groupId"]?.stringValue ?? ""
        let defId = UUID(uuidString: def)!
        await refused(rig, defId, role: "placed instance")
        _ = await rig.ok("scene.delete_objects", ["ids": [.string(gid), .string(def)]])
        #expect(rig.p.definition(defId) == nil && rig.p.instances.isEmpty && rig.p.groups.isEmpty)
    }

    @Test func wallsOpeningsDoNotBlockTheirWallsMaterial() async throws {
        let rig = PRig()
        let mat = Material(name: "Frame", color: RGBColor(9, 9, 9))
        _ = try rig.store.run("Mat") { $0.addMaterial(mat) }
        let wall = await rig.id("geometry.create_wall", ["start": xy(0, 0), "end": xy(4000, 0)])
        let wid = UUID(uuidString: wall)!
        let op = try rig.store.run("Opening") { p in
            let o = try p.addOpening(wallId: wid, kind: .door, width: 900, height: 2000)
            try p.modify(\.openings, o, "Opening") { $0.frameMaterialId = mat.id }
        }
        _ = op
        let opening = rig.p.openings[0].id
        await refused(rig, mat.id, role: "frame material", by: opening)
        _ = await rig.ok("scene.delete_objects", ["ids": [.string(wall), sid(mat.id)]])
        #expect(rig.p.material(mat.id) == nil && rig.p.openings.isEmpty)
    }

    @Test func materialStillUsedByKeptInstanceIsRefused() async throws {
        let rig = PRig()
        let mat = Material(name: "Wood", color: RGBColor(5, 5, 5))
        _ = try rig.store.run("Mat") { $0.addMaterial(mat) }
        let def = await rig.id("furniture.create_definition", box())
        let keep = await rig.id("furniture.create_instance", ["definitionId": .string(def), "position": xyz(1000, 1000)])
        let gone = await rig.id("furniture.create_instance", ["definitionId": .string(def), "position": xyz(3000, 1000)])
        let comp = rig.p.definition(UUID(uuidString: def)!)!.components[0].id
        _ = try rig.store.run("Ovr") { p in
            for s in [keep, gone] { try p.modify(\.instances, UUID(uuidString: s)!, "Furniture") { $0.materialOverrides[comp] = mat.id } }
        }
        let e = await rig.error("scene.delete_objects", ["ids": [sid(mat.id), .string(gone)]])
        #expect(e?.code == AgentError.invalidArgument)
        let refs = e?.details?["referenced"]?.arrayValue?.first?["references"]?.arrayValue ?? []
        #expect(refs.count == 1 && refs.first?["id"]?.stringValue == keep)
        #expect(rig.p.material(mat.id) != nil && rig.p.instance(UUID(uuidString: gone)!) != nil)
    }

    @Test func roomOpeningDefinitionAndConfigurationReferencesBlock() async throws {
        let rig = PRig()
        let mat = Material(name: "M", color: RGBColor(7, 7, 7))
        _ = try rig.store.run("Mat") { $0.addMaterial(mat) }
        let room = UUID(uuidString: await rig.id("geometry.create_room", ["name": "R", "points": [xy(0, 0), xy(3000, 0), xy(3000, 3000)]]))!
        _ = try rig.store.run("Floor") { try $0.modify(\.rooms, room, "Room") { $0.floorMaterialId = mat.id } }
        await refused(rig, mat.id, role: "floor material", by: room)
        _ = try rig.store.run("Floor") { try $0.modify(\.rooms, room, "Room") { $0.floorMaterialId = nil; $0.ceilingMaterialId = mat.id } }
        await refused(rig, mat.id, role: "ceiling material", by: room)
        _ = try rig.store.run("Ceil") { try $0.modify(\.rooms, room, "Room") { $0.ceilingMaterialId = nil } }

        let wall = UUID(uuidString: await rig.id("geometry.create_wall", ["start": xy(0, 0), "end": xy(4000, 0)]))!
        let opening = try rig.store.run("Op") { p in
            let o = try p.addOpening(wallId: wall, kind: .window, width: 900, height: 1200)
            try p.modify(\.openings, o, "Opening") { $0.frameMaterialId = mat.id }
        }
        _ = opening
        await refused(rig, mat.id, role: "frame material", by: rig.p.openings[0].id)
        _ = try rig.store.run("Op") { p in try p.modify(\.openings, p.openings[0].id, "Opening") { $0.frameMaterialId = nil } }

        let def = UUID(uuidString: await rig.id("furniture.create_definition", box()))!
        _ = try rig.store.run("Comp") { try $0.modify(\.definitions, def, "Definition") { $0.components[0].materialId = mat.id } }
        await refused(rig, mat.id, role: "component material", by: def)
        _ = try rig.store.run("Comp") { try $0.modify(\.definitions, def, "Definition") { $0.components[0].materialId = nil } }

        let a = await rig.id("furniture.create_instance", ["definitionId": .string(def.uuidString.lowercased()), "position": xyz(1000, 1000)])
        let g = await rig.ok("scene.group_objects", ["ids": [.string(a)], "name": "G"])
        let gid = UUID(uuidString: g["id"]?.stringValue ?? g["groupId"]?.stringValue ?? "")!
        let member = UUID(uuidString: a)!
        let comp = rig.p.definition(def)!.components[0].id
        _ = try rig.store.run("Cfg") { p in
            let c = try p.saveConfiguration(groupId: gid, name: "Night")
            try p.modify(\.groups, gid, "Group") { grp in
                let k = grp.configurations.firstIndex { $0.id == c }!
                grp.configurations[k].poses[member]?.materialOverrides = [comp: mat.id]
            }
        }
        await refused(rig, mat.id, role: "configuration material override", by: gid)
        // Deleting the group together with the material is fine.
        _ = await rig.ok("scene.delete_objects", ["ids": [sid(gid), sid(mat.id)]])
        #expect(rig.p.material(mat.id) == nil)
    }
}

// MARK: - Align with rotated furniture

@MainActor
struct ParityAlignRotatedTests {
    @Test func rotatedOddWidthEdgesAreExact() async {
        for deg in [30.0, 90.0] {
            for edge in ["left", "right", "top", "bottom"] {
                let rig = PRig()
                let a = await rig.id("furniture.create_definition", box("A", w: 601, d: 333))
                let b = await rig.id("furniture.create_definition", box("B", w: 1001, d: 457))
                var ids: [String] = []
                for (d, pos, r) in [(a, xyz(1000, 1000), deg), (b, xyz(3127, 2501), 0), (a, xyz(5003, 777), deg + 45)] {
                    ids.append(await rig.id("furniture.create_instance", ["definitionId": .string(d), "position": pos, "rotationDeg": .number(r)]))
                }
                _ = await rig.ok("scene.align_objects", ["ids": .array(ids.map { .string($0) }), "edge": .string(edge)])
                let bs = ids.map { rig.p.alignBounds(UUID(uuidString: $0)!)! }
                let vals: [MM]
                switch edge {
                case "left": vals = bs.map { $0.lo.x }
                case "right": vals = bs.map { $0.hi.x }
                case "top": vals = bs.map { $0.hi.y }
                default: vals = bs.map { $0.lo.y }
                }
                #expect(Set(vals).count == 1, "\(deg) \(edge): \(vals)")
            }
        }
    }
}
