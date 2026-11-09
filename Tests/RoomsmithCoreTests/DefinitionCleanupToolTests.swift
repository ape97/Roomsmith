import Foundation
import Testing
@testable import RoomsmithCore
@testable import RoomsmithIPC

// MCP tools that keep the design list tidy: create_definition reuse and hints, replace_definition, delete_definitions,
// prune_unused_definitions (dry run by default) and the list_definitions filters.

@MainActor
private final class CleanContext: AgentAppContext {
    var selection: Set<UUID> = []
    var activeLevelId: UUID
    var fileURL: URL?
    var appVersion = "test"
    init(activeLevelId: UUID) { self.activeLevelId = activeLevelId }
    func saveForAgent() throws -> String { fileURL?.path ?? "/tmp/test.roomsmith" }
}

@MainActor
private struct CleanRig {
    let store: DocumentStore
    let registry: ToolRegistry
    var p: Project { store.project }

    init() {
        let project = Project.empty(name: "Cleanup")
        store = DocumentStore(project: project)
        store.agentWriteEnabled = true
        registry = ToolRegistry(store: store, context: CleanContext(activeLevelId: project.levels[0].id))
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

    func create(_ name: String = "Wardrobe", width: Int = 1000, extra: [String: JSONValue] = [:]) async -> JSONValue {
        await ok("furniture.create_definition", .object(design(name, width: width).merging(extra) { _, new in new }))
    }

    func place(_ def: String, _ x: Int = 0) async -> String {
        await ok("furniture.create_instance", ["definitionId": .string(def), "position": ["x": .int(Int64(x)), "y": 0, "z": 0]])["id"]?.stringValue ?? ""
    }
}

private func design(_ name: String, width: Int) -> [String: JSONValue] {
    [
        "name": .string(name), "category": "Test",
        "size": ["width": .int(Int64(width)), "depth": 500, "height": 2000],
        "components": [
            ["name": "body", "shape": "box", "position": ["x": 0, "y": 0, "z": 1000],
             "size": ["width": .int(Int64(width)), "depth": 500, "height": 2000]],
        ],
    ]
}

@MainActor
struct DefinitionCleanupToolTests {
    // MARK: create_definition

    @Test func creatingTheSameDesignTwiceReturnsTheFirstOne() async {
        let rig = CleanRig()
        let first = await rig.create()
        let second = await rig.create()
        #expect(second["reused"]?.boolValue == true)
        #expect(second["id"]?.stringValue == first["id"]?.stringValue)
        #expect(second["componentIds"] == first["componentIds"])
        #expect(rig.p.definitions.count == 1)
    }

    @Test func forceNewAndAGivenIdAlwaysAddADesign() async {
        let rig = CleanRig()
        _ = await rig.create()
        let forced = await rig.create(extra: ["forceNew": true])
        #expect(forced["reused"] == nil && rig.p.definitions.count == 2)
        let withId = await rig.create(extra: ["id": .string(UUID().uuidString.lowercased())])
        #expect(withId["reused"] == nil && rig.p.definitions.count == 3)
    }

    @Test func aChangedDesignWithTheSameNameIsAddedAndPointsToTheOldOne() async {
        let rig = CleanRig()
        let old = await rig.create()
        let new = await rig.create(width: 1200)
        #expect(new["reused"] == nil && rig.p.definitions.count == 2)
        let similar = new["similar"]?.arrayValue ?? []
        #expect(similar.count == 1 && similar[0]["id"]?.stringValue == old["id"]?.stringValue)
        #expect(new["hint"]?.stringValue?.contains("furniture.replace_definition") == true)
        #expect(old["similar"] == nil, "the first design of a name has no hint")
    }

    // MARK: replace_definition

    @Test func replaceDefinitionMovesThePiecesAndDropsTheOldDesign() async throws {
        let rig = CleanRig()
        let old = await rig.create().stringField("id"), new = await rig.create(width: 1200).stringField("id")
        let piece = await rig.place(old, 700)
        let r = await rig.ok("furniture.replace_definition", ["fromId": .string(old), "toId": .string(new)])
        #expect(r["replaced"]?.int64Value == 1 && r["ids"]?.arrayValue?.first?.stringValue == piece)
        #expect(r["removedDefinitions"]?.arrayValue?.first?["id"]?.stringValue == old)
        let i = try #require(rig.p.instance(UUID(uuidString: piece)!))
        #expect(i.definitionId == UUID(uuidString: new) && i.position.x == 700)
        #expect(rig.p.definition(UUID(uuidString: old)!) == nil)
        _ = try rig.store.undo()
        #expect(rig.p.definition(UUID(uuidString: old)!) != nil, "one undo step")
    }

    @Test func replaceDefinitionKeepsTheOldDesignWhenAskedOrPartial() async {
        let rig = CleanRig()
        let old = await rig.create().stringField("id"), new = await rig.create(width: 1200).stringField("id")
        let a = await rig.place(old), b = await rig.place(old, 3000)
        let partial = await rig.ok("furniture.replace_definition", ["fromId": .string(old), "toId": .string(new), "instanceIds": [.string(a)]])
        #expect(partial["replaced"]?.int64Value == 1 && partial["keptDefinitionIds"]?.arrayValue?.first?.stringValue == old)
        let rest = await rig.ok("furniture.replace_definition", ["fromId": .string(old), "toId": .string(new), "removeOld": false])
        #expect(rest["replaced"]?.int64Value == 1 && rest["ids"]?.arrayValue?.first?.stringValue == b)
        #expect(rig.p.definition(UUID(uuidString: old)!) != nil)
    }

