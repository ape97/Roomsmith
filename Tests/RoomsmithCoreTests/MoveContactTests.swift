import Testing
import Foundation
import simd
@testable import RoomsmithCore

// MARK: - Helpers

private func A(center: V2 = V2(0, 0), half: V2 = V2(500, 250), rot: Double = 0, z0: Double = 0, z1: Double = 750) -> ContactBody {
    ContactBody(rect: OrientedRect(center: center, halfSize: half, rotationDeg: rot), z0: z0, z1: z1)
}

private func B(center: V2 = V2(1500, 0), half: V2 = V2(300, 300), rot: Double = 0, z0: Double = 0, z1: Double = 750) -> ContactObstacle {
    ContactObstacle(polygon: OrientedRect(center: center, halfSize: half, rotationDeg: rot).corners, z0: z0, z1: z1, id: UUID())
}

private func resolve(_ moving: [ContactBody], _ raw: V2, _ obs: [ContactObstacle] = [B()], slide: Bool = true,
                     axis: V2? = nil, tolerance: Double = 80) -> ContactResult {
    MoveContact.resolve(moving: moving, raw: raw, obstacles: obs, tolerance: tolerance, slide: slide, constrainedTo: axis)
}

private func resolve(_ raw: V2, _ obs: [ContactObstacle] = [B()], slide: Bool = true, axis: V2? = nil,
                     tolerance: Double = 80) -> ContactResult {
    resolve([A()], raw, obs, slide: slide, axis: axis, tolerance: tolerance)
}

private func box(_ w: MM, _ d: MM, _ h: MM) -> FurnitureDefinition {
    FurnitureDefinition(name: "Box", category: "t", size: Size3(w, d, h),
                        components: [Component(name: "c", shape: .box, position: P3(0, 0, h / 2), size: Size3(w, d, h))])
}

private func place(_ p: inout Project, _ def: FurnitureDefinition, _ lvl: UUID, _ x: MM, _ y: MM, z: MM = 0, rot: Double = 0) -> FurnitureInstance {
    if !p.definitions.contains(where: { $0.id == def.id }) { p.definitions.append(def) }
    let i = FurnitureInstance(definitionId: def.id, levelId: lvl, name: "i", position: P3(x, y, z), rotationDeg: rot)
    p.instances.append(i)
    return i
}

private func scene() -> (Project, UUID) {
    let p = Project.empty(name: "T")
    return (p, p.levels[0].id)
}

private func contactSetup(_ p: Project, _ lvl: UUID, move id: UUID) -> ([ContactBody], [ContactObstacle]) {
    (MoveContact.bodies(project: p, levelId: lvl, ids: [id]), MoveContact.obstacles(project: p, levelId: lvl, excluding: [id]))
}

@Suite("MoveContact") struct MoveContactTests {
    // MARK: Table

    @Test func freeFarAway() {
        let r = resolve(V2(500, 0))
        #expect(r.delta == V2(500, 0))
        #expect(!r.contact && r.guides.isEmpty)
    }

    @Test func magnetPullsFlush() {
        let r = resolve(V2(650, 0))
        #expect(r.delta == V2(700, 0))
        #expect(r.contact)
        let onFace = r.guides.contains { (g: SnapGuide) -> Bool in
            let a: Double = abs(g.from.x - 1200)
            let b: Double = abs(g.to.x - 1200)
            return a < 1e-6 && b < 1e-6
        }
        #expect(onFace)
    }

    @Test func stopsAtContact() {
        let r = resolve(V2(850, 0))
        #expect(r.delta == V2(700, 0))
        #expect(r.contact)
    }

    @Test func breaksThrough() {
        let r = resolve(V2(1000, 0))
        #expect(r.delta == V2(1000, 0))
    }

    @Test func slidesAlongFace() {
        let r = resolve(V2(880, 300))
        #expect(r.delta == V2(700, 300))
        #expect(r.contact)
    }

    @Test func axisBindingStaysOnAxis() {
        let r = resolve(V2(900, 0), slide: false, axis: V2(1, 0))
        #expect(r.delta == V2(700, 0))
        // slide is ignored with an axis
        let s = resolve(V2(900, 0), slide: true, axis: V2(1, 0))
        #expect(s.delta == V2(700, 0))
    }

    @Test func passesBy() {
        let r = resolve(V2(900, 800))
        #expect(r.delta == V2(900, 800))
        #expect(!r.contact)
    }

