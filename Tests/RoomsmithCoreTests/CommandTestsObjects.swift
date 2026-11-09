import Testing
import Foundation
@testable import RoomsmithCore

// MARK: - Walls

@MainActor @Suite("Command walls") struct CommandWallTests {
    /// Closed 4000 x 3000 rectangle: w1 bottom, w2 right, w3 top, w4 left.
    private func rectangle(_ w: CTWorld) throws -> [UUID] {
        var ids: [UUID] = []
        try w.store.run("Rect") { ids = try $0.addWalls(levelId: w.level, points: [P2(0, 0), P2(4000, 0), P2(4000, 3000), P2(0, 3000)], closed: true) }
        return ids
    }

    @Test func updateWallMoveJoinedMovesNeighbourEndpointsExactly() throws {
        let w = CTWorld()
        let ids = try rectangle(w)
        try w.store.run("Stretch") { try $0.updateWall(ids[0], end: P2(4500, 0)) }
        #expect(w.p.wall(ids[0])?.end == P2(4500, 0))
        #expect(w.p.wall(ids[1])?.start == P2(4500, 0), "right wall follows")
        #expect(w.p.wall(ids[1])?.end == P2(4000, 3000), "its far end stays")
        #expect(w.p.wall(ids[2])?.start == P2(4000, 3000))
        #expect(w.p.wall(ids[3])?.end == P2(0, 0))
        // Start point: the previous wall (left) ends at (0,0) and follows.
        try w.store.run("Shift start") { try $0.updateWall(ids[0], start: P2(-100, 20)) }
        #expect(w.p.wall(ids[3])?.end == P2(-100, 20))
        #expect(w.p.wall(ids[3])?.start == P2(0, 3000))
        // Untouched walls keep their revision.
        #expect(w.p.wall(ids[2])?.rev == 1)
    }

    @Test func moveJoinedFalseAndOtherLevelsAreLeftAlone() throws {
        let w = CTWorld()
        var up = UUID()
        try w.store.run("Level") { up = $0.addLevel(name: "Up") }
        let a = try w.wall(P2(0, 0), P2(1000, 0))
        let b = try w.wall(P2(1000, 0), P2(1000, 1000))
        let other = try w.wall(P2(1000, 0), P2(2000, 0), level: up)
        try w.store.run("Detach") { try $0.updateWall(a, end: P2(1200, 0), moveJoined: false) }
        #expect(w.p.wall(b)?.start == P2(1000, 0))
        try w.store.run("Move back") { try $0.updateWall(a, end: P2(1000, 0), moveJoined: false) }
        try w.store.run("Join") { try $0.updateWall(a, end: P2(1300, 0)) }
        #expect(w.p.wall(b)?.start == P2(1300, 0))
        #expect(w.p.wall(other)?.start == P2(1000, 0), "wall on another level does not follow")
    }

    @Test func lockedNeighbourBlocksMoveJoined() throws {
        let w = CTWorld()
        let ids = try rectangle(w)
        try w.store.run("Lock") { try $0.setLocked([ids[1]], true) }
        let before = w.p
        let e = ctThrows(.locked) { try w.store.run("Stretch") { try $0.updateWall(ids[0], end: P2(4500, 0)) } }
        #expect(e?.ids == [ids[1]])
        #expect(w.p == before, "the first wall must not be half moved")
        // Without following the neighbour the edit is fine.
        try w.store.run("Detach") { try $0.updateWall(ids[0], end: P2(4500, 0), moveJoined: false) }
        #expect(w.p.wall(ids[0])?.end == P2(4500, 0))
    }

    @Test func splitWallRedistributesOpeningsAndKeepsRelativePositions() throws {
        let w = CTWorld()
        let a = try w.wall(P2(0, 0), P2(6000, 0))
        let o1 = try w.opening(a, offset: 1000, width: 800)
        let o2 = try w.opening(a, offset: 5000, width: 800)
        var halves: (UUID, UUID) = (UUID(), UUID())
        try w.store.run("Split") { halves = try $0.splitWall(a, at: P2(3000, 400)) }
        #expect(halves.0 == a)
        let first = try #require(w.p.wall(halves.0))
        let second = try #require(w.p.wall(halves.1))
        #expect(first.start == P2(0, 0) && first.end == P2(3000, 0))
        #expect(second.start == P2(3000, 0) && second.end == P2(6000, 0))
        #expect(second.thickness == first.thickness && second.height == first.height)
        #expect(w.p.opening(o1)?.wallId == a)
        #expect(w.p.opening(o1)?.offset == 1000)
        #expect(w.p.opening(o2)?.wallId == halves.1)
        #expect(w.p.opening(o2)?.offset == 2000)
        #expect(w.p.walls.count == 2)
        try w.store.undo()
        #expect(w.p.walls.count == 1)
        #expect(w.p.wall(a)?.end == P2(6000, 0))
        #expect(w.p.opening(o2)?.wallId == a && w.p.opening(o2)?.offset == 5000)
    }

    @Test func splitWallThroughOpeningIsRejected() throws {
        let w = CTWorld()
        let a = try w.wall(P2(0, 0), P2(6000, 0))
        try w.opening(a, offset: 3000, width: 800)
        let before = w.p
        let e = ctThrows(.invalidArgument) { try w.store.run("Split") { _ = try $0.splitWall(a, at: P2(3200, 0)) } }
        #expect(e?.ids.contains(a) == true)
        #expect(w.p == before)
        // Cutting exactly at the opening's edge is allowed.
        try w.store.run("Split") { _ = try $0.splitWall(a, at: P2(3400, 0)) }
        #expect(w.p.walls.count == 2)
    }

    @Test func splitWallNearEndsIsRejected() throws {
        let w = CTWorld()
        let a = try w.wall(P2(0, 0), P2(6000, 0))
        ctThrows(.invalidArgument) { try w.store.run("S") { _ = try $0.splitWall(a, at: P2(0, 0)) } }
        ctThrows(.invalidArgument) { try w.store.run("S") { _ = try $0.splitWall(a, at: P2(6000, 10)) } }
        ctThrows(.invalidArgument) { try w.store.run("S") { _ = try $0.splitWall(a, at: P2(-500, 0)) } }
        ctThrows(.notFound) { try w.store.run("S") { _ = try $0.splitWall(UUID(), at: P2(10, 0)) } }
    }

    @Test func splitOfLockedWallIsRejected() throws {
        let w = CTWorld()
        let a = try w.wall(P2(0, 0), P2(6000, 0))
        try w.store.run("Lock") { try $0.setLocked([a], true) }
        ctThrows(.locked) { try w.store.run("S") { _ = try $0.splitWall(a, at: P2(3000, 0)) } }
    }

    @Test func addWallsValidatesPolyline() throws {
        let w = CTWorld()
        ctThrows(.invalidArgument) { try w.store.run("W") { _ = try $0.addWalls(levelId: w.level, points: [P2(0, 0)], closed: false) } }
        ctThrows(.invalidArgument) { try w.store.run("W") { _ = try $0.addWalls(levelId: w.level, points: [P2(0, 0), P2(5, 0)], closed: true) } }
        try w.store.run("W") { _ = try $0.addWalls(levelId: w.level, points: [P2(0, 0), P2(1000, 0), P2(1000, 1000)], closed: false) }
        #expect(w.p.walls.count == 2)
        #expect(w.p.walls[0].thickness == w.p.settings.defaultWallThickness)
    }
}

// MARK: - Move and rotate

