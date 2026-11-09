import Foundation
import Testing
@testable import RoomsmithCore
@testable import RoomsmithIPC

// MARK: - Test double and helpers

@MainActor
private final class TestContext: AgentAppContext {
    var selection: Set<UUID> = []
    var agentSelections = 0
    func setSelectionByAgent(_ ids: Set<UUID>) { agentSelections += 1; selection = ids }
    var activeLevelId: UUID
    var fileURL: URL?
    var appVersion = "test"
    var saveCount = 0
    var saveError: Error?

    init(activeLevelId: UUID) { self.activeLevelId = activeLevelId }

    func saveForAgent() throws -> String {
        if let saveError { throw saveError }
        saveCount += 1
        return fileURL?.path ?? "/tmp/test.roomsmith"
    }
}

@MainActor
private struct Rig {
    let store: DocumentStore
    let context: TestContext
    let registry: ToolRegistry
    var levelId: UUID { store.project.levels[0].id }

    init(write: Bool = true, project: Project = Project.empty(name: "Tools")) {
        store = DocumentStore(project: project)
        store.agentWriteEnabled = write
        context = TestContext(activeLevelId: project.levels[0].id)
        registry = ToolRegistry(store: store, context: context)
    }

    @discardableResult
    func call(_ tool: String, _ args: JSONValue = .object([:]), client: String = "test") async -> AgentResponse {
        await registry.call(AgentRequest(id: 1, token: "t", clientId: client, tool: tool, arguments: args))
    }

    /// Calls a tool that must succeed and returns its result.
    func ok(_ tool: String, _ args: JSONValue = .object([:]), sourceLocation: SourceLocation = #_sourceLocation) async -> JSONValue {
        let r = await call(tool, args)
        #expect(r.ok, "\(tool) failed: \(r.error?.code ?? "?") \(r.error?.message ?? "")", sourceLocation: sourceLocation)
        return r.result ?? .null
    }

    func errorCode(_ tool: String, _ args: JSONValue = .object([:])) async -> String? {
        let r = await call(tool, args)
        return r.ok ? nil : r.error?.code
    }

    func id(_ tool: String, _ args: JSONValue) async -> String {
        let r = await ok(tool, args)
        return r["id"]?.stringValue ?? ""
    }
}

private func xy(_ x: Int, _ y: Int) -> JSONValue { ["x": .int(Int64(x)), "y": .int(Int64(y))] }
private func xyz(_ x: Int, _ y: Int, _ z: Int = 0) -> JSONValue { ["x": .int(Int64(x)), "y": .int(Int64(y)), "z": .int(Int64(z))] }

private func boxDefinition(name: String = "Test box") -> JSONValue {
    [
        "name": .string(name),
        "category": "Test",
        "size": ["width": 1000, "depth": 500, "height": 800],
        "components": [
            ["name": "body", "shape": "box", "position": xyz(0, 0, 400), "size": ["width": 1000, "depth": 500, "height": 800]],
            ["name": "lid", "shape": "box", "position": xyz(0, 0, 810), "size": ["width": 1000, "depth": 500, "height": 20]],
        ],
        "states": [
            ["name": "open", "poses": ["lid": ["position": xyz(0, 0, 1200)]]],
        ],
    ]
}

// MARK: - Registry basics

