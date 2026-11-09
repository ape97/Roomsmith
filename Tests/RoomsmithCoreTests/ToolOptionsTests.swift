import Foundation
import Testing
@testable import RoomsmithCore
@testable import RoomsmithIPC

// MCP tools for furniture options (variants): define/delete groups, set_options, options on create/update, detail output.

@MainActor
private final class OptContext: AgentAppContext {
    var selection: Set<UUID> = []
    var activeLevelId: UUID
    var fileURL: URL?
    var appVersion = "test"
    init(activeLevelId: UUID) { self.activeLevelId = activeLevelId }
    func saveForAgent() throws -> String { fileURL?.path ?? "/tmp/test.roomsmith" }
}

@MainActor
private struct ORig {
    let store: DocumentStore
    let registry: ToolRegistry
    var p: Project { store.project }

    init() {
        let project = Project.empty(name: "Options")
        store = DocumentStore(project: project)
        store.agentWriteEnabled = true
        registry = ToolRegistry(store: store, context: OptContext(activeLevelId: project.levels[0].id))
    }

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

private func xyz(_ x: Int, _ y: Int, _ z: Int = 0) -> JSONValue { ["x": .int(Int64(x)), "y": .int(Int64(y)), "z": .int(Int64(z))] }

private func wardrobe() -> JSONValue {
    [
        "name": "Wardrobe", "category": "Test",
        "size": ["width": 1000, "depth": 500, "height": 2000],
        "components": [
            ["name": "body", "shape": "box", "position": xyz(0, 0, 1000), "size": ["width": 1000, "depth": 500, "height": 2000]],
            ["name": "door", "shape": "box", "position": xyz(0, 250, 1000), "size": ["width": 1000, "depth": 20, "height": 2000]],
        ],
    ]
}

private func uuid(_ s: String?) -> UUID { UUID(uuidString: s ?? "") ?? UUID() }

@MainActor
struct ToolOptionsTests {
    /// Design with a "Colour" group (Oak/Black) and a "Door" group (With/Without).
    private func setup(_ rig: ORig) async -> (def: String, colour: String, door: String) {
        _ = await rig.ok("material.create", ["name": "Oak", "color": "#B08D57"])
        _ = await rig.ok("material.create", ["name": "Black", "color": "#111111"])
        let def = await rig.id("furniture.create_definition", wardrobe())
        let c = await rig.ok("furniture.define_option_group", [
            "definitionId": .string(def), "name": "Colour",
            "choices": [["name": "Oak", "effects": ["body": ["material": "Oak"]]],
                        ["name": "Black", "effects": ["body": ["material": "Black"]]]],
        ])
        let d = await rig.ok("furniture.define_option_group", [
            "definitionId": .string(def), "name": "Door",
            "choices": [["name": "With"], ["name": "Without", "effects": ["door": ["visible": false]]]],
        ])
        return (def, c["groupId"]?.stringValue ?? "", d["groupId"]?.stringValue ?? "")
    }

    @Test func defineByNameKeepsChoiceIdsOnRedefine() async throws {
        let rig = ORig()
        let s = await setup(rig)
        let first = rig.p.definition(uuid(s.def))!.optionGroups.first { $0.name == "Colour" }!
        #expect(first.choices.count == 2)
        let again = await rig.ok("furniture.define_option_group", [
            "definitionId": .string(s.def), "name": "Colour",
            "choices": [["name": "Oak", "effects": ["body": ["material": "Oak"]]], ["name": "Black"]],
        ])
        #expect(again["groupId"]?.stringValue == s.colour)
        let after = rig.p.definition(uuid(s.def))!.optionGroups.filter { $0.name == "Colour" }
        #expect(after.count == 1)
        #expect(after[0].choices.map(\.id) == first.choices.map(\.id))
    }

