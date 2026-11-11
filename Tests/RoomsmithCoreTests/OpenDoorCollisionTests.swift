import Testing
import Foundation
import simd
@testable import RoomsmithCore

/// Open doors: a piece in a moving state collides as its real parts, not as one rectangle around all of them.
@Suite("Open door collision") struct OpenDoorCollisionTests {
    private func cabinets(_ xs: [MM], states: [String], key: String = "wardrobe.1000") throws -> (Project, UUID, FurnitureDefinition, [UUID]) {
        let d = try #require(BuiltinCatalog.definition(key))
        var p = Project.empty(name: "T")
        let lvl = p.levels[0].id
        p.definitions.append(d)
        var ids: [UUID] = []
        for (x, st) in zip(xs, states) {
            var i = FurnitureInstance(definitionId: d.id, levelId: lvl, name: "w", position: P3(x, 0, 0))
            i.stateId = d.states.first { $0.name == st }?.id
            p.instances.append(i)
            ids.append(i.id)
        }
        return (p, lvl, d, ids)
    }

    @Test func partsAreCarcassPlusDoors() throws {
        let (p, _, d, _) = try cabinets([0], states: ["open"])
        let parts = try #require(FurnitureResolver.collisionParts(of: p.instances[0], definition: d))
        #expect(parts.filter { !$0.swings }.count == 1)
        #expect(parts.filter(\.swings).count >= 2)
        // closed: one shape, nothing to split
        let (c, _, dc, _) = try cabinets([0], states: ["closed"])
        #expect(FurnitureResolver.collisionParts(of: c.instances[0], definition: dc) == nil)
    }

    @Test func neighbouringOpenCabinetsDoNotCollide() throws {
        // The hull of a cabinet with open doors is wider than the carcass (the doors swing 100°), so the old single
        // rectangle of each cabinet overlapped the neighbour.
        let (p, lvl, d, _) = try cabinets([0, 1000, 2000], states: ["open", "open", "open"])
        let hullA = FurnitureResolver.footprint(of: p.instances[0], definition: d).corners
        let hullB = FurnitureResolver.footprint(of: p.instances[1], definition: d).corners
        #expect(penetration(hullA, hullB) != nil, "the rectangles around the open doors do overlap")
        #expect(CollisionChecker.check(p, levelId: lvl).isEmpty)
    }

    @Test func openCabinetNextToClosedOneDoesNotCollide() throws {
        let (p, lvl, _, _) = try cabinets([0, 1000], states: ["open", "closed"])
        #expect(CollisionChecker.check(p, levelId: lvl).isEmpty)
        let (q, lvq, _, _) = try cabinets([0, 1000], states: ["closed", "open"])
        #expect(CollisionChecker.check(q, levelId: lvq).isEmpty)
    }

    @Test func doorSwingingIntoAPieceStillCollides() throws {
        // A cabinet standing in the swing of the left door (clear of the carcass) is hit by that door, far from its hinge.
        var (p, lvl, d, ids) = try cabinets([0], states: ["open"])
        var blocker = FurnitureInstance(definitionId: d.id, levelId: lvl, name: "b", position: P3(-600, -700, 0))
        blocker.stateId = d.states.first { $0.name == "closed" }?.id
        p.instances.append(blocker)
        let issues = CollisionChecker.check(p, levelId: lvl)
        #expect(issues.contains { $0.kind == .furnitureOverlap && ($0.a == ids[0] || $0.b == ids[0]) })
    }

    @Test func overlappingCarcassesStillCollideWhenOpen() throws {
        let (p, lvl, _, _) = try cabinets([0, 400], states: ["open", "open"])
        #expect(CollisionChecker.check(p, levelId: lvl).contains { $0.kind == .furnitureOverlap })
    }

    @Test func dragContactUsesTheRealParts() throws {
        let (p, lvl, _, ids) = try cabinets([0, 1000], states: ["open", "open"])
        let bodies = MoveContact.bodies(project: p, levelId: lvl, ids: [ids[1]])
        #expect(bodies.count > 1 && bodies.contains { $0.swings })
        let obstacles = MoveContact.obstacles(project: p, levelId: lvl, excluding: [ids[1]])
        // Pushing the second cabinet 100 mm toward the first one stops flush at the carcass, not at the door hull.
        let r = MoveContact.resolve(moving: bodies, raw: V2(-100, 0), obstacles: obstacles, tolerance: 0, slide: false)
        #expect(r.delta.x > -1, "already flush: \(r.delta)")
        let away = MoveContact.resolve(moving: bodies, raw: V2(100, 0), obstacles: obstacles, tolerance: 0, slide: false)
        #expect(away.delta.x == 100)
    }
}