@MainActor
struct ToolRegistryTests {
    @Test func exposesAll120ToolsInFamilies() async {
        let rig = Rig()
        let names = rig.registry.descriptors.map(\.name)
        #expect(names.count == 120)
        #expect(Set(names).count == 120)
        let expected: [String: [String]] = [
            "app": ["get_capabilities", "get_active_project", "list_tools", "subscribe_changes", "batch"],
            "project": ["get_summary", "save", "get_scene_snapshot", "update_settings", "new", "open", "save_as"],
            "export": ["plan", "obj"],
            "report": ["rooms", "bom", "clearances"],
            "scene": ["list_objects", "get_object", "select_objects", "create_object", "move_objects", "rotate_objects", "set_material",
                      "group_objects", "ungroup_objects", "delete_objects", "duplicate_objects", "set_locked", "set_visible", "check_collisions",
                      "rename_object", "align_objects", "transfer_objects"],
            "geometry": ["create_wall", "update_wall", "split_wall", "create_room", "update_room", "add_opening", "update_opening",
                         "create_dimension", "create_level", "measure_distance", "update_level", "update_dimension", "create_room_from_walls", "dimension_chain"],
            "catalog": ["create_product", "update_product", "search_products", "link_product", "list_builtin", "insert_builtin", "import_model"],
            "furniture": ["create_definition", "list_definitions", "create_instance", "update_instance", "define_state", "activate_state",
                          "save_configuration", "activate_configuration", "delete_configuration", "list_configurations",
                          "delete_state", "set_animation", "update_configuration", "update_definition", "create_from_template",
                          "define_option_group", "delete_option_group", "set_options", "replace_definition", "delete_definitions", "prune_unused_definitions"],
            "background": ["add", "calibrate", "update"],
            "material": ["create", "update", "apply_preset", "list_presets"],
            "camera": ["get_state", "set_state", "save", "preset", "apply"],
            "view": ["get", "set"],
            "render": ["scene_image", "plan_image"],
            "walk": ["get", "set", "toggle_door", "measure"],
            "light": ["get", "set", "set_emitter", "remove_emitter", "toggle"],
            "history": ["undo", "redo"],
            "workspace": ["list", "activate", "open", "close", "compare"], "library": ["list", "get", "add_from_object", "update", "delete", "place", "thumbnail", "create_from_photo", "create_category", "update_category", "delete_category", "duplicate"],
        ]
        for (family, tools) in expected {
            for t in tools { #expect(names.contains("\(family).\(t)"), "missing \(family).\(t)") }
        }
        #expect(expected.values.map(\.count).reduce(0, +) == 120)
    }

    @Test func descriptorsHaveSchemasAndReadOnlyFlags() async {
        let rig = Rig()
        for d in rig.registry.descriptors {
            #expect(!d.description.isEmpty, "\(d.name) has no description")
            #expect(d.inputSchema["type"]?.stringValue == "object", "\(d.name) schema is not an object")
        }
        let byName = Dictionary(uniqueKeysWithValues: rig.registry.descriptors.map { ($0.name, $0) })
        #expect(byName["scene.list_objects"]?.readOnly == true)
        #expect(byName["scene.move_objects"]?.readOnly == false)
        #expect(byName["history.undo"]?.readOnly == false)
        #expect(byName["app.list_tools"]?.readOnly == true)
    }

    @Test func selectObjectsChangesTheAppSoItIsNotReadOnlyAndNeedsWriteAccess() async throws {
        let rig = Rig(write: false)
        let d = try #require(rig.registry.descriptors.first { $0.name == "scene.select_objects" })
        #expect(!d.readOnly)
        // Changing the selection or the active level is refused while the agent may not write ...
        #expect(await rig.errorCode("scene.select_objects", ["mode": "clear"]) == AgentError.writeLocked)
        #expect(await rig.errorCode("scene.select_objects", ["levelId": .string(rig.levelId.uuidString.lowercased()), "mode": "get"]) == AgentError.writeLocked)
        #expect(rig.context.agentSelections == 0)
        // ... but reading the current selection stays possible.
        let got = await rig.ok("scene.select_objects", ["mode": "get"])
        #expect(got["selection"]?.arrayValue?.isEmpty == true)
    }

    @Test func listToolsReturnsDescriptorArrayDirectly() async throws {
        let rig = Rig()
        let result = await rig.ok(agentListToolsName)
        let decoded = try result.decode([ToolDescriptor].self)
        #expect(decoded.count == 120)
        #expect(decoded.map(\.name) == rig.registry.descriptors.map(\.name))
    }

    @Test func capabilitiesAndActiveProject() async {
        let rig = Rig()
        let caps = await rig.ok("app.get_capabilities")
        #expect(caps["toolCount"]?.int64Value == 120)
        #expect(caps["writeEnabled"]?.boolValue == true)
        #expect(caps["appVersion"]?.stringValue == "test")
        let active = await rig.ok("app.get_active_project")
        #expect(active["name"]?.stringValue == "Tools")
        #expect(active["activeLevelId"]?.stringValue == rig.levelId.uuidString.lowercased())
        #expect(active["canUndo"]?.boolValue == false)
    }

    @Test func unknownToolIsRejected() async {
        let rig = Rig()
        let r = await rig.call("scene.fly_to_moon")
        #expect(!r.ok)
        #expect(r.error?.code == AgentError.unknownTool)
    }

    @Test func invalidArgumentsNameTheField() async {
        let rig = Rig()
        // missing required field
        var r = await rig.call("geometry.create_wall", ["start": xy(0, 0)])
        #expect(r.error?.code == AgentError.invalidArgument || r.ok == false)
        // wrong type
        r = await rig.call("scene.get_object", ["id": 5])
        #expect(r.error?.code == AgentError.invalidArgument)
        #expect(r.error?.message.contains("id") == true)
        // not a UUID
        r = await rig.call("scene.get_object", ["id": "not-a-uuid"])
        #expect(r.error?.code == AgentError.invalidArgument)
        // unknown key
        r = await rig.call("scene.list_objects", ["bogus": 1])
        #expect(r.error?.code == AgentError.invalidArgument)
        #expect(r.error?.message.contains("bogus") == true)
        // required key missing
        r = await rig.call("scene.move_objects", [:])
        #expect(r.error?.code == AgentError.invalidArgument)
        #expect(r.error?.message.contains("ids") == true)
        // limit out of range
        r = await rig.call("scene.list_objects", ["limit": 501])
        #expect(r.error?.code == AgentError.invalidArgument)
        // nothing changed
        #expect(rig.store.project.revision == 0 || rig.store.canUndo == false)
    }

    @Test func notFoundForUnknownIds() async {
        let rig = Rig()
        let missing = UUID().uuidString.lowercased()
        #expect(await rig.errorCode("scene.get_object", ["id": .string(missing)]) == AgentError.notFound)
        #expect(await rig.errorCode("scene.move_objects", ["ids": [.string(missing)], "delta": xyz(1, 0)]) == AgentError.notFound)
        #expect(await rig.errorCode("geometry.update_wall", ["id": .string(missing), "thicknessMm": 100]) == AgentError.notFound)
    }

    @Test func writeLockedBlocksMutationsButNotReads() async {
        let rig = Rig(write: false)
        #expect(await rig.errorCode("geometry.create_wall", ["start": xy(0, 0), "end": xy(1000, 0)]) == AgentError.writeLocked)
        #expect(await rig.errorCode("project.update_settings", ["snapEnabled": true]) == AgentError.writeLocked)
        #expect(await rig.errorCode("history.undo") == AgentError.writeLocked)
        #expect(await rig.errorCode("project.save") == AgentError.writeLocked)
        #expect(rig.context.saveCount == 0)
        // reads keep working
        let summary = await rig.ok("project.get_summary")
        #expect(summary["writeEnabled"]?.boolValue == false)
        _ = await rig.ok("scene.list_objects")
        _ = await rig.ok("catalog.list_builtin")
        _ = await rig.ok("camera.get_state")
        // dry runs are allowed and change nothing
        let dry = await rig.ok("geometry.create_wall", ["start": xy(0, 0), "end": xy(1000, 0), "dryRun": true])
        #expect(dry["committed"]?.boolValue == false)
        #expect(rig.store.project.walls.isEmpty)
    }

    @Test func mutatingResponseShapeAndOrigin() async {
        let rig = Rig()
        let r = await rig.ok("geometry.create_wall", ["start": xy(0, 0), "end": xy(4000, 0), "thicknessMm": 120], )
        #expect(r["committed"]?.boolValue == true)
        #expect((r["revision"]?.int64Value ?? 0) > 0)
        #expect(r["changes"]?.arrayValue?.count == 1)
        #expect(r["changes"]?[0]?["kind"]?.stringValue == "wall")
        #expect(r["changes"]?[0]?["op"]?.stringValue == "added")
        #expect(r["id"]?.stringValue == rig.store.project.walls[0].id.uuidString.lowercased())
        let ev = rig.store.events(after: 0).events.last
        #expect(ev?.origin == .agent("test"))
    }
}

// MARK: - dryRun, conflicts, pagination, subscribe, undo

@MainActor
struct ToolSafetyTests {
    @Test func dryRunChangesNothing() async {
        let rig = Rig()
        let before = rig.store.project.revision
        let r = await rig.ok("geometry.create_wall", ["start": xy(0, 0), "end": xy(3000, 0), "dryRun": true])
        #expect(r["committed"]?.boolValue == false)
        #expect(r["dryRun"]?.boolValue == true)
        #expect((r["changes"]?.arrayValue?.count ?? 0) == 1)
        #expect(rig.store.project.walls.isEmpty)
        #expect(rig.store.project.revision == before)
        #expect(rig.store.canUndo == false)
        #expect(rig.store.lastSeq == 0)
    }

    @Test func expectedObjectRevisionsDetectConflicts() async {
        let rig = Rig()
        let wall = await rig.id("geometry.create_wall", ["start": xy(0, 0), "end": xy(3000, 0)])
        let rev = await rig.ok("scene.get_object", ["id": .string(wall)])["rev"]?.int64Value ?? -1
        // someone else edits the wall
        _ = await rig.ok("geometry.update_wall", ["id": .string(wall), "thicknessMm": 200])
        let seq = rig.store.lastSeq
        let r = await rig.call("geometry.update_wall", [
            "id": .string(wall), "thicknessMm": 300,
            "expectedObjectRevisions": [wall: .int(rev)],
        ])
        #expect(!r.ok)
        #expect(r.error?.code == AgentError.conflict)
        #expect(rig.store.project.walls[0].thickness == 200)
        #expect(rig.store.lastSeq == seq)
        // with the current revision it works
        let fresh = await rig.ok("scene.get_object", ["id": .string(wall)])["rev"]?.int64Value ?? -1
        let ok = await rig.call("geometry.update_wall", [
            "id": .string(wall), "thicknessMm": 300,
            "expectedObjectRevisions": [wall: .int(fresh)],
        ])
        #expect(ok.ok)
        #expect(rig.store.project.walls[0].thickness == 300)
    }

    @Test func expectedRevisionDetectsConflicts() async {
        let rig = Rig()
        _ = await rig.ok("geometry.create_wall", ["start": xy(0, 0), "end": xy(3000, 0)])
        let rev = rig.store.project.revision
        let code = await rig.errorCode("geometry.create_wall", ["start": xy(0, 1000), "end": xy(3000, 1000), "expectedRevision": .int(rev - 1)])
        #expect(code == AgentError.conflict)
        #expect(rig.store.project.walls.count == 1)
    }

