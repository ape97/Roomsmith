import Foundation
import Testing
@testable import RoomsmithCore
@testable import RoomsmithIPC

// workspace.* and scene.transfer_objects over a fake workspace of two documents.

@MainActor
private final class FakeWorkspace: AgentWorkspaceBridge {
    struct Tab { var id = UUID(); var store: DocumentStore; var url: URL?; var inCompare = false }
    var tabs: [Tab]
    var activeId: UUID
    var shown: [(UUID, UUID, AgentArrangement?)] = []
    var opened: [URL?] = []
    var closed: [(UUID, Bool)] = []

    init(_ stores: [DocumentStore], urls: [URL?]) {
        tabs = zip(stores, urls).map { Tab(store: $0, url: $1) }
        activeId = tabs[0].id
    }

    func workspaceTabs() -> [AgentWorkspaceTab] {
        tabs.map { AgentWorkspaceTab(id: $0.id, projectId: $0.store.project.id, name: $0.store.project.name, path: $0.url?.path,
                                     dirty: $0.store.isDirty, active: $0.id == activeId, inCompare: $0.inCompare) }
    }
    func workspaceActivate(_ id: UUID) throws { activeId = id }
    func workspaceOpen(_ url: URL?) throws -> UUID {
        opened.append(url)
        let t = Tab(store: DocumentStore(project: Project.empty(name: url?.lastPathComponent ?? "Untitled")), url: url)
        tabs.append(t); activeId = t.id
        return t.id
    }
    func workspaceClose(_ id: UUID, discard: Bool) throws {
        guard let t = tabs.first(where: { $0.id == id }) else { return }
        if t.store.isDirty, !discard {
            throw AgentError(code: AgentError.conflict, message: "unsaved changes")
        }
        closed.append((id, discard))
        tabs.removeAll { $0.id == id }
    }
    func workspaceProject(_ id: UUID) -> Project? { tabs.first { $0.id == id }?.store.project }
    func workspaceShowCompare(left: UUID, right: UUID, arrangement: AgentArrangement?) throws { shown.append((left, right, arrangement)) }
    func workspaceTransfer(ids: [UUID], from source: DocumentStore, to target: UUID, move: Bool, clientId: String) throws -> AgentTransferOutcome {
        guard let src = tabs.first(where: { $0.store === source }), let dst = tabs.first(where: { $0.id == target }) else {
            throw CommandError.invalid("unknown project")
        }
        let options = CommandOptions(origin: .agent(clientId))
        let level = dst.store.project.levels[0].id
        if move {
            let o = try FurnitureTransferService.move(ids: ids, from: src.store, sourcePackage: src.url, to: dst.store, targetPackage: dst.url,
                                                      levelId: level, options: options)
            return AgentTransferOutcome(targetName: dst.store.project.name, newIds: o.newIds, moved: o.sourceRemoved, deleteError: o.deleteError)
        }
        let o = try FurnitureTransferService.copy(ids: ids, from: src.store, sourcePackage: src.url, to: dst.store, targetPackage: dst.url,
                                                  levelId: level, options: options)
        return AgentTransferOutcome(targetName: dst.store.project.name, newIds: o.newIds, moved: false, deleteError: nil)
    }
}

@MainActor
private final class WorkspaceContext: AgentAppContext {
    var selection: Set<UUID> = []
    var activeLevelId: UUID
    var fileURL: URL?
    var appVersion = "test"
    var bridge: FakeWorkspace?
    var workspaceBridge: AgentWorkspaceBridge? { bridge }
    init(activeLevelId: UUID) { self.activeLevelId = activeLevelId }
    func saveForAgent() throws -> String { "/tmp/x.roomsmith" }
}

@MainActor
private struct WorkspaceRig {
    let a: DocumentStore, b: DocumentStore
    let context: WorkspaceContext
    let registry: ToolRegistry
    let workspace: FakeWorkspace

    init(bridge: Bool = true) {
        a = DocumentStore(project: Project.empty(name: "Flat A"))
        b = DocumentStore(project: Project.empty(name: "Flat B"))
        a.agentWriteEnabled = true
        context = WorkspaceContext(activeLevelId: a.project.levels[0].id)
        workspace = FakeWorkspace([a, b], urls: [nil, nil])
        if bridge { context.bridge = workspace }
        registry = ToolRegistry(store: a, context: context)
    }

    func call(_ tool: String, _ args: JSONValue = .object([:])) async -> AgentResponse {
        await registry.call(AgentRequest(id: 1, token: "t", clientId: "test", tool: tool, arguments: args))
    }

    func ok(_ tool: String, _ args: JSONValue = .object([:])) async -> JSONValue {
        let r = await call(tool, args)
        #expect(r.ok, "\(tool) failed: \(r.error?.code ?? "?") \(r.error?.message ?? "")")
        return r.result ?? .null
    }

    /// A one-box design with one instance in A; returns the instance id.
    func addChair() throws -> UUID {
        var iid = UUID()
        try a.run("chair") { p in
            let def = FurnitureDefinition(name: "Chair", category: "Test", size: Size3(400, 400, 900),
                                          components: [Component(name: "seat", shape: .box, position: P3(0, 0, 450), size: Size3(400, 400, 900))])
            p.addDefinition(def)
            iid = try p.addInstance(definitionId: def.id, levelId: p.levels[0].id, position: P3(1000, 1000, 0))
        }
        return iid
    }
}

@MainActor
struct WorkspaceToolTests {
    @Test func listShowsTabsAndActive() async {
        let rig = WorkspaceRig()
        let r = await rig.ok("workspace.list")
        let rows = r["projects"]?.arrayValue ?? []
        #expect(rows.count == 2)
        #expect(rows[0]["name"]?.stringValue == "Flat A")
        #expect(rows[0]["active"]?.boolValue == true)
        #expect(rows[1]["active"]?.boolValue == false)
    }

