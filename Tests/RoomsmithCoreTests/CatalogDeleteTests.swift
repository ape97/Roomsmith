import Testing
import Foundation
@testable import RoomsmithCore

@MainActor @Suite("Catalog delete") struct CatalogDeleteTests {
    @Test func unusedMaterialIsDeletedInOneUndoStep() throws {
        let w = CTWorld()
        let m = Material(name: "Oak", color: RGBColor(10, 20, 30))
        try w.store.run("Add") { _ = $0.addMaterial(m) }
        try w.store.run("Delete") { try $0.deleteUnusedCatalogEntry(m.id) }
        #expect(w.p.material(m.id) == nil)
        try w.store.undo()
        #expect(w.p.material(m.id) != nil)
    }

    @Test func usedMaterialIsRefusedWithCountAndNothingChanges() throws {
        let w = CTWorld()
        let m = Material(name: "Oak", color: RGBColor(10, 20, 30))
        var ids: [UUID] = []
        try w.store.run("Setup") { p in
            _ = p.addMaterial(m)
            ids = try p.addWalls(levelId: w.level, points: [P2(0, 0), P2(4000, 0)], closed: false)
            try p.setMaterial(ids, slot: .wallBoth, materialId: m.id)
        }
        #expect(throws: CommandError.self) { try w.store.run("Delete") { try $0.deleteUnusedCatalogEntry(m.id) } }
        #expect(w.p.material(m.id) != nil)
        #expect(w.p.wall(ids[0])?.leftMaterialId == m.id, "reference stays")
        do { try w.store.run("Delete") { try $0.deleteUnusedCatalogEntry(m.id) } } catch let e as CommandError {
            #expect(e.message.contains("used by 1 object"))
        }
    }

    @Test func usedProductAndNonCatalogKindsAreRefused() throws {
        let w = CTWorld()
        let pr = CatalogProduct(name: "Lamp")
        var wall: UUID?
        try w.store.run("Setup") { p in
            _ = p.addProduct(pr)
            wall = try p.addWalls(levelId: w.level, points: [P2(0, 0), P2(4000, 0)], closed: false).first
        }
        #expect(throws: CommandError.self) { try w.store.run("Bad") { try $0.deleteUnusedCatalogEntry(wall!) } }
        try w.store.run("Delete") { try $0.deleteUnusedCatalogEntry(pr.id) }
        #expect(w.p.product(pr.id) == nil)
    }

    @Test func designWithPlacedInstanceIsRefusedUntilInstanceIsGone() throws {
        let w = CTWorld()
        let def = w.definition()
        let inst = try w.instance(def, 0, 0)
        #expect(throws: CommandError.self) { try w.store.run("Delete") { try $0.deleteUnusedCatalogEntry(def) } }
        #expect(w.p.definition(def) != nil)
        try w.store.run("Remove") { try $0.deleteObjects([inst]) }
        try w.store.run("Delete") { try $0.deleteUnusedCatalogEntry(def) }
        #expect(w.p.definition(def) == nil)
    }

    @Test func productLinkedToFurnitureIsRefused() throws {
        let w = CTWorld()
        let pr = CatalogProduct(name: "Lamp")
        let def = w.definition()
        let inst = try w.instance(def, 0, 0)
        try w.store.run("Link") { p in _ = p.addProduct(pr); try p.linkProduct(pr.id, to: inst) }
        #expect(throws: CommandError.self) { try w.store.run("Delete") { try $0.deleteUnusedCatalogEntry(pr.id) } }
        #expect(w.p.product(pr.id) != nil)
        #expect(w.p.instance(inst)?.productId == pr.id, "link stays")
    }

    @Test func materialOnRoomFloorOrComponentsIsRefused() throws {
        let w = CTWorld()
        let floor = Material(name: "Tiles", color: RGBColor(200, 200, 200))
        let fabric = Material(name: "Fabric", color: RGBColor(90, 40, 40))
        let def = w.definition()
        let inst = try w.instance(def, 0, 0)
        try w.store.run("Setup") { p in
            _ = p.addMaterial(floor); _ = p.addMaterial(fabric)
            let room = try p.addRoom(levelId: w.level, name: "Kitchen", points: [P2(0, 0), P2(3000, 0), P2(3000, 3000), P2(0, 3000)])
            try p.setMaterial([room], slot: .roomFloor, materialId: floor.id)
            try p.setMaterial([inst], slot: .allComponents, materialId: fabric.id)
        }
        for m in [floor.id, fabric.id] {
            #expect(throws: CommandError.self) { try w.store.run("Delete") { try $0.deleteUnusedCatalogEntry(m) } }
            #expect(w.p.material(m) != nil)
        }
    }

    @Test func builtinDesignIsRefused() throws {
        let w = CTWorld()
        var d = FurnitureDefinition(name: "Builtin", category: "t", size: Size3(500, 500, 500), components: [
            Component(name: "body", shape: .box, position: P3(0, 0, 250), size: Size3(500, 500, 500)),
        ])
        d.builtin = true
        try w.store.run("Add") { _ = $0.addDefinition(d) }
        #expect(throws: CommandError.self) { try w.store.run("Delete") { try $0.deleteUnusedCatalogEntry(d.id) } }
        #expect(w.p.definition(d.id) != nil)
    }
}
