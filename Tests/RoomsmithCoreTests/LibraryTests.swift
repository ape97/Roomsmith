import Foundation
import simd
import Testing
@testable import RoomsmithCore

// MARK: - Fixtures

@MainActor
private struct Lab {
    let dir: URL
    let store: LibraryStore
    let project: DocumentStore
    var level: UUID { project.project.levels[0].id }
    var chest = UUID(), instance = UUID(), material = UUID()

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("rs-library-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = LibraryStore(root: dir.appendingPathComponent("Library"))
        project = DocumentStore(project: Project.empty(name: "Lab"))
        var ids = (chest: UUID(), instance: UUID(), material: UUID())
        try project.run("build") { p in
            ids.material = p.addMaterial(Material(name: "Walnut", color: RGBColor(110, 70, 40)))
            var body = Component(name: "body", shape: .box, position: P3(0, 0, 400), size: Size3(1000, 500, 800))
            body.materialId = ids.material
            ids.chest = p.addDefinition(FurnitureDefinition(name: "Chest", category: "Test", size: Size3(1000, 500, 800), components: [body]))
            ids.instance = try p.addInstance(definitionId: ids.chest, levelId: p.levels[0].id, position: P3(2000, 3000, 0))
        }
        chest = ids.chest; instance = ids.instance; material = ids.material
    }

    func pack() throws -> FurnitureTransfer {
        try LibraryContent.pack(project: project.project, ids: [instance], packageURL: nil)
    }
}


@MainActor
private final class LibContext: AgentAppContext {
    var selection: Set<UUID> = []
    var activeLevelId: UUID
    var fileURL: URL?
    var appVersion = "test"
    let libraryRoot: URL
    var libraryBridge: (any AgentLibraryBridge)?
    init(level: UUID, root: URL) { activeLevelId = level; libraryRoot = root }
    func saveForAgent() throws -> String { "/tmp/test.roomsmith" }
}

@MainActor
private struct ToolRig {
    let lab: Lab
    let registry: ToolRegistry
    let context: LibContext
    init(write: Bool = true) throws {
        lab = try Lab()
        lab.project.agentWriteEnabled = write
        context = LibContext(level: lab.level, root: lab.store.root)
        registry = ToolRegistry(store: lab.project, context: context)
    }
    func call(_ tool: String, _ args: JSONValue = .object([:])) async -> AgentResponse {
        await registry.call(AgentRequest(id: 1, token: "t", clientId: "test", tool: tool, arguments: args))
    }
    func ok(_ tool: String, _ args: JSONValue = .object([:])) async -> JSONValue {
        let r = await call(tool, args)
        #expect(r.ok, "\(tool) failed: \(r.error?.code ?? "?") \(r.error?.message ?? "")")
        return r.result ?? .null
    }
}

@MainActor
private final class FakeBridge: AgentLibraryBridge {
    var sizes: [Int] = []
    func renderLibraryThumbnail(_ transfer: FurnitureTransfer, size: Int) async throws -> Data { sizes.append(size); return Data("img\(size)".utf8) }
}

/// A furniture piece with a mesh and a textured material, living in a package on disk (source), plus an empty target package.
@MainActor
private struct AssetLab {
    let dir: URL, sourcePkg: URL, targetPkg: URL
    let source: DocumentStore
    var instance = UUID()

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("rs-liblab-\(UUID().uuidString)")
        sourcePkg = dir.appendingPathComponent("a.roomsmith")
        targetPkg = dir.appendingPathComponent("b.roomsmith")
        for u in [sourcePkg, targetPkg] { try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true) }
        let base = dir
        func file(_ n: String, _ b: String) throws -> URL { let u = base.appendingPathComponent(n); try Data(b.utf8).write(to: u); return u }
        let mesh = try ProjectPackage.importAsset(file("m.usdz", "mesh-bytes"), kind: .mesh, into: sourcePkg)
        let tex = try ProjectPackage.importAsset(file("w.png", "tex-bytes"), kind: .texture, into: sourcePkg)
        let src = DocumentStore(project: Project.empty(name: "Src"))
        var inst = UUID()
        try src.run("build") { p in
            _ = p.addAsset(mesh); _ = p.addAsset(tex)
            var wood = Material(name: "Wood", color: RGBColor(150, 100, 50)); wood.textureAssetId = tex.id
            let mid = p.addMaterial(wood)
            var body = Component(name: "body", shape: .mesh, position: P3(0, 0, 400), size: Size3(1000, 500, 800))
            body.meshAssetId = mesh.id; body.materialId = mid
            let def = p.addDefinition(FurnitureDefinition(name: "Meshy", category: "Test", size: Size3(1000, 500, 800), components: [body]))
            inst = try p.addInstance(definitionId: def, levelId: p.levels[0].id, position: P3(0, 0, 0))
        }
        source = src
        instance = inst
    }
    func pack() throws -> FurnitureTransfer { try LibraryContent.pack(project: source.project, ids: [instance], packageURL: sourcePkg) }
    func files(in pkg: URL) -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: ProjectPackage.assetsDir(pkg).path)) ?? [] }
}

// MARK: - Store

@MainActor
struct LibraryStoreTests {
    @Test func saveLoadDeleteRoundTrip() throws {
        let lab = try Lab()
        let t = try lab.pack()
        let entry = LibraryContent.makeEntry(from: t, name: "My chest", description: "Walnut chest", tags: ["storage"])
        let saved = try lab.store.add(entry, transfer: t)
        #expect(saved.rev == 1)
        #expect(saved.size.width == 1000 && saved.size.height == 800)
        #expect(saved.materialNames == ["Walnut"])

        let reloaded = LibraryStore(root: lab.store.root)
        #expect(reloaded.entries().map(\.name) == ["My chest"])
        #expect(try reloaded.transfer(for: saved.id).instances.count == 1)

        try reloaded.remove(saved.id)
        #expect(reloaded.entries().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: lab.store.root.appendingPathComponent(saved.transferFile).path))
        #expect(throws: LibraryError.self) { try reloaded.transfer(for: saved.id) }
        #expect(throws: LibraryError.self) { try reloaded.remove(saved.id) }
    }

    @Test func emptyFurnitureIsRejected() throws {
        let lab = try Lab()
        let empty = FurnitureTransfer(sourceProjectName: "x", definitions: [], materials: [], products: [], assets: [], instances: [])
        #expect(throws: LibraryError.self) { try lab.store.add(LibraryEntry(name: "x", size: Size3(1, 1, 1)), transfer: empty) }
    }

    @Test func corruptIndexIsMovedAsideNotCrashing() throws {
        let lab = try Lab()
        try FileManager.default.createDirectory(at: lab.store.root, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: lab.store.root.appendingPathComponent("library.json"))
        let load = lab.store.load()
        #expect(load.index.entries.isEmpty)
        #expect(load.warning != nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: lab.store.root.path)
        #expect(names.contains { $0.hasPrefix("library.json.broken") })
        // The library is usable again afterwards.
        let t = try lab.pack()
        _ = try lab.store.add(LibraryContent.makeEntry(from: t), transfer: t)
        #expect(lab.store.entries().count == 1)
    }

