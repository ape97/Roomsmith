import Testing
import Foundation
import simd
@testable import RoomsmithCore

// MARK: - Helpers

private func makeProject() -> (Project, UUID) {
    let p = Project.empty(name: "T")
    return (p, p.levels[0].id)
}

private func box(_ w: MM, _ d: MM, _ h: MM) -> FurnitureDefinition {
    FurnitureDefinition(name: "Box", category: "t", size: Size3(w, d, h),
                        components: [Component(name: "c", shape: .box, position: P3(0, 0, h / 2), size: Size3(w, d, h))])
}

private func minFaceDistance(_ inst: FurnitureInstance, _ def: FurnitureDefinition, position: P2, rotation: Double, wall: Wall, side: Double) -> Double {
    var i = inst
    i.position = P3(position.x, position.y, 0)
    i.rotationDeg = rotation
    let ax = Geo.axis(wall.start, wall.end)
    let n = ax.normal * side
    let f0 = wall.start.v + n * (Double(wall.thickness) / 2)
    return FurnitureResolver.footprint(of: i, definition: def).corners.map { simd_dot($0 - f0, n) }.min()!
}

@Suite("Snap") struct SnapTests {
    let settings = SnapSettings() // grid 10, angleStep 15

    @Test func endpointBeatsGridInsideTolerance() {
        let (_, lvl) = makeProject()
        let ctx = SnapContext(walls: [Wall(levelId: lvl, start: P2(1003, 2001), end: P2(5003, 2001))])
        let r = SnapEngine.snapPoint(V2(1010, 1998), context: ctx, settings: settings, tolerance: 20)
        #expect(r.kind == .wallEndpoint)
        #expect(r.point == P2(1003, 2001))
        #expect(r.targetId != nil)
    }

    @Test func outsideToleranceFallsBackToGrid() {
        let (_, lvl) = makeProject()
        let ctx = SnapContext(walls: [Wall(levelId: lvl, start: P2(1003, 2001), end: P2(5003, 2001))])
        let r = SnapEngine.snapPoint(V2(3004, 8004), context: ctx, settings: settings, tolerance: 20)
        #expect(r.kind == .grid)
        #expect(r.point == P2(3000, 8000))
    }

    @Test func midpointAndFacePriority() {
        let (_, lvl) = makeProject()
        let w = Wall(levelId: lvl, start: P2(0, 0), end: P2(4000, 0), thickness: 100)
        let ctx = SnapContext(walls: [w])
        let mid = SnapEngine.snapPoint(V2(2005, 10), context: ctx, settings: settings, tolerance: 30)
        #expect(mid.kind == .wallMidpoint)
        #expect(mid.point == P2(2000, 0))
        let face = SnapEngine.snapPoint(V2(1000, 60), context: ctx, settings: settings, tolerance: 30)
        #expect(face.kind == .wallFace)
        #expect(face.point == P2(1000, 50))
    }

    @Test func disabledReturnsRoundedInput() {
        var s = settings; s.enabled = false
        let r = SnapEngine.snapPoint(V2(10.5, -3.5), context: SnapContext(), settings: s, tolerance: 50)
        #expect(r.kind == .none)
        #expect(r.point == P2(11, -4))
    }

    @Test func drawWall45DegreesWith15Step() {
        var ctx = SnapContext()
        ctx.anchor = P2(0, 0)
        let r = SnapEngine.snapPoint(V2(3005, 2995), context: ctx, settings: settings, tolerance: 60)
        #expect(r.kind == .angle)
        #expect(r.point.x == r.point.y)
        let ang = atan2(Double(r.point.y), Double(r.point.x)) * 180 / .pi
        #expect(abs(ang - 45) < 1e-9)
        #expect(abs(Geo.distance(P2(0, 0), r.point) - 4240) < 1)
    }

    @Test func drawWallLengthExactly4250() {
        var ctx = SnapContext()
        ctx.anchor = P2(1000, 1000)
        let r = SnapEngine.snapPoint(V2(1000 + 4247, 1000 + 4), context: ctx, settings: settings, tolerance: 30)
        #expect(r.kind == .angle)
        #expect(r.point == P2(5250, 1000))
        #expect(Geo.distance(P2(1000, 1000), r.point) == 4250)
        let free = SnapEngine.snapPoint(V2(1000 + 4247, 1000 + 400), context: ctx, settings: settings, tolerance: 30)
        #expect(free.kind == .length)
    }