    @Test func replaceDefinitionRefusesBadInput() async {
        let rig = CleanRig()
        let old = await rig.create().stringField("id")
        #expect(await rig.error("furniture.replace_definition", ["fromId": .string(old), "toId": .string(old)]) != nil)
        #expect(await rig.error("furniture.replace_definition", ["fromId": .string(old), "toId": .string(UUID().uuidString.lowercased())]) != nil)
    }

    // MARK: delete_definitions

    @Test func deleteDefinitionsRefusesAUsedDesignAndChangesNothing() async {
        let rig = CleanRig()
        let free = await rig.create("Free").stringField("id"), used = await rig.create("Used").stringField("id")
        _ = await rig.place(used)
        let e = await rig.error("furniture.delete_definitions", ["ids": [.string(free), .string(used)]])
        #expect(e != nil)
        #expect(rig.p.definitions.count == 2, "nothing was deleted")
        let ok = await rig.ok("furniture.delete_definitions", ["ids": [.string(free)]])
        #expect(ok["count"]?.int64Value == 1 && rig.p.definitions.count == 1)
    }

    @Test func deleteDefinitionsDryRunDeletesNothing() async {
        let rig = CleanRig()
        let free = await rig.create("Free").stringField("id")
        let r = await rig.ok("furniture.delete_definitions", ["ids": [.string(free)], "dryRun": true])
        #expect(r["committed"]?.boolValue == false)
        #expect(rig.p.definitions.count == 1)
    }

    // MARK: prune_unused_definitions

    @Test func pruneIsADryRunByDefault() async {
        let rig = CleanRig()
        _ = await rig.create("A")
        let b = await rig.create("B").stringField("id")
        _ = await rig.place(b)
        let before = rig.p.revision
        let r = await rig.ok("furniture.prune_unused_definitions")
        #expect(r["dryRun"]?.boolValue == true && r["committed"]?.boolValue == false)
        #expect(r["count"]?.int64Value == 1 && r["wouldRemove"]?.arrayValue?.count == 1)
        #expect(rig.p.definitions.count == 2 && rig.p.revision == before)
    }

    @Test func pruneWithDryRunFalseDeletesInOneUndoStepAndKeepsLinkedDesigns() async throws {
        let rig = CleanRig()
        _ = await rig.create("A")
        _ = await rig.create("B")
        let used = await rig.create("C").stringField("id")
        let linked = await rig.create("D").stringField("id")
        _ = await rig.place(used)
        let product = await rig.ok("catalog.create_product", ["name": "Planned"])["id"]?.stringValue
        if let product {
            _ = try rig.store.run("link") { try $0.linkProduct(UUID(uuidString: product)!, to: UUID(uuidString: linked)!) }
        }
        let r = await rig.ok("furniture.prune_unused_definitions", ["dryRun": false])
        #expect(r["count"]?.int64Value == 2 && r["removed"]?.arrayValue?.count == 2)
        #expect(Set(rig.p.definitions.map(\.name)) == (product == nil ? ["C"] : ["C", "D"]))
        #expect(r["unusedLinkedKept"]?.arrayValue?.count == (product == nil ? 0 : 1))
        _ = try rig.store.undo()
        #expect(rig.p.definitions.count == 4, "one undo step")
    }

    @Test func pruneNeedsWriteAccessToDelete() async {
        let rig = CleanRig()
        _ = await rig.create("A")
        rig.store.agentWriteEnabled = false
        let dry = await rig.call("furniture.prune_unused_definitions")
        #expect(dry.ok, "the dry run only reads")
        let real = await rig.call("furniture.prune_unused_definitions", ["dryRun": false])
        #expect(!real.ok, "deleting needs agent write access")
        #expect(rig.p.definitions.count == 1)
    }

    // MARK: list_definitions

    @Test func listDefinitionsShowsPlacedCountAndFiltersUnused() async {
        let rig = CleanRig()
        let a = await rig.create("A").stringField("id")
        _ = await rig.create("B")
        _ = await rig.place(a)
        _ = await rig.place(a, 2000)
        let all = await rig.ok("furniture.list_definitions", ["builtin": false])
        let rows = all["items"]?.arrayValue ?? []
        #expect(rows.first { $0["name"]?.stringValue == "A" }?["placedCount"]?.int64Value == 2)
        #expect(rows.first { $0["name"]?.stringValue == "B" }?["placedCount"]?.int64Value == 0)
        let unused = await rig.ok("furniture.list_definitions", ["builtin": false, "unused": true])
        let names = (unused["items"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
        #expect(names == ["B"])
    }
}

private extension JSONValue {
    func stringField(_ key: String) -> String { self[key]?.stringValue ?? "" }
}