    @Test func searchSectionsAndStatus() throws {
        let lab = try Lab()
        let t = try lab.pack()
        let a = try lab.store.add(LibraryContent.makeEntry(from: t, name: "Oak table", description: "Dining", tags: ["kitchen"]), transfer: t)
        let b = try lab.store.add(LibraryContent.makeEntry(from: t, section: .planned, name: "Blue sofa", tags: ["living"]), transfer: t)
        let c = try lab.store.add(LibraryContent.makeEntry(from: t, section: .ai, name: "Lamp"), transfer: t)
        #expect(b.status == .idea)
        #expect(Set(lab.store.search(query: "walnut").map(\.id)) == [a.id, b.id, c.id])  // material name
        #expect(lab.store.search(query: "oak dining").map(\.id) == [a.id])  // all words
        #expect(lab.store.search(query: "oak sofa").isEmpty)
        #expect(lab.store.search(query: "kitchen").map(\.id) == [a.id])  // tags
        #expect(lab.store.search(section: .planned).map(\.id) == [b.id])
        #expect(lab.store.search(status: .idea).map(\.id) == [b.id])
        #expect(lab.store.search(query: "AI").map(\.id) == [c.id])  // section title
    }

    @Test func updateKeepsFurnitureAndReplaceCountsRevUp() throws {
        let lab = try Lab()
        let t = try lab.pack()
        let e = try lab.store.add(LibraryContent.makeEntry(from: t, name: "A"), transfer: t)
        let u = try lab.store.update(e.id) { $0.name = "B"; $0.tags = ["x"] }
        #expect(u.name == "B" && u.rev == 1)
        let r = try lab.store.replaceTransfer(e.id, with: t)
        #expect(r.rev == 2)
        #expect(lab.store.entry(e.id)?.name == "B")
    }

    @Test func photosAreDeduplicatedAndRemovedWithTheirLastEntry() throws {
        let lab = try Lab()
        let t = try lab.pack()
        let n1 = try lab.store.storeAsset(Data("photo".utf8), ext: "JPG")
        let n2 = try lab.store.storeAsset(Data("photo".utf8), ext: "jpg")
        #expect(n1 == n2)
        #expect(lab.store.assetURL(n1) != nil)
        #expect(lab.store.assetURL("../library.json") == nil)
        var e1 = LibraryContent.makeEntry(from: t, name: "One"); e1.photoAssetNames = [n1]
        var e2 = LibraryContent.makeEntry(from: t, name: "Two"); e2.photoAssetNames = [n1]
        let s1 = try lab.store.add(e1, transfer: t), s2 = try lab.store.add(e2, transfer: t)
        try lab.store.remove(s1.id)
        #expect(lab.store.assetURL(n1) != nil)
        try lab.store.remove(s2.id)
        #expect(lab.store.assetURL(n1) == nil)
    }

    @Test func thumbnailIsCachedPerRevision() throws {
        let lab = try Lab()
        let t = try lab.pack()
        let e = try lab.store.add(LibraryContent.makeEntry(from: t), transfer: t)
        #expect(lab.store.thumbnail(e) == nil)
        try lab.store.storeThumbnail(Data("png1".utf8), for: e)
        #expect(lab.store.thumbnail(e) == Data("png1".utf8))
        let r = try lab.store.replaceTransfer(e.id, with: t)
        #expect(lab.store.thumbnail(r) == nil)  // stale after the furniture changed
        try lab.store.storeThumbnail(Data("png2".utf8), for: r)
        #expect(lab.store.thumbnail(r) == Data("png2".utf8))
        #expect(!FileManager.default.fileExists(atPath: lab.store.thumbnailURL(e).path))
    }

    @Test func dragTokenRoundTrips() {
        let id = UUID()
        let token = LibraryDragToken(entryId: id)
        #expect(token.payload == "roomsmith-library:" + id.uuidString.lowercased())
        #expect(LibraryDragToken(payload: token.payload) == token)
        #expect(LibraryDragToken(payload: "roomsmith-furniture:abc") == nil)
        #expect(LibraryDragToken(payload: "roomsmith-library:nope") == nil)
    }

    @Test func definitionOnlyPackNeedsNoInstance() throws {
        let lab = try Lab()
        let t = try LibraryContent.pack(project: lab.project.project, definitionId: lab.chest, packageURL: nil)
        #expect(t.instances.count == 1)
        #expect(t.definitions.count == 1)
        #expect(throws: CommandError.self) { try LibraryContent.pack(project: lab.project.project, definitionId: UUID(), packageURL: nil) }
    }
}

// MARK: - Placing

@MainActor
struct LibraryPlacementTests {
    @Test func placeIsOneUndoStepWithFreshIdsAndLibraryUnchanged() throws {
        let lab = try Lab()
        let t = try lab.pack()
        let e = try lab.store.add(LibraryContent.makeEntry(from: t, name: "Chest"), transfer: t)
        let target = DocumentStore(project: Project.empty(name: "Target"))
        let level = target.project.levels[0].id
        let before = target.project.revision

        let ids = try LibraryPlacement.place(e.id, from: lab.store, into: target, targetPackage: nil, levelId: level, at: P2(5000, 6000))
        #expect(ids.count == 1)
        #expect(!ids.contains(lab.instance))
        let inst = try #require(target.project.instance(ids[0]))
        #expect(inst.position.x == 5000 && inst.position.y == 6000)
        // Fresh ids: neither the source design nor the source material is reused by id.
        #expect(inst.definitionId != lab.chest)
        let def = try #require(target.project.definition(inst.definitionId))
        let matId = try #require(def.components[0].materialId)
        #expect(matId != lab.material)
        #expect(target.project.material(matId)?.name == "Walnut")
        // Library is unchanged and can place again.
        #expect(lab.store.entries().map(\.id) == [e.id])
        #expect(lab.store.entries()[0].rev == e.rev)
        let again = try LibraryPlacement.place(e.id, from: lab.store, into: target, targetPackage: nil, levelId: level, at: P2(0, 0))
        #expect(again != ids)
        #expect(target.project.instances.count == 2)

        try target.undo()
        #expect(target.project.instances.count == 1)
        try target.undo()
        #expect(target.project.instances.isEmpty)
        #expect(target.project.definitions.isEmpty)
        #expect(target.project.revision >= before)
    }

    @Test func placeKeepsTheStoredHeightOfAPieceOnAShelf() throws {
        let lab = try Lab()
        var t = try lab.pack()
        t.instances[0].position.z = 900
        let e = try lab.store.add(LibraryContent.makeEntry(from: t, name: "Shelf item"), transfer: t)
        let target = DocumentStore(project: Project.empty(name: "Target"))
        let ids = try LibraryPlacement.place(e.id, from: lab.store, into: target, targetPackage: nil,
                                             levelId: target.project.levels[0].id, at: P2(5000, 6000))
        let inst = try #require(target.project.instance(ids[0]))
        #expect(inst.position.z == 900)
    }

    @Test func missingEntryThrowsAndChangesNothing() throws {
        let lab = try Lab()
        let target = DocumentStore(project: Project.empty(name: "Target"))
        #expect(throws: LibraryError.self) {
            try LibraryPlacement.place(UUID(), from: lab.store, into: target, targetPackage: nil, levelId: target.project.levels[0].id, at: P2(0, 0))
        }
        #expect(target.project.instances.isEmpty)
    }
}

// MARK: - Tools