    @Test func snapDeltaRoundsHalfAwayFromZero() {
        #expect(SnapEngine.snapDelta(3.4, grid: 5, enabled: true) == 5)
        #expect(SnapEngine.snapDelta(2.4, grid: 5, enabled: true) == 0)
        #expect(SnapEngine.snapDelta(2.5, grid: 5, enabled: true) == 5)
        #expect(SnapEngine.snapDelta(-2.5, grid: 5, enabled: true) == -5)
        #expect(SnapEngine.snapDelta(14, grid: 10, enabled: true) == 10)
        #expect(SnapEngine.snapDelta(15, grid: 10, enabled: true) == 20)
        #expect(SnapEngine.snapDelta(-15, grid: 10, enabled: true) == -20)
        #expect(SnapEngine.snapDelta(14.6, grid: 10, enabled: false) == 15)
    }

    @Test func snapAngleSteps() {
        #expect(SnapEngine.snapAngle(52, step: 15, enabled: true) == 45)
        #expect(SnapEngine.snapAngle(-10, step: 15, enabled: true) == 345)
        #expect(SnapEngine.snapAngle(52, step: 15, enabled: false) == 52)
    }

    @Test func furnitureDocksFlushOnAxisWall() {
        let (_, lvl) = makeProject()
        let def = box(1000, 500, 800)
        let inst = FurnitureInstance(definitionId: def.id, levelId: lvl, name: "f", position: P3(2000, 290, 0))
        let wall = Wall(levelId: lvl, start: P2(0, 0), end: P2(5000, 0), thickness: 100)
        let r = SnapEngine.snapFurniture(inst, definition: def, proposed: P2(2000, 290), context: SnapContext(walls: [wall]), tolerance: 40, alignRotation: false)
        #expect(r.kind == .wallFace)
        #expect(r.position == P2(2000, 300)) // face at y = 50, half depth 250
        #expect(r.guides.count == 1)
        let far = SnapEngine.snapFurniture(inst, definition: def, proposed: P2(2000, 500), context: SnapContext(walls: [wall]), tolerance: 40, alignRotation: false)
        #expect(far.kind == .none)
        #expect(far.position == P2(2000, 500))
    }

    @Test func furnitureDocksToRotatedWallWithAlignment() {
        let (_, lvl) = makeProject()
        let def = box(1000, 500, 800)
        let end = P2(4330, 2500) // ≈ 30°
        let wall = Wall(levelId: lvl, start: P2(0, 0), end: end, thickness: 100)
        let ax = Geo.axis(wall.start, wall.end)
        let centre = ax.dir * 2000 + ax.normal * (50 + 250 + 25) // 25 mm too far
        let proposed = P2(rounding: centre)
        let inst = FurnitureInstance(definitionId: def.id, levelId: lvl, name: "f", position: P3(proposed.x, proposed.y, 0), rotationDeg: 38)
        let r = SnapEngine.snapFurniture(inst, definition: def, proposed: proposed, context: SnapContext(walls: [wall]), tolerance: 40, alignRotation: true)
        #expect(r.kind == .wallFace)
        let wallDeg = atan2(ax.dir.y, ax.dir.x) * 180 / .pi
        #expect(abs(r.rotationDeg - wallDeg) < 0.001)
        let d = minFaceDistance(inst, def, position: r.position, rotation: r.rotationDeg, wall: wall, side: 1)
        #expect(abs(d) < 0.5)
        // Without alignment the rotation stays; the nearest corner touches the face instead.
        let free = SnapEngine.snapFurniture(inst, definition: def, proposed: proposed, context: SnapContext(walls: [wall]), tolerance: 40, alignRotation: false)
        #expect(free.rotationDeg == 38)
    }

    @Test func furnitureDocksIntoRoomCorner() {
        let (_, lvl) = makeProject()
        let def = box(1000, 500, 800)
        let walls = [Wall(levelId: lvl, start: P2(0, 0), end: P2(5000, 0), thickness: 100),
                     Wall(levelId: lvl, start: P2(0, 0), end: P2(0, 5000), thickness: 100)]
        let inst = FurnitureInstance(definitionId: def.id, levelId: lvl, name: "f", position: P3(560, 290, 0))
        let r = SnapEngine.snapFurniture(inst, definition: def, proposed: P2(560, 290), context: SnapContext(walls: walls), tolerance: 40, alignRotation: false)
        #expect(r.position == P2(550, 300))
        #expect(r.guides.count == 2)
    }