@MainActor @Suite("Command move and rotate") struct CommandMoveRotateTests {
    @Test func movingAWallKeepsItsOpeningsRelative() throws {
        let w = CTWorld()
        let a = try w.wall(P2(0, 0), P2(4000, 0))
        let o = try w.opening(a, offset: 1500)
        let openingRev = try #require(w.p.opening(o)).rev
        try w.store.run("Move") { try $0.moveObjects([a], by: P3(1000, -200, 0)) }
        #expect(w.p.wall(a)?.start == P2(1000, -200))
        #expect(w.p.wall(a)?.end == P2(5000, -200))
        #expect(w.p.opening(o)?.offset == 1500)
        #expect(w.p.opening(o)?.rev == openingRev, "the opening itself was not touched")
        // Wall and opening both selected: the opening is not moved a second time.
        try w.store.run("Move both") { try $0.moveObjects([a, o], by: P3(100, 0, 0)) }
        #expect(w.p.opening(o)?.offset == 1500)
        #expect(w.p.wall(a)?.start == P2(1100, -200))
    }

    @Test func loneOpeningSlidesAlongWallByProjectedDelta() throws {
        let w = CTWorld()
        let a = try w.wall(P2(0, 0), P2(4000, 0))
        let o = try w.opening(a, offset: 1500)
        try w.store.run("Slide") { try $0.moveObjects([o], by: P3(300, 700, 0)) }
        #expect(w.p.opening(o)?.offset == 1800)
        try w.store.run("Slide back") { try $0.moveObjects([o], by: P3(-1000, 5, 0)) }
        #expect(w.p.opening(o)?.offset == 800)
        #expect(w.p.wall(a)?.start == P2(0, 0))
        // Diagonal 3-4-5 wall: direction (0.6, 0.8); a delta of (500, 0) projects to 300.
        let d = try w.wall(P2(0, 1000), P2(3000, 5000))
        let od = try w.opening(d, offset: 2000)
        try w.store.run("Slide diag") { try $0.moveObjects([od], by: P3(500, 0, 0)) }
        #expect(w.p.opening(od)?.offset == 2300)
        // Sliding off the wall is rejected and leaves everything as it was.
        ctThrows(.outOfRange) { try w.store.run("Off") { try $0.moveObjects([o], by: P3(5000, 0, 0)) } }
        #expect(w.p.opening(o)?.offset == 800)
    }

    @Test func movingRoomDimensionAndLevelWork() throws {
        let w = CTWorld()
        var rid = UUID(), did = UUID()
        try w.store.run("Make") {
            rid = try $0.addRoom(levelId: w.level, name: "R", points: [P2(0, 0), P2(1000, 0), P2(1000, 1000)])
            did = try $0.addDimension(levelId: w.level, a: P2(0, 0), b: P2(1000, 0))
        }
        try w.store.run("Move") { try $0.moveObjects([rid, did, w.level], by: P3(10, 20, 30)) }
        #expect(w.p.room(rid)?.points == [P2(10, 20), P2(1010, 20), P2(1010, 1020)])
        #expect(w.p.dimension(did)?.a == P2(10, 20))
        #expect(w.p.dimension(did)?.b == P2(1010, 20))
        #expect(w.p.level(w.level)?.elevation == 30)
        ctThrows(.invalidArgument) {
            let m = w.material()
            try w.store.run("Move material") { try $0.moveObjects([m], by: P3(1, 1, 0)) }
        }
        let before = w.p.revision
        try w.store.run("Zero") { try $0.moveObjects([rid], by: .zero) }
        #expect(w.p.revision == before, "moving by zero is a no-op")
    }

    @Test func moveObjectToTargetPosition() throws {
        let w = CTWorld()
        let def = w.definition()
        let i = try w.instance(def, 100, 200, z: 50)
        try w.store.run("To") { try $0.moveObject(i, to: P3(1000, 2000, 0)) }
        #expect(w.p.instance(i)?.position == P3(1000, 2000, 0))
        ctThrows(.notFound) { try w.store.run("To") { try $0.moveObject(UUID(), to: .zero) } }
    }

    @Test func groupMovesOriginAndMembersExactlyOnce() throws {
        let w = CTWorld()
        let def = w.definition()
        let a = try w.instance(def, 0, 0)
        let b = try w.instance(def, 1000, 0)
        let g = try w.group([a, b])
        let origin = try #require(w.p.group(g)).origin
        #expect(origin == P3(500, 0, 0))
        try w.store.run("Move group") { try $0.moveObjects([g], by: P3(100, 50, 0)) }
        #expect(w.p.group(g)?.origin == P3(600, 50, 0))
        #expect(w.p.instance(a)?.position == P3(100, 50, 0))
        #expect(w.p.instance(b)?.position == P3(1100, 50, 0))
        // Group and member both selected: still moved once.
        try w.store.run("Move both") { try $0.moveObjects([g, a, b], by: P3(10, 0, 0)) }
        #expect(w.p.group(g)?.origin == P3(610, 50, 0))
        #expect(w.p.instance(a)?.position == P3(110, 50, 0))
        #expect(w.p.instance(b)?.position == P3(1110, 50, 0))
        // A single member moves alone; the group origin stays.
        try w.store.run("Move member") { try $0.moveObjects([a], by: P3(0, 5, 0)) }
        #expect(w.p.instance(a)?.position == P3(110, 55, 0))
        #expect(w.p.group(g)?.origin == P3(610, 50, 0))
    }

    @Test func rotateSingleInstanceAroundItself() throws {
        let w = CTWorld()
        let def = w.definition()
        let i = try w.instance(def, 700, -300, rot: 350)
        try w.store.run("Rotate") { try $0.rotateObjects([i], by: 20) }
        #expect(w.p.instance(i)?.position == P3(700, -300, 0))
        #expect(w.p.instance(i)?.rotationDeg == 10)
        try w.store.run("Rotate") { try $0.rotateObjects([i], by: -30) }
        #expect(w.p.instance(i)?.rotationDeg == 340)
    }

    @Test func rotateNinetyDegreesIsExactAroundDefaultAndExplicitPivots() throws {
        let w = CTWorld()
        let def = w.definition()
        let a = try w.instance(def, 0, 0)
        let b = try w.instance(def, 1001, 0)
        // Default pivot for several objects: centre of the bounding box of their positions (500.5 -> 501, 0).
        let pv = try #require(w.p.boundsCenter([a, b]))
        #expect(pv == P2(501, 0))
        try w.store.run("Rotate") { try $0.rotateObjects([a, b], by: 90) }
        #expect(w.p.instance(a)?.position.xy == P2(501, -501))
        #expect(w.p.instance(b)?.position.xy == P2(501, 500))
        #expect(w.p.instance(a)?.rotationDeg == 90)
        // Explicit pivot.
        try w.store.run("Rotate pivot") { try $0.rotateObjects([a], by: 90, pivot: P2(0, 0)) }
        #expect(w.p.instance(a)?.position.xy == P2(501, 501))
        // Four quarter turns are the identity.
        let start = w.p.instance(b)
        for _ in 0..<4 { try w.store.run("Quarter") { try $0.rotateObjects([b], by: 90, pivot: P2(-3, 7)) } }
        #expect(w.p.instance(b)?.position == start?.position)
        #expect(w.p.instance(b)?.rotationDeg == start?.rotationDeg)
        try w.store.run("180") { try $0.rotateObjects([b], by: 180, pivot: P2(0, 0)) }
        #expect(w.p.instance(b)?.position.xy == P2(-501, -500))
        try w.store.run("270") { try $0.rotateObjects([b], by: 270, pivot: P2(0, 0)) }
        #expect(w.p.instance(b)?.position.xy == P2(-500, 501))
    }