@MainActor
struct LibraryToolTests {
    @Test func addListGetUpdateDeleteRoundTrip() async throws {
        let rig = try ToolRig()
        let added = await rig.ok("library.add_from_object", .object([
            "ids": .array([.string(rig.lab.instance.uuidString.lowercased())]), "name": "Chest", "description": "Walnut", "tags": .array(["storage"]),
            "section": "planned",
        ]))
        let id = try #require(added["entry"]?["id"]?.stringValue)
        #expect(added["entry"]?["status"]?.stringValue == "idea")

        let list = await rig.ok("library.list", .object(["query": "walnut storage"]))
        #expect(list["total"]?.int64Value == 1)
        #expect(list["sectionCounts"]?["planned"]?.int64Value == 1)
        #expect(list["sectionCounts"]?["own"]?.int64Value == 0)

        let got = await rig.ok("library.get", .object(["id": .string(id)]))
        #expect(got["definitions"]?.arrayValue?.count == 1)
        #expect(got["pieces"]?.int64Value == 1)

        let upd = await rig.ok("library.update", .object(["id": .string(id), "name": "Big chest", "status": "ordered", "section": "own"]))
        #expect(upd["entry"]?["name"]?.stringValue == "Big chest")
        #expect(upd["entry"]?["status"]?.stringValue == "ordered")
        let cleared = await rig.ok("library.update", .object(["id": .string(id), "status": .null]))
        #expect(cleared["entry"]?["status"]?.isNull == true)

        // The open project was not touched by saving into the library.
        #expect(rig.lab.project.project.instances.count == 1)

        _ = await rig.ok("library.delete", .object(["id": .string(id)]))
        let after = await rig.ok("library.list")
        #expect(after["total"]?.int64Value == 0)
        #expect((await rig.call("library.get", .object(["id": .string(id)]))).error?.code == AgentError.notFound)
    }

    @Test func placeAddsFurnitureWithOneUndoStepAndDryRunChangesNothing() async throws {
        let rig = try ToolRig()
        let t = try rig.lab.pack()
        let e = try rig.lab.store.add(LibraryContent.makeEntry(from: t, name: "Chest"), transfer: t)
        let args: JSONValue = .object(["id": .string(e.id.uuidString.lowercased()), "position": .object(["x": 9000, "y": 9000])])

        var dry = args.objectValue ?? [:]; dry["dryRun"] = true
        _ = await rig.ok("library.place", .object(dry))
        #expect(rig.lab.project.project.instances.count == 1)

        let r = await rig.ok("library.place", args)
        let newId = try #require(r["newIds"]?.arrayValue?.first?.stringValue.flatMap(UUID.init(uuidString:)))
        #expect(rig.lab.project.project.instance(newId)?.position.x == 9000)
        #expect(rig.lab.project.project.instances.count == 2)
        try rig.lab.project.undo()
        #expect(rig.lab.project.project.instances.count == 1)
    }

    @Test func agentAddedEntriesAreAnnounced() async throws {
        let rig = try ToolRig()
        var seen: [UUID] = []
        let token = NotificationCenter.default.addObserver(forName: .roomsmithLibraryAgentAdded, object: nil, queue: nil) { n in
            if let id = n.object as? UUID { seen.append(id) }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        // A UI save (store.add) is silent; the agent tools announce the entry.
        let t = try rig.lab.pack()
        let uiEntry = try rig.lab.store.add(LibraryContent.makeEntry(from: t, section: .own, name: "UI"), transfer: t)
        #expect(seen.isEmpty)
        let added = await rig.ok("library.add_from_object", .object(["ids": .array([.string(rig.lab.instance.uuidString.lowercased())])]))
        let id = try #require(added["entry"]?["id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        #expect(seen == [id])
        var tracker = NewItemTracker()
        for s in seen { tracker.noteAdded([s], origin: .agent("library")) }
        #expect(tracker.contains(id) && !tracker.contains(uiEntry.id))
    }

    @Test func writeToolsNeedWriteAccessReadsDoNot() async throws {
        let rig = try ToolRig(write: false)
        let id = rig.lab.instance.uuidString.lowercased()
        #expect((await rig.call("library.add_from_object", .object(["ids": .array([.string(id)])]))).error?.code == AgentError.writeLocked)
        #expect((await rig.call("library.update", .object(["id": .string(UUID().uuidString.lowercased()), "name": "x"]))).error?.code == AgentError.writeLocked)
        #expect((await rig.call("library.delete", .object(["id": .string(UUID().uuidString.lowercased())]))).error?.code == AgentError.writeLocked)
        _ = await rig.ok("library.list")
    }

    @Test func invalidInputsAreReported() async throws {
        let rig = try ToolRig()
        #expect((await rig.call("library.add_from_object", .object([:]))).ok == false)
        #expect((await rig.call("library.add_from_object", .object(["ids": .array([.string(UUID().uuidString.lowercased())])]))).ok == false)
        #expect((await rig.call("library.update", .object(["id": .string(UUID().uuidString.lowercased())]))).ok == false)
        #expect((await rig.call("library.list", .object(["section": "nope"]))).ok == false)
    }

    @Test func thumbnailWithoutWindowIsUnsupportedUnlessCached() async throws {
        let rig = try ToolRig()
        let t = try rig.lab.pack()
        let e = try rig.lab.store.add(LibraryContent.makeEntry(from: t), transfer: t)
        let args: JSONValue = .object(["id": .string(e.id.uuidString.lowercased())])
        #expect((await rig.call("library.thumbnail", args)).error?.code == ExportTools.unsupported)
        try rig.lab.store.storeThumbnail(Data("png".utf8), for: e)
        let r = await rig.ok("library.thumbnail", args)
        #expect(r["cached"]?.boolValue == true)
        #expect(r["image"]?["base64"]?.stringValue == Data("png".utf8).base64EncodedString())
    }
}


// MARK: - Review fixes

@MainActor
struct LibraryRobustnessTests {
    private func indexURL(_ lab: Lab) -> URL { lab.store.root.appendingPathComponent("library.json") }

    @Test func brokenIndexKeepsItsContent() throws {
        let lab = try Lab()
        try FileManager.default.createDirectory(at: lab.store.root, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: indexURL(lab))
        _ = lab.store.load()
        let kept = lab.store.root.appendingPathComponent("library.json.broken-1")
        #expect(try String(contentsOf: kept, encoding: .utf8) == "{ not json")
    }

    @Test func newerIndexVersionIsKeptAside() throws {
        let lab = try Lab()
        try FileManager.default.createDirectory(at: lab.store.root, withIntermediateDirectories: true)
        try Data(#"{"version": 99, "entries": []}"#.utf8).write(to: indexURL(lab))
        let load = lab.store.load()
        #expect(load.warning?.contains("newer") == true)
        #expect(FileManager.default.fileExists(atPath: lab.store.root.appendingPathComponent("library.json.broken-1").path))
    }

    @Test func unreadableIndexIsNeverOverwritten() throws {
        let lab = try Lab()
        // A folder where the index file should be: it exists but cannot be read.
        try FileManager.default.createDirectory(at: indexURL(lab), withIntermediateDirectories: true)
        #expect(lab.store.load().warning != nil)
        let t = try lab.pack()
        #expect(throws: LibraryError.self) { try lab.store.add(LibraryContent.makeEntry(from: t), transfer: t) }
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: indexURL(lab).path, isDirectory: &isDir) && isDir.boolValue)
    }

