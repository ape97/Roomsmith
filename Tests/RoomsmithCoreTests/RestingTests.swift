import Testing
import Foundation
import simd
@testable import RoomsmithCore

// Round footprints in the collision check, and pieces that stand on other furniture (`RestingSurface`).

private func box(_ name: String, _ w: MM, _ d: MM, _ h: MM) -> FurnitureDefinition {
    FurnitureDefinition(name: name, category: "t", size: Size3(w, d, h),
                        components: [Component(name: "c", shape: .box, position: P3(0, 0, h / 2), size: Size3(w, d, h))])
}

private func round(_ name: String, _ dia: MM, _ h: MM) -> FurnitureDefinition {
    FurnitureDefinition(name: name, category: "t", size: Size3(dia, dia, h),
                        components: [Component(name: "c", shape: .cylinder, position: P3(0, 0, h / 2), size: Size3(dia, dia, h))])
}

@Suite("Resting and round footprints") struct RestingTests {
    // MARK: Round footprint

    /// The real case: a round tray (diameter 700, turned 120 degrees) next to an armchair module 8633 mm to the right.
    private func trayNextToArmModule(trayDef: FurnitureDefinition) throws -> (Project, UUID, UUID) {
        var p = Project.empty(name: "T")
        let lvl = p.levels[0].id
        let arm = box("Arm", 1215, 1230, 660)
        p.addDefinition(arm); p.addDefinition(trayDef)
        let a = try p.addInstance(definitionId: arm.id, levelId: lvl, position: P3(8018, -3502, 0), rotationDeg: 90)
        // Floating a little (z 100) so the flat-on-floor exemption does not hide the case.
        let t = try p.addInstance(definitionId: trayDef.id, levelId: lvl, position: P3(9040, -3450, 100), rotationDeg: 120)
        return (p, a, t)
    }

    @Test func roundTrayThatOnlyTouchesTheCornerOfItsSquareIsFree() throws {
        let (p, a, t) = try trayNextToArmModule(trayDef: round("Tray", 700, 30))
        #expect(FurnitureResolver.isRound(definition: p.definition(p.instance(t)!.definitionId)!))
        let issues = CollisionChecker.check(p, levelId: p.levels[0].id).filter { $0.kind == .furnitureOverlap }
        #expect(issues.isEmpty, "circle 8690 > 8633 must be free, got \(issues) (\(a))")
    }

    @Test func taperUprightOrUpsideDownIsRoundButTiltedIsNot() {
        func pot(_ rot: R3) -> FurnitureDefinition {
            FurnitureDefinition(name: "Pot", category: "t", size: Size3(400, 400, 500), components: [
                Component(name: "p", shape: .taper, position: P3(0, 0, 250), size: Size3(400, 400, 500), rotation: rot),
                Component(name: "leaf", shape: .sphere, position: P3(0, 0, 450), size: Size3(250, 250, 100))])
        }
        #expect(FurnitureResolver.isRound(definition: pot(R3(0, 0, 0))))
        #expect(FurnitureResolver.isRound(definition: pot(R3(180, 0, 0))))
        #expect(!FurnitureResolver.isRound(definition: pot(R3(90, 0, 0))))
        var poked = pot(R3(180, 0, 0))
        poked.components.append(Component(name: "corner", shape: .box, position: P3(180, 180, 450), size: Size3(20, 20, 20)))
        #expect(!FurnitureResolver.isRound(definition: poked))
    }

    @Test func turnedSquareOfTheSameSizeCollides() throws {
        let (p, _, _) = try trayNextToArmModule(trayDef: box("Square", 700, 700, 30))
        let issues = CollisionChecker.check(p, levelId: p.levels[0].id).filter { $0.kind == .furnitureOverlap }
        #expect(issues.count == 1, "square corner reaches 8562 < 8633")
    }