    @Test func rotateNonRightAngleRoundsToMillimetres() throws {
        let w = CTWorld()
        let def = w.definition()
        let i = try w.instance(def, 1000, 0)
        try w.store.run("45") { try $0.rotateObjects([i], by: 45, pivot: P2(0, 0)) }
        #expect(w.p.instance(i)?.position.xy == P2(707, 707))
        #expect(w.p.instance(i)?.rotationDeg == 45)
    }

    @Test func rotatingWallsRoomsAndDimensionsAndFollowingOpenings() throws {
        let w = CTWorld()
        let a = try w.wall(P2(1000, 0), P2(3000, 0))
        let o = try w.opening(a, offset: 1000)
        var rid = UUID(), did = UUID()
        try w.store.run("Make") {
            rid = try $0.addRoom(levelId: w.level, name: "R", points: [P2(0, 0), P2(1000, 0), P2(1000, 500)])
            did = try $0.addDimension(levelId: w.level, a: P2(0, 0), b: P2(2000, 0))
        }
        try w.store.run("Rotate") { try $0.rotateObjects([a, o, rid, did], by: 90, pivot: P2(0, 0)) }
        #expect(w.p.wall(a)?.start == P2(0, 1000))
        #expect(w.p.wall(a)?.end == P2(0, 3000))
        #expect(w.p.opening(o)?.offset == 1000, "opening follows its wall")
        #expect(w.p.room(rid)?.points == [P2(0, 0), P2(0, 1000), P2(-500, 1000)])
        #expect(w.p.dimension(did)?.b == P2(0, 2000))
        // Rotating only an opening is a no-op.
        let rev = w.p.revision
        try w.store.run("Noop") { try $0.rotateObjects([o], by: 90) }
        #expect(w.p.revision == rev)
        ctThrows(.invalidArgument) { try w.store.run("Bad") { try $0.rotateObjects([], by: 90) } }
    }

    @Test func rotatingAGroupRotatesMembersAroundItsOriginOnce() throws {
        let w = CTWorld()
        let def = w.definition()
        let a = try w.instance(def, 0, 0)
        let b = try w.instance(def, 1000, 0)
        let g = try w.group([a, b])
        try w.store.run("Rotate") { try $0.rotateObjects([g], by: 90) }
        #expect(w.p.group(g)?.origin == P3(500, 0, 0))
        #expect(w.p.group(g)?.rotationDeg == 90)
        #expect(w.p.instance(a)?.position.xy == P2(500, -500))
        #expect(w.p.instance(b)?.position.xy == P2(500, 500))
        #expect(w.p.instance(a)?.rotationDeg == 90)
        // Group plus a member selected: nothing is rotated twice.
        try w.store.run("Rotate again") { try $0.rotateObjects([g, a], by: 90) }
        #expect(w.p.group(g)?.rotationDeg == 180)
        #expect(w.p.instance(a)?.rotationDeg == 180)
        #expect(w.p.instance(b)?.rotationDeg == 180)
        #expect(w.p.instance(a)?.position.xy == P2(1000, 0))
        #expect(w.p.instance(b)?.position.xy == P2(0, 0))
    }
}

// MARK: - Delete

@MainActor @Suite("Command delete") struct CommandDeleteTests {
    @Test func deletingWallRemovesItsOpeningsAndUndoRestores() throws {
        let w = CTWorld()
        let a = try w.wall(P2(0, 0), P2(4000, 0))
        let keep = try w.wall(P2(0, 500), P2(4000, 500))
        let o = try w.opening(a, offset: 1000)
        let snapshot = ctNormalized(w.p)
        var removed: [UUID] = []
        let r = try w.store.apply("Delete") { removed = try $0.deleteObjects([a]) }
        #expect(Set(removed) == [a, o])
        #expect(w.p.wall(a) == nil && w.p.opening(o) == nil)
        #expect(w.p.wall(keep) != nil)
        #expect(Set(r.changes.ids(.opening, [.removed])) == [o])
        try w.store.undo()
        #expect(ctNormalized(w.p) == snapshot)
        // Deleting wall and its opening in one call works too.
        try w.store.run("Delete") { try $0.deleteObjects([o, a]) }
        #expect(w.p.openings.isEmpty)
    }

    @Test func deletingGroupRemovesMembers() throws {
        let w = CTWorld()
        let def = w.definition()
        let a = try w.instance(def, 0, 0)
        let b = try w.instance(def, 1000, 0)
        let other = try w.instance(def, 5000, 0)
        let g = try w.group([a, b])
        try w.store.run("Delete") { try $0.deleteObjects([g]) }
        #expect(w.p.groups.isEmpty)
        #expect(w.p.instances.map(\.id) == [other])
    }

    @Test func deletingInstanceUpdatesItsGroupAndRemovesEmptyGroup() throws {
        let w = CTWorld()
        let def = w.definition()
        let a = try w.instance(def, 0, 0)
        let b = try w.instance(def, 1000, 0)
        let g = try w.group([a, b])
        var cfg = UUID()
        try w.store.run("Cfg") { cfg = try $0.saveConfiguration(groupId: g, name: "1") }
        try w.store.run("Delete a") { try $0.deleteObjects([a]) }
        #expect(w.p.group(g)?.memberIds == [b])
        #expect(w.p.group(g)?.configurations.first(where: { $0.id == cfg })?.poses.keys.sorted { $0.uuidString < $1.uuidString } == [b])
        try w.store.run("Delete b") { try $0.deleteObjects([b]) }
        #expect(w.p.groups.isEmpty)
        #expect(w.p.instances.isEmpty)
        // Deleting both members plus the group id in a mixed order must not fail.
        let c = try w.instance(def, 0, 0)
        let d = try w.instance(def, 100, 0)
        let g2 = try w.group([c, d])
        try w.store.run("Delete all") { try $0.deleteObjects([c, g2, d]) }
        #expect(w.p.groups.isEmpty && w.p.instances.isEmpty)
    }

    @Test func deletingLevelRemovesAllItsContentButNothingElse() throws {
        let w = CTWorld()
        var up = UUID()
        try w.store.run("Level") { up = $0.addLevel(name: "Up") }
        let def = w.definition()
        let keepWall = try w.wall(P2(0, 0), P2(1000, 0))
        let keepInst = try w.instance(def, 0, 0)
        let upWall = try w.wall(P2(0, 0), P2(4000, 0), level: up)
        let upOpening = try w.opening(upWall, offset: 2000)
        let i1 = try w.instance(def, 0, 0, level: up)
        let i2 = try w.instance(def, 500, 0, level: up)
        let i3 = try w.instance(def, 900, 0, level: up)
        let g = try w.group([i1, i2])
        var room = UUID(), dim = UUID()
        try w.store.run("More") {
            room = try $0.addRoom(levelId: up, name: "R", points: [P2(0, 0), P2(1000, 0), P2(1000, 1000)])
            dim = try $0.addDimension(levelId: up, a: P2(0, 0), b: P2(10, 0))
        }
        var removed: [UUID] = []
        try w.store.run("Delete level") { removed = try $0.deleteObjects([up]) }
        let expected: Set<UUID> = [up, upWall, upOpening, i1, i2, i3, g, room, dim]
        #expect(Set(removed) == expected)
        #expect(w.p.levels.map(\.id) == [w.level])
        #expect(w.p.walls.map(\.id) == [keepWall])
        #expect(w.p.instances.map(\.id) == [keepInst])
        #expect(w.p.openings.isEmpty && w.p.groups.isEmpty && w.p.rooms.isEmpty && w.p.dimensions.isEmpty)
        #expect(w.p.definitions.count == 1)
        try w.store.undo()
        #expect(w.p.levels.count == 2 && w.p.walls.count == 2 && w.p.instances.count == 4)
        #expect(w.p.groups.count == 1 && w.p.openings.count == 1)
    }