    @Test func contextMakeExcludesAndFiltersLevel() {
        var (p, lvl) = makeProject()
        let other = UUID()
        let w1 = Wall(levelId: lvl, start: P2(0, 0), end: P2(1000, 0))
        let w2 = Wall(levelId: other, start: P2(0, 0), end: P2(1000, 0))
        p.walls = [w1, w2]
        #expect(SnapContext.make(project: p, levelId: lvl, exclude: []).walls.count == 1)
        #expect(SnapContext.make(project: p, levelId: lvl, exclude: [w1.id]).walls.isEmpty)
    }
}

@Suite("Collision") struct CollisionTests {
    private func place(_ p: inout Project, _ def: FurnitureDefinition, _ lvl: UUID, _ x: MM, _ y: MM, z: MM = 0, rot: Double = 0) -> FurnitureInstance {
        if !p.definitions.contains(where: { $0.id == def.id }) { p.definitions.append(def) }
        let i = FurnitureInstance(definitionId: def.id, levelId: lvl, name: "i", position: P3(x, y, z), rotationDeg: rot)
        p.instances.append(i)
        return i
    }

    @Test func overlapTouchStack() {
        var (p, lvl) = makeProject()
        let def = box(1000, 1000, 800)
        let a = place(&p, def, lvl, 0, 0)
        let b = place(&p, def, lvl, 900, 0)
        var issues = CollisionChecker.check(p, levelId: lvl)
        #expect(issues.count == 1)
        #expect(issues[0].kind == .furnitureOverlap)
        #expect(Set([issues[0].a, issues[0].b!]) == Set([a.id, b.id]))
        #expect(abs(issues[0].depth - 100) < 0.01)
        // touching
        p.instances[1].position = P3(1000, 0, 0)
        #expect(CollisionChecker.check(p, levelId: lvl).isEmpty)
        // stacked: shelf above the table's top
        p.instances[1].position = P3(0, 0, 800)
        #expect(CollisionChecker.check(p, levelId: lvl).isEmpty)
        // 1 mm lower is still resting (`RestingSurface.zTolerance`); a real sink-in collides.
        p.instances[1].position = P3(0, 0, 799)
        #expect(CollisionChecker.check(p, levelId: lvl).isEmpty)
        p.instances[1].position = P3(0, 0, 790)
        issues = CollisionChecker.check(p, levelId: lvl)
        #expect(issues.count == 1)
        // invisible ignored
        p.instances[1].visible = false
        #expect(CollisionChecker.check(p, levelId: lvl).isEmpty)
    }

    @Test func rotatedOverlap() {
        var (p, lvl) = makeProject()
        let def = box(2000, 200, 800)
        _ = place(&p, def, lvl, 0, 0)
        _ = place(&p, def, lvl, 0, 0, rot: 90)
        #expect(CollisionChecker.check(p, levelId: lvl).count == 1)
    }

    @Test func groupMembersIgnoreEachOther() {
        var (p, lvl) = makeProject()
        let def = box(1000, 1000, 800)
        let a = place(&p, def, lvl, 0, 0)
        let b = place(&p, def, lvl, 500, 0)
        let g = FurnitureGroup(name: "g", levelId: lvl, origin: .zero, memberIds: [a.id, b.id])
        p.groups = [g]
        p.instances[0].groupId = g.id
        p.instances[1].groupId = g.id
        #expect(CollisionChecker.check(p, levelId: lvl).isEmpty)
        p.instances[1].groupId = nil
        p.groups[0].memberIds = [a.id]
        #expect(CollisionChecker.check(p, levelId: lvl).count == 1)
    }

    @Test func furnitureAgainstWall() {
        var (p, lvl) = makeProject()
        p.walls = [Wall(levelId: lvl, start: P2(0, 0), end: P2(4000, 0), thickness: 100, height: 2500)]
        let def = box(1000, 500, 800)
        let f = place(&p, def, lvl, 2000, 280) // bottom edge y = 30 < face y = 50
        let issues = CollisionChecker.check(p, levelId: lvl)
        #expect(issues.count == 1)
        #expect(issues[0].kind == .furnitureWall)
        #expect(issues[0].a == f.id && issues[0].b == p.walls[0].id)
        #expect(abs(issues[0].depth - 20) < 0.01)
        p.instances[0].position = P3(2000, 300, 0) // flush
        #expect(CollisionChecker.check(p, levelId: lvl).isEmpty)
        p.instances[0].position = P3(2000, 280, 2500) // above the wall
        #expect(CollisionChecker.check(p, levelId: lvl).isEmpty)
    }