    @Test func listPaginationIsStable() async {
        let rig = Rig()
        for i in 0..<7 {
            _ = await rig.ok("geometry.create_wall", ["start": xy(0, i * 1000), "end": xy(3000, i * 1000)])
        }
        let all = await rig.ok("scene.list_objects", ["kind": "wall", "limit": 500])
        #expect(all["total"]?.int64Value == 7)
        let allIds = all["items"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? []
        #expect(allIds.count == 7)

        var collected: [String] = []
        var cursor: String?
        var pages = 0
        repeat {
            var args: [String: JSONValue] = ["kind": "wall", "limit": 3]
            if let cursor { args["cursor"] = .string(cursor) }
            let page = await rig.ok("scene.list_objects", .object(args))
            collected += page["items"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? []
            cursor = page["nextCursor"]?.stringValue
            pages += 1
        } while cursor != nil && pages < 10
        #expect(pages == 3)
        #expect(collected == allIds)
        // a bad cursor is rejected
        #expect(await rig.errorCode("scene.list_objects", ["cursor": "abc"]) == AgentError.invalidArgument)
    }

    @Test func listFiltersByQueryAndLevel() async {
        let rig = Rig()
        _ = await rig.ok("geometry.create_room", ["name": "Living room", "points": [xy(0, 0), xy(4000, 0), xy(4000, 3000), xy(0, 3000)]])
        _ = await rig.ok("geometry.create_room", ["name": "Kitchen", "points": [xy(5000, 0), xy(8000, 0), xy(8000, 3000), xy(5000, 3000)]])
        let living = await rig.ok("scene.list_objects", ["kind": "room", "query": "LIVING"])
        #expect(living["total"]?.int64Value == 1)
        #expect(living["items"]?[0]?["name"]?.stringValue == "Living room")
        let level = await rig.ok("scene.list_objects", ["kind": "room", "levelId": .string(rig.levelId.uuidString.lowercased())])
        #expect(level["total"]?.int64Value == 2)
        #expect(await rig.errorCode("scene.list_objects", ["levelId": .string(UUID().uuidString.lowercased())]) == AgentError.notFound)
    }

    @Test func subscribeReturnsEventsAfterAChangeAndTimesOutEmpty() async {
        let rig = Rig()
        let start = await rig.ok("app.subscribe_changes")
        let seq = start["latestSeq"]?.int64Value ?? -1
        #expect(seq == 0)
        // nothing happens: empty after the timeout
        let t0 = ContinuousClock.now
        let quiet = await rig.ok("app.subscribe_changes", ["afterSeq": .int(seq), "timeoutMs": 150])
        #expect(quiet["events"]?.arrayValue?.isEmpty == true)
        #expect(quiet["latestSeq"]?.int64Value == seq)
        #expect(t0.duration(to: .now) >= .milliseconds(100))
        // a change arrives
        _ = await rig.ok("geometry.create_wall", ["start": xy(0, 0), "end": xy(3000, 0)])
        let after = await rig.ok("app.subscribe_changes", ["afterSeq": .int(seq), "timeoutMs": 1000])
        #expect(after["events"]?.arrayValue?.count == 1)
        #expect((after["latestSeq"]?.int64Value ?? 0) > seq)
        #expect(after["events"]?[0]?["origin"]?.stringValue?.contains("agent") == true)
        // a pending long poll wakes up when a change happens
        let latest = after["latestSeq"]?.int64Value ?? 0
        async let waiting = rig.call("app.subscribe_changes", ["afterSeq": .int(latest), "timeoutMs": 5000])
        try? await Task.sleep(for: .milliseconds(100))
        _ = await rig.ok("geometry.create_wall", ["start": xy(0, 1000), "end": xy(3000, 1000)])
        let woke = await waiting
        #expect(woke.ok)
        #expect(woke.result?["events"]?.arrayValue?.count == 1)
        // invalid timeout
        #expect(await rig.errorCode("app.subscribe_changes", ["afterSeq": 0, "timeoutMs": 60000]) == AgentError.invalidArgument)
    }

    @Test func undoRedoViaTools() async {
        let rig = Rig()
        _ = await rig.ok("geometry.create_wall", ["start": xy(0, 0), "end": xy(3000, 0)])
        #expect(rig.store.project.walls.count == 1)
        let undone = await rig.ok("history.undo")
        #expect(undone["committed"]?.boolValue == true)
        #expect(undone["performed"]?.int64Value == 1)
        #expect(rig.store.project.walls.isEmpty)
        #expect(undone["changes"]?[0]?["op"]?.stringValue == "removed")
        let redone = await rig.ok("history.redo")
        #expect(redone["performed"]?.int64Value == 1)
        #expect(rig.store.project.walls.count == 1)
        // nothing left to redo: succeeds without committing
        let none = await rig.ok("history.redo")
        #expect(none["committed"]?.boolValue == false)
        #expect(none["performed"]?.int64Value == 0)
    }
}

// MARK: - Batch

@MainActor
struct ToolBatchTests {
    @Test func batchIsAtomicAndOneUndoStep() async {
        let rig = Rig()
        let wallId = UUID().uuidString.lowercased()
        let r = await rig.ok("app.batch", ["steps": [
            ["tool": "geometry.create_wall", "arguments": ["id": .string(wallId), "start": xy(0, 0), "end": xy(4000, 0)]],
            ["tool": "geometry.add_opening", "arguments": ["wallId": .string(wallId), "type": "door"]],
            ["tool": "geometry.create_room", "arguments": ["name": "R", "points": [xy(0, 0), xy(4000, 0), xy(4000, 3000)]]],
        ]])
        #expect(r["committed"]?.boolValue == true)
        #expect(r["steps"]?.arrayValue?.count == 3)
        #expect(r["changeCount"]?.int64Value == 3)
        #expect(rig.store.project.walls.count == 1 && rig.store.project.openings.count == 1 && rig.store.project.rooms.count == 1)
        // exactly one undo entry
        _ = await rig.ok("history.undo")
        #expect(rig.store.project.walls.isEmpty && rig.store.project.openings.isEmpty && rig.store.project.rooms.isEmpty)
        #expect(rig.store.canUndo == false)
    }

    @Test func batchRollsBackWhenAStepFails() async {
        let rig = Rig()
        _ = await rig.ok("geometry.create_wall", ["start": xy(0, 0), "end": xy(3000, 0)])
        let before = rig.store.project
        let seq = rig.store.lastSeq
        let r = await rig.call("app.batch", ["steps": [
            ["tool": "geometry.create_wall", "arguments": ["start": xy(0, 1000), "end": xy(3000, 1000)]],
            ["tool": "geometry.create_wall", "arguments": ["start": xy(0, 2000), "end": xy(3000, 2000)]],
            ["tool": "scene.delete_objects", "arguments": ["ids": [.string(UUID().uuidString.lowercased())]]],
        ]])
        #expect(!r.ok)
        #expect(r.error?.code == AgentError.notFound)
        #expect(r.error?.message.contains("Step 2") == true)
        #expect(r.error?.details?["step"]?.int64Value == 2)
        #expect(r.error?.details?["tool"]?.stringValue == "scene.delete_objects")
        #expect(rig.store.project.walls.count == 1)
        #expect(rig.store.project.revision == before.revision)
        #expect(rig.store.lastSeq == seq)
    }

    @Test func batchRejectsNonBatchableAndUnknownSteps() async {
        let rig = Rig()
        var r = await rig.call("app.batch", ["steps": [["tool": "app.batch", "arguments": ["steps": []]]]])
        #expect(r.error?.code == AgentError.invalidArgument)
        r = await rig.call("app.batch", ["steps": [["tool": "scene.list_objects"]]])
        #expect(r.error?.code == AgentError.invalidArgument)
        r = await rig.call("app.batch", ["steps": [["tool": "nope.nothing"]]])
        #expect(r.error?.code == AgentError.unknownTool)
        r = await rig.call("app.batch", ["steps": []])
        #expect(r.error?.code == AgentError.invalidArgument)
        r = await rig.call("app.batch", [:])
        #expect(r.error?.code == AgentError.invalidArgument)
    }

    @Test func batchDryRunChangesNothing() async {
        let rig = Rig()
        let r = await rig.ok("app.batch", ["dryRun": true, "steps": [
            ["tool": "geometry.create_wall", "arguments": ["start": xy(0, 0), "end": xy(3000, 0)]],
        ]])
        #expect(r["committed"]?.boolValue == false)
        #expect(rig.store.project.walls.isEmpty)
    }

    @Test func batchHonoursExpectedObjectRevisionsOfSteps() async {
        let rig = Rig()
        let wall = await rig.id("geometry.create_wall", ["start": xy(0, 0), "end": xy(3000, 0)])
        let rev = await rig.ok("scene.get_object", ["id": .string(wall)])["rev"]?.int64Value ?? 0
        _ = await rig.ok("geometry.update_wall", ["id": .string(wall), "heightMm": 2600])
        let r = await rig.call("app.batch", ["steps": [
            ["tool": "geometry.update_wall", "arguments": ["id": .string(wall), "thicknessMm": 400, "expectedObjectRevisions": [wall: .int(rev)]]],
        ]])
        #expect(r.error?.code == AgentError.conflict)
        #expect(rig.store.project.walls[0].thickness != 400)
    }
}

// MARK: - Families

@MainActor
struct ToolFamilyTests {
    @Test func projectFamily() async {
        let rig = Rig()
        let summary = await rig.ok("project.get_summary")
        #expect(summary["name"]?.stringValue == "Tools")
        #expect(summary["counts"]?["walls"]?.int64Value == 0)
        #expect(summary["levels"]?.arrayValue?.count == 1)

        let s = await rig.ok("project.update_settings", ["snapEnabled": true, "snapToWalls": true, "gridMm": 50])
        #expect(s["settings"]?["snapToWalls"]?.boolValue == true)
        #expect(rig.store.project.settings.snap.toWalls)
        #expect(rig.store.project.settings.snap.grid == 50)
        #expect(await rig.errorCode("project.update_settings", [:]) == AgentError.invalidArgument)
        #expect(await rig.errorCode("project.update_settings", ["gridMm": 0]) != nil)

        _ = await rig.ok("geometry.create_wall", ["start": xy(0, 0), "end": xy(3000, 0)])
        let text = await rig.ok("project.get_scene_snapshot")
        #expect(text["text"]?.stringValue?.contains("wall") == true)
        let json = await rig.ok("project.get_scene_snapshot", ["format": "json"])
        #expect(json["items"]?.arrayValue?.isEmpty == false)
        #expect(await rig.errorCode("project.get_scene_snapshot", ["format": "xml"]) == AgentError.invalidArgument)

        let saved = await rig.ok("project.save")
        #expect(saved["saved"]?.boolValue == true)
        #expect(rig.context.saveCount == 1)
        rig.context.saveError = AgentError(code: "NO_FILE", message: "untitled")
        #expect(await rig.errorCode("project.save") == "NO_FILE")
    }

    @Test func geometryFamily() async throws {
        let rig = Rig()
        let wall = await rig.id("geometry.create_wall", ["start": xy(0, 0), "end": xy(4000, 0)])
        let chain = await rig.ok("geometry.create_wall", ["points": [xy(0, 0), xy(0, 3000), xy(4000, 3000)], "closed": false])
        #expect(chain["ids"]?.arrayValue?.count == 2)
        #expect(rig.store.project.walls.count == 3)

        let upd = await rig.ok("geometry.update_wall", ["id": .string(wall), "thicknessMm": 150, "heightMm": 2700])
        #expect(upd["committed"]?.boolValue == true)
        #expect(rig.store.project.walls.first { $0.id.uuidString.lowercased() == wall }?.thickness == 150)
        // nothing to do is an error
        #expect(await rig.errorCode("geometry.update_wall", ["id": .string(wall)]) == AgentError.invalidArgument)

        let split = await rig.ok("geometry.split_wall", ["id": .string(wall), "at": xy(1500, 0)])
        #expect(split["ids"]?.arrayValue?.count == 2)
        #expect(rig.store.project.walls.count == 4)

        let firstHalf = split["ids"]?[0]?.stringValue ?? ""
        let opening = await rig.id("geometry.add_opening", ["wallId": .string(firstHalf), "type": "window", "offsetMm": 700])
        let o = try #require(rig.store.project.openings.first)
        #expect(o.id.uuidString.lowercased() == opening)
        #expect(o.kind == .window)
        let updOpening = await rig.ok("geometry.update_opening", ["id": .string(opening), "widthMm": 800])
        #expect(updOpening["committed"]?.boolValue == true)
        #expect(rig.store.project.openings[0].width == 800)

        let room = await rig.id("geometry.create_room", ["name": "Hall", "points": [xy(0, 0), xy(4000, 0), xy(4000, 3000), xy(0, 3000)]])
        _ = await rig.ok("geometry.update_room", ["id": .string(room), "name": "Big hall"])
        #expect(rig.store.project.rooms[0].name == "Big hall")
        #expect(await rig.errorCode("geometry.create_room", ["name": "Bad", "points": [xy(0, 0), xy(10, 0)]]) == AgentError.invalidArgument)

        let dim = await rig.ok("geometry.create_dimension", ["a": xy(0, 0), "b": xy(4000, 0)])
        #expect(dim["id"]?.stringValue != nil)
        #expect(rig.store.project.dimensions.count == 1)

        let level = await rig.ok("geometry.create_level", ["name": "Upper floor", "heightMm": 2600])
        #expect(level["id"]?.stringValue != nil)
        #expect(rig.store.project.levels.count == 2)

        // distances: two points 3-4-5
        let m = await rig.ok("geometry.measure_distance", ["from": xy(0, 0), "to": xy(3000, 4000)])
        #expect(m["distanceMm"]?.int64Value == 5000)
        let mw = await rig.ok("geometry.measure_distance", ["from": ["id": .string(room)], "to": xy(6000, 1000)])
        #expect(mw["distanceMm"]?.int64Value == 2000)
    }

    @Test func sceneFamily() async throws {
        let rig = Rig()
        let defId = await rig.id("furniture.create_definition", boxDefinition())
        let a = await rig.id("furniture.create_instance", ["definitionId": .string(defId), "position": xyz(1000, 1000), "name": "Box A"])
        let b = await rig.id("furniture.create_instance", ["definitionId": .string(defId), "position": xyz(3000, 1000), "name": "Box B"])

        let detail = await rig.ok("scene.get_object", ["id": .string(a)])
        #expect(detail["kind"]?.stringValue == "furniture")
        #expect(detail["position"]?["x"]?.int64Value == 1000)

        // move / rotate
        let moved = await rig.ok("scene.move_objects", ["ids": [.string(a)], "delta": xyz(-250, 0)])
        #expect(moved["objects"]?[0]?["position"]?["x"]?.int64Value == 750)
        _ = await rig.ok("scene.move_objects", ["ids": [.string(b)], "to": xy(3500, 2000)])
        let bPos = try #require(rig.store.project.instances.first { $0.name == "Box B" }).position
        #expect(bPos.x == 3500 && bPos.y == 2000)
        _ = await rig.ok("scene.rotate_objects", ["ids": [.string(a)], "degrees": 90])
        #expect(try #require(rig.store.project.instances.first { $0.name == "Box A" }).rotationDeg.truncatingRemainder(dividingBy: 360) == 90)
        #expect(await rig.errorCode("scene.move_objects", ["ids": [.string(a)]]) == AgentError.invalidArgument)
        #expect(await rig.errorCode("scene.move_objects", ["ids": [.string(a)], "delta": xyz(1, 1), "to": xy(0, 0)]) == AgentError.invalidArgument)

        // lock / visibility
        _ = await rig.ok("scene.set_locked", ["ids": [.string(a)], "locked": true])
        #expect(try #require(rig.store.project.instances.first { $0.name == "Box A" }).locked)
        #expect(await rig.errorCode("scene.move_objects", ["ids": [.string(a)], "delta": xyz(10, 0)]) == AgentError.locked)
        _ = await rig.ok("scene.set_locked", ["ids": [.string(a)], "locked": false])
        _ = await rig.ok("scene.set_visible", ["ids": [.string(a)], "visible": false])
        #expect(try #require(rig.store.project.instances.first { $0.name == "Box A" }).visible == false)

        // group / ungroup
        let grp = await rig.ok("scene.group_objects", ["ids": [.string(a), .string(b)], "name": "Pair"])
        let gid = grp["id"]?.stringValue ?? ""
        #expect(rig.store.project.groups.count == 1)
        _ = await rig.ok("scene.ungroup_objects", ["ids": [.string(gid)]])
        #expect(rig.store.project.groups.isEmpty)

        // duplicate / delete
        let dup = await rig.ok("scene.duplicate_objects", ["ids": [.string(b)], "offset": xyz(0, 1000)])
        #expect(dup["idMap"]?.objectValue?.count == 1)
        #expect(rig.store.project.instances.count == 3)
        let newId = dup["idMap"]?[b]?.stringValue ?? ""
        _ = await rig.ok("scene.delete_objects", ["ids": [.string(newId)]])
        #expect(rig.store.project.instances.count == 2)

        // create_object dispatch
        let w = await rig.ok("scene.create_object", ["kind": "wall", "start": xy(0, 0), "end": xy(2000, 0)])
        #expect(w["id"]?.stringValue != nil)
        #expect(await rig.errorCode("scene.create_object", ["kind": "spaceship"]) == AgentError.invalidArgument)

        // material
        let material = Material(name: "Test paint", color: RGBColor(230, 30, 30))
        _ = try rig.store.run("Add material") { $0.addMaterial(material) }
        let mats = await rig.ok("scene.list_objects", ["kind": "material"])
        let matId = try #require(mats["items"]?[0]?["id"]?.stringValue)
        let wall = try #require(w["id"]?.stringValue)
        _ = await rig.ok("scene.set_material", ["ids": [.string(wall)], "slot": "wallBoth", "material": .string(matId)])
        #expect(rig.store.project.walls.first?.leftMaterialId?.uuidString.lowercased() == matId)
        _ = await rig.ok("scene.set_material", ["ids": [.string(wall)], "slot": "wallBoth", "material": .null])
        #expect(rig.store.project.walls.first?.leftMaterialId == nil)

        // selection touches only the app context
        let seq = rig.store.lastSeq
        let sel = await rig.ok("scene.select_objects", ["ids": [.string(a), .string(b)]])
        #expect(sel["selection"]?.arrayValue?.count == 2)
        #expect(rig.context.selection.count == 2)
        #expect(rig.context.agentSelections == 1, "agent selections go through setSelectionByAgent (no 'seen' marking)")
        #expect(rig.store.lastSeq == seq)
        _ = await rig.ok("scene.select_objects", ["mode": "clear"])
        #expect(rig.context.selection.isEmpty)

        // collisions: two boxes on the same spot
        _ = await rig.ok("scene.move_objects", ["ids": [.string(b)], "to": xy(750, 1000)])
        _ = await rig.ok("scene.set_visible", ["ids": [.string(a)], "visible": true])
        let coll = await rig.ok("scene.check_collisions")
        #expect((coll["total"]?.int64Value ?? 0) >= 1)
    }

    @Test func catalogFamily() async throws {
        let rig = Rig()
        let list = await rig.ok("catalog.list_builtin", ["limit": 5])
        #expect((list["total"]?.int64Value ?? 0) > 5)
        #expect(list["items"]?[0]?["key"]?.stringValue == "sofa.modular")
        let found = await rig.ok("catalog.list_builtin", ["query": "sofa"])
        #expect((found["total"]?.int64Value ?? 0) >= 1)

        // plain builtin
        let entry = try #require(BuiltinCatalog.entries.first)
        let inserted = await rig.ok("catalog.insert_builtin", ["key": .string(entry.key), "position": xyz(1000, 1000), "rotationDeg": 90])
        #expect(inserted["id"]?.stringValue != nil)
        #expect(inserted["definitionId"]?.stringValue != nil)
        #expect(rig.store.project.instances.count == 1)
        #expect(rig.store.project.instances[0].rotationDeg == 90)
        // second insert reuses the definition
        _ = await rig.ok("catalog.insert_builtin", ["key": .string(entry.key), "position": xyz(3000, 1000)])
        #expect(rig.store.project.definitions.count == 1)
        #expect(rig.store.project.instances.count == 2)
        #expect(await rig.errorCode("catalog.insert_builtin", ["key": "does.not.exist", "position": xyz(0, 0)]) == AgentError.notFound)

        // modular sofa inserts a group
        let sofa = await rig.ok("catalog.insert_builtin", ["key": "sofa.modular", "position": xyz(5000, 3000)])
        #expect(sofa["groupId"]?.stringValue != nil)
        #expect(sofa["memberIds"]?.arrayValue?.count == 7)
        #expect(rig.store.project.groups.count == 1)

        // products
        let prod = await rig.id("catalog.create_product", [
            "name": "Sofa X", "category": "sofa", "priceMinor": 129900, "currency": "EUR",
            "linkTo": .string(inserted["id"]?.stringValue ?? ""),
        ])
        #expect(rig.store.project.products.count == 1)
        #expect(rig.store.project.instances.first { $0.id.uuidString.lowercased() == inserted["id"]?.stringValue }?.productId?.uuidString.lowercased() == prod)
        _ = await rig.ok("catalog.update_product", ["id": .string(prod), "status": "shortlisted", "priceMinor": 119900])
        #expect(rig.store.project.products[0].priceMinor == 119900)
        let hits = await rig.ok("catalog.search_products", ["query": "sofa"])
        #expect(hits["total"]?.int64Value == 1)
        let none = await rig.ok("catalog.search_products", ["query": "table"])
        #expect(none["total"]?.int64Value == 0)
        // relink to the other instance, then unlink
        let other = rig.store.project.instances[1].id.uuidString.lowercased()
        _ = await rig.ok("catalog.link_product", ["productId": .string(prod), "objectId": .string(other)])
        _ = await rig.ok("catalog.link_product", ["productId": .null, "objectId": .string(other)])
        #expect(rig.store.project.instances[1].productId == nil)
        #expect(await rig.errorCode("catalog.create_product", ["name": "X", "currency": "EURO"]) == AgentError.invalidArgument)
        #expect(await rig.errorCode("catalog.create_product", ["name": "X", "priceMinor": -1]) != nil)
    }

    @Test func furnitureFamily() async throws {
        let rig = Rig()
        let created = await rig.ok("furniture.create_definition", boxDefinition())
        let defId = try #require(created["id"]?.stringValue)
        #expect(created["componentIds"]?.objectValue?.count == 2)
        #expect(created["stateIds"]?["open"]?.stringValue != nil)
        let defs = await rig.ok("furniture.list_definitions")
        #expect(defs["total"]?.int64Value == 1)
        #expect(await rig.errorCode("furniture.create_definition", [
            "name": "Dup", "size": ["width": 100, "depth": 100, "height": 100],
            "components": [
                ["name": "a", "shape": "box", "position": xyz(0, 0, 0), "size": ["width": 10, "depth": 10, "height": 10]],
                ["name": "a", "shape": "box", "position": xyz(0, 0, 0), "size": ["width": 10, "depth": 10, "height": 10]],
            ],
        ]) == AgentError.invalidArgument)