    @Test func deletingMaterialClearsEveryReference() throws {
        let w = CTWorld()
        let def = w.definition()
        let m = w.material()
        let keepMat = w.material("Other")
        let wall = try w.wall(P2(0, 0), P2(4000, 0))
        let o = try w.opening(wall, offset: 2000)
        let a = try w.instance(def, 0, 0)
        let b = try w.instance(def, 1000, 0)
        var room = UUID()
        try w.store.run("Room") { room = try $0.addRoom(levelId: w.level, name: "R", points: [P2(0, 0), P2(1000, 0), P2(1000, 1000)]) }
        let compA = try #require(w.p.definition(def)).components[0].id
        let compB = try #require(w.p.definition(def)).components[1].id
        try w.store.run("Apply") { p in
            try p.setMaterial([wall], slot: .wallBoth, materialId: m)
            try p.setMaterial([room], slot: .roomFloor, materialId: m)
            try p.setMaterial([room], slot: .roomCeiling, materialId: keepMat)
            try p.setMaterial([o], slot: .openingFrame, materialId: m)
            try p.setMaterial([a], slot: .allComponents, materialId: m)
            try p.setMaterial([b], slot: .component(compA), materialId: keepMat)
            try p.updateDefinition(def) { $0.components[1].materialId = m }
        }
        let g = try w.group([a, b])
        try w.store.run("Cfg") { _ = try $0.saveConfiguration(groupId: g, name: "1") }
        try w.store.run("Delete") { try $0.deleteObjects([m]) }
        let p = w.p
        #expect(p.material(m) == nil)
        #expect(p.wall(wall)?.leftMaterialId == nil && p.wall(wall)?.rightMaterialId == nil)
        #expect(p.room(room)?.floorMaterialId == nil)
        #expect(p.room(room)?.ceilingMaterialId == keepMat)
        #expect(p.opening(o)?.frameMaterialId == nil)
        #expect(p.instance(a)?.materialOverrides.isEmpty == true)
        #expect(p.instance(b)?.materialOverrides == [compA: keepMat])
        #expect(p.definition(def)?.components.first(where: { $0.id == compB })?.materialId == nil)
        // Stored group configurations must not keep dangling material ids either.
        let cfg = try #require(p.group(g)?.configurations.first)
        for (_, pose) in cfg.poses {
            #expect(!(pose.materialOverrides ?? [:]).values.contains(m), "configuration still references the deleted material")
        }
        // ...so activating the configuration still works.
        let cid = cfg.id
        try w.store.run("Activate") { try $0.activateConfiguration(groupId: g, configurationId: cid) }
    }

    @Test func definitionInUseCannotBeDeleted() throws {
        let w = CTWorld()
        let def = w.definition()
        let i = try w.instance(def, 0, 0)
        let e = ctThrows(.invalidArgument) { try w.store.run("Delete") { try $0.deleteObjects([def]) } }
        #expect(e?.ids == [def])
        #expect(w.p.definition(def) != nil)
        // Linked product reference is cleared once the definition goes.
        var prod = UUID()
        try w.store.run("Product") { p in
            prod = p.addProduct(CatalogProduct(name: "Sofa"))
            try p.linkProduct(prod, to: def)
        }
        #expect(w.p.product(prod)?.definitionId == def)
        try w.store.run("Delete instance") { try $0.deleteObjects([i]) }
        try w.store.run("Delete definition") { try $0.deleteObjects([def]) }
        #expect(w.p.definitions.isEmpty)
        #expect(w.p.product(prod)?.definitionId == nil)
    }

    @Test func deletingProductClearsReferences() throws {
        let w = CTWorld()
        let def = w.definition()
        let a = try w.instance(def, 0, 0)
        let b = try w.instance(def, 1000, 0)
        let g = try w.group([a, b])
        var prod = UUID()
        try w.store.run("Link") { p in
            prod = p.addProduct(CatalogProduct(name: "Sofa"))
            try p.linkProduct(prod, to: a)
            try p.linkProduct(prod, to: g)
            try p.linkProduct(prod, to: def)
        }
        #expect(w.p.instance(a)?.productId == prod && w.p.group(g)?.productId == prod && w.p.definition(def)?.productId == prod)
        try w.store.run("Delete") { try $0.deleteObjects([prod]) }
        #expect(w.p.products.isEmpty)
        #expect(w.p.instance(a)?.productId == nil)
        #expect(w.p.group(g)?.productId == nil)
        #expect(w.p.definition(def)?.productId == nil)
        // Unknown product cannot be linked.
        ctThrows(.notFound) { try w.store.run("Link") { try $0.linkProduct(UUID(), to: a) } }
        ctThrows(.invalidArgument) { try w.store.run("Link") { p in
            let q = p.addProduct(CatalogProduct(name: "Q"))
            try p.linkProduct(q, to: w.level)
        } }
    }

    @Test func deleteRejectsUnknownAndLockedObjects() throws {
        let w = CTWorld()
        let a = try w.wall(P2(0, 0), P2(1000, 0))
        ctThrows(.notFound) { try w.store.run("D") { try $0.deleteObjects([UUID()]) } }
        try w.store.run("Lock") { try $0.setLocked([a], true) }
        ctThrows(.locked) { try w.store.run("D") { try $0.deleteObjects([a]) } }
        #expect(w.p.walls.count == 1)
    }

    @Test func assetInUseCannotBeDeleted() throws {
        let w = CTWorld()
        let asset = ProjectAsset(kind: .background, storedName: "a.png", originalName: "a.png", sha256: "abc", byteCount: 3)
        var bg = UUID()
        try w.store.run("Bg") { p in
            p.addAsset(asset)
            bg = try p.addBackground(BackgroundImage(levelId: w.level, assetId: asset.id, calibrationA: P2(0, 0), calibrationB: P2(100, 0), calibrationLength: 1000, origin: .zero))
        }
        ctThrows(.invalidArgument) { try w.store.run("D") { try $0.deleteObjects([asset.id]) } }
        try w.store.run("D") { try $0.deleteObjects([bg]) }
        try w.store.run("D") { try $0.deleteObjects([asset.id]) }
        #expect(w.p.assets.isEmpty)
    }
}

// MARK: - Duplicate

@MainActor @Suite("Command duplicate") struct CommandDuplicateTests {
    @Test func duplicateWallCopiesOpeningsWithNewIds() throws {
        let w = CTWorld()
        let a = try w.wall(P2(0, 0), P2(4000, 0))
        let o = try w.opening(a, offset: 1000, width: 900)
        try w.store.run("Lock") { try $0.setLocked([a], true) }
        var map: [UUID: UUID] = [:]
        try w.store.run("Dup") { map = try $0.duplicateObjects([a], offset: P3(0, 2000, 0)) }
        #expect(map.count == 2)
        let na = try #require(map[a]), no = try #require(map[o])
        #expect(na != a && no != o)
        #expect(w.p.wall(na)?.start == P2(0, 2000))
        #expect(w.p.wall(na)?.end == P2(4000, 2000))
        #expect(w.p.wall(na)?.locked == false)
        #expect(w.p.opening(no)?.wallId == na)
        #expect(w.p.opening(no)?.offset == 1000 && w.p.opening(no)?.width == 900)
        // Original untouched.
        #expect(w.p.wall(a)?.start == P2(0, 0))
        #expect(w.p.opening(o)?.wallId == a)
        #expect(w.p.openings.count == 2 && w.p.walls.count == 2)
    }