    @Test func failedBackUpAbortsWritesAndKeepsTheFile() throws {
        let lab = try Lab()
        try FileManager.default.createDirectory(at: lab.store.root, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: indexURL(lab))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lab.store.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lab.store.root.path) }
        let t = try lab.pack()
        #expect(throws: LibraryError.self) { try lab.store.add(LibraryContent.makeEntry(from: t), transfer: t) }
        #expect(try String(contentsOf: indexURL(lab), encoding: .utf8) == "{ not json")
    }

    @Test func unsafeAssetNamesAreNeverTouched() throws {
        let lab = try Lab()
        #expect(LibraryStore.isSafeAssetName("ab12.png"))
        for bad in ["../library.json", "a/b.png", ".hidden", "AB.png", "ab", "ab.", "ab.p.ng", ""] { #expect(!LibraryStore.isSafeAssetName(bad), "\(bad)") }
        #expect(lab.store.assetURL("../library.json") == nil)
        let t = try lab.pack()
        let added = try lab.store.add(LibraryEntry(name: "x", size: Size3(1, 1, 1), photoAssetNames: ["../library.json", "ab12.png"]), transfer: t)
        #expect(added.photoAssetNames == ["ab12.png"])
        // An index written by hand with a traversal name must not delete files outside the library on remove.
        let victim = lab.store.root.deletingLastPathComponent().appendingPathComponent("victim.json")
        try Data("keep".utf8).write(to: victim)
        var idx = lab.store.load().index
        idx.entries[0].photoAssetNames = ["../../victim.json"]
        try lab.store.save(idx)
        try lab.store.remove(added.id)
        #expect(FileManager.default.fileExists(atPath: victim.path))
        // update drops unsafe names too.
        let again = try lab.store.add(LibraryEntry(name: "y", size: Size3(1, 1, 1)), transfer: t)
        let u = try lab.store.update(again.id) { $0.photoAssetNames = ["../x.png", "cd34.jpg"] }
        #expect(u.photoAssetNames == ["cd34.jpg"])
    }

    @Test func entryRoundTripKeepsSpecAndPhotos() throws {
        var params = BuilderParams(); params.shelves = 5
        let e = LibraryEntry(name: "Shelf", size: Size3(800, 300, 1800), spec: ParametricSpec(template: .shelf, params: params), photoAssetNames: ["ab12.png"])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(LibraryEntry.self, from: enc.encode(e))
        #expect(back.spec == e.spec)
        #expect(back.photoAssetNames == ["ab12.png"])
        #expect(back.spec?.params.shelves == 5)
    }

    @Test func damagedSpecBecomesNilNotAWholeLibraryFailure() throws {
        let lab = try Lab()
        let t = try lab.pack()
        let e = try lab.store.add(LibraryContent.makeEntry(from: t, name: "Keep"), transfer: t)
        var text = try String(contentsOf: indexURL(lab), encoding: .utf8)
        text = text.replacingOccurrences(of: "\"rev\" : 1", with: "\"rev\" : 1,\n      \"spec\" : { \"template\": \"nonsense\", \"params\": 7 }")
        try Data(text.utf8).write(to: indexURL(lab))
        let load = lab.store.load()
        #expect(load.warning == nil)
        #expect(load.index.entries.map(\.id) == [e.id])
        #expect(load.index.entries[0].spec == nil)
    }

    @Test func builderParamsDecodeWithMissingKeys() throws {
        let p = try JSONDecoder().decode(BuilderParams.self, from: Data(#"{"shelves": 7}"#.utf8))
        #expect(p.shelves == 7)
        #expect(p.width == BuilderParams().width)
        #expect(p.materialId == BuilderParams().materialId)
    }

    @Test func builderParamsWithoutMaterialStayWithoutMaterialAfterRoundTrip() throws {
        #expect(BuilderParams().materialId != nil, "the default is a real material (Oak)")
        var none = BuilderParams(); none.materialId = nil; none.shelves = 3
        let back = try JSONDecoder().decode(BuilderParams.self, from: JSONEncoder().encode(none))
        #expect(back.materialId == nil)
        #expect(back == none)
        // explicit null in the JSON means "no material"; a missing key still means the default
        let nulled = try JSONDecoder().decode(BuilderParams.self, from: Data(#"{"materialId": null}"#.utf8))
        #expect(nulled.materialId == nil)
        let missing = try JSONDecoder().decode(BuilderParams.self, from: Data(#"{"shelves": 3}"#.utf8))
        #expect(missing.materialId == BuilderParams().materialId)
        // a set material survives too
        var set = BuilderParams(); set.materialId = UUID()
        #expect(try JSONDecoder().decode(BuilderParams.self, from: JSONEncoder().encode(set)).materialId == set.materialId)
    }

    @Test func newerThumbnailSurvivesAnOlderStore() throws {
        let lab = try Lab()
        let t = try lab.pack()
        let e = try lab.store.add(LibraryContent.makeEntry(from: t), transfer: t)
        var newer = e; newer.rev = 2
        try lab.store.storeThumbnail(Data("new".utf8), for: newer)
        try lab.store.storeThumbnail(Data("old".utf8), for: e)
        #expect(lab.store.thumbnail(newer) == Data("new".utf8))
        #expect(lab.store.thumbnail(e) == Data("old".utf8))
        var third = e; third.rev = 3
        try lab.store.storeThumbnail(Data("3".utf8), for: third)
        #expect(lab.store.thumbnail(e) == nil && lab.store.thumbnail(newer) == nil)
    }

    @Test func transferForMissingOrDamagedFile() throws {
        let lab = try Lab()
        #expect(throws: LibraryError.notFound(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)) {
            try lab.store.transfer(for: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        }
        let t = try lab.pack()
        let e = try lab.store.add(LibraryContent.makeEntry(from: t), transfer: t)
        try Data("garbage".utf8).write(to: lab.store.root.appendingPathComponent(e.transferFile))
        #expect(throws: LibraryError.self) { try lab.store.transfer(for: e.id) }
        try FileManager.default.removeItem(at: lab.store.root.appendingPathComponent(e.transferFile))
        #expect(throws: LibraryError.self) { try lab.store.transfer(for: e.id) }
    }

    @Test func replaceTransferRefreshesSizeAndRev() throws {
        let lab = try Lab()
        let t = try lab.pack()
        var made = LibraryContent.makeEntry(from: t)
        made.spec = ParametricSpec(template: .shelf, params: BuilderParams())
        let e = try lab.store.add(made, transfer: t)
        #expect(e.spec != nil)
        try lab.project.run("big") { p in
            let d = p.addDefinition(FurnitureDefinition(name: "Big", category: "T", size: Size3(3000, 500, 800),
                                                        components: [Component(name: "b", shape: .box, position: P3(0, 0, 400), size: Size3(3000, 500, 800))]))
            _ = try p.addInstance(definitionId: d, levelId: p.levels[0].id, position: P3(0, 0, 0))
        }
        let big = try #require(lab.project.project.instances.last)
        let r = try lab.store.replaceTransfer(e.id, with: LibraryContent.pack(project: lab.project.project, ids: [big.id], packageURL: nil))
        #expect(r.rev == 2 && r.size.width == 3000)
        #expect(r.spec == nil)   // the old recipe no longer describes the stored piece
    }
}

@MainActor
struct LibraryAssetToolTests {
    @Test func placeWithAssetsNeedsSavedProjectThenCopiesFilesAndRemapsIds() async throws {
        let rig = try ToolRig()
        let a = try AssetLab()
        let t = try a.pack()
        let e = try rig.lab.store.add(LibraryContent.makeEntry(from: t, name: "Meshy"), transfer: t)
        let args: [String: JSONValue] = ["id": .string(e.id.uuidString.lowercased()), "position": .object(["x": 500, "y": 500])]

        let unsaved = await rig.call("library.place", .object(args))
        #expect(!unsaved.ok)
        #expect(rig.lab.project.project.instances.count == 1)

        rig.context.fileURL = a.targetPkg
        var dry = args; dry["dryRun"] = true
        _ = await rig.ok("library.place", .object(dry))
        #expect(a.files(in: a.targetPkg).isEmpty, "dry run must not leave staged files")
        #expect(rig.lab.project.project.instances.count == 1)

        let r = await rig.ok("library.place", .object(args))
        let newId = try #require(r["newIds"]?.arrayValue?.first?.stringValue.flatMap(UUID.init(uuidString:)))
        #expect(newId != a.instance)
        let p = rig.lab.project.project
        #expect(p.instance(newId) != nil)
        #expect(!a.files(in: a.targetPkg).isEmpty)
        for asset in p.assets { #expect(FileManager.default.fileExists(atPath: ProjectPackage.assetURL(asset, in: a.targetPkg).path)) }
        #expect(p.assets.allSatisfy { $0.id != a.source.project.assets.first?.id })
    }

    @Test func placeWithUnknownLevelFailsBeforeStagingAnything() async throws {
        let rig = try ToolRig()
        let a = try AssetLab()
        let t = try a.pack()
        let e = try rig.lab.store.add(LibraryContent.makeEntry(from: t), transfer: t)
        rig.context.fileURL = a.targetPkg
        let r = await rig.call("library.place", .object(["id": .string(e.id.uuidString.lowercased()), "position": .object(["x": 0, "y": 0]),
                                                         "levelId": .string(UUID().uuidString.lowercased())]))
        #expect(!r.ok)
        #expect(a.files(in: a.targetPkg).isEmpty)
        #expect(rig.lab.project.project.instances.count == 1)
    }

    @Test func thumbnailToolIsNotAdvertisedAsReadOnly() throws {
        // It writes the thumbnail cache and, with `path`, a file, so clients must not treat it as a pure read.
        let rig = try ToolRig()
        let d = try #require(rig.registry.descriptors.first { $0.name == "library.thumbnail" })
        #expect(!d.readOnly)
    }

    @Test func thumbnailOfOtherSizeIsNotCachedAndDefaultIs() async throws {
        let rig = try ToolRig()
        let bridge = FakeBridge()
        rig.context.libraryBridge = bridge
        let t = try rig.lab.pack()
        let e = try rig.lab.store.add(LibraryContent.makeEntry(from: t), transfer: t)
        let id: JSONValue = .string(e.id.uuidString.lowercased())
        let small = await rig.ok("library.thumbnail", .object(["id": id, "size": 128]))
        #expect(small["cached"]?.boolValue == false)
        #expect(rig.lab.store.thumbnail(e) == nil)
        let def = await rig.ok("library.thumbnail", .object(["id": id]))
        #expect(def["cached"]?.boolValue == false)
        #expect(rig.lab.store.thumbnail(e) == Data("img\(LibraryStore.thumbnailPixels)".utf8))
        // Cache present, other size asked: rendered fresh, cache untouched.
        let again = await rig.ok("library.thumbnail", .object(["id": id, "size": 64]))
        #expect(again["cached"]?.boolValue == false)
        #expect(rig.lab.store.thumbnail(e) == Data("img\(LibraryStore.thumbnailPixels)".utf8))
        #expect(bridge.sizes == [128, LibraryStore.thumbnailPixels, 64])
    }

    @Test func updateFromObjectReplacesFurnitureAndCountsRevUp() async throws {
        let rig = try ToolRig()
        let t = try rig.lab.pack()
        let e = try rig.lab.store.add(LibraryContent.makeEntry(from: t), transfer: t)
        var bigId = UUID()
        try rig.lab.project.run("big") { p in
            let d = p.addDefinition(FurnitureDefinition(name: "Big", category: "T", size: Size3(3000, 500, 800),
                                                        components: [Component(name: "b", shape: .box, position: P3(0, 0, 400), size: Size3(3000, 500, 800))]))
            bigId = try p.addInstance(definitionId: d, levelId: p.levels[0].id, position: P3(0, 0, 0))
        }
        let r = await rig.ok("library.update", .object(["id": .string(e.id.uuidString.lowercased()), "fromObjectId": .string(bigId.uuidString.lowercased())]))
        #expect(r["entry"]?["rev"]?.int64Value == 2)
        #expect(r["entry"]?["size"]?["width"]?.int64Value == 3000)
        #expect(try rig.lab.store.transfer(for: e.id).definitions.first?.name == "Big")
        let bad = await rig.call("library.update", .object(["id": .string(e.id.uuidString.lowercased()), "fromObjectId": .string(UUID().uuidString.lowercased())]))
        #expect(!bad.ok)
    }
}

// MARK: - Categories (My Furniture)

@MainActor
struct LibraryCategoryTests {
    private func add(_ lab: Lab, name: String? = nil, category: UUID? = nil) throws -> LibraryEntry {
        let t = try lab.pack()
        return try lab.store.add(LibraryContent.makeEntry(from: t, name: name, categoryId: category), transfer: t)
    }

    private let v1Index = """
    {"version": 1, "entries": [{"id": "11111111-1111-1111-1111-111111111111", "section": "own", "name": "Old chest",
      "size": {"width": 1000, "depth": 500, "height": 800}, "rev": 3, "createdAt": "2024-05-01T10:00:00Z"}]}
    """

    @Test func versionOneFileWithoutCategoriesLoadsAndStaysVersionOne() throws {
        let lab = try Lab()
        try FileManager.default.createDirectory(at: lab.store.root, withIntermediateDirectories: true)
        try Data(v1Index.utf8).write(to: lab.store.root.appendingPathComponent("library.json"))
        let load = lab.store.load()
        #expect(load.warning == nil)
        #expect(load.index.entries.count == 1 && load.index.categories.isEmpty)
        #expect(load.index.entries[0].categoryId == nil && load.index.entries[0].rev == 3)
        let c = try lab.store.createCategory(name: "Chairs")
        let again = lab.store.load().index
        #expect(again.version == 1 && again.entries.count == 1 && again.categories.map(\.id) == [c.id])
        #expect(!FileManager.default.fileExists(atPath: lab.store.root.appendingPathComponent("library.json.broken-1").path))
    }

    @Test func damagedCategoryIsSkippedAndNeverHidesTheFurniture() throws {
        let lab = try Lab()
        try FileManager.default.createDirectory(at: lab.store.root, withIntermediateDirectories: true)
        let good = "{\"id\": \"22222222-2222-2222-2222-222222222222\", \"name\": \"Tables\", \"order\": 1}"
        let json = v1Index.replacingOccurrences(of: "\"entries\"", with: "\"categories\": [{\"name\": 5}, \(good), \"x\"], \"entries\"")
        try Data(json.utf8).write(to: lab.store.root.appendingPathComponent("library.json"))
        let load = lab.store.load()
        #expect(load.warning?.contains("library.json.broken-1") == true && load.index.entries.count == 1)
        #expect(load.index.categories.map(\.name) == ["Tables"])
        // A categories value of the wrong type is ignored as a whole, and reported.
        let wrong = v1Index.replacingOccurrences(of: "\"entries\"", with: "\"categories\": 7, \"entries\"")
        try Data(wrong.utf8).write(to: lab.store.root.appendingPathComponent("library.json"))
        let wrongLoad = lab.store.load()
        #expect(wrongLoad.index.entries.count == 1 && wrongLoad.index.categories.isEmpty && wrongLoad.warning != nil)
    }

    @Test func damagedEntryIsSkippedButTheRawFileIsCopiedAndReported() throws {
        let lab = try Lab()
        try FileManager.default.createDirectory(at: lab.store.root, withIntermediateDirectories: true)
        let good = """
        {"id": "33333333-3333-3333-3333-333333333333", "section": "own", "name": "Good",
         "size": {"width": 1000, "depth": 500, "height": 800}, "rev": 1, "createdAt": "2024-05-01T10:00:00Z"}
        """
        let json = "{\"version\": 1, \"entries\": [{\"name\": 5}, \(good), \"x\"]}"
        let indexFile = lab.store.root.appendingPathComponent("library.json")
        try Data(json.utf8).write(to: indexFile)
        let load = lab.store.load()
        #expect(load.warning?.contains("2 damaged") == true && load.warning?.contains("library.json.broken-1") == true)
        #expect(load.index.entries.map(\.name) == ["Good"])
        // The index itself stays; the copy holds the original bytes, so the damaged items' metadata is not lost.
        #expect(try Data(contentsOf: indexFile) == Data(json.utf8))
        let copy = lab.store.root.appendingPathComponent("library.json.broken-1")
        #expect(try Data(contentsOf: copy) == Data(json.utf8))
        // Loading the same damaged file again reuses the copy.
        _ = lab.store.load()
        #expect(!FileManager.default.fileExists(atPath: lab.store.root.appendingPathComponent("library.json.broken-2").path))
        // A writer copies first, then saves without the damaged items.
        _ = try lab.store.createCategory(name: "Chairs")
        #expect(try Data(contentsOf: copy) == Data(json.utf8))
        #expect(lab.store.load().warning == nil)
    }

    @Test func twoStoresOnTheSameFolderStayConsistent() throws {
        let lab = try Lab()
        let other = LibraryStore(root: lab.store.root)
        let t = try lab.pack()
        let a = try lab.store.add(LibraryContent.makeEntry(from: t), transfer: t)
        let b = try other.add(LibraryContent.makeEntry(from: t), transfer: t)
        let c = try lab.store.createCategory(name: "Chairs")
        try other.update(a.id) { $0.categoryId = c.id }
        _ = try lab.store.replaceTransfer(b.id, with: t)
        let copy = try other.duplicate(a.id)
        try lab.store.remove(b.id)
        let idx = other.load().index
        #expect(Set(idx.entries.map(\.id)) == [a.id, copy.id])
        #expect(idx.entries.first { $0.id == a.id }?.categoryId == c.id)
        #expect(idx.categories.map(\.id) == [c.id])
        // The lock file lives in the library folder and nothing else is left over.
        #expect(FileManager.default.fileExists(atPath: lab.store.root.appendingPathComponent("library.json.lock").path))
        #expect(!FileManager.default.fileExists(atPath: lab.store.transferURL(b).path))
    }

    @Test func failedIndexWriteRestoresTheOldFurnitureOnReplace() throws {
        let lab = try Lab()
        let t = try lab.pack()
        let e = try lab.store.add(LibraryContent.makeEntry(from: t), transfer: t)
        let before = try Data(contentsOf: lab.store.transferURL(e))
        // A read-only library folder: the index can be read and entries/ is still writable, but the new index cannot be
        // written (atomic replace needs a temporary file next to it).
        var bigger = t
        bigger.sourceProjectName = "changed"
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lab.store.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lab.store.root.path) }
        #expect(throws: LibraryError.self) { try lab.store.replaceTransfer(e.id, with: bigger) }
        #expect(try Data(contentsOf: lab.store.transferURL(e)) == before)
        #expect(lab.store.entry(e.id)?.rev == 1)
    }

    @Test func categoryCrudOrderAndNameRules() throws {
        let lab = try Lab()
        let a = try lab.store.createCategory(name: "  Chairs ")
        let b = try lab.store.createCategory(name: "Tables")
        let c = try lab.store.createCategory(name: "Lamps")
        #expect(a.name == "Chairs" && [a.order, b.order, c.order] == [0, 1, 2])
        #expect(throws: LibraryError.self) { try lab.store.createCategory(name: "   ") }
        #expect(throws: LibraryError.self) { try lab.store.createCategory(name: "chairs") }
        #expect(throws: LibraryError.self) { try lab.store.renameCategory(b.id, to: "CHAIRS") }
        _ = try lab.store.renameCategory(a.id, to: "Chairs")   // its own name again is fine
        let renamed = try lab.store.renameCategory(b.id, to: "Desks")
        #expect(renamed.name == "Desks")
        _ = try lab.store.reorderCategories([c.id, a.id, b.id])
        #expect(lab.store.categories().map(\.name) == ["Lamps", "Chairs", "Desks"])
        #expect(throws: LibraryError.self) { try lab.store.reorderCategories([a.id, b.id]) }
        #expect(throws: LibraryError.self) { try lab.store.reorderCategories([a.id, a.id, b.id]) }
        #expect(throws: LibraryError.self) { try lab.store.reorderCategories([a.id, b.id, UUID()]) }
        #expect(lab.store.categories().map(\.name) == ["Lamps", "Chairs", "Desks"])
        _ = try lab.store.moveCategory(a.id, by: -1)
        #expect(lab.store.categories().map(\.name) == ["Chairs", "Lamps", "Desks"])
        _ = try lab.store.moveCategory(a.id, by: -1)   // at the top already
        #expect(lab.store.categories().first?.id == a.id)
    }

    @Test func entriesLiveInCategoriesAndDanglingIdsCountAsUnsorted() throws {
        let lab = try Lab()
        let cat = try lab.store.createCategory(name: "Chairs")
        let inCat = try add(lab, name: "Armchair", category: cat.id)
        let loose = try add(lab, name: "Stool")
        #expect(throws: LibraryError.self) { try add(lab, name: "Ghost", category: UUID()) }
        #expect(lab.store.search(category: .category(cat.id)).map(\.id) == [inCat.id])
        #expect(lab.store.search(category: .unsorted).map(\.id) == [loose.id])
        #expect(lab.store.search(query: "chairs").map(\.id) == [inCat.id])   // the category name is searchable
        #expect(throws: LibraryError.self) { try lab.store.move(loose.id, toCategory: UUID()) }
        #expect(try lab.store.move(loose.id, toCategory: cat.id).categoryId == cat.id)
        #expect(try lab.store.move(loose.id, toCategory: nil).categoryId == nil)
        // A category id that no category has anymore reads as Unsorted, and an unrelated edit does not trip over it.
        var idx = lab.store.load().index
        idx.entries[0].categoryId = UUID()
        try lab.store.save(idx)
        let dangling = lab.store.load().index
        #expect(dangling.effectiveCategoryId(dangling.entries[0]) == nil)
        #expect(lab.store.search(category: .unsorted).count == 2)
        _ = try lab.store.update(dangling.entries[0].id) { $0.name = "Renamed" }
    }

    @Test func deleteCategoryMovesEntriesAndRejectsBadTargets() throws {
        let lab = try Lab()
        let a = try lab.store.createCategory(name: "A"), b = try lab.store.createCategory(name: "B"), c = try lab.store.createCategory(name: "C")
        let e1 = try add(lab, category: a.id), e2 = try add(lab, category: a.id)
        #expect(throws: LibraryError.self) { try lab.store.deleteCategory(a.id, moveTo: a.id) }
        #expect(throws: LibraryError.self) { try lab.store.deleteCategory(a.id, moveTo: UUID()) }
        #expect(lab.store.categories().count == 3 && lab.store.entry(e1.id)?.categoryId == a.id)
        try lab.store.deleteCategory(a.id, moveTo: b.id)
        #expect(lab.store.entry(e1.id)?.categoryId == b.id && lab.store.entry(e2.id)?.categoryId == b.id)
        #expect(lab.store.categories().map(\.order) == [0, 1])
        try lab.store.deleteCategory(b.id)
        #expect(lab.store.entry(e1.id)?.categoryId == nil && lab.store.entries().count == 2)
        #expect(lab.store.categories().map(\.id) == [c.id])
        #expect(throws: LibraryError.self) { try lab.store.deleteCategory(b.id) }
    }

    @Test func duplicateCopiesFurnitureThumbnailAndSharesPhotos() throws {
        let lab = try Lab()
        let cat = try lab.store.createCategory(name: "Chairs")
        let t = try lab.pack()
        let photo = try lab.store.storeAsset(Data("photo".utf8), ext: "png")
        var meta = LibraryContent.makeEntry(from: t, name: "Armchair", categoryId: cat.id)
        meta.photoAssetNames = [photo]
        let src = try lab.store.add(meta, transfer: t)
        try lab.store.storeThumbnail(Data("png1".utf8), for: src)
        let copy = try lab.store.duplicate(src.id)
        #expect(copy.id != src.id && copy.name == "Armchair 2" && copy.rev == 1 && copy.categoryId == cat.id)
        #expect(lab.store.thumbnailURL(copy).lastPathComponent == "\(copy.id.uuidString.lowercased())-1.png")
        #expect(lab.store.thumbnail(copy) == Data("png1".utf8))
        #expect(try lab.store.transfer(for: copy.id) == lab.store.transfer(for: src.id))
        #expect(try lab.store.duplicate(src.id).name == "Armchair 3")
        #expect(try lab.store.duplicate(copy.id).name == "Armchair 4")   // "Armchair 2" -> next free number of the base name
        // A trailing number is never cut back: "Shelf 3" becomes "Shelf 4", not "Shelf 2".
        let shelf = try lab.store.add(LibraryContent.makeEntry(from: t, name: "Shelf 3"), transfer: t)
        #expect(try lab.store.duplicate(shelf.id).name == "Shelf 4")
        #expect(try lab.store.duplicate(shelf.id).name == "Shelf 5")
        // Deleting a copy keeps the photo the original still uses.
        try lab.store.remove(copy.id)
        #expect(lab.store.assetURL(photo) != nil)
        #expect(lab.store.thumbnail(copy) == nil && lab.store.entry(src.id) != nil)
        #expect(throws: LibraryError.self) { try lab.store.duplicate(UUID()) }
    }

    @Test func replaceTransferKeepsOrDropsTheSpec() throws {
        let lab = try Lab()
        let t = try lab.pack()
        let spec = ParametricSpec(template: .box, params: BuilderParams())
        let e = try lab.store.add(LibraryContent.makeEntry(from: t, spec: spec), transfer: t)
        #expect(try lab.store.replaceTransfer(e.id, with: t).spec == nil)
        #expect(try lab.store.replaceTransfer(e.id, with: t, spec: spec).spec == spec)
    }

    @Test func savingSceneObjectsCreatesAnEntryInTheCategory() throws {
        let lab = try Lab()
        let cat = try lab.store.createCategory(name: "Chests")
        let e = try LibraryContent.save(project: lab.project.project, ids: [lab.instance, UUID()], packageURL: nil,
                                        into: lab.store, categoryId: cat.id)
        #expect(e.categoryId == cat.id && e.name == "Chest" && lab.store.entries().count == 1)
        #expect(throws: LibraryError.self) { try LibraryContent.save(project: lab.project.project, ids: [UUID()], packageURL: nil, into: lab.store) }
        #expect(throws: LibraryError.self) {
            try LibraryContent.save(project: lab.project.project, ids: [lab.instance], packageURL: nil, into: lab.store, categoryId: UUID())
        }
        #expect(lab.store.entries().count == 1)
    }

    @Test func catalogPieceBecomesATransfer() throws {
        let first = try #require(BuiltinCatalog.entries.first)
        let t = try LibraryContent.transfer(fromCatalog: first.key)
        #expect(!t.isEmpty && t.instances.count == 1 && !t.definitions.isEmpty)
        #expect(throws: CommandError.self) { try LibraryContent.transfer(fromCatalog: "no-such-piece") }
        let lab = try Lab()
        let e = try lab.store.add(LibraryContent.makeEntry(from: t), transfer: t)
        #expect(e.name == first.name)
    }
}

// MARK: - Category tools (handlers called directly; they join the registry with the final tool-count change)

@MainActor
struct LibraryCategoryToolTests {
    private let lab: Lab
    private let env: ToolEnv
    private let registry: ToolRegistry

    init(write: Bool = true) throws {
        lab = try Lab()
        lab.project.agentWriteEnabled = write
        let ctx = LibContext(level: lab.level, root: lab.store.root)
        registry = ToolRegistry(store: lab.project, context: ctx)
        env = ToolEnv(store: lab.project, context: ctx, clientId: "test", registry: registry)
    }

    private func call(_ spec: ToolSpec, _ json: JSONValue) throws -> JSONValue {
        let args = try registry.prepareArgs(spec, json, extraKeys: ToolSpec.commonKeys)
        switch spec.handler {
        case .action(let h), .read(let h): return try h(env, args)
        default: fatalError("action or read tool expected")
        }
    }
    private func id(_ u: UUID) -> JSONValue { .string(u.uuidString.lowercased()) }
    private func fails(_ spec: ToolSpec, _ json: JSONValue) -> String? {
        do { _ = try call(spec, json); return nil } catch let e as AgentError { return e.code } catch { return "\(error)" }
    }

    @Test func specsAreNamedAndRegistered() {
        #expect(LibraryTools.categorySpecs().map(\.name) == ["library.create_category", "library.update_category", "library.delete_category", "library.duplicate"])
        let registered = Set(LibraryTools.specs().map(\.name))
        #expect(registered.isSuperset(of: LibraryTools.categorySpecs().map(\.name)))
    }

    @Test func createUpdateDeleteCategoryThroughTheTools() throws {
        let create = LibraryTools.createCategory(), update = LibraryTools.updateCategory(), delete = LibraryTools.deleteCategory()
        let a = try call(create, .object(["name": "Chairs"]))["category"]
        let b = try call(create, .object(["name": "Tables"]))["category"]
        let aId = try #require(a?["id"]?.stringValue.flatMap(UUID.init)), bId = try #require(b?["id"]?.stringValue.flatMap(UUID.init))
        #expect(fails(create, .object(["name": "chairs"])) != nil)
        #expect(fails(create, .object(["name": "  "])) != nil)
        #expect(fails(create, .object(["name": "X", "nope": true])) != nil)
        let moved = try call(update, .object(["id": id(bId), "position": 0, "name": "Desks"]))
        #expect(moved["categories"]?.arrayValue?.compactMap { $0["name"]?.stringValue } == ["Desks", "Chairs"])
        #expect(fails(update, .object(["id": id(bId)])) != nil)
        #expect(fails(update, .object(["id": id(UUID()), "name": "Z"])) == AgentError.notFound)
        #expect(fails(update, .object(["id": id(bId), "position": -1])) != nil)
        // Entries move on delete.
        let t = try lab.pack()
        let e = try lab.store.add(LibraryContent.makeEntry(from: t, categoryId: aId), transfer: t)
        #expect(fails(delete, .object(["id": id(aId), "moveTo": id(aId)])) != nil)
        #expect(fails(delete, .object(["id": id(aId), "moveTo": id(UUID())])) != nil)
        #expect(lab.store.entry(e.id)?.categoryId == aId)
        let r = try call(delete, .object(["id": id(aId), "moveTo": id(bId)]))
        #expect(r["name"]?.stringValue == "Chairs" && lab.store.entry(e.id)?.categoryId == bId)
        _ = try call(delete, .object(["id": id(bId)]))
        #expect(lab.store.entry(e.id)?.categoryId == nil && lab.store.categories().isEmpty)
        #expect(fails(delete, .object(["id": id(bId)])) == AgentError.notFound)
    }

    @Test func writeLockBlocksEveryCategoryTool() throws {
        let locked = try LibraryCategoryToolTests(write: false)
        let t = try locked.lab.pack()
        let e = try locked.lab.store.add(LibraryContent.makeEntry(from: t), transfer: t)
        let cases: [(ToolSpec, JSONValue)] = [
            (LibraryTools.createCategory(), .object(["name": "A"])),
            (LibraryTools.updateCategory(), .object(["id": locked.id(UUID()), "name": "A"])),
            (LibraryTools.deleteCategory(), .object(["id": locked.id(UUID())])),
            (LibraryTools.duplicate(), .object(["id": locked.id(e.id)])),
            (LibraryTools.update(), .object(["id": locked.id(e.id), "categoryId": .null])),
        ]
        for (spec, args) in cases { #expect(locked.fails(spec, args) != nil, "\(spec.name)") }
        #expect(locked.lab.store.entries().count == 1 && locked.lab.store.categories().isEmpty)
    }

    @Test func duplicateTool() throws {
        let t = try lab.pack()
        let e = try lab.store.add(LibraryContent.makeEntry(from: t, name: "Chest"), transfer: t)
        let r = try call(LibraryTools.duplicate(), .object(["id": id(e.id)]))["entry"]
        #expect(r?["name"]?.stringValue == "Chest 2" && r?["rev"]?.int64Value == 1)
        #expect(lab.store.entries().count == 2)
        #expect(fails(LibraryTools.duplicate(), .object(["id": id(UUID())])) == AgentError.notFound)
    }

    @Test func listUpdateAndAddCarryTheCategory() throws {
        let cat = try lab.store.createCategory(name: "Chairs")
        let t = try lab.pack()
        let plain = try lab.store.add(LibraryContent.makeEntry(from: t, name: "Plain"), transfer: t)
        let added = try call(LibraryTools.addFromObject(), .object(["ids": .array([id(lab.instance)]), "categoryId": id(cat.id), "name": "Sorted"]))["entry"]
        #expect(added?["categoryId"]?.stringValue == cat.id.uuidString.lowercased())
        #expect(fails(LibraryTools.addFromObject(), .object(["ids": .array([id(lab.instance)]), "categoryId": id(UUID())])) != nil)
        #expect(lab.store.entries().count == 2)

        let list = try call(LibraryTools.list(), .object([:]))
        #expect(list["categories"]?.arrayValue?.first?["entries"]?.int64Value == 1)
        let rows = list["items"]?.arrayValue ?? list["entries"]?.arrayValue ?? []
        #expect(rows.contains { $0["name"]?.stringValue == "Plain" && $0["categoryId"]?.isNull == true })
        let only = try call(LibraryTools.list(), .object(["categoryId": id(cat.id)]))
        #expect((only["items"]?.arrayValue ?? only["entries"]?.arrayValue ?? []).count == 1)
        let unsorted = try call(LibraryTools.list(), .object(["categoryId": "unsorted"]))
        #expect((unsorted["items"]?.arrayValue ?? unsorted["entries"]?.arrayValue ?? []).first?["name"]?.stringValue == "Plain")
        #expect(fails(LibraryTools.list(), .object(["categoryId": id(UUID())])) != nil)

        // update: set, clear (null counts as a field) and reject unknown ids.
        let set = try call(LibraryTools.update(), .object(["id": id(plain.id), "categoryId": id(cat.id)]))["entry"]
        #expect(set?["categoryId"]?.stringValue == cat.id.uuidString.lowercased())
        let cleared = try call(LibraryTools.update(), .object(["id": id(plain.id), "categoryId": .null]))["entry"]
        #expect(cleared?["categoryId"]?.isNull == true && lab.store.entry(plain.id)?.categoryId == nil)
        #expect(fails(LibraryTools.update(), .object(["id": id(plain.id), "categoryId": id(UUID())])) != nil)
        #expect(fails(LibraryTools.update(), .object(["id": id(plain.id)])) != nil)
    }
}

// MARK: - Drop point and height

struct DropPointTests {
    private func settings(enabled: Bool = true, toGrid: Bool = true, grid: MM = 100) -> SnapSettings {
        var s = SnapSettings(); s.enabled = enabled; s.toGrid = toGrid; s.grid = grid; return s
    }

    @Test func snapsToTheGridAndRoundsAwayFromZero() {
        #expect(DropPoint.snapped(1234.4, -1250, settings: settings()) == P2(1200, -1300))
    }

    @Test func offSwitchesAndOptionKeyLeavePlainMillimetres() {
        #expect(DropPoint.snapped(1234.4, 987.6, settings: settings(enabled: false)) == P2(1234, 988))
        #expect(DropPoint.snapped(1234.4, 987.6, settings: settings(toGrid: false)) == P2(1234, 988))
        #expect(DropPoint.snapped(1234.4, 987.6, settings: settings(), modifierOff: true) == P2(1234, 988))
        #expect(DropPoint.snapped(P2(1250, 40), settings: settings()) == P2(1300, 0))
    }

    @Test func floorHitUsesTheLevelElevation() throws {
        let origin = SIMD3<Double>(1000, 2000, 5000), down = simd_normalize(SIMD3<Double>(0, 0, -1))
        let ground = try #require(DropPoint.onFloor(origin: origin, direction: down, elevation: 0, settings: settings()))
        #expect(ground == P2(1000, 2000))
        // A slanted ray reaches an upper floor sooner, so the hit lies nearer the eye than on the ground floor.
        let slant = simd_normalize(SIMD3<Double>(1, 0, -1))
        let low = try #require(DropPoint.onFloor(origin: origin, direction: slant, elevation: 0, settings: settings()))
        let high = try #require(DropPoint.onFloor(origin: origin, direction: slant, elevation: 3000, settings: settings()))
        #expect(low == P2(6000, 2000))
        #expect(high == P2(3000, 2000))
    }

    @Test func floorHitRejectsParallelBackwardAndFarRays() {
        let o = SIMD3<Double>(0, 0, 1600), s = settings()
        #expect(DropPoint.onFloor(origin: o, direction: SIMD3(1, 0, 0), elevation: 0, settings: s) == nil)
        #expect(DropPoint.onFloor(origin: o, direction: SIMD3(0, 0, 1), elevation: 0, settings: s) == nil)
        #expect(DropPoint.onFloor(origin: o, direction: simd_normalize(SIMD3(1, 0, -0.0001)), elevation: 0, settings: s) == nil)
    }
}