    @Test func separatedInZNeverBlocks() {
        let r = resolve(V2(850, 0), [B(z0: 900, z1: 1200)])
        #expect(r.delta == V2(850, 0))
        #expect(!r.contact)
        // touching in z is no overlap either
        #expect(resolve(V2(850, 0), [B(z0: 750, z1: 1200)]).delta == V2(850, 0))
    }

    @Test func rotatedObstacle() {
        let r = resolve(V2(700, 0), [B(rot: 45)])
        #expect(abs(r.delta.x - 575) <= 1)
        #expect(r.delta.y == 0)
    }

    @Test func rotatedMover() {
        let r = resolve([A(half: V2(250, 250), rot: 45)], V2(900, 0), [B()])
        #expect(abs(r.delta.x - 846) <= 1)
    }

    @Test func startOverlapDoesNotBlock() {
        // A reaches x = 1300, 100 into B: moving on or out is free.
        let r = resolve([A(center: V2(800, 0))], V2(50, 0))
        #expect(r.delta == V2(50, 0))
        #expect(!r.contact)
        #expect(resolve([A(center: V2(800, 0))], V2(-50, 0)).delta == V2(-50, 0))
    }

    @Test func tinyStartOverlapCountsAsContact() {
        let mover = [A(center: V2(700.3, 0))]
        let stop = resolve(mover, V2(150, 0))
        #expect(abs(stop.delta.x) <= 1)
        #expect(stop.contact)
        let through = resolve(mover, V2(250, 0))
        #expect(through.delta == V2(250, 0))
        // moving away is not blocked
        #expect(resolve(mover, V2(-100, 0)).delta == V2(-100, 0))
    }

    // MARK: Break through

    @Test func breakThroughMeasuredBeyondContact() {
        // Wall 100 thick, A touching its face.
        let wall = B(center: V2(1200, 0), half: V2(50, 2000))
        let mover = [A(center: V2(650, 0))]
        #expect(resolve(mover, V2(150, 0), [wall]).delta == V2(0, 0))
        #expect(resolve(mover, V2(250, 0), [wall]).delta == V2(250, 0))
        // thick obstacle: depth 600 stays on raw, no jump back
        let slab = B(center: V2(1200, 0), half: V2(500, 2000))
        #expect(resolve([A(center: V2(200, 0))], V2(600, 0), [slab]).delta == V2(600, 0))
    }

    @Test func wallFace() {
        let wall = B(center: V2(1200, 0), half: V2(50, 2000))
        #expect(resolve(V2(800, 0), [wall]).delta == V2(650, 0))
    }

    @Test func breakThroughDepthStaysRelativeToRawWhileSliding() {
        // Slide along B, then a second obstacle (a wall above) stops the slide.
        let ceiling = B(center: V2(500, 700), half: V2(2000, 50))
        let r = resolve(V2(880, 400), [B(), ceiling])
        #expect(r.delta.x == 700)
        #expect(r.delta.y <= 400 && r.delta.y >= 0)
        // A top face = 250 + dy must not pass the ceiling's lower face (650)
        #expect(250 + r.delta.y <= 650 + 1)
    }

    // MARK: Axis (B2)

    @Test func axisIgnoresSideNeighbours() {
        let ahead = B(center: V2(1500, 600)) // y 300..900, A tops at 250: 50 gap in y
        #expect(resolve(V2(900, 0), [ahead], slide: false, axis: V2(1, 0)).delta == V2(900, 0)) // (a)
        let far = B(center: V2(1500, 1550)) // 1000 gap
        #expect(resolve(V2(900, 0), [far], slide: false, axis: V2(1, 0)).delta == V2(900, 0)) // (b)
        let beside = B(center: V2(0, 600)) // 50 mm beside, overlapping in x
        let c = resolve(V2(300, 0), [beside], slide: false, axis: V2(1, 0)) // (c)
        #expect(c.delta == V2(300, 0))
        #expect(!c.contact)
    }

    @Test func axisAgainstRotatedObstacleIsFlush() {
        let obstacle = B(rot: 45)
        let r = resolve(V2(700, 0), [obstacle], slide: false, axis: V2(1, 0)) // (d)
        #expect(r.delta.y == 0)
        #expect(r.contact)
        let moved = A().rect
        var m = moved; m.center += r.delta
        let pen = penetration(m.corners, obstacle.polygon)
        #expect(pen == nil || pen! <= 0.5 + 1e-9)
        // no gap larger than a millimetre: one more millimetre would overlap
        var m2 = moved; m2.center += r.delta + V2(2, 0)
        #expect(penetration(m2.corners, obstacle.polygon) != nil)
    }