    @Test func duplicateGroupWithConfigurationsRemapsPoses() throws {
        let w = CTWorld()
        let def = w.definition()
        let a = try w.instance(def, 0, 0)
        let b = try w.instance(def, 1000, 0)
        let g = try w.group([a, b])
        var c1 = UUID()
        try w.store.run("Cfg1") { c1 = try $0.saveConfiguration(groupId: g, name: "1") }
        try w.store.run("Move") { try $0.moveObjects([b], by: P3(0, 1000, 0)) }
        try w.store.run("Cfg2") { _ = try $0.saveConfiguration(groupId: g, name: "2") }
        let original = try #require(w.p.group(g))
        var map: [UUID: UUID] = [:]
        try w.store.run("Dup") { map = try $0.duplicateObjects([g], offset: P3(5000, 0, 0)) }
        let ng = try #require(map[g])
        let na = try #require(map[a]), nb = try #require(map[b])
        #expect(Set([ng, na, nb]).count == 3)
        #expect(![ng, na, nb].contains { [g, a, b].contains($0) })
        let copy = try #require(w.p.group(ng))
        #expect(copy.memberIds == [na, nb])
        #expect(copy.origin == original.origin + P3(5000, 0, 0))
        #expect(w.p.instance(na)?.groupId == ng && w.p.instance(nb)?.groupId == ng)
        #expect(w.p.instance(nb)?.position == P3(6000, 1000, 0))
        #expect(copy.configurations.map(\.name) == ["1", "2"])
        #expect(Set(copy.configurations.map(\.id)).isDisjoint(with: original.configurations.map(\.id)))
        for cfg in copy.configurations { #expect(Set(cfg.poses.keys) == [na, nb]) }
        #expect(copy.configurations[0].poses[nb]?.local == original.configurations[0].poses[b]?.local)
        // Active configuration points at the copy's own configuration "2".
        #expect(copy.activeConfigurationId == copy.configurations[1].id)
        // Original is unchanged.
        #expect(w.p.group(g) == original)
        // Activating "1" on the copy puts its members relative to the copy origin.
        let copyC1 = copy.configurations[0].id
        try w.store.run("Activate") { try $0.activateConfiguration(groupId: ng, configurationId: copyC1) }
        #expect(w.p.instance(nb)?.position == P3(6000, 0, 0))
        #expect(w.p.instance(b)?.position == P3(1000, 1000, 0))
        _ = c1
    }

    @Test func duplicateInstanceAndGroupTogetherCopiesMembersOnce() throws {
        let w = CTWorld()
        let def = w.definition()
        let a = try w.instance(def, 0, 0)
        let b = try w.instance(def, 1000, 0)
        let loose = try w.instance(def, 3000, 0)
        let g = try w.group([a, b])
        try w.store.run("Dup") { _ = try $0.duplicateObjects([a, g, loose]) }
        #expect(w.p.instances.count == 6)
        #expect(w.p.groups.count == 2)
        // A single group member is copied as a loose piece.
        var map: [UUID: UUID] = [:]
        try w.store.run("Dup member") { map = try $0.duplicateObjects([b]) }
        #expect(w.p.instance(try #require(map[b]))?.groupId == nil)
    }

    @Test func duplicateRejectsOpeningsAndUnknownIds() throws {
        let w = CTWorld()
        let a = try w.wall(P2(0, 0), P2(4000, 0))
        let o = try w.opening(a, offset: 1000)
        ctThrows(.invalidArgument) { try w.store.run("Dup") { _ = try $0.duplicateObjects([o]) } }
        ctThrows(.notFound) { try w.store.run("Dup") { _ = try $0.duplicateObjects([UUID()]) } }
        #expect(w.p.openings.count == 1)
    }
}

// MARK: - Groups and configurations

@MainActor @Suite("Command groups") struct CommandGroupTests {
    /// Modular sofa: three 1000 mm modules in a row.
    private struct Sofa { let w: CTWorld; let a: UUID; let b: UUID; let c: UUID; let g: UUID }
    private func sofa() throws -> Sofa {
        let w = CTWorld()
        let def = w.definition()
        let a = try w.instance(def, 0, 0)
        let b = try w.instance(def, 1000, 0)
        let c = try w.instance(def, 2000, 0)
        return Sofa(w: w, a: a, b: b, c: c, g: try w.group([a, b, c]))
    }

    @Test func groupOriginIsBoundingBoxCentreAtLowestMember() throws {
        let w = CTWorld()
        let def = w.definition()
        let a = try w.instance(def, 0, 0, z: 100)
        let b = try w.instance(def, 1001, 600, z: 50)
        let g = try w.group([a, b])
        // x: (0 + 1001) / 2 = 500.5 rounds away from zero -> 501; y: 300; z: lowest member.
        #expect(w.p.group(g)?.origin == P3(501, 300, 50))
        #expect(w.p.group(g)?.rotationDeg == 0)
        #expect(w.p.instance(a)?.groupId == g)
    }

    @Test func groupingRulesAreEnforced() throws {
        let w = CTWorld()
        let def = w.definition()
        var up = UUID()
        try w.store.run("Level") { up = $0.addLevel(name: "Up") }
        let a = try w.instance(def, 0, 0)
        let b = try w.instance(def, 1000, 0)
        let upstairs = try w.instance(def, 0, 0, level: up)
        let wall = try w.wall(P2(0, 0), P2(1000, 0))
        ctThrows(.invalidArgument) { try w.store.run("G") { _ = try $0.groupObjects([], name: "x") } }
        ctThrows(.invalidArgument) { try w.store.run("G") { _ = try $0.groupObjects([a, wall], name: "x") } }
        ctThrows(.invalidArgument) { try w.store.run("G") { _ = try $0.groupObjects([a, upstairs], name: "x") } }
        ctThrows(.notFound) { try w.store.run("G") { _ = try $0.groupObjects([a, UUID()], name: "x") } }
        let g = try w.group([a, b])
        ctThrows(.invalidArgument) { try w.store.run("G") { _ = try $0.groupObjects([a], name: "x") } }
        ctThrows(.invalidArgument) { try w.store.run("Add") { try $0.addToGroup(g, [a]) } }
        ctThrows(.invalidArgument) { try w.store.run("Add") { try $0.addToGroup(g, [upstairs]) } }
        let c = try w.instance(def, 2000, 0)
        try w.store.run("Add") { try $0.addToGroup(g, [c]) }
        #expect(w.p.group(g)?.memberIds == [a, b, c])
        #expect(w.p.instance(c)?.groupId == g)
    }

    @Test func groupingTheSameInstanceTwiceInOneCallKeepsMembersUnique() throws {
        let w = CTWorld()
        let def = w.definition()
        let a = try w.instance(def, 0, 0)
        let b = try w.instance(def, 1000, 0)
        let g = try w.group([a, b, a])
        #expect(w.p.group(g)?.memberIds == [a, b])
        let c = try w.instance(def, 2000, 0)
        try w.store.run("Add") { try $0.addToGroup(g, [c, c]) }
        #expect(w.p.group(g)?.memberIds == [a, b, c])
    }

    @Test func ungroupKeepsMembersInPlace() throws {
        let s = try sofa()
        try s.w.store.run("Ungroup") { _ = try $0.ungroup(s.g) }
        #expect(s.w.p.groups.isEmpty)
        #expect(s.w.p.instance(s.b)?.groupId == nil)
        #expect(s.w.p.instance(s.c)?.position == P3(2000, 0, 0))
        try s.w.store.undo()
        #expect(s.w.p.group(s.g)?.memberIds == [s.a, s.b, s.c])
        #expect(s.w.p.instance(s.b)?.groupId == s.g)
    }