    @Test func roundPolygonIsInscribedInTheEllipse() throws {
        let def = round("Tray", 700, 30)
        var inst = FurnitureInstance(definitionId: def.id, levelId: UUID(), name: "T", position: P3(1000, 2000, 0), rotationDeg: 33)
        inst.position = P3(1000, 2000, 0)
        let poly = try #require(FurnitureResolver.footprintPolygon(of: inst, definition: def))
        #expect(poly.count == FurnitureResolver.roundSegments)
        for q in poly { #expect(abs(simd_length(q - V2(1000, 2000)) - 350) < 1e-6) }
        #expect(FurnitureResolver.footprintPolygon(of: inst, definition: box("B", 700, 700, 30)) == nil)
    }

    // MARK: Standing on furniture

    private func tableScene() throws -> (Project, UUID, UUID, UUID) {
        var p = Project.empty(name: "T")
        let lvl = p.levels[0].id
        let table = box("Table", 1000, 1000, 740), tray = round("Tray", 400, 30)
        p.addDefinition(table); p.addDefinition(tray)
        let t = try p.addInstance(definitionId: table.id, levelId: lvl, position: P3(0, 0, 0))
        let r = try p.addInstance(definitionId: tray.id, levelId: lvl, position: P3(5000, 0, 0))
        return (p, lvl, t, r)
    }

    @Test func pieceOverATableStandsOnItsTop() throws {
        let (p, _, _, r) = try tableScene()
        let inst = try #require(p.instance(r))
        #expect(RestingSurface.z(for: inst, at: P2(100, -50), in: p) == 740)
        // Sticking out over the edge: not carried, stays on the floor.
        #expect(RestingSurface.z(for: inst, at: P2(450, 0), in: p) == 0)
    }

    @Test func droppedPieceStandsOnTheTableUnlessItIsLeftOnTheFloor() throws {
        var (p, lvl, _, r) = try tableScene()
        let def = try #require(p.instance(r)).definitionId
        let on = try p.placeDragged(.definition(def), levelId: lvl, at: P2(0, 0), restOnFurniture: true)
        #expect(p.instance(on)?.position.z == 740)
        let off = try p.placeDragged(.definition(def), levelId: lvl, at: P2(0, 0), restOnFurniture: false)
        #expect(p.instance(off)?.position.z == 0)
    }

    @Test func pullingAPieceOffTheTableLowersItToTheFloorOnlyIfItStoodOnIt() throws {
        var (p, lvl, _, r) = try tableScene()
        // Standing on the table: dragging away gives z = 0.
        p.instances[p.instances.firstIndex { $0.id == r }!].position = P3(0, 0, 740)
        let drag = try #require(RestingDrag(project: p, levelId: lvl, ids: [r]))
        #expect(drag.wasResting)
        #expect(drag.z(at: V2(0, 0)) == 740)
        #expect(drag.z(at: V2(4000, 0)) == 0)
        // Held up by hand at 300 mm in the open: keeps its height.
        p.instances[p.instances.firstIndex { $0.id == r }!].position = P3(5000, 0, 300)
        let lifted = try #require(RestingDrag(project: p, levelId: lvl, ids: [r]))
        #expect(!lifted.wasResting)
        #expect(lifted.z(at: V2(-5000, 0)) == 740)
        #expect(lifted.z(at: V2(2000, 0)) == 300)
    }

    @Test func aSelectionOfSeveralPiecesKeepsItsHeight() throws {
        let (p, lvl, t, r) = try tableScene()
        #expect(RestingDrag(project: p, levelId: lvl, ids: [t, r]) == nil)
    }

    @Test func aPieceStandingOnATableIsNoCollision() throws {
        var (p, lvl, _, r) = try tableScene()
        let i = p.instances.firstIndex { $0.id == r }!
        p.instances[i].position = P3(0, 0, 740)
        #expect(CollisionChecker.check(p, levelId: lvl).filter { $0.kind == .furnitureOverlap }.isEmpty)
        // Sunk 40 mm into the top: a real overlap.
        p.instances[i].position = P3(0, 0, 700)
        #expect(CollisionChecker.check(p, levelId: lvl).filter { $0.kind == .furnitureOverlap }.count == 1)
    }

    // MARK: Carrier choice

    private func place(_ p: inout Project, _ d: FurnitureDefinition, at pos: P3, _ lvl: UUID) throws -> UUID {
        if p.definition(d.id) == nil { p.addDefinition(d) }
        return try p.addInstance(definitionId: d.id, levelId: lvl, position: pos)
    }

    private func flat(_ name: String, _ w: MM, _ d: MM, _ h: MM, z: MM) -> FurnitureDefinition {
        FurnitureDefinition(name: name, category: "t", size: Size3(w, d, z + h),
                            components: [Component(name: "c", shape: .box, position: P3(0, 0, z + h / 2), size: Size3(w, d, h))])
    }

    @Test func aWorktopBeatsAWallCabinetAboveIt() throws {
        var p = Project.empty(name: "T")
        let lvl = p.levels[0].id
        _ = try place(&p, box("Worktop", 1000, 600, 900), at: P3(0, 0, 0), lvl)
        // Top at exactly 1500, underside at 1000: a hanging carrier.
        _ = try place(&p, flat("Wall cabinet", 1000, 300, 500, z: 1000), at: P3(0, 0, 0), lvl)
        let item = box("Cup", 200, 200, 100)
        let id = try place(&p, item, at: P3(5000, 0, 0), lvl)
        #expect(RestingSurface.z(for: try #require(p.instance(id)), at: P2(0, 0), in: p) == 900)
    }

    @Test func aWallShelfCarriesWhenNothingStandsBelow() throws {
        var p = Project.empty(name: "T")
        let lvl = p.levels[0].id
        _ = try place(&p, flat("Shelf", 1000, 300, 30, z: 1200), at: P3(0, 0, 0), lvl)
        let id = try place(&p, box("Cup", 200, 200, 100), at: P3(5000, 0, 0), lvl)
        #expect(RestingSurface.z(for: try #require(p.instance(id)), at: P2(0, 0), in: p) == 1230)
    }

    @Test func aPieceTooTallForTheCeilingIsNotPutOnTheCabinet() throws {
        var p = Project.empty(name: "T")
        let lvl = p.levels[0].id
        let ceiling = try #require(p.level(lvl)).height
        _ = try place(&p, box("Cabinet", 1000, 600, 900), at: P3(0, 0, 0), lvl)
        let tall = box("Tall", 200, 200, ceiling - 800)
        let id = try place(&p, tall, at: P3(5000, 0, 0), lvl)
        #expect(RestingSurface.z(for: try #require(p.instance(id)), at: P2(0, 0), in: p) == 0)
        let fits = try place(&p, box("Low", 200, 200, ceiling - 900), at: P3(5000, 0, 0), lvl)
        #expect(RestingSurface.z(for: try #require(p.instance(fits)), at: P2(0, 0), in: p) == 900)
    }

    @Test func aPieceThatAllowsOverlapIsNeverPutOnFurniture() throws {
        var (p, lvl, _, r) = try tableScene()
        p.instances[p.instances.firstIndex { $0.id == r }!].allowsOverlap = true
        let inst = try #require(p.instance(r))
        #expect(RestingSurface.z(for: inst, at: P2(0, 0), in: p) == 0)
        #expect(RestingDrag(project: p, levelId: lvl, ids: [r]) == nil)
    }

    @Test func rugsAndTallCabinetsAndLampsAreNoCarriers() throws {
        var p = Project.empty(name: "T")
        let lvl = p.levels[0].id
        _ = try place(&p, flat("Mat", 1000, 1000, 100, z: 0), at: P3(0, 0, 0), lvl)
        _ = try place(&p, box("Tall", 1000, 1000, 2200), at: P3(3000, 0, 0), lvl)
        var lamp = box("Lamp", 1000, 1000, 600)
        lamp.category = "Lighting"
        _ = try place(&p, lamp, at: P3(6000, 0, 0), lvl)
        let id = try place(&p, box("Cup", 200, 200, 100), at: P3(9000, 0, 0), lvl)
        let inst = try #require(p.instance(id))
        for x: MM in [0, 3000, 6000] { #expect(RestingSurface.z(for: inst, at: P2(x, 0), in: p) == 0, "x = \(x)") }
        #expect(RestingField(project: p, levelId: lvl, excluding: [], group: nil, showLamps: true).surfaces.isEmpty)
        #expect(RestingField(project: p, levelId: lvl, excluding: [], group: nil, showLamps: false).surfaces.isEmpty)
    }

    @Test func aHiddenLampDoesNotBlockTheSpaceAboveATable() throws {
        var p = Project.empty(name: "T")
        let lvl = p.levels[0].id
        _ = try place(&p, box("Table", 1000, 1000, 740), at: P3(0, 0, 0), lvl)
        var lamp = flat("Lamp", 300, 300, 100, z: 1000)
        lamp.category = "Lighting"
        _ = try place(&p, lamp, at: P3(0, 0, 0), lvl)
        let id = try place(&p, box("Vase", 200, 200, 400), at: P3(5000, 0, 0), lvl)
        let inst = try #require(p.instance(id))
        #expect(RestingSurface.z(for: inst, at: P2(0, 0), in: p, showLamps: true) == 0)
        #expect(RestingSurface.z(for: inst, at: P2(0, 0), in: p, showLamps: false) == 740)
    }

    @Test func aTallPotUnderALidCollidesButAFreePotDoesNot() throws {
        var p = Project.empty(name: "T")
        let lvl = p.levels[0].id
        let shelf = FurnitureDefinition(name: "Shelf", category: "t", size: Size3(1000, 400, 1000), components: [
            Component(name: "board", shape: .box, position: P3(0, 0, 390), size: Size3(1000, 400, 20)),
            Component(name: "lid", shape: .box, position: P3(0, 0, 790), size: Size3(1000, 400, 20)),
        ])
        p.addDefinition(shelf)
        _ = try p.addInstance(definitionId: shelf.id, levelId: lvl, position: P3(0, 0, 0))
        let tall = round("Tall pot", 200, 500), low = round("Low pot", 200, 300)
        p.addDefinition(tall); p.addDefinition(low)
        let a = try p.addInstance(definitionId: tall.id, levelId: lvl, position: P3(0, 0, 400))
        func overlaps() -> Int { CollisionChecker.check(p, levelId: lvl).filter { $0.kind == .furnitureOverlap }.count }
        #expect(overlaps() == 1, "400 + 500 reaches into the lid at 780")
        p.instances.removeAll { $0.id == a }
        _ = try p.addInstance(definitionId: low.id, levelId: lvl, position: P3(0, 0, 400))
        #expect(overlaps() == 0)
    }

    @Test func aPotThatSticksIntoASidePanelCollides() throws {
        var p = Project.empty(name: "T")
        let lvl = p.levels[0].id
        let shelf = FurnitureDefinition(name: "Shelf", category: "t", size: Size3(1000, 400, 1000), components: [
            Component(name: "board", shape: .box, position: P3(0, 0, 390), size: Size3(1000, 400, 20)),
            Component(name: "side", shape: .box, position: P3(490, 0, 500), size: Size3(20, 400, 1000)),
        ])
        let pot = round("Pot", 200, 150)
        p.addDefinition(shelf); p.addDefinition(pot)
        _ = try p.addInstance(definitionId: shelf.id, levelId: lvl, position: P3(0, 0, 0))
        let id = try p.addInstance(definitionId: pot.id, levelId: lvl, position: P3(395, 0, 400))
        func overlaps() -> Int { CollisionChecker.check(p, levelId: lvl).filter { $0.kind == .furnitureOverlap }.count }
        #expect(overlaps() == 1, "pot reaches x = 495, the panel starts at 480")
        p.instances[p.instances.firstIndex { $0.id == id }!].position = P3(300, 0, 400)
        #expect(overlaps() == 0)
    }

    @Test func aPieceOnALowShelfBoardInsideATallFrameIsNoCollision() throws {
        var p = Project.empty(name: "T")
        let lvl = p.levels[0].id
        // Tall shelf: a board at 400 mm and a side panel up to 1000 mm, so the overall height is 1000.
        let shelf = FurnitureDefinition(name: "Shelf", category: "t", size: Size3(1000, 400, 1000), components: [
            Component(name: "board", shape: .box, position: P3(0, 0, 390), size: Size3(1000, 400, 20)),
            Component(name: "side", shape: .box, position: P3(490, 0, 500), size: Size3(20, 400, 1000)),
        ])
        let pot = round("Pot", 200, 150)
        p.addDefinition(shelf); p.addDefinition(pot)
        _ = try p.addInstance(definitionId: shelf.id, levelId: lvl, position: P3(0, 0, 0))
        let id = try p.addInstance(definitionId: pot.id, levelId: lvl, position: P3(0, 0, 400))
        #expect(RestingSurface.z(for: try #require(p.instance(id)), at: P2(0, 0), in: p) == 400)
        #expect(CollisionChecker.check(p, levelId: lvl).filter { $0.kind == .furnitureOverlap }.isEmpty)
    }
}