    @Test func furnitureInDoorHoleBlocksOpeningNotWall() {
        var (p, lvl) = makeProject()
        let wall = Wall(levelId: lvl, start: P2(0, 0), end: P2(4000, 0), thickness: 100, height: 2500)
        p.walls = [wall]
        let door = Opening(wallId: wall.id, kind: .door, offset: 2000, width: 900, height: 2100, sill: 0)
        p.openings = [door]
        let def = box(500, 300, 800)
        let f = place(&p, def, lvl, 2000, 0)
        let issues = CollisionChecker.check(p, levelId: lvl)
        #expect(!issues.contains { $0.kind == .furnitureWall })
        #expect(issues.contains { $0.kind == .blocksOpening && $0.a == f.id && $0.b == door.id })
        // beside the door the solid wall still counts
        p.instances[0].position = P3(500, 0, 0)
        let beside = CollisionChecker.check(p, levelId: lvl)
        #expect(beside.map(\.kind) == [.furnitureWall])
    }

    @Test func doorSwingAreaIsBlocked() {
        var (p, lvl) = makeProject()
        let wall = Wall(levelId: lvl, start: P2(0, 0), end: P2(4000, 0), thickness: 100)
        p.walls = [wall]
        var door = Opening(wallId: wall.id, kind: .door, offset: 2000, width: 900, height: 2100, sill: 0)
        door.inward = true // swings to the left side (+Y)
        p.openings = [door]
        let def = box(400, 400, 800)
        let f = place(&p, def, lvl, 2000, 500) // inside 900 x 900 swing square (y 50…950)
        #expect(CollisionChecker.check(p, levelId: lvl).contains { $0.kind == .blocksOpening && $0.a == f.id && $0.b == door.id })
        p.instances[0].position = P3(2000, -500, 0) // other side: free
        #expect(CollisionChecker.check(p, levelId: lvl).isEmpty)
        p.openings[0].inward = false
        #expect(CollisionChecker.check(p, levelId: lvl).contains { $0.kind == .blocksOpening })
        p.instances[0].position = P3(2000, 1500, 0) // beyond the square
        #expect(CollisionChecker.check(p, levelId: lvl).isEmpty)
    }

    // MARK: Free pieces (allowsOverlap, flat floor pieces)

    @Test func furnitureOverTheRugReportsNothing() {
        var (p, lvl) = makeProject()
        let rug = place(&p, box(2000, 3000, 20), lvl, 0, 0)
        let table = place(&p, box(1000, 1000, 800), lvl, 200, 100)
        #expect(CollisionChecker.check(p, levelId: lvl).isEmpty)
        #expect(CollisionChecker.check(p, levelId: lvl, only: [rug.id]).isEmpty)
        #expect(CollisionChecker.check(p, levelId: lvl, only: [table.id]).isEmpty)
        // two pieces on top of each other without the rug do collide (control)
        let other = place(&p, box(1000, 1000, 800), lvl, 600, 100)
        #expect(CollisionChecker.check(p, levelId: lvl).contains { $0.kind == .furnitureOverlap && Set([$0.a, $0.b!]) == Set([table.id, other.id]) })
    }

    @Test func flatPieceHeightLimit() {
        var (p, lvl) = makeProject()
        let a = place(&p, box(1000, 1000, 800), lvl, 0, 0)
        let flat150 = place(&p, box(1000, 1000, 150), lvl, 0, 0)
        #expect(CollisionChecker.check(p, levelId: lvl).isEmpty)
        let flat151 = place(&p, box(1000, 1000, 151), lvl, 0, 0)
        let issues = CollisionChecker.check(p, levelId: lvl)
        #expect(issues.count == 1 && issues[0].kind == .furnitureOverlap)
        #expect(Set([issues[0].a, issues[0].b!]) == Set([a.id, flat151.id]))
        _ = flat150
    }

    @Test func flatPieceAboveTheFloorIsNotFree() {
        var (p, lvl) = makeProject()
        _ = place(&p, box(1000, 1000, 800), lvl, 0, 0)
        _ = place(&p, box(1000, 1000, 20), lvl, 0, 0, z: 300) // a shelf board inside the other piece
        #expect(CollisionChecker.check(p, levelId: lvl).count == 1)
    }