    @Test func modularSofaConfigurationsRestoreExactlyAndFollowGroupRotation() throws {
        let s = try sofa()
        let w = s.w
        #expect(w.p.group(s.g)?.origin == P3(1000, 0, 0))

        // Configuration "1": the straight row.
        var c1 = UUID()
        try w.store.run("Save 1") { c1 = try $0.saveConfiguration(groupId: s.g, name: "1") }
        let cfg1 = try #require(w.p.group(s.g)?.configurations.first)
        #expect(cfg1.poses[s.a]?.local == P3(-1000, 0, 0))
        #expect(cfg1.poses[s.b]?.local == P3(0, 0, 0))
        #expect(cfg1.poses[s.c]?.local == P3(1000, 0, 0))
        #expect(w.p.group(s.g)?.activeConfigurationId == c1)

        // Change the layout: module c turns into a chaise (moved up, rotated), module b hidden.
        try w.store.run("Edit") { p in
            try p.moveObjects([s.c], by: P3(0, 1000, 0))
            try p.rotateObjects([s.c], by: 90)
            try p.setVisible([s.b], false)
        }
        var c2 = UUID()
        try w.store.run("Save 2") { c2 = try $0.saveConfiguration(groupId: s.g, name: "2") }
        #expect(c1 != c2)
        let afterSave2 = try #require(w.p.group(s.g))
        #expect(afterSave2.configurations.count == 2)
        #expect(afterSave2.configurations[0] == cfg1, "saving 2 does not touch 1")
        #expect(afterSave2.configurations[1].poses[s.c]?.local == P3(1000, 1000, 0))
        #expect(afterSave2.configurations[1].poses[s.c]?.rotationDeg == 90)
        #expect(afterSave2.configurations[1].poses[s.b]?.visible == false)

        // Editing while in 2 and re-saving 2 leaves 1 untouched.
        try w.store.run("Edit more") { try $0.moveObjects([s.a], by: P3(0, -300, 0)) }
        try w.store.run("Save 2 again") { c2 = try $0.saveConfiguration(groupId: s.g, name: "2") }
        #expect(w.p.group(s.g)?.configurations.count == 2, "same name replaces")
        #expect(w.p.group(s.g)?.configurations[0] == cfg1)

        // Activate 1: exact positions, rotations and visibility come back.
        try w.store.run("Activate 1") { try $0.activateConfiguration(groupId: s.g, configurationId: c1) }
        #expect(w.p.instance(s.a)?.position == P3(0, 0, 0))
        #expect(w.p.instance(s.b)?.position == P3(1000, 0, 0))
        #expect(w.p.instance(s.c)?.position == P3(2000, 0, 0))
        #expect(w.p.instance(s.c)?.rotationDeg == 0)
        #expect(w.p.instance(s.b)?.visible == true)
        #expect(w.p.group(s.g)?.activeConfigurationId == c1)

        // Rotate the whole group by 90 degrees, then activate 2.
        try w.store.run("Rotate group") { try $0.rotateObjects([s.g], by: 90) }
        #expect(w.p.group(s.g)?.rotationDeg == 90)
        #expect(w.p.instance(s.c)?.position.xy == P2(1000, 1000))
        try w.store.run("Activate 2") { try $0.activateConfiguration(groupId: s.g, configurationId: c2) }
        // Configuration 2 locals: a (-1000,-300), b (0,0), c (1000,1000). Rotated 90 degrees CCW around (1000,0).
        #expect(w.p.instance(s.a)?.position.xy == P2(1300, -1000))
        #expect(w.p.instance(s.b)?.position.xy == P2(1000, 0))
        #expect(w.p.instance(s.c)?.position.xy == P2(0, 1000))
        #expect(w.p.instance(s.a)?.rotationDeg == 90)
        #expect(w.p.instance(s.c)?.rotationDeg == 180)
        #expect(w.p.instance(s.b)?.visible == false)

        // Rotating back and re-activating 1 gives the original row again.
        try w.store.run("Rotate back") { try $0.rotateObjects([s.g], by: 270) }
        try w.store.run("Activate 1") { try $0.activateConfiguration(groupId: s.g, configurationId: c1) }
        #expect(w.p.instance(s.a)?.position == P3(0, 0, 0))
        #expect(w.p.instance(s.c)?.position == P3(2000, 0, 0))
        #expect(w.p.instance(s.c)?.rotationDeg == 0)
        #expect(w.p.group(s.g)?.rotationDeg == 0)
    }

    @Test func configurationsSurviveUndoAndRedo() throws {
        let s = try sofa()
        let w = s.w
        var c1 = UUID(), c2 = UUID()
        try w.store.run("Save 1") { c1 = try $0.saveConfiguration(groupId: s.g, name: "1") }
        try w.store.run("Edit") { try $0.moveObjects([s.c], by: P3(0, 500, 0)) }
        try w.store.run("Save 2") { c2 = try $0.saveConfiguration(groupId: s.g, name: "2") }
        try w.store.run("Activate 1") { try $0.activateConfiguration(groupId: s.g, configurationId: c1) }
        let atOne = ctNormalized(w.p)
        try w.store.undo() // activate 1
        #expect(w.p.instance(s.c)?.position == P3(2000, 500, 0))
        #expect(w.p.group(s.g)?.activeConfigurationId == c2)
        try w.store.undo() // save 2
        #expect(w.p.group(s.g)?.configurations.map(\.id) == [c1])
        try w.store.redo()
        #expect(w.p.group(s.g)?.configurations.map(\.id) == [c1, c2])
        try w.store.redo()
        #expect(ctNormalized(w.p) == atOne)
        // Deleting a configuration clears the active pointer and is undoable.
        try w.store.run("Del cfg") { try $0.deleteConfiguration(groupId: s.g, configurationId: c1) }
        #expect(w.p.group(s.g)?.configurations.map(\.id) == [c2])
        #expect(w.p.group(s.g)?.activeConfigurationId == nil)
        try w.store.undo()
        #expect(w.p.group(s.g)?.activeConfigurationId == c1)
        ctThrows(.notFound) { try w.store.run("Del cfg") { try $0.deleteConfiguration(groupId: s.g, configurationId: UUID()) } }
    }

    @Test func configurationErrors() throws {
        let s = try sofa()
        ctThrows(.invalidArgument) { try s.w.store.run("Save") { _ = try $0.saveConfiguration(groupId: s.g, name: "  ") } }
        ctThrows(.notFound) { try s.w.store.run("Save") { _ = try $0.saveConfiguration(groupId: UUID(), name: "x") } }
        ctThrows(.notFound) { try s.w.store.run("Act") { try $0.activateConfiguration(groupId: s.g, configurationId: UUID()) } }
        var c = UUID()
        try s.w.store.run("Save") { c = try $0.saveConfiguration(groupId: s.g, name: "Row") }
        // Case-insensitive name replaces the existing configuration.
        var again = UUID()
        try s.w.store.run("Save") { again = try $0.saveConfiguration(groupId: s.g, name: "ROW") }
        #expect(again == c)
        // A locked member blocks activation.
        try s.w.store.run("Lock") { try $0.setLocked([s.b], true) }
        let before = s.w.p
        ctThrows(.locked) { try s.w.store.run("Act") { try $0.activateConfiguration(groupId: s.g, configurationId: c) } }
        #expect(s.w.p == before)
    }