        let inst = await rig.id("furniture.create_instance", ["definitionId": .string(defId), "position": xyz(2000, 2000), "name": "Chest"])
        _ = await rig.ok("furniture.update_instance", ["id": .string(inst), "name": "Big chest", "position": xy(2500, 2000), "rotationDeg": 45])
        let chest = try #require(rig.store.project.instances.first)
        #expect(chest.name == "Big chest" && chest.position.x == 2500 && chest.rotationDeg == 45)

        // states
        _ = await rig.ok("furniture.define_state", [
            "definitionId": .string(defId), "name": "wide",
            "poses": ["lid": ["position": xyz(300, 0, 810)]],
            "transition": ["durationMs": 500, "easing": "easeInOut"],
        ])
        #expect(rig.store.project.definitions[0].states.count == 2)
        _ = await rig.ok("furniture.activate_state", ["ids": [.string(inst)], "state": "open"])
        #expect(rig.store.project.instances[0].stateId != nil)
        _ = await rig.ok("furniture.activate_state", ["ids": [.string(inst)], "state": .null])
        #expect(rig.store.project.instances[0].stateId == nil)
        #expect(await rig.errorCode("furniture.activate_state", ["ids": [.string(inst)], "state": "missing"]) == AgentError.notFound)

        // configurations on a group of two chests
        let inst2 = await rig.id("furniture.create_instance", ["definitionId": .string(defId), "position": xyz(4000, 2000)])
        let grp = await rig.ok("scene.group_objects", ["ids": [.string(inst), .string(inst2)], "name": "Pair"])
        let gid = try #require(grp["id"]?.stringValue)
        let c1 = await rig.ok("furniture.save_configuration", ["groupId": .string(gid), "name": "Spread"])
        #expect(c1["configurationId"]?.stringValue != nil)
        _ = await rig.ok("scene.move_objects", ["ids": [.string(inst2)], "delta": xyz(0, 1500)])
        _ = await rig.ok("furniture.save_configuration", ["groupId": .string(gid), "name": "Apart"])
        let listed = await rig.ok("furniture.list_configurations", ["groupId": .string(gid)])
        #expect(listed["groups"]?[0]?["configurations"]?.arrayValue?.count == 2)
        _ = await rig.ok("furniture.activate_configuration", ["groupId": .string(gid), "configuration": "Spread"])
        #expect(rig.store.project.instances.first { $0.id.uuidString.lowercased() == inst2 }?.position.y == 2000)
        _ = await rig.ok("furniture.delete_configuration", ["groupId": .string(gid), "configuration": "Apart"])
        #expect(rig.store.project.groups[0].configurations.count == 1)
        #expect(await rig.errorCode("furniture.activate_configuration", ["groupId": .string(gid), "configuration": "Nope"]) == AgentError.notFound)
    }

