import Testing
import Foundation
@testable import RoomsmithCore

private func box(_ name: String, _ w: MM, _ d: MM, _ h: MM) -> FurnitureDefinition {
    FurnitureDefinition(name: name, category: "t", size: Size3(w, d, h),
                        components: [Component(name: "c", shape: .box, position: P3(0, 0, h / 2), size: Size3(w, d, h))])
}

@Suite("Vertical contact of the Z arrow") struct VerticalContactTests {
    /// A piece of 300 x 300 x 200 at height `z`, and one other piece `other` at the same spot (or at `at`).
    private func scene(_ other: FurnitureDefinition, otherZ: MM = 0, at: P3? = nil, z: MM = 1000)
        throws -> (Project, UUID, UUID, UUID) {
        var p = Project.empty(name: "T")
        let lvl = p.levels[0].id
        let piece = box("Piece", 300, 300, 200)
        p.addDefinition(piece); p.addDefinition(other)
        let m = try p.addInstance(definitionId: piece.id, levelId: lvl, position: P3(0, 0, z), rotationDeg: 0)
        let o = try p.addInstance(definitionId: other.id, levelId: lvl, position: at ?? P3(0, 0, otherZ), rotationDeg: 0)
        return (p, lvl, m, o)
    }

    @Test func snapsOntoATopAboveTheAutomaticCarrierLimit() throws {
        let (p, lvl, m, _) = try scene(box("Wardrobe", 1000, 600, 2364), z: 2300)
        let v = VerticalContact(project: p, levelId: lvl, moving: [m])
        #expect(v.stops.contains(64))
        #expect(v.stop(near: 90, tolerance: 40) == 64)
        #expect(v.stop(near: 200, tolerance: 40) == nil)
    }

    @Test func aPieceWiderThanItsCarrierStillSnaps() throws {
        let (p, lvl, m, _) = try scene(box("Stool", 200, 200, 450))
        #expect(VerticalContact(project: p, levelId: lvl, moving: [m]).stops.contains(-550))
    }

    @Test func aPieceNextToTheOtherHasOnlyTheFloor() throws {
        let (p, lvl, m, _) = try scene(box("Table", 500, 500, 750), at: P3(2000, 0, 0))
        #expect(VerticalContact(project: p, levelId: lvl, moving: [m]).stops == [-1000])
    }

    @Test func topOfThePieceStopsUnderAHangingCabinet() throws {
        let (p, lvl, m, _) = try scene(box("Cabinet", 500, 500, 700), otherZ: 1500)
        #expect(VerticalContact(project: p, levelId: lvl, moving: [m]).stops.contains(300))
    }

    @Test func theFloorIsAStop() throws {
        let (p, lvl, m, _) = try scene(box("Table", 500, 500, 750), at: P3(2000, 0, 0), z: 40)
        #expect(VerticalContact(project: p, levelId: lvl, moving: [m]).stop(near: -25, tolerance: 30) == -40)
    }

    @Test func theClosestStopWins() {
        let v = VerticalContact(stops: [-100, 0, 40])
        #expect(v.stop(near: 25, tolerance: 80) == 40)
        #expect(v.stop(near: 15, tolerance: 80) == 0)
    }

    @Test func lampsAndHiddenPiecesAreNoStops() throws {
        let (p0, lvl, m, _) = try scene(box("Lamp", 500, 500, 750))
        #expect(VerticalContact(project: p0, levelId: lvl, moving: [m]).stops == [-1000])
        var (p1, lvl1, m1, o1) = try scene(box("Table", 500, 500, 750))
        p1.instances[p1.instances.firstIndex { $0.id == o1 }!].visible = false
        #expect(VerticalContact(project: p1, levelId: lvl1, moving: [m1]).stops == [-1000])
    }

    @Test func aRugIsNoStop() throws {
        let (p, lvl, m, _) = try scene(box("Rug", 2000, 2000, 12))
        #expect(VerticalContact(project: p, levelId: lvl, moving: [m]).stops == [-1000])
    }

    @Test func anUndersideTooLowForThePieceIsNoStop() throws {
        // Cabinet underside at 150, piece height 200: its top against that underside would put it 50 mm under the floor.
        let (p, lvl, m, _) = try scene(box("Cabinet", 500, 500, 700), otherZ: 150)
        let stops = VerticalContact(project: p, levelId: lvl, moving: [m]).stops
        #expect(!stops.contains(-1050))
        #expect(stops.contains(-150) && stops.contains(-1000))
    }

    @Test func aPieceThatMayOverlapStillSnaps() throws {
        var (p, lvl, m, _) = try scene(box("Table", 500, 500, 750))
        p.instances[p.instances.firstIndex { $0.id == m }!].allowsOverlap = true
        #expect(VerticalContact(project: p, levelId: lvl, moving: [m]).stops.contains(-250))
    }

    @Test func aMovingGroupDoesNotSnapToItself() throws {
        var (p, lvl, m, o) = try scene(box("Table", 500, 500, 750))
        let g = FurnitureGroup(name: "G", levelId: lvl, origin: P3(0, 0, 0), memberIds: [m, o])
        p.groups.append(g)
        #expect(VerticalContact(project: p, levelId: lvl, moving: [g.id]).stops == [0])
    }
}
