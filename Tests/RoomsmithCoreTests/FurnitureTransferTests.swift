import Foundation
import Testing
@testable import RoomsmithCore

// MARK: - Fixtures

@MainActor
private struct Pair {
    let dir: URL
    let sourcePkg: URL
    let targetPkg: URL
    let source: DocumentStore
    let target: DocumentStore
    var sourceLevel: UUID { source.project.levels[0].id }
    var targetLevel: UUID { target.project.levels[0].id }

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("rs-transfer-\(UUID().uuidString)")
        sourcePkg = dir.appendingPathComponent("a.roomsmith")
        targetPkg = dir.appendingPathComponent("b.roomsmith")
        try FileManager.default.createDirectory(at: sourcePkg, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetPkg, withIntermediateDirectories: true)
        source = DocumentStore(project: Project.empty(name: "Source"))
        target = DocumentStore(project: Project.empty(name: "Target"))
    }

    func file(_ name: String, _ bytes: String) throws -> URL {
        let u = dir.appendingPathComponent(name)
        try Data(bytes.utf8).write(to: u)
        return u
    }
}

private struct Ids {
    var instance = UUID(), definition = UUID(), body = UUID(), lid = UUID(), open = UUID(), track = UUID()
    var material = UUID(), override = UUID(), mesh = UUID(), texture = UUID(), product = UUID(), manual = UUID()
}

/// A chest with a mesh body, a lid, an "open" state, a track, a textured material, an override and a product with a manual.
@MainActor
private func buildChest(_ pair: Pair, textureText: String = "tex-bytes") throws -> Ids {
    var ids = Ids()
    let meshAsset = try ProjectPackage.importAsset(pair.file("chest.usdz", "mesh-bytes"), kind: .mesh, into: pair.sourcePkg)
    let texAsset = try ProjectPackage.importAsset(pair.file("wood.png", textureText), kind: .texture, into: pair.sourcePkg)
    let manualAsset = try ProjectPackage.importAsset(pair.file("manual.pdf", "manual-bytes"), kind: .file, into: pair.sourcePkg)
    try pair.source.run("build") { p in
        ids.mesh = p.addAsset(meshAsset)
        ids.texture = p.addAsset(texAsset)
        ids.manual = p.addAsset(manualAsset)
        var wood = Material(name: "Wood", color: RGBColor(150, 100, 50))
        wood.textureAssetId = ids.texture
        ids.material = p.addMaterial(wood)
        let plain = Material(name: "Paint", color: RGBColor(255, 255, 255))
        ids.override = p.addMaterial(plain)
        var body = Component(name: "body", shape: .mesh, position: P3(0, 0, 400), size: Size3(1000, 500, 800))
        body.meshAssetId = ids.mesh
        body.materialId = ids.material
        let lid = Component(name: "lid", shape: .box, position: P3(0, 0, 810), size: Size3(1000, 500, 20))
        ids.body = body.id; ids.lid = lid.id
        var def = FurnitureDefinition(name: "Chest", category: "Test", size: Size3(1000, 500, 820), components: [body, lid])
        let open = FurnitureState(name: "open", poses: [lid.id: ComponentPose(position: P3(0, 0, 1200))])
        ids.open = open.id
        def.states = [open]
        def.defaultStateId = open.id
        var track = AnimationTrack(fromStateId: nil, toStateId: open.id)
        track.keyframes = [.init(t: 0.5, poses: [lid.id: ComponentPose(position: P3(0, 0, 1000))])]
        ids.track = track.id
        def.tracks = [track]
        var prod = CatalogProduct(name: "Chest product")
        prod.fileAssetIds = [ids.manual]
        prod.roomIds = [UUID()]
        ids.product = p.addProduct(prod)
        def.productId = ids.product
        ids.definition = p.addDefinition(def)
        ids.instance = try p.addInstance(definitionId: ids.definition, levelId: pair.sourceLevel, position: P3(2000, 3000, 0), rotationDeg: 90)
        if let i = p.instances.firstIndex(where: { $0.id == ids.instance }) {
            p.instances[i].materialOverrides = [ids.lid: ids.override]
            p.instances[i].stateId = ids.open
        }
        let mate = try p.addInstance(definitionId: ids.definition, levelId: pair.sourceLevel, position: P3(4000, 3000, 0))
        _ = try p.groupObjects([ids.instance, mate], name: "Pair")
    }
    return ids
}