    @Test func configurationStoresRotationOfARotatedGroupRelatively() throws {
        let s = try sofa()
        let w = s.w
        try w.store.run("Rotate") { try $0.rotateObjects([s.g], by: 90) }
        var c = UUID()
        try w.store.run("Save") { c = try $0.saveConfiguration(groupId: s.g, name: "Rotated row") }
        let cfg = try #require(w.p.group(s.g)?.configurations.first)
        #expect(cfg.poses[s.a]?.local == P3(-1000, 0, 0), "stored in the group's own frame")
        #expect(cfg.poses[s.a]?.rotationDeg == 0)
        try w.store.run("Rotate more") { try $0.rotateObjects([s.g], by: 90) }
        try w.store.run("Act") { try $0.activateConfiguration(groupId: s.g, configurationId: c) }
        #expect(w.p.instance(s.a)?.position.xy == P2(2000, 0))
        #expect(w.p.instance(s.a)?.rotationDeg == 180)
    }
}

// MARK: - States

@MainActor @Suite("Command states") struct CommandStateTests {
    @Test func defineAndActivateStateChangesStateIdAndUndoRestores() throws {
        let w = CTWorld()
        let def = w.definition()
        let i = try w.instance(def, 0, 0)
        let comp = try #require(w.p.definition(def)).components[0].id
        #expect(w.p.instance(i)?.stateId == nil)
        var open = UUID()
        try w.store.run("Define") {
            open = try $0.defineState(definitionId: def, FurnitureState(name: "open", poses: [comp: ComponentPose(position: P3(0, 0, 300))]))
        }
        #expect(w.p.definition(def)?.states.map(\.id) == [open])
        #expect(w.p.definition(def)?.defaultStateId == open, "first state becomes the default")
        #expect(w.p.instance(i)?.stateId == nil, "existing instances keep the base pose")
        try w.store.run("Activate") { try $0.activateState([i], stateId: open) }
        #expect(w.p.instance(i)?.stateId == open)
        try w.store.undo()
        #expect(w.p.instance(i)?.stateId == nil)
        try w.store.redo()
        #expect(w.p.instance(i)?.stateId == open)
        try w.store.run("Base") { try $0.activateState([i], stateId: nil) }
        #expect(w.p.instance(i)?.stateId == nil)
        // New instances start in the default state.
        let j = try w.instance(def, 500, 0)
        #expect(w.p.instance(j)?.stateId == open)
    }

    @Test func activateStateRejectsForeignAndUnknownStates() throws {
        let w = CTWorld()
        let d1 = w.definition(name: "One")
        let d2 = w.definition(name: "Two")
        let i = try w.instance(d1, 0, 0)
        let comp2 = try #require(w.p.definition(d2)).components[0].id
        var foreign = UUID()
        try w.store.run("Define") { foreign = try $0.defineState(definitionId: d2, FurnitureState(name: "x", poses: [comp2: ComponentPose(visible: false)])) }
        ctThrows(.notFound) { try w.store.run("Act") { try $0.activateState([i], stateId: foreign) } }
        ctThrows(.notFound) { try w.store.run("Act") { try $0.activateState([i], stateId: UUID()) } }
        ctThrows(.notFound) { try w.store.run("Act") { try $0.activateState([UUID()], stateId: nil) } }
        #expect(w.p.instance(i)?.stateId == nil)
        // A raw edit that smuggles in a foreign state is caught by the validator.
        ctThrows(.notFound) { try w.store.run("Raw") { try $0.updateInstance(i) { $0.stateId = foreign } } }
    }

    @Test func defineStateWithSameNameReplacesAndKeepsId() throws {
        let w = CTWorld()
        let def = w.definition()
        let comp = try #require(w.p.definition(def)).components[0].id
        var s1 = UUID(), s2 = UUID(), s3 = UUID()
        try w.store.run("D1") { s1 = try $0.defineState(definitionId: def, FurnitureState(name: "Folded", poses: [:])) }
        try w.store.run("D2") { s2 = try $0.defineState(definitionId: def, FurnitureState(name: "folded", poses: [comp: ComponentPose(visible: false)])) }
        #expect(s1 == s2)
        #expect(w.p.definition(def)?.states.count == 1)
        #expect(w.p.definition(def)?.states[0].poses[comp]?.visible == false)
        try w.store.run("D3") { s3 = try $0.defineState(definitionId: def, FurnitureState(name: "Open"), makeDefault: true) }
        #expect(w.p.definition(def)?.defaultStateId == s3)
        // Poses for a component that does not exist are rejected.
        ctThrows(.notFound) { try w.store.run("D4") { _ = try $0.defineState(definitionId: def, FurnitureState(name: "Bad", poses: [UUID(): ComponentPose()])) } }
    }

    @Test func removingAStateResetsInstancesToTheDefault() throws {
        let w = CTWorld()
        let def = w.definition()
        let i = try w.instance(def, 0, 0)
        var s1 = UUID(), s2 = UUID()
        try w.store.run("D") { p in
            s1 = try p.defineState(definitionId: def, FurnitureState(name: "A"))
            s2 = try p.defineState(definitionId: def, FurnitureState(name: "B"))
        }
        try w.store.run("Act") { try $0.activateState([i], stateId: s2) }
        try w.store.run("Remove") { try $0.updateDefinition(def) { $0.states.removeAll { $0.id == s2 } } }
        #expect(w.p.instance(i)?.stateId == s1, "falls back to the default state")
    }

    @Test func lockedInstanceCannotChangeState() throws {
        let w = CTWorld()
        let def = w.definition()
        let i = try w.instance(def, 0, 0)
        var s = UUID()
        try w.store.run("D") { s = try $0.defineState(definitionId: def, FurnitureState(name: "A")) }
        try w.store.run("Lock") { try $0.setLocked([i], true) }
        ctThrows(.locked) { try w.store.run("Act") { try $0.activateState([i], stateId: s) } }
    }
}

// MARK: - Materials and locks

@MainActor @Suite("Command materials and locks") struct CommandMaterialLockTests {
    @Test func materialSlotParsing() {
        let id = UUID()
        #expect(MaterialSlot(string: "wallLeft") == .wallLeft)
        #expect(MaterialSlot(string: "wall_left") == .wallLeft)
        #expect(MaterialSlot(string: "LEFT") == .wallLeft)
        #expect(MaterialSlot(string: "wall_right") == .wallRight)
        #expect(MaterialSlot(string: "wall") == .wallBoth)
        #expect(MaterialSlot(string: "Both") == .wallBoth)
        #expect(MaterialSlot(string: "floor") == .roomFloor)
        #expect(MaterialSlot(string: "room_ceiling") == .roomCeiling)
        #expect(MaterialSlot(string: "frame") == .openingFrame)
        #expect(MaterialSlot(string: "opening_frame") == .openingFrame)
        #expect(MaterialSlot(string: "furniture") == .allComponents)
        #expect(MaterialSlot(string: "all_components") == .allComponents)
        #expect(MaterialSlot(string: "component:\(id.uuidString)") == .component(id))
        #expect(MaterialSlot(string: "Component:\(id.uuidString.lowercased())") == .component(id))
        #expect(MaterialSlot(string: "component:not-a-uuid") == nil)
        #expect(MaterialSlot(string: "component:") == nil)
        #expect(MaterialSlot(string: "component") == nil)
        #expect(MaterialSlot(string: "") == nil)
        #expect(MaterialSlot(string: "roof") == nil)
    }