    @Test func axisMagnetUsesAxisPath() {
        // Obstacle ahead, 50 gap along the axis: pulled flush along the axis only.
        let r = resolve(V2(650, 0), slide: false, axis: V2(1, 0))
        #expect(r.delta == V2(700, 0))
        // diagonal axis: result stays on the axis
        let d = simd_normalize(V2(1, 1))
        let s = resolve(V2(300, 300), [B(center: V2(1500, 1500))], slide: false, axis: d)
        #expect(abs(s.delta.x - s.delta.y) <= 1)
    }

    // MARK: Several bodies

    @Test func groupStopsAtFirstBodyToHit() {
        let near = A(center: V2(0, 0), half: V2(100, 100))
        let far = A(center: V2(-1000, 0), half: V2(100, 100))
        let wall = B(center: V2(700, 0), half: V2(50, 2000)) // face x = 650
        let r = resolve([far, near], V2(700, 0), [wall])
        #expect(r.delta == V2(550, 0))
    }

    // MARK: Project integration

    @Test func freeMoverHasNoContact() {
        var (p, lvl) = scene()
        let a = place(&p, box(1000, 500, 750), lvl, 0, 0)
        _ = place(&p, box(600, 600, 750), lvl, 1500, 0)
        p.instances[0].allowsOverlap = true
        #expect(MoveContact.bodies(project: p, levelId: lvl, ids: [a.id]).isEmpty)
        let r = MoveContact.resolve(moving: MoveContact.bodies(project: p, levelId: lvl, ids: [a.id]), raw: V2(850, 0),
                                    obstacles: MoveContact.obstacles(project: p, levelId: lvl, excluding: [a.id]), tolerance: 80, slide: true)
        #expect(r.delta == V2(850, 0))
        #expect(!r.contact)
    }

    @Test func freeObstaclesAreSkipped() {
        var (p, lvl) = scene()
        let a = place(&p, box(1000, 500, 750), lvl, 0, 0)
        let rug = place(&p, box(600, 600, 20), lvl, 1500, 0) // flat on the floor
        let ghost = place(&p, box(600, 600, 750), lvl, 1500, 1500)
        p.instances[2].allowsOverlap = true
        let (bodies, obs) = contactSetup(p, lvl, move: a.id)
        #expect(bodies.count == 1)
        #expect(!obs.contains { $0.id == rug.id || $0.id == ghost.id })
        let r = MoveContact.resolve(moving: bodies, raw: V2(850, 0), obstacles: obs, tolerance: 80, slide: true)
        #expect(r.delta == V2(850, 0))
    }

    @Test func groupMembersAndMovingSetNeverBlock() {
        var (p, lvl) = scene()
        let def = box(1000, 500, 750)
        let a = place(&p, def, lvl, 0, 0)
        let b = place(&p, def, lvl, 1100, 0)
        let c = place(&p, def, lvl, 5000, 0)
        let g = FurnitureGroup(name: "g", levelId: lvl, origin: .zero, memberIds: [a.id, b.id])
        p.groups = [g]
        p.instances[0].groupId = g.id
        p.instances[1].groupId = g.id
        // moving a alone: its group mate b is no obstacle, c is
        let alone = MoveContact.obstacles(project: p, levelId: lvl, excluding: [a.id])
        #expect(alone.map(\.id) == [c.id])
        // moving the group id: both members are in the moving set
        let viaGroup = MoveContact.obstacles(project: p, levelId: lvl, excluding: [g.id])
        #expect(viaGroup.map(\.id) == [c.id])
        #expect(MoveContact.bodies(project: p, levelId: lvl, ids: [g.id]).count == 2)
        // moving two ungrouped pieces together
        p.instances[0].groupId = nil; p.instances[1].groupId = nil; p.groups = []
        let two = MoveContact.obstacles(project: p, levelId: lvl, excluding: [a.id, b.id])
        #expect(two.map(\.id) == [c.id])
    }