    @Test func allowsOverlapThroughTools() async throws {
        let rig = Rig()
        let created = await rig.ok("furniture.create_definition", boxDefinition())
        let defId = try #require(created["id"]?.stringValue)
        let plain = await rig.id("furniture.create_instance", ["definitionId": .string(defId), "position": xyz(1000, 1000)])
        let flagged = await rig.id("furniture.create_instance", ["definitionId": .string(defId), "position": xyz(3000, 1000), "allowsOverlap": true])
        #expect(rig.store.project.instances.first { $0.id.uuidString.lowercased() == plain }?.allowsOverlap == false)
        #expect(rig.store.project.instances.first { $0.id.uuidString.lowercased() == flagged }?.allowsOverlap == true)
        // update, alone and with other fields
        _ = await rig.ok("furniture.update_instance", ["id": .string(plain), "allowsOverlap": true])
        #expect(rig.store.project.instances.first { $0.id.uuidString.lowercased() == plain }?.allowsOverlap == true)
        _ = await rig.ok("furniture.update_instance", ["id": .string(plain), "name": "Rug", "allowsOverlap": false])
        let back = try #require(rig.store.project.instances.first { $0.id.uuidString.lowercased() == plain })
        #expect(back.allowsOverlap == false && back.name == "Rug")
        // one undo step reverts the flag
        _ = await rig.ok("furniture.update_instance", ["id": .string(plain), "allowsOverlap": true])
        _ = await rig.ok("history.undo")
        #expect(rig.store.project.instances.first { $0.id.uuidString.lowercased() == plain }?.allowsOverlap == false)
        // wrong type and no-op request
        #expect(await rig.errorCode("furniture.update_instance", ["id": .string(plain), "allowsOverlap": "yes"]) == AgentError.invalidArgument)
        #expect(await rig.errorCode("furniture.create_instance", ["definitionId": .string(defId), "position": xyz(0, 0), "allowsOverlap": 3]) == AgentError.invalidArgument)
        // locked pieces stay unchanged
        _ = await rig.ok("scene.set_locked", ["ids": [.string(plain)], "locked": true])
        #expect(await rig.call("furniture.update_instance", ["id": .string(plain), "allowsOverlap": true]).ok == false)
        // scene rows carry the flag
        let rows = await rig.ok("scene.list_objects", ["kind": "furniture"])
        let flaggedRow = rows["items"]?.arrayValue?.first { $0["id"]?.stringValue == plain }
        #expect(flaggedRow?["allowsOverlap"] != nil)
    }