/// Every id the imported chest refers to exists in the target project.
@MainActor
private func expectNoDanglingIds(_ p: Project, instanceId: UUID) {
    guard let inst = p.instance(instanceId), let def = p.definition(inst.definitionId) else {
        Issue.record("instance or definition missing"); return
    }
    let comps = Set(def.components.map(\.id)), states = Set(def.states.map(\.id))
    for c in def.components {
        if let m = c.materialId { #expect(p.material(m) != nil) }
        if let a = c.meshAssetId { #expect(p.asset(a) != nil) }
    }
    for m in def.components.compactMap(\.materialId) { if let t = p.material(m)?.textureAssetId { #expect(p.asset(t) != nil) } }
    for s in def.states { #expect(Set(s.poses.keys).isSubset(of: comps)) }
    if let d = def.defaultStateId { #expect(states.contains(d)) }
    for t in def.tracks {
        #expect(states.contains(t.toStateId))
        if let f = t.fromStateId { #expect(states.contains(f)) }
        for k in t.keyframes { #expect(Set(k.poses.keys).isSubset(of: comps)) }
    }
    for (k, v) in inst.materialOverrides { #expect(comps.contains(k)); #expect(p.material(v) != nil) }
    if let s = inst.stateId { #expect(states.contains(s)) }
    for pid in [def.productId, inst.productId].compactMap({ $0 }) {
        guard let prod = p.product(pid) else { Issue.record("product missing"); continue }
        for a in prod.fileAssetIds + prod.imageAssetIds { #expect(p.asset(a) != nil) }
    }
}

// MARK: - Tests

@MainActor
struct FurnitureTransferTests {
    @Test func roundTripRemapsEveryIdAndCopiesAssets() throws {
        let pair = try Pair()
        let ids = try buildChest(pair)
        let out = try FurnitureTransferService.copy(ids: [ids.instance], from: pair.source, sourcePackage: pair.sourcePkg,
                                                    to: pair.target, targetPackage: pair.targetPkg, levelId: pair.targetLevel)
        #expect(out.newIds.count == 1)
        let p = pair.target.project
        let newId = out.newIds[0]
        #expect(newId != ids.instance)
        expectNoDanglingIds(p, instanceId: newId)

        let inst = try #require(p.instance(newId))
        let def = try #require(p.definition(inst.definitionId))
        #expect(def.id != ids.definition)
        #expect(Set(def.components.map(\.id)).isDisjoint(with: [ids.body, ids.lid]))
        #expect(def.states.count == 1 && def.states[0].id != ids.open)
        #expect(def.tracks.count == 1 && def.tracks[0].id != ids.track)
        #expect(def.tracks[0].keyframes.count == 1)
        #expect(inst.position == P3(2000, 3000, 0))
        #expect(inst.rotationDeg == 90)
        #expect(inst.groupId == nil)
        #expect(inst.levelId == pair.targetLevel)
        #expect(inst.materialOverrides.count == 1)
        #expect(inst.stateId == def.states[0].id)

        // Assets arrived with their bytes.
        #expect(p.assets.count == 3)
        for a in p.assets { #expect(FileManager.default.fileExists(atPath: ProjectPackage.assetURL(a, in: pair.targetPkg).path)) }
        let mesh = try #require(def.components.first { $0.meshAssetId != nil }?.meshAssetId.flatMap { p.asset($0) })
        #expect(try Data(contentsOf: ProjectPackage.assetURL(mesh, in: pair.targetPkg)) == Data("mesh-bytes".utf8))
        let tex = try #require(def.components.compactMap(\.materialId).compactMap { p.material($0)?.textureAssetId }.first.flatMap { p.asset($0) })
        #expect(tex.sha256 == pair.source.project.asset(ids.texture)?.sha256)

        // Product: copied, linked to the new design, files carried, rooms dropped.
        let prod = try #require(def.productId.flatMap { p.product($0) })
        #expect(prod.id != ids.product)
        #expect(prod.definitionId == nil || prod.definitionId == def.id)
        #expect(prod.roomIds.isEmpty)
        #expect(prod.fileAssetIds.count == 1)

        // One undo step in the target; the source is untouched.
        #expect(pair.target.undoDepth == 1)
        try pair.target.undo()
        #expect(pair.target.project.instances.isEmpty)
        #expect(pair.source.project.instance(ids.instance) != nil)
    }

    @Test func codableRoundTripKeepsEverything() throws {
        let pair = try Pair()
        let ids = try buildChest(pair)
        let t = try FurnitureTransfer.make(from: pair.source.project, ids: [ids.instance], packageURL: pair.sourcePkg)
        let back = try JSONDecoder().decode(FurnitureTransfer.self, from: JSONEncoder().encode(t))
        #expect(back == t)
        #expect(back.assets.count == 3)
    }

    @Test func lightSwitchAndOverlapExemptionTravelWithTheInstance() throws {
        let pair = try Pair()
        let ids = try buildChest(pair)
        try pair.source.run("flags") { p in
            if let i = p.instances.firstIndex(where: { $0.id == ids.instance }) {
                p.instances[i].lightOn = false
                p.instances[i].allowsOverlap = true
            }
        }
        let out = try FurnitureTransferService.copy(ids: [ids.instance], from: pair.source, sourcePackage: pair.sourcePkg,
                                                    to: pair.target, targetPackage: pair.targetPkg, levelId: pair.targetLevel)
        let inst = try #require(out.newIds.compactMap { pair.target.project.instance($0) }.first)
        #expect(inst.lightOn == false)
        #expect(inst.allowsOverlap == true)
    }

    @Test func transferWithoutLightAndOverlapKeysStillDecodes() throws {
        let pair = try Pair()
        let ids = try buildChest(pair)
        var t = try FurnitureTransfer.make(from: pair.source.project, ids: [ids.instance], packageURL: pair.sourcePkg)
        t.instances[0].lightOn = false
        t.instances[0].allowsOverlap = true
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(t)) as! [String: Any]
        var old = json
        var insts = json["instances"] as! [[String: Any]]
        #expect(insts[0]["lightOn"] as? Bool == false)
        insts[0].removeValue(forKey: "lightOn")
        insts[0].removeValue(forKey: "allowsOverlap")
        old["instances"] = insts
        let back = try JSONDecoder().decode(FurnitureTransfer.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(back.instances[0].lightOn == true)
        #expect(back.instances[0].allowsOverlap == false)
        // The new keys survive a normal round trip.
        let again = try JSONDecoder().decode(FurnitureTransfer.self, from: JSONEncoder().encode(t))
        #expect(again.instances[0].lightOn == false && again.instances[0].allowsOverlap == true)
    }

    @Test func equalMaterialsAreDeduplicatedByTextureContent() throws {
        let pair = try Pair()
        let ids = try buildChest(pair)
        _ = try FurnitureTransferService.copy(ids: [ids.instance], from: pair.source, sourcePackage: pair.sourcePkg,
                                              to: pair.target, targetPackage: pair.targetPkg, levelId: pair.targetLevel)
        let materialsAfterFirst = pair.target.project.materials.count
        let assetsAfterFirst = pair.target.project.assets.count
        // Second copy: same textures by content (different asset UUIDs in the target) -> no new materials or assets.
        _ = try FurnitureTransferService.copy(ids: [ids.instance], from: pair.source, sourcePackage: pair.sourcePkg,
                                              to: pair.target, targetPackage: pair.targetPkg, levelId: pair.targetLevel)
        #expect(pair.target.project.materials.count == materialsAfterFirst)
        #expect(pair.target.project.assets.count == assetsAfterFirst)
        #expect(pair.target.project.instances.count == 2)
    }

    @Test func sameLookingMaterialWithOtherTextureGetsANewId() throws {
        let pair = try Pair()
        let ids = try buildChest(pair)
        // Target already has a "Wood" material with identical values but another texture.
        let other = try ProjectPackage.importAsset(pair.file("other.png", "different-bytes"), kind: .texture, into: pair.targetPkg)
        try pair.target.run("seed") { p in
            let a = p.addAsset(other)
            var wood = Material(name: "Wood", color: RGBColor(150, 100, 50))
            wood.textureAssetId = a
            p.addMaterial(wood)
        }
        let before = pair.target.project.materials.count
        let out = try FurnitureTransferService.copy(ids: [ids.instance], from: pair.source, sourcePackage: pair.sourcePkg,
                                                    to: pair.target, targetPackage: pair.targetPkg, levelId: pair.targetLevel)
        #expect(pair.target.project.materials.count == before + 2)  // new Wood (other texture) and Paint
        expectNoDanglingIds(pair.target.project, instanceId: out.newIds[0])
    }

    @Test func materialWithSamePlainValuesButOtherPatternIsNotReused() throws {
        // Contract: a target material is reused only when it looks identical; every visual field counts, not only colour.
        let variants: [(String, (inout Material) -> Void)] = [
            ("pattern", { $0.pattern = .stripes }),
            ("finish", { $0.finish = .polished }),
            ("color2", { $0.color2 = RGBColor(1, 2, 3) }),
            ("patternSize", { $0.patternSize = 250 }),
            ("patternAngle", { $0.patternAngleDeg = 45 }),
            ("grout", { $0.grout = 9 }),
            ("clearcoat", { $0.clearcoat = 0.8 }),
            ("specular", { $0.specular = 0.9 }),
        ]
        for (label, change) in variants {
            let pair = try Pair()
            let ids = try buildChest(pair)
            var twin = Material(name: "Paint", color: RGBColor(255, 255, 255))
            change(&twin)
            try pair.target.run("seed") { p in p.addMaterial(twin) }
            let before = pair.target.project.materials.count
            _ = try FurnitureTransferService.copy(ids: [ids.instance], from: pair.source, sourcePackage: pair.sourcePkg,
                                                  to: pair.target, targetPackage: pair.targetPkg, levelId: pair.targetLevel)
            #expect(pair.target.project.materials.count == before + 2, "\(label): Wood and Paint must both be added")
        }
        // Control: an identical Paint is reused.
        let pair = try Pair()
        let ids = try buildChest(pair)
        try pair.target.run("seed") { p in p.addMaterial(Material(name: "Paint", color: RGBColor(255, 255, 255))) }
        let before = pair.target.project.materials.count
        _ = try FurnitureTransferService.copy(ids: [ids.instance], from: pair.source, sourcePackage: pair.sourcePkg,
                                              to: pair.target, targetPackage: pair.targetPkg, levelId: pair.targetLevel)
        #expect(pair.target.project.materials.count == before + 1)
    }

    @Test func builtinDefinitionIsReusedOnlyWhenIdsMatch() throws {
        let pair = try Pair()
        let ids = try buildChest(pair)
        // Make the source design a built-in and give the target an identical one (same ids), then one with other ids.
        try pair.source.run("builtin") { p in
            try p.updateDefinition(ids.definition) { $0.catalogKey = "chest-1"; $0.builtin = true }
        }
        var twin = try #require(pair.source.project.definition(ids.definition))
        twin.productId = nil
        twin.components = twin.components.map { var c = $0; c.materialId = nil; c.meshAssetId = nil; c.shape = .box; return c }
        try pair.target.run("twin") { p in p.addDefinition(twin) }
        let defsBefore = pair.target.project.definitions.count
        let out = try FurnitureTransferService.copy(ids: [ids.instance], from: pair.source, sourcePackage: pair.sourcePkg,
                                                    to: pair.target, targetPackage: pair.targetPkg, levelId: pair.targetLevel)
        #expect(pair.target.project.definitions.count == defsBefore)
        let inst = try #require(pair.target.project.instance(out.newIds[0]))
        #expect(inst.definitionId == ids.definition)
        #expect(inst.stateId == ids.open)
        #expect(inst.materialOverrides.keys.contains(ids.lid))
        expectNoDanglingIds(pair.target.project, instanceId: inst.id)

        // Same key, different component ids -> copied.
        let pair2 = try Pair()
        let ids2 = try buildChest(pair2)
        try pair2.source.run("builtin") { p in try p.updateDefinition(ids2.definition) { $0.catalogKey = "chest-1" } }
        var other = try #require(pair2.source.project.definition(ids2.definition))
        other.id = UUID()
        other.components = other.components.map { var c = $0; c.id = UUID(); c.materialId = nil; c.meshAssetId = nil; c.shape = .box; return c }
        other.states = []; other.tracks = []; other.defaultStateId = nil; other.productId = nil
        try pair2.target.run("other") { p in p.addDefinition(other) }
        let before2 = pair2.target.project.definitions.count
        let out2 = try FurnitureTransferService.copy(ids: [ids2.instance], from: pair2.source, sourcePackage: pair2.sourcePkg,
                                                     to: pair2.target, targetPackage: pair2.targetPkg, levelId: pair2.targetLevel)
        #expect(pair2.target.project.definitions.count == before2 + 1)
        expectNoDanglingIds(pair2.target.project, instanceId: out2.newIds[0])
    }

    @Test func targetWithoutPackageIsRefusedWhenAssetsTravel() throws {
        let pair = try Pair()
        let ids = try buildChest(pair)
        do {
            _ = try FurnitureTransferService.copy(ids: [ids.instance], from: pair.source, sourcePackage: pair.sourcePkg,
                                                  to: pair.target, targetPackage: nil, levelId: pair.targetLevel)
            Issue.record("expected an error")
        } catch let e as CommandError {
            #expect(e.message.contains("Save the target project first"))
        }
        #expect(pair.target.project.instances.isEmpty)
        #expect(pair.target.undoDepth == 0)
    }

    @Test func projectsWithoutAssetsNeedNoPackages() throws {
        let pair = try Pair()
        try pair.source.run("box") { p in
            var def = FurnitureDefinition(name: "Box", category: "Test", size: Size3(500, 500, 500),
                                          components: [Component(name: "b", shape: .box, position: P3(0, 0, 250), size: Size3(500, 500, 500))])
            def.id = UUID()
            p.addDefinition(def)
            _ = try p.addInstance(definitionId: def.id, levelId: p.levels[0].id, position: P3(0, 0, 0))
        }
        let id = pair.source.project.instances[0].id
        let out = try FurnitureTransferService.copy(ids: [id], from: pair.source, sourcePackage: nil,
                                                    to: pair.target, targetPackage: nil, levelId: pair.targetLevel)
        #expect(out.newIds.count == 1)
    }

    @Test func dropOffsetPutsTheMiddleAtThePointer() throws {
        let pair = try Pair()
        try pair.source.run("boxes") { p in
            var def = FurnitureDefinition(name: "Box", category: "Test", size: Size3(500, 500, 500),
                                          components: [Component(name: "b", shape: .box, position: P3(0, 0, 250), size: Size3(500, 500, 500))])
            def.id = UUID()
            p.addDefinition(def)
            _ = try p.addInstance(definitionId: def.id, levelId: p.levels[0].id, position: P3(1000, 2000, 0))
            _ = try p.addInstance(definitionId: def.id, levelId: p.levels[0].id, position: P3(3000, 2000, 0))
        }
        let ids = pair.source.project.instances.map(\.id)
        let t = try FurnitureTransfer.make(from: pair.source.project, ids: ids, packageURL: nil)
        let c = try #require(t.center)
        #expect(c == P2(2000, 2000))
        let to = P2(10_000, 5000)
        let out = try FurnitureTransferService.copy(ids: ids, from: pair.source, sourcePackage: nil, to: pair.target, targetPackage: nil,
                                                    levelId: pair.targetLevel, offset: P2(to.x - c.x, to.y - c.y))
        let xs = out.newIds.compactMap { pair.target.project.instance($0)?.position.x }.sorted()
        #expect(xs == [9000, 11_000])
    }

    @Test func instanceWithoutStateOrProductStaysWithoutInTheTarget() throws {
        let pair = try Pair()
        let ids = try buildChest(pair)
        try pair.source.run("clear") { p in
            if let i = p.instances.firstIndex(where: { $0.id == ids.instance }) {
                p.instances[i].stateId = nil
                p.instances[i].productId = nil
            }
        }
        #expect(pair.source.project.definition(ids.definition)?.defaultStateId != nil)
        #expect(pair.source.project.definition(ids.definition)?.productId != nil)
        let out = try FurnitureTransferService.copy(ids: [ids.instance], from: pair.source, sourcePackage: pair.sourcePkg,
                                                    to: pair.target, targetPackage: pair.targetPkg, levelId: pair.targetLevel)
        let inst = try #require(out.newIds.compactMap { pair.target.project.instance($0) }.first)
        #expect(inst.stateId == nil)
        #expect(inst.productId == nil)
        #expect(pair.target.project.definition(inst.definitionId)?.defaultStateId != nil)
    }

    @Test func lockedTargetRejectsTheImportAndAMoveKeepsTheSource() throws {
        let pair = try Pair()
        let ids = try buildChest(pair)
        pair.target.agentWriteEnabled = false
        let before = pair.source.project.instances.count
        do {
            _ = try FurnitureTransferService.move(ids: [ids.instance], from: pair.source, sourcePackage: pair.sourcePkg,
                                                  to: pair.target, targetPackage: pair.targetPkg, levelId: pair.targetLevel,
                                                  options: .agent("test"))
            Issue.record("expected the locked target to refuse the import")
        } catch let e as CommandError {
            #expect(e.code == .writeLocked)
        }
        #expect(pair.target.project.instances.isEmpty)
        #expect(pair.source.project.instances.count == before)
        #expect(pair.source.project.instance(ids.instance) != nil)
        #expect(pair.source.undoDepth == 1)  // only the fixture build
    }

    @Test func moveCopiesFirstThenDeletes() throws {
        let pair = try Pair()
        let ids = try buildChest(pair)
        let out = try FurnitureTransferService.move(ids: [ids.instance], from: pair.source, sourcePackage: pair.sourcePkg,
                                                    to: pair.target, targetPackage: pair.targetPkg, levelId: pair.targetLevel)
        #expect(out.sourceRemoved)
        #expect(pair.source.project.instance(ids.instance) == nil)
        #expect(pair.target.project.instances.count == 1)
        // Each side has its own undo step.
        #expect(pair.target.undoDepth == 1)
        let sourceDepth = pair.source.undoDepth
        try pair.source.undo()
        #expect(pair.source.undoDepth == sourceDepth - 1)
        #expect(pair.source.project.instance(ids.instance) != nil)
    }

    @Test func failedDeleteKeepsTheCopyAndReportsIt() throws {
        let pair = try Pair()
        let ids = try buildChest(pair)
        try pair.source.run("lock") { p in try p.setLocked([ids.instance], true) }
        let out = try FurnitureTransferService.move(ids: [ids.instance], from: pair.source, sourcePackage: pair.sourcePkg,
                                                    to: pair.target, targetPackage: pair.targetPkg, levelId: pair.targetLevel)
        #expect(!out.sourceRemoved)
        #expect(out.deleteError != nil)
        #expect(pair.source.project.instance(ids.instance) != nil)
        #expect(pair.target.project.instances.count == 1)
    }

    @Test func failedImportLeavesTheSourceAlone() throws {
        let pair = try Pair()
        let ids = try buildChest(pair)
        do {
            _ = try FurnitureTransferService.move(ids: [ids.instance], from: pair.source, sourcePackage: pair.sourcePkg,
                                                  to: pair.target, targetPackage: nil, levelId: pair.targetLevel)
            Issue.record("expected an error")
        } catch is CommandError {}
        #expect(pair.source.project.instance(ids.instance) != nil)
        #expect(pair.target.project.instances.isEmpty)
    }
}