    @Test func snapSettingsPickTheObstacles() {
        var (p, lvl) = scene()
        p.walls = [Wall(levelId: lvl, start: P2(1200, -2000), end: P2(1200, 2000), thickness: 100, height: 2500)]
        let a = place(&p, box(1000, 500, 750), lvl, 0, 0)
        let c = place(&p, box(1000, 500, 750), lvl, 0, 2000)
        func ids(_ walls: Bool, _ objects: Bool) -> [UUID?] {
            MoveContact.obstacles(project: p, levelId: lvl, excluding: [a.id], toWalls: walls, toObjects: objects).map(\.id)
        }
        #expect(ids(true, true).count == 2)
        #expect(ids(false, true) == [c.id])
        #expect(ids(true, false) == [p.walls[0].id])
        #expect(ids(false, false).isEmpty)
    }

    @Test func flatFloorPiecesAreDetectedPublicly() {
        var (p, lvl) = scene()
        let rug = place(&p, box(2000, 1500, 20), lvl, 0, 0)
        let table = place(&p, box(1000, 500, 750), lvl, 3000, 0)
        #expect(CollisionChecker.isFlatOnFloor(rug, definition: p.definitions[0]))
        #expect(!CollisionChecker.isFlatOnFloor(table, definition: p.definitions[1]))
    }

    @Test func wallAndHeightThroughProject() {
        var (p, lvl) = scene()
        p.walls = [Wall(levelId: lvl, start: P2(1200, -2000), end: P2(1200, 2000), thickness: 100, height: 2500)]
        let a = place(&p, box(1000, 500, 750), lvl, 0, 0)
        let (bodies, obs) = contactSetup(p, lvl, move: a.id)
        let r = MoveContact.resolve(moving: bodies, raw: V2(800, 0), obstacles: obs, tolerance: 80, slide: true)
        #expect(r.delta == V2(650, 0))
        // a piece above the wall passes
        p.instances[0].position = P3(0, 0, 2500)
        let (b2, o2) = contactSetup(p, lvl, move: a.id)
        #expect(MoveContact.resolve(moving: b2, raw: V2(800, 0), obstacles: o2, tolerance: 80, slide: true).delta == V2(800, 0))
    }

    @Test func windowOnlyBlocksWhereCollisionDoes() {
        var (p, lvl) = scene()
        let wall = Wall(levelId: lvl, start: P2(0, 0), end: P2(4000, 0), thickness: 100, height: 2500)
        p.walls = [wall]
        p.openings = [Opening(wallId: wall.id, kind: .window, offset: 2000, width: 1000, height: 1000, sill: 900)]
        // A low piece (z 0..750) is below the sill (solid), a tall one (0..2000) hits the sill band too.
        let low = place(&p, box(400, 400, 750), lvl, 2000, -500)
        let (b, o) = contactSetup(p, lvl, move: low.id)
        let r = MoveContact.resolve(moving: b, raw: V2(0, 300), obstacles: o, tolerance: 80, slide: true)
        #expect(r.delta.y == 250) // face of the wall at y = -50, mover top at -300 -> 250
        // a piece between sill and head (z 1000..1500) passes through the window hole
        p.instances[0].position = P3(2000, -500, 1000)
        p.definitions[0].size = Size3(400, 400, 500)
        p.definitions[0].components[0].size = Size3(400, 400, 500)
        let (b2, o2) = contactSetup(p, lvl, move: low.id)
        #expect(MoveContact.resolve(moving: b2, raw: V2(0, 300), obstacles: o2, tolerance: 80, slide: true).delta == V2(0, 300))
    }