    @Test func cameraFamily() async {
        let rig = Rig()
        let state = await rig.ok("camera.get_state")
        #expect(state["camera"]?["mode"]?.stringValue != nil)
        // set_state is not an undo step
        let before = rig.store.canUndo
        let set = await rig.ok("camera.set_state", ["yawDeg": 33.5, "pitchDeg": -20, "distanceMm": 8000])
        #expect(set["camera"]?["yawDeg"]?.doubleValue == 33.5)
        #expect(rig.store.project.camera.yawDeg == 33.5)
        #expect(rig.store.canUndo == before)
        #expect(await rig.errorCode("camera.set_state", [:]) == AgentError.invalidArgument)
        #expect(await rig.errorCode("camera.set_state", ["mode": "sideways"]) == AgentError.invalidArgument)
        let saved = await rig.ok("camera.save", ["name": "Corner view"])
        #expect(saved["id"]?.stringValue != nil)
        #expect(rig.store.project.cameras.count == 1)
        let again = await rig.ok("camera.get_state")
        #expect(again["savedCameras"]?.arrayValue?.count == 1)
        #expect(rig.store.canUndo)
    }
}

// MARK: - Scenario A02

@MainActor
struct ToolScenarioTests {
    /// "Show all sofas in the living room, move sofa A exactly 250 mm to the left, snap to walls, save as configuration 2."
    @Test func moveSofaExactly250mmLeft() async throws {
        let rig = Rig()
        _ = await rig.ok("geometry.create_room", ["name": "Living room", "points": [xy(0, 0), xy(6000, 0), xy(6000, 5000), xy(0, 5000)]])
        let sofa = await rig.ok("catalog.insert_builtin", ["key": "sofa.modular", "position": xyz(2000, 2500)])
        let groupId = try #require(sofa["groupId"]?.stringValue)

        // list -> get -> move
        let rows = await rig.ok("scene.list_objects", ["kind": "furniture", "query": "Corner A"])
        #expect(rows["total"]?.int64Value == 1)
        let row = try #require(rows["items"]?[0])
        let id = try #require(row["id"]?.stringValue)
        #expect(row["room"]?.stringValue == "Living room")
        let rev = try #require(row["rev"]?.int64Value)
        let x0 = try #require(row["position"]?["x"]?.int64Value)
        let y0 = try #require(row["position"]?["y"]?.int64Value)

        let moved = await rig.ok("scene.move_objects", [
            "ids": [.string(id)], "delta": xyz(-250, 0),
            "expectedObjectRevisions": [id: .int(rev)],
        ])
        #expect(moved["committed"]?.boolValue == true)
        #expect(moved["objects"]?[0]?["position"]?["x"]?.int64Value == x0 - 250)
        #expect(moved["objects"]?[0]?["position"]?["y"]?.int64Value == y0)
        let inst = try #require(rig.store.project.instances.first { $0.id.uuidString.lowercased() == id })
        #expect(inst.position.x == x0 - 250 && inst.position.y == y0)

        // the old revision is now stale
        #expect(await rig.errorCode("scene.move_objects", [
            "ids": [.string(id)], "delta": xyz(-1, 0),
            "expectedObjectRevisions": [id: .int(rev)],
        ]) == AgentError.conflict)

        // snapping on, save as configuration 2
        _ = await rig.ok("project.update_settings", ["snapEnabled": true, "snapToWalls": true])
        #expect(rig.store.project.settings.snap.enabled && rig.store.project.settings.snap.toWalls)
        let cfg = await rig.ok("furniture.save_configuration", ["groupId": .string(groupId), "name": "Configuration 2"])
        #expect(cfg["configurationId"]?.stringValue != nil)
        let group = try #require(rig.store.project.groups.first)
        #expect(group.configurations.contains { $0.name == "Configuration 2" })

        // everything else untouched: the other six members stayed where they were
        #expect(rig.store.project.instances.count == 7)
    }
}