    @Test func allowsOverlapSuppressesFurnitureWallAndOpening() {
        var (p, lvl) = makeProject()
        let wall = Wall(levelId: lvl, start: P2(0, 0), end: P2(4000, 0), thickness: 100, height: 2500)
        p.walls = [wall]
        var door = Opening(wallId: wall.id, kind: .door, offset: 3000, width: 900, height: 2100, sill: 0)
        door.inward = true
        p.openings = [door]
        let def = box(800, 800, 800)
        let a = place(&p, def, lvl, 5000, 5000)
        let b = place(&p, def, lvl, 5300, 5000)          // overlaps a
        let inWall = place(&p, def, lvl, 1000, 0)        // in the wall
        let inDoor = place(&p, def, lvl, 3000, 300)      // in the door swing
        let ids = [a.id, b.id, inWall.id, inDoor.id]
        // control: without the flag everything is reported
        let before = CollisionChecker.check(p, levelId: lvl)
        #expect(before.contains { $0.kind == .furnitureOverlap })
        #expect(before.contains { $0.kind == .furnitureWall && $0.a == inWall.id })
        #expect(before.contains { $0.kind == .blocksOpening && $0.a == inDoor.id })
        for k in p.instances.indices { p.instances[k].allowsOverlap = true }
        #expect(CollisionChecker.check(p, levelId: lvl).isEmpty)
        #expect(CollisionChecker.check(p, levelId: lvl, only: Set(ids)).isEmpty)
        #expect(CollisionChecker.check(p, levelId: lvl, only: [wall.id, door.id]).isEmpty)
        // one flagged piece is enough for a pair, but the other one still collides with the wall
        p.instances[0].allowsOverlap = true; p.instances[1].allowsOverlap = false
        p.instances[2].allowsOverlap = false; p.instances[3].allowsOverlap = false
        let some = CollisionChecker.check(p, levelId: lvl)
        #expect(!some.contains { $0.kind == .furnitureOverlap })
        #expect(some.contains { $0.kind == .furnitureWall && $0.a == inWall.id })
    }

    @Test func allowsOverlapKeepsOutsideRoomsWarning() {
        var (p, lvl) = makeProject()
        p.rooms = [Room(levelId: lvl, name: "r", points: [P2(0, 0), P2(5000, 0), P2(5000, 4000), P2(0, 4000)])]
        let f = place(&p, box(500, 500, 800), lvl, 8000, 1000)
        p.instances[0].allowsOverlap = true
        #expect(CollisionChecker.check(p, levelId: lvl).map(\.kind) == [.outsideRooms])
        _ = f
    }

    @Test func groupMembersStillIgnoreEachOtherWithFlags() {
        var (p, lvl) = makeProject()
        let def = box(1000, 1000, 800)
        let a = place(&p, def, lvl, 0, 0)
        let b = place(&p, def, lvl, 500, 0)
        p.groups = [FurnitureGroup(name: "g", levelId: lvl, origin: .zero, memberIds: [a.id, b.id])]
        p.instances[0].groupId = p.groups[0].id
        p.instances[1].groupId = p.groups[0].id
        #expect(CollisionChecker.check(p, levelId: lvl).isEmpty)
    }

    @Test func outsideRooms() {
        var (p, lvl) = makeProject()
        let def = box(500, 500, 800)
        let f = place(&p, def, lvl, 8000, 1000)
        #expect(CollisionChecker.check(p, levelId: lvl).isEmpty) // no rooms: nothing to be outside of
        p.rooms = [Room(levelId: lvl, name: "r", points: [P2(0, 0), P2(5000, 0), P2(5000, 4000), P2(0, 4000)])]
        let issues = CollisionChecker.check(p, levelId: lvl)
        #expect(issues.count == 1)
        #expect(issues[0].kind == .outsideRooms && issues[0].a == f.id && issues[0].b == nil)
        #expect(abs(issues[0].depth - 3000) < 0.01)
        p.instances[0].position = P3(2000, 1000, 0)
        #expect(CollisionChecker.check(p, levelId: lvl).isEmpty)
    }

    @Test func onlyFiltersToGivenIds() {
        var (p, lvl) = makeProject()
        let def = box(1000, 1000, 800)
        let a = place(&p, def, lvl, 0, 0)
        let b = place(&p, def, lvl, 500, 0)
        let c = place(&p, def, lvl, 10_000, 0)
        let d = place(&p, def, lvl, 10_500, 0)
        let all = CollisionChecker.check(p, levelId: lvl)
        #expect(all.count == 2)
        let onlyA = CollisionChecker.check(p, levelId: lvl, only: [a.id])
        #expect(onlyA.count == 1 && Set([onlyA[0].a, onlyA[0].b!]) == Set([a.id, b.id]))
        let onlyD = CollisionChecker.check(p, levelId: lvl, only: [d.id])
        #expect(onlyD.count == 1 && Set([onlyD[0].a, onlyD[0].b!]) == Set([c.id, d.id]))
        #expect(CollisionChecker.check(p, levelId: lvl, only: [UUID()]).isEmpty)
    }