    @Test func doorPassageAndSwingStopPiece() {
        var (p, lvl) = scene()
        let wall = Wall(levelId: lvl, start: P2(0, 0), end: P2(4000, 0), thickness: 100, height: 2500)
        p.walls = [wall]
        var door = Opening(wallId: wall.id, kind: .door, offset: 2000, width: 900, height: 2100, sill: 0)
        door.inward = true
        p.openings = [door]
        let def = box(400, 400, 800)
        // from outside into the door hole (y -50..50)
        let out = place(&p, def, lvl, 2000, -400)
        var (b, o) = contactSetup(p, lvl, move: out.id)
        var r = MoveContact.resolve(moving: b, raw: V2(0, 300), obstacles: o, tolerance: 80, slide: true)
        #expect(r.contact)
        #expect(r.delta.y == 150)
        var moved = p; moved.instances[0].position = P3(2000, -400 + MM(r.delta.y), 0)
        #expect(CollisionChecker.check(moved, levelId: lvl).isEmpty)
        // from the room side into the swing square (x 1550..2450, y 50..950)
        p.instances.removeAll()
        let inside = place(&p, def, lvl, 1200, 600)
        (b, o) = contactSetup(p, lvl, move: inside.id)
        r = MoveContact.resolve(moving: b, raw: V2(300, 0), obstacles: o, tolerance: 80, slide: true)
        #expect(r.contact)
        #expect(r.delta.x == 150)
        moved = p; moved.instances[0].position = P3(1200 + MM(r.delta.x), 600, 0)
        #expect(CollisionChecker.check(moved, levelId: lvl).isEmpty)
        // pushing hard goes through
        r = MoveContact.resolve(moving: b, raw: V2(600, 0), obstacles: o, tolerance: 80, slide: true)
        #expect(r.delta == V2(600, 0))
    }

    // MARK: Contract: the result is not reported by the collision check

    @Test func resultIsNeverNewRed() {
        var (p, lvl) = scene()
        let wall = Wall(levelId: lvl, start: P2(-3000, 0), end: P2(6000, 0), thickness: 100, height: 2500)
        p.walls = [wall]
        var door = Opening(wallId: wall.id, kind: .door, offset: 2500, width: 900, height: 2100, sill: 0)
        door.inward = true
        p.openings = [door]
        let def = box(400, 400, 800)
        let mover = place(&p, def, lvl, 500, 600)
        _ = place(&p, def, lvl, 1100, 600)
        _ = place(&p, box(600, 300, 800), lvl, 500, 1800, rot: 30)
        #expect(CollisionChecker.check(p, levelId: lvl).isEmpty)
        let (bodies, obs) = contactSetup(p, lvl, move: mover.id)
        var checked = 0
        for dx in stride(from: -300.0, through: 1500.0, by: 37.0) {
            for dy in stride(from: -600.0, through: 1400.0, by: 41.0) {
                let raw = V2(dx, dy)
                for slide in [true, false] {
                    let r = MoveContact.resolve(moving: bodies, raw: raw, obstacles: obs, tolerance: 80, slide: slide)
                    // break-through cases are allowed to collide; they follow the raw movement
                    if penetratesAny(bodies, r.delta, obs) {
                        #expect(simd_length(raw) > 200, "penetration without break through: raw \(raw) -> \(r.delta)")
                        continue
                    }
                    var q = p
                    q.instances[0].position = P3(500 + MM(r.delta.x), 600 + MM(r.delta.y), 0)
                    let issues = CollisionChecker.check(q, levelId: lvl)
                    #expect(issues.isEmpty, "raw \(raw) slide \(slide) -> \(r.delta): \(issues.map(\.kind))")
                    checked += 1
                }
            }
        }
        #expect(checked > 500)
    }

    @Test func resultIsNeverNewRedForAxisDrag() {
        var (p, lvl) = scene()
        let def = box(400, 400, 800)
        let mover = place(&p, def, lvl, 0, 0)
        _ = place(&p, def, lvl, 1000, 0)
        _ = place(&p, def, lvl, 0, 900, rot: 45)
        let (bodies, obs) = contactSetup(p, lvl, move: mover.id)
        for axis in [V2(1, 0), V2(0, 1), V2(-1, 0), V2(0, -1)] {
            for t in stride(from: 0.0, through: 700.0, by: 13.0) {
                let r = MoveContact.resolve(moving: bodies, raw: axis * t, obstacles: obs, tolerance: 80, slide: false, constrainedTo: axis)
                #expect(r.delta.x * axis.y == r.delta.y * axis.x)
                if penetratesAny(bodies, r.delta, obs) { continue } // break through
                var q = p
                q.instances[0].position = P3(MM(r.delta.x), MM(r.delta.y), 0)
                #expect(CollisionChecker.check(q, levelId: lvl).isEmpty, "axis \(axis) t \(t) -> \(r.delta)")
            }
        }
    }

    private func penetratesAny(_ bodies: [ContactBody], _ d: V2, _ obs: [ContactObstacle]) -> Bool {
        for b in bodies {
            var r = b.rect; r.center += d
            for o in obs where b.z0 < o.z1 && o.z0 < b.z1 && penetration(r.corners, o.polygon) != nil { return true }
        }
        return false
    }
}