// MARK: - Socket round trip

@MainActor
struct ToolSocketTests {
    /// Real Unix socket between AgentSocketClient and the registry. Uses a short temp path (sun_path limit).
    @Test func registryOverRealSocket() async throws {
        let rig = Rig()
        let path = "/private/tmp/rs-tool-\(UUID().uuidString.prefix(8).lowercased()).sock"
        nonisolated(unsafe) let registry = rig.registry
        let server = AgentSocketServer(socketPath: path, token: "secret-token") { request in
            await registry.call(request)
        }
        try server.start()
        defer { server.stop(); unlink(path) }

        let client = AgentSocketClient(socketPath: path, token: "secret-token", clientId: "socket-test")
        let tools = try await client.call(agentListToolsName)
        #expect(try tools.decode([ToolDescriptor].self).count == 120)

        let created = try await client.call("geometry.create_wall", arguments: ["start": xy(0, 0), "end": xy(2500, 0)])
        #expect(created["committed"]?.boolValue == true)
        #expect(rig.store.project.walls.count == 1)

        do {
            _ = try await client.call("scene.get_object", arguments: ["id": .string(UUID().uuidString.lowercased())])
            Issue.record("expected NOT_FOUND")
        } catch let e as AgentError {
            #expect(e.code == AgentError.notFound)
        }
        let ev = rig.store.events(after: 0).events.last
        #expect(ev?.origin == .agent("socket-test"))
    }
}

@MainActor
struct ReportToolTests {
    private func roomRig() -> Rig {
        var p = Project.empty(name: "Flat")
        p.levels[0].height = 2500
        let lv = p.levels[0].id
        let pts = [P2(0, 0), P2(4000, 0), P2(4000, 3000), P2(0, 3000)]
        p.rooms = [Room(levelId: lv, name: "Living", points: pts)]
        for i in 0..<4 { p.walls.append(Wall(levelId: lv, start: pts[i], end: pts[(i + 1) % 4], thickness: 100, height: 2500)) }
        return Rig(project: p)
    }

    @Test func roomsReportGivesExactAreasAndVolume() async throws {
        let rig = roomRig()
        let r = await rig.ok("report.rooms")
        let room = try #require(r["levels"]?[0]?["rooms"]?[0])
        #expect(room["name"]?.stringValue == "Living")
        #expect(room["floorAreaM2"]?.stringValue == "12.00")
        #expect(room["perimeterM"]?.stringValue == "14.00")
        #expect(room["volumeM3"]?.stringValue == "30.000")
        #expect(room["wallAreaGrossM2"]?.stringValue == "35.00")
        #expect(r["totals"]?["floorAreaM2"]?.stringValue == "12.00")
    }

    @Test func roomsReportTextFormatsAndLevelFilter() async {
        let rig = roomRig()
        let csv = await rig.ok("report.rooms", ["format": "csv"])
        #expect(csv["format"]?.stringValue == "csv")
        #expect(csv["text"]?.stringValue?.contains("\r\n") == true)
        let md = await rig.ok("report.rooms", ["format": "markdown", "levelId": .string(rig.levelId.uuidString)])
        #expect(md["text"]?.stringValue?.hasPrefix("# Room report: Flat") == true)
        #expect(await rig.errorCode("report.rooms", ["format": "xlsx"]) == AgentError.invalidArgument)
        #expect(await rig.errorCode("report.rooms", ["levelId": .string(UUID().uuidString)]) == AgentError.notFound)
    }

    @Test func bomListsFurnitureAndWalls() async throws {
        let rig = roomRig()
        let entry = try #require(BuiltinCatalog.entries.first)
        _ = await rig.ok("catalog.insert_builtin", ["key": .string(entry.key), "position": xyz(1000, 1000)])
        _ = await rig.ok("catalog.insert_builtin", ["key": .string(entry.key), "position": xyz(3000, 1000)])
        let b = await rig.ok("report.bom")
        #expect(b["furnitureCount"]?.int64Value == 2)
        #expect(b["furniture"]?[0]?["count"]?.int64Value == 2)
        #expect(b["walls"]?["count"]?.int64Value == 4)
        #expect(b["walls"]?["totalLengthM"]?.stringValue == "14.00")
        #expect(b["walls"]?["areaM2"]?.stringValue == "35.00")
        let md = await rig.ok("report.bom", ["format": "markdown"])
        #expect(md["text"]?.stringValue?.contains("Bill of materials") == true)
    }

    @Test func clearancesFindOverlapAndValidateRules() async throws {
        let rig = roomRig()
        let entry = try #require(BuiltinCatalog.entries.first)
        _ = await rig.ok("catalog.insert_builtin", ["key": .string(entry.key), "position": xyz(2000, 1500)])
        _ = await rig.ok("catalog.insert_builtin", ["key": .string(entry.key), "position": xyz(2000, 1500)])
        let r = await rig.ok("report.clearances", ["checkDoorSwing": false])
        let findings = try #require(r["findings"]?.arrayValue)
        #expect(!findings.isEmpty)
        #expect(findings.contains { $0["kind"]?.stringValue == "furnitureGap" && $0["overlaps"] == .bool(true) })
        #expect(r["count"]?.int64Value == Int64(findings.count))
        let csv = await rig.ok("report.clearances", ["format": "csv"])
        #expect(csv["text"]?.stringValue?.hasPrefix("Kind,Level,Furniture") == true)
        #expect(await rig.errorCode("report.clearances", ["minWalkwayMm": -5]) == AgentError.invalidArgument)
        #expect(rig.store.project.instances.count == 2) // read-only: nothing moved or removed
    }