    @Test func onlyWallFindsFurniture() {
        var (p, lvl) = makeProject()
        let wall = Wall(levelId: lvl, start: P2(0, 0), end: P2(4000, 0), thickness: 100)
        p.walls = [wall]
        let def = box(1000, 500, 800)
        _ = place(&p, def, lvl, 2000, 280)
        #expect(CollisionChecker.check(p, levelId: lvl, only: [wall.id]).map(\.kind) == [.furnitureWall])
    }

    @Test func performance300WallsAnd1000Furniture() {
        var (p, lvl) = makeProject()
        let def = box(800, 600, 800)
        p.definitions = [def]
        // 12 x 25 walls between the furniture rows, 40 x 25 furniture on a 1500 mm grid.
        for r in 0..<25 {
            for c in 0..<12 {
                p.walls.append(Wall(levelId: lvl, start: P2(MM(c * 5000), MM(r * 1500 + 750)), end: P2(MM(c * 5000 + 4500), MM(r * 1500 + 750)), thickness: 100))
            }
        }
        for r in 0..<25 {
            for c in 0..<40 {
                p.instances.append(FurnitureInstance(definitionId: def.id, levelId: lvl, name: "f", position: P3(MM(c * 1500), MM(r * 1500), 0), rotationDeg: Double((r + c) % 4) * 15))
            }
        }
        p.rooms = [Room(levelId: lvl, name: "all", points: [P2(-1000, -1000), P2(70_000, -1000), P2(70_000, 40_000), P2(-1000, 40_000)])]
        // A few real problems so the result is not trivially empty.
        p.instances[5].position = P3(p.instances[4].position.x + 500, p.instances[4].position.y, 0)
        p.instances[100].position = P3(p.instances[100].position.x, 750 - 200, 0)
        #expect(p.walls.count == 300 && p.instances.count == 1000)

        var full = Double.infinity, partial = Double.infinity
        var issues: [CollisionIssue] = []
        for _ in 0..<20 {  // best of 20: the full suite runs in parallel and steals cores
            let t0 = ContinuousClock.now
            issues = CollisionChecker.check(p, levelId: lvl)
            let t1 = ContinuousClock.now
            let o = CollisionChecker.check(p, levelId: lvl, only: [p.instances[500].id])
            let t2 = ContinuousClock.now
            full = min(full, Double((t1 - t0).components.attoseconds) / 1e15 + Double((t1 - t0).components.seconds) * 1000)
            partial = min(partial, Double((t2 - t1).components.attoseconds) / 1e15 + Double((t2 - t1).components.seconds) * 1000)
            _ = o
        }
        print("PERF full=\(full) ms partial=\(partial) ms issues=\(issues.count)")
        #expect(issues.contains { $0.kind == .furnitureOverlap })
        #expect(issues.contains { $0.kind == .furnitureWall })
        #expect(full < 30)
        #expect(partial < 4)  // one dragged piece; a 120 Hz frame is 8.3 ms
    }
}

@Suite("Warned ids") struct WarnedIdsTests {
    @Test func onlyRealWarningKindsCount() {
        var p = Project.empty(name: "T")
        let lvl = p.levels[0].id
        let def = box(500, 500, 500)
        p.definitions.append(def)
        let mk = { FurnitureInstance(definitionId: def.id, levelId: lvl, name: "f", position: P3(0, 0, 0)) }
        let outside = mk(), x = mk(), y = mk(), z = mk()
        p.instances += [outside, x, y, z]
        let missing = UUID()
        let issues = [
            CollisionIssue(kind: .outsideRooms, a: outside.id, depth: 1),
            CollisionIssue(kind: .furnitureOverlap, a: x.id, b: y.id, depth: 1),
            CollisionIssue(kind: .blocksOpening, a: z.id, b: missing, depth: 1),
        ]
        let ids = CollisionChecker.warnedIds(issues, in: p)
        #expect(!ids.contains(outside.id))
        #expect(ids == [x.id, y.id, z.id])
        #expect(!ids.contains(missing))
    }
}