    @Test func activateAcceptsTabIdAndProjectId() async {
        let rig = WorkspaceRig()
        _ = await rig.ok("workspace.activate", ["projectId": .string(rig.workspace.tabs[1].id.uuidString.lowercased())])
        #expect(rig.workspace.activeId == rig.workspace.tabs[1].id)
        _ = await rig.ok("workspace.activate", ["projectId": .string(rig.a.project.id.uuidString.lowercased())])
        #expect(rig.workspace.activeId == rig.workspace.tabs[0].id)
        let bad = await rig.call("workspace.activate", ["projectId": .string(UUID().uuidString.lowercased())])
        #expect(bad.error?.code == AgentError.notFound)
    }

    @Test func openAndCloseGoThroughTheBridge() async throws {
        let rig = WorkspaceRig()
        let opened = await rig.ok("workspace.open")
        #expect(rig.workspace.opened.count == 1 && rig.workspace.opened[0] == nil)
        #expect(opened["opened"]?.stringValue != nil)
        let missing = await rig.call("workspace.open", ["path": "/nonexistent/x.roomsmith"])
        #expect(missing.error?.code == AgentError.notFound)

        try rig.b.run("dirty") { p in _ = p.addMaterial(Material(name: "m", color: RGBColor(1, 2, 3))) }
        let id = rig.workspace.tabs[1].id.uuidString.lowercased()
        let blocked = await rig.call("workspace.close", ["projectId": .string(id)])
        #expect(blocked.error?.code == AgentError.conflict)
        _ = await rig.ok("workspace.close", ["projectId": .string(id), "discard": true])
        #expect(rig.workspace.closed.count == 1)
    }

    @Test func compareReportsFiguresAndCanShowTheSplit() async throws {
        let rig = WorkspaceRig()
        _ = try rig.addChair()
        try rig.b.run("room") { p in
            _ = try p.addRoom(levelId: p.levels[0].id, name: "Hall",
                              points: [P2(0, 0), P2(4000, 0), P2(4000, 3000), P2(0, 3000)])
        }
        let r = await rig.ok("workspace.compare", ["show": true, "arrangement": "stacked"])
        #expect(r["a"]?["furnitureCount"]?.int64Value == 1)
        #expect(r["b"]?["totalAreaM2"]?.stringValue == "12.00")
        #expect(r["b"]?["rooms"]?.arrayValue?.first?["name"]?.stringValue == "Hall")
        #expect(r["difference"]?["totalAreaM2"]?.stringValue == "12.00")
        #expect(r["difference"]?["furnitureCount"]?.int64Value == -1)
        #expect(rig.workspace.shown.count == 1)
        #expect(rig.workspace.shown[0].2 == .stacked)
    }

    @Test func compareShowNeedsWriteAccessButPlainCompareDoesNot() async throws {
        let rig = WorkspaceRig()
        rig.a.agentWriteEnabled = false
        let shown = await rig.call("workspace.compare", ["show": true])
        #expect(shown.error?.code == AgentError.writeLocked)
        #expect(rig.workspace.shown.isEmpty)
        let plain = await rig.ok("workspace.compare")
        #expect(plain["a"] != nil && rig.workspace.shown.isEmpty)
        rig.a.agentWriteEnabled = true
        _ = await rig.ok("workspace.compare", ["show": true])
        #expect(rig.workspace.shown.count == 1)
    }

    @Test func transferCopiesAndMovesWithOwnUndoSteps() async throws {
        let rig = WorkspaceRig()
        let chair = try rig.addChair()
        let target = rig.workspace.tabs[1].id.uuidString.lowercased()
        let copied = await rig.ok("scene.transfer_objects", ["targetProjectId": .string(target), "ids": [.string(chair.uuidString.lowercased())]])
        #expect(copied["moved"]?.boolValue == false)
        #expect(rig.b.project.instances.count == 1)
        #expect(rig.a.project.instance(chair) != nil)
        #expect(rig.b.undoDepth == 1)

        let moved = await rig.ok("scene.transfer_objects", ["targetProjectId": .string(target), "ids": [.string(chair.uuidString.lowercased())], "move": true])
        #expect(moved["moved"]?.boolValue == true)
        #expect(rig.b.project.instances.count == 2)
        #expect(rig.a.project.instance(chair) == nil)
        #expect(rig.b.undoDepth == 2)
    }

    @Test func transferNeedsWriteAccessAndKnownIds() async throws {
        let rig = WorkspaceRig()
        let chair = try rig.addChair()
        let target = rig.workspace.tabs[1].id.uuidString.lowercased()
        let unknown = await rig.call("scene.transfer_objects", ["targetProjectId": .string(target), "ids": [.string(UUID().uuidString.lowercased())]])
        #expect(unknown.error?.code == AgentError.notFound)
        rig.a.agentWriteEnabled = false
        let locked = await rig.call("scene.transfer_objects", ["targetProjectId": .string(target), "ids": [.string(chair.uuidString.lowercased())]])
        #expect(locked.error?.code == AgentError.writeLocked)
        #expect(rig.b.project.instances.isEmpty)
    }

    @Test func withoutBridgeEverythingIsUnsupported() async {
        let rig = WorkspaceRig(bridge: false)
        for tool in ["workspace.list", "workspace.open", "workspace.compare"] {
            let r = await rig.call(tool)
            #expect(r.error?.code == ExportTools.unsupported, "\(tool)")
        }
    }
}