    @Test func setMaterialAppliesSlotsAndClears() throws {
        let w = CTWorld()
        let def = w.definition()
        let m = w.material()
        let wall = try w.wall(P2(0, 0), P2(4000, 0))
        let o = try w.opening(wall, offset: 2000)
        let i = try w.instance(def, 0, 0)
        let comps = try #require(w.p.definition(def)).components.map(\.id)
        var room = UUID()
        try w.store.run("Room") { room = try $0.addRoom(levelId: w.level, name: "R", points: [P2(0, 0), P2(1000, 0), P2(1000, 1000)]) }
        try w.store.run("Left") { try $0.setMaterial([wall], slot: .wallLeft, materialId: m) }
        #expect(w.p.wall(wall)?.leftMaterialId == m && w.p.wall(wall)?.rightMaterialId == nil)
        try w.store.run("Right") { try $0.setMaterial([wall], slot: .wallRight, materialId: m) }
        try w.store.run("Clear both") { try $0.setMaterial([wall], slot: .wallBoth, materialId: nil) }
        #expect(w.p.wall(wall)?.leftMaterialId == nil && w.p.wall(wall)?.rightMaterialId == nil)
        try w.store.run("Floor") { try $0.setMaterial([room], slot: .roomFloor, materialId: m) }
        try w.store.run("Ceiling") { try $0.setMaterial([room], slot: .roomCeiling, materialId: m) }
        try w.store.run("Frame") { try $0.setMaterial([o], slot: .openingFrame, materialId: m) }
        #expect(w.p.room(room)?.floorMaterialId == m && w.p.room(room)?.ceilingMaterialId == m)
        #expect(w.p.opening(o)?.frameMaterialId == m)
        try w.store.run("All") { try $0.setMaterial([i], slot: .allComponents, materialId: m) }
        #expect(w.p.instance(i)?.materialOverrides == [comps[0]: m, comps[1]: m])
        try w.store.run("One") { try $0.setMaterial([i], slot: .component(comps[1]), materialId: nil) }
        #expect(w.p.instance(i)?.materialOverrides[comps[1]] == nil)
        try w.store.run("None") { try $0.setMaterial([i], slot: .allComponents, materialId: nil) }
        #expect(w.p.instance(i)?.materialOverrides.isEmpty == true)
    }

    @Test func setMaterialOnGroupAppliesToMembers() throws {
        let w = CTWorld()
        let def = w.definition()
        let m = w.material()
        let a = try w.instance(def, 0, 0)
        let b = try w.instance(def, 1000, 0)
        let g = try w.group([a, b])
        try w.store.run("Mat") { try $0.setMaterial([g], slot: .allComponents, materialId: m) }
        #expect(w.p.instance(a)?.materialOverrides.count == 2)
        #expect(w.p.instance(b)?.materialOverrides.count == 2)
    }

    @Test func setMaterialErrors() throws {
        let w = CTWorld()
        let def = w.definition()
        let m = w.material()
        let wall = try w.wall(P2(0, 0), P2(4000, 0))
        let i = try w.instance(def, 0, 0)
        ctThrows(.notFound) { try w.store.run("M") { try $0.setMaterial([wall], slot: .wallBoth, materialId: UUID()) } }
        ctThrows(.invalidArgument) { try w.store.run("M") { try $0.setMaterial([wall], slot: .roomFloor, materialId: m) } }
        ctThrows(.invalidArgument) { try w.store.run("M") { try $0.setMaterial([i], slot: .wallLeft, materialId: m) } }
        ctThrows(.notFound) { try w.store.run("M") { try $0.setMaterial([i], slot: .component(UUID()), materialId: m) } }
        ctThrows(.notFound) { try w.store.run("M") { try $0.setMaterial([UUID()], slot: .wallLeft, materialId: m) } }
        #expect(w.p.wall(wall)?.leftMaterialId == nil)
    }

    @Test func setLockedWorksOnLockedObjectsButOtherEditsThrowLocked() throws {
        let w = CTWorld()
        let def = w.definition()
        let a = try w.wall(P2(0, 0), P2(4000, 0))
        let o = try w.opening(a, offset: 2000)
        let i = try w.instance(def, 0, 0)
        let m = w.material()
        try w.store.run("Lock") { try $0.setLocked([a, i], true) }
        try w.store.run("Lock again") { try $0.setLocked([a], true) } // no-op, no error
        #expect(w.p.wall(a)?.locked == true && w.p.instance(i)?.locked == true)
        let before = w.p
        let e = ctThrows(.locked) { try w.store.run("Move") { try $0.moveObjects([a], by: P3(1, 0, 0)) } }
        #expect(e?.ids == [a])
        ctThrows(.locked) { try w.store.run("Move") { try $0.moveObjects([i], by: P3(1, 0, 0)) } }
        ctThrows(.locked) { try w.store.run("Rotate") { try $0.rotateObjects([i], by: 90) } }
        ctThrows(.locked) { try w.store.run("Wall") { try $0.updateWall(a, thickness: 300) } }
        ctThrows(.locked) { try w.store.run("Opening") { try $0.updateOpening(o, width: 700) } }
        ctThrows(.locked) { try w.store.run("Opening") { _ = try $0.addOpening(wallId: a, kind: .window, offset: 500, width: 400, height: 500) } }
        ctThrows(.locked) { try w.store.run("Mat") { try $0.setMaterial([i], slot: .allComponents, materialId: m) } }
        ctThrows(.locked) { try w.store.run("Inst") { try $0.updateInstance(i) { $0.name = "x" } } }
        ctThrows(.locked) { try w.store.run("Del") { try $0.deleteObjects([i]) } }
        ctThrows(.locked) { try w.store.run("Slide") { try $0.moveObjects([o], by: P3(10, 0, 0)) } }
        #expect(w.p == before)
        try w.store.run("Unlock") { try $0.setLocked([a, i], false) }
        try w.store.run("Move") { try $0.moveObjects([a, i], by: P3(1, 0, 0)) }
        #expect(w.p.wall(a)?.start == P2(1, 0))
    }

    @Test func lockRulesForGroupsLevelsAndUnsupportedKinds() throws {
        let w = CTWorld()
        let def = w.definition()
        let a = try w.instance(def, 0, 0)
        let b = try w.instance(def, 1000, 0)
        let g = try w.group([a, b])
        let wall = try w.wall(P2(0, 0), P2(4000, 0))
        let o = try w.opening(wall, offset: 2000)
        try w.store.run("Lock group") { try $0.setLocked([g], true) }
        ctThrows(.locked) { try w.store.run("Move") { try $0.moveObjects([a], by: P3(1, 0, 0)) } }
        // Unlocking one member does not unlock the group.
        try w.store.run("Unlock member") { try $0.setLocked([a], false) }
        ctThrows(.locked) { try w.store.run("Move") { try $0.moveObjects([a], by: P3(1, 0, 0)) } }
        try w.store.run("Unlock group") { try $0.setLocked([g], false) }
        try w.store.run("Move") { try $0.moveObjects([a], by: P3(1, 0, 0)) }
        // Locked level blocks edits of its content but can be unlocked.
        try w.store.run("Lock level") { try $0.setLocked([w.level], true) }
        ctThrows(.locked) { try w.store.run("Move") { try $0.moveObjects([wall], by: P3(1, 0, 0)) } }
        ctThrows(.locked) { try w.store.run("Move") { try $0.moveObjects([b], by: P3(1, 0, 0)) } }
        try w.store.run("Unlock level") { try $0.setLocked([w.level], false) }
        try w.store.run("Move") { try $0.moveObjects([wall], by: P3(1, 0, 0)) }
        // Not lockable / unknown.
        ctThrows(.invalidArgument) { try w.store.run("L") { try $0.setLocked([o], true) } }
        ctThrows(.notFound) { try w.store.run("L") { try $0.setLocked([UUID()], true) } }
    }

    @Test func lockedStateStaysAfterUndoOfLaterCommands() throws {
        let w = CTWorld()
        let a = try w.wall(P2(0, 0), P2(4000, 0))
        try w.store.run("Lock") { try $0.setLocked([a], true) }
        #expect(w.p.wall(a)?.rev == 2)
        try w.store.undo()
        #expect(w.p.wall(a)?.locked == false)
        try w.store.redo()
        #expect(w.p.wall(a)?.locked == true)
    }
}