    @Test func setOptionsOnSeveralPiecesAndNullResets() async throws {
        let rig = ORig()
        let s = await setup(rig)
        let a = await rig.id("furniture.create_instance", ["definitionId": .string(s.def), "position": xyz(1000, 1000)])
        let b = await rig.id("furniture.create_instance", ["definitionId": .string(s.def), "position": xyz(3000, 1000)])
        _ = await rig.ok("furniture.set_options", ["ids": [.string(a), .string(b)], "options": ["Colour": "Black", "Door": "Without"]])
        for i in [a, b] {
            let sel = rig.p.instance(uuid(i))!.optionSelection
            #expect(sel.count == 2)
        }
        _ = await rig.ok("furniture.set_options", ["ids": [.string(a)], "options": ["Colour": .null]])
        #expect(rig.p.instance(uuid(a))!.optionSelection[uuid(s.colour)] == nil)
        #expect(rig.p.instance(uuid(b))!.optionSelection[uuid(s.colour)] != nil)
    }

    @Test func optionsOnCreateAndUpdateInstance() async throws {
        let rig = ORig()
        let s = await setup(rig)
        let a = await rig.id("furniture.create_instance", ["definitionId": .string(s.def), "position": xyz(1000, 1000), "options": ["Colour": "Black"]])
        #expect(rig.p.instance(uuid(a))!.optionSelection.count == 1)
        _ = await rig.ok("furniture.update_instance", ["id": .string(a), "options": ["Door": "Without"]])
        #expect(rig.p.instance(uuid(a))!.optionSelection.count == 2)
    }

    @Test func detailListsAvailableOptions() async throws {
        let rig = ORig()
        let s = await setup(rig)
        let a = await rig.id("furniture.create_instance", ["definitionId": .string(s.def), "position": xyz(1000, 1000), "options": ["Colour": "Black"]])
        let o = await rig.ok("scene.get_object", ["id": .string(a)])
        let groups = o["availableOptions"]?.arrayValue ?? []
        #expect(groups.count == 2)
        let colour = groups.first { $0["name"]?.stringValue == "Colour" }
        #expect(colour?["selectedChoice"]?.stringValue == "Black")
        #expect(colour?["choices"]?.arrayValue?.count == 2)
        #expect(o["options"]?["Door"]?.stringValue == "With")
        let d = await rig.ok("scene.get_object", ["id": .string(s.def)])
        #expect(d["optionGroups"]?.arrayValue?.count == 2)
    }

    @Test func foreignAndUnknownReferencesAreErrors() async throws {
        let rig = ORig()
        let s = await setup(rig)
        let other = await rig.id("furniture.create_definition", wardrobe())
        let inst = await rig.id("furniture.create_instance", ["definitionId": .string(other), "position": xyz(1000, 1000)])
        // group of another design
        #expect((await rig.error("furniture.set_options", ["ids": [.string(inst)], "options": .object([s.colour: "Black"])]))?.code == AgentError.notFound)
        // unknown choice
        let mine = await rig.id("furniture.create_instance", ["definitionId": .string(s.def), "position": xyz(3000, 1000)])
        let e = await rig.error("furniture.set_options", ["ids": [.string(mine)], "options": ["Colour": "Pink"]])
        #expect(e?.code == AgentError.notFound || e?.code == AgentError.invalidArgument)
        #expect((await rig.error("furniture.set_options", ["ids": [.string(mine)], "options": .object([:])]))?.code == AgentError.invalidArgument)
        #expect((await rig.error("furniture.define_option_group", ["definitionId": .string(s.def), "name": "X", "choices": []]))?.code == AgentError.invalidArgument)
    }

    @Test func deleteGroupAndUndo() async throws {
        let rig = ORig()
        let s = await setup(rig)
        let a = await rig.id("furniture.create_instance", ["definitionId": .string(s.def), "position": xyz(1000, 1000), "options": ["Colour": "Black"]])
        let depth = rig.store.undoDepth
        _ = await rig.ok("furniture.delete_option_group", ["definitionId": .string(s.def), "group": "Colour"])
        #expect(rig.store.undoDepth == depth + 1)
        #expect(rig.p.definition(uuid(s.def))!.optionGroups.count == 1)
        #expect(rig.p.instance(uuid(a))!.optionSelection.isEmpty)
        _ = await rig.ok("history.undo")
        #expect(rig.p.definition(uuid(s.def))!.optionGroups.count == 2)
        #expect(rig.p.instance(uuid(a))!.optionSelection.count == 1)
    }
}