    /// Second level with a 2×2 m room and no walls: the filter must limit rooms and totals to that level, and a room
    /// without walls has null wall areas (counted in roomsWithoutWalls).
    @Test func levelFilterLimitsTotalsAndWalllessRoomIsNull() async throws {
        var p = Project.empty(name: "Two")
        p.levels[0].height = 2500
        let lv0 = p.levels[0].id
        let pts = [P2(0, 0), P2(4000, 0), P2(4000, 3000), P2(0, 3000)]
        p.rooms = [Room(levelId: lv0, name: "Living", points: pts)]
        for i in 0..<4 { p.walls.append(Wall(levelId: lv0, start: pts[i], end: pts[(i + 1) % 4], thickness: 100, height: 2500)) }
        let upper = Level(name: "Upper", elevation: 2700, height: 2400)
        p.levels.append(upper)
        p.rooms.append(Room(levelId: upper.id, name: "Attic", points: [P2(0, 0), P2(2000, 0), P2(2000, 2000), P2(0, 2000)]))
        let rig = Rig(project: p)

        let all = await rig.ok("report.rooms")
        #expect(all["totals"]?["floorAreaM2"]?.stringValue == "16.00")
        #expect(all["totals"]?["roomsWithoutWalls"]?.int64Value == 1)

        let only = await rig.ok("report.rooms", ["levelId": .string(upper.id.uuidString)])
        #expect(only["levels"]?.arrayValue?.count == 1)
        let attic = try #require(only["levels"]?[0]?["rooms"]?[0])
        #expect(attic["name"]?.stringValue == "Attic")
        #expect(attic["floorAreaM2"]?.stringValue == "4.00")
        #expect(attic["volumeM3"]?.stringValue == "9.600")
        #expect(attic["wallAreaGrossM2"] == .null)
        #expect(attic["wallAreaNetM2"] == .null)
        #expect(only["totals"]?["floorAreaM2"]?.stringValue == "4.00")
        #expect(only["totals"]?["wallAreaGrossM2"]?.stringValue == "0.00")
    }

    @Test func clearancesLevelFilterAndRuleBounds() async throws {
        let rig = roomRig()
        let entry = try #require(BuiltinCatalog.entries.first)
        _ = await rig.ok("catalog.insert_builtin", ["key": .string(entry.key), "position": xyz(2000, 1500)])
        _ = await rig.ok("catalog.insert_builtin", ["key": .string(entry.key), "position": xyz(2000, 1500)])
        let same = await rig.ok("report.clearances", ["levelId": .string(rig.levelId.uuidString), "checkDoorSwing": false])
        #expect((same["count"]?.int64Value ?? 0) > 0)
        #expect(await rig.errorCode("report.clearances", ["levelId": .string(UUID().uuidString)]) == AgentError.notFound)
        #expect(await rig.errorCode("report.clearances", ["doorApproachMm": 100_001]) == AgentError.invalidArgument)
        let edge = await rig.ok("report.clearances", ["minWalkwayMm": 100_000, "doorApproachMm": 0, "format": "JSON"])
        #expect(edge["rules"]?["minWalkwayMm"]?.doubleValue == 100_000)
        #expect(edge["rules"]?["doorApproachMm"]?.doubleValue == 0)
    }
}

// MARK: - Opening detail and material tools

@MainActor
struct DetailToolTests {
    @Test func openingDetailThroughTools() async throws {
        let rig = Rig()
        let wall = await rig.id("geometry.create_wall", ["start": xy(0, 0), "end": xy(4000, 0)])
        let door = await rig.id("geometry.add_opening", ["wallId": .string(wall), "type": "door", "style": "panel4", "handle": "lever",
                                                         "frameWidthMm": 70, "mullionCols": 1, "mullionRows": 2, "glass": "frosted"])
        let o = try #require(rig.store.project.opening(UUID(uuidString: door)!))
        #expect(o.style == .panel4 && o.handle == .lever && o.frameWidth == 70 && o.mullionCols == 1 && o.mullionRows == 2 && o.glassType == .frosted)

        _ = await rig.ok("geometry.update_opening", ["id": .string(door), "style": "sliding", "handle": "bar"])
        #expect(rig.store.project.opening(UUID(uuidString: door)!)?.style == .sliding)
        // A style that does not suit the kind, an unknown value and out-of-range numbers are rejected.
        #expect(await rig.errorCode("geometry.update_opening", ["id": .string(door), "style": "tiltTurn2"]) != nil)
        #expect(await rig.errorCode("geometry.update_opening", ["id": .string(door), "style": "round"]) == AgentError.invalidArgument)
        #expect(await rig.errorCode("geometry.update_opening", ["id": .string(door), "mullionCols": 9]) != nil)
        #expect(await rig.errorCode("geometry.update_opening", ["id": .string(door), "frameWidthMm": 5]) != nil)
        #expect(rig.store.project.opening(UUID(uuidString: door)!)?.style == .sliding)
        // The detail keys alone count as a change.
        _ = await rig.ok("geometry.update_opening", ["id": .string(door), "glass": "tinted"])
        #expect(rig.store.project.opening(UUID(uuidString: door)!)?.glassType == .tinted)
    }

    @Test func materialKeysAndPresets() async throws {
        let rig = Rig()
        let created = await rig.ok("material.create", ["name": "Parquet", "color": "#B08D57", "pattern": "wood", "finish": "satin",
                                                       "color2": "#6B4A2A", "patternSizeMm": 140, "patternAngleDeg": 90, "groutMm": 2,
                                                       "clearcoat": 0.3, "specular": 0.6])
        let id = created["id"]?.stringValue ?? ""
        let m = try #require(rig.store.project.material(UUID(uuidString: id)!))
        #expect(m.patternSize == 140 && m.patternAngleDeg == 90 && m.grout == 2 && m.clearcoat == 0.3 && m.specular == 0.6)

        _ = await rig.ok("material.update", ["id": .string(id), "specular": 0.1])
        #expect(rig.store.project.material(UUID(uuidString: id)!)?.specular == 0.1)
        #expect(await rig.errorCode("material.update", ["id": .string(id), "clearcoat": 2]) != nil)
        #expect(await rig.errorCode("material.update", ["id": .string(id), "pattern": "dots"]) == AgentError.invalidArgument)
        #expect(await rig.errorCode("material.update", ["id": .string(id), "color2": "red"]) != nil)

        let list = await rig.ok("material.list_presets")
        let presets = try #require(list["presets"]?.arrayValue)
        #expect(presets.count == MaterialPresets.all.count && presets.count >= 15)
        let applied = await rig.ok("material.apply_preset", ["id": .string(id), "preset": "tiles-white"])
        #expect(applied["pattern"]?.stringValue == "tiles" && applied["preset"]?.stringValue == "tiles-white")
        #expect(await rig.errorCode("material.apply_preset", ["id": .string(id), "preset": "nope"]) != nil)
        // Undo restores the wood parquet.
        try rig.store.undo()
        #expect(rig.store.project.material(UUID(uuidString: id)!)?.pattern == .wood)
    }
}
