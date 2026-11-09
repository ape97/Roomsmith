import Testing
import Foundation
import simd
@testable import RoomsmithCore

// MARK: - Helpers

private func boxDef(_ w: MM, _ d: MM, _ h: MM) -> FurnitureDefinition {
    FurnitureDefinition(name: "Box", category: "t", size: Size3(w, d, h),
                        components: [Component(name: "c", shape: .box, position: P3(0, 0, h / 2), size: Size3(w, d, h))])
}

/// One wall along y = 0 (x 0...6000, 100 thick) with the given openings.
private func wallProject(_ openings: [(OpeningKind, MM, MM)]) -> (Project, UUID, [Opening]) {
    var p = Project.empty(name: "W")
    let lvl = p.levels[0].id
    let wall = Wall(levelId: lvl, start: P2(0, 0), end: P2(6000, 0))
    p.walls = [wall]
    let ops = openings.map { Opening(wallId: wall.id, kind: $0.0, offset: $0.1, width: $0.2, height: $0.0 == .window ? 1200 : 2100, sill: $0.0 == .window ? 900 : 0) }
    p.openings = ops
    return (p, lvl, ops)
}

private func collider(_ p: Project, _ lvl: UUID, open: Set<UUID> = []) -> WalkCollider {
    WalkCollider(project: p, levelId: lvl, eyeHeightMm: 1638, bodyRadiusMm: 220, openDoors: open)
}

// MARK: - Settings and FOV

@Suite("WalkSettings") struct WalkSettingsTests {
    @Test func defaultsMatchTheSpec() {
        let s = WalkSettings()
        #expect(s.bodyHeightMm == 1750)
        #expect(s.eyeHeightMm == 1638) // round(1750 * 0.936)
        #expect(s.speedSlowMps == 0.8 && s.speedNormalMps == 1.4 && s.speedFastMps == 2.5)
        #expect(s.accelerationMps2 == 3 && s.crouchEyeFactor == 0.6)
        #expect(s.headBob == false && s.collision == true)
        #expect(s.controllerDeadzone == 0.15 && s.bodyRadiusMm == 220 && s.viewingDistanceMm == 600)
        #expect(s.fovMode == .standard(fovDeg: 60))
    }

    @Test func eyeOverrideWins() {
        var s = WalkSettings()
        s.eyeHeightOverrideMm = 1500
        #expect(s.eyeHeightMm == 1500)
        s.eyeHeightOverrideMm = nil
        s.bodyHeightMm = 1000
        #expect(s.eyeHeightMm == 936)
    }

    @Test func codableRoundTripAndMissingKeys() throws {
        var s = WalkSettings()
        s.fovMode = .calibrated
        s.screenHeightMm = 200
        s.headBob = true
        let back = try JSONDecoder().decode(WalkSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        let old = try JSONDecoder().decode(WalkSettings.self, from: Data(#"{"bodyHeightMm":1900}"#.utf8))
        #expect(old.bodyHeightMm == 1900 && old.collision == true && old.fovMode == .standard(fovDeg: 60))
    }

    @Test func sanitizedClampsAndRejectsNaN() {
        var s = WalkSettings()
        s.bodyHeightMm = 50
        s.speedFastMps = .nan
        s.fovMode = .standard(fovDeg: 500)
        let c = s.sanitized()
        #expect(c.bodyHeightMm == 1000)
        #expect(c.speedFastMps == 2.5)
        #expect(c.fovMode == .standard(fovDeg: 120))
        #expect(WalkSettings() == WalkSettings().sanitized())
    }

    @Test func calibratedFovKnownValues() {
        // 2 atan(0.5) = 53.130 degrees, 2 atan(1) = 90 degrees
        #expect(abs(WalkFOV.calibratedVerticalDeg(viewHeightMm: 600, distanceMm: 600) - 53.1301) < 1e-3)
        #expect(abs(WalkFOV.calibratedVerticalDeg(viewHeightMm: 600, distanceMm: 300) - 90) < 1e-9)
        #expect(abs(WalkFOV.calibratedVerticalDeg(viewHeightMm: 200, distanceMm: 600) - 18.9246) < 1e-3)
    }

    @Test func fovForSettingsUsesViewShare() {
        var s = WalkSettings()
        #expect(WalkFOV.verticalDeg(s, autoScreenHeightMm: nil, viewHeightPoints: 500, screenHeightPoints: 1000) == 60)
        s.fovMode = .calibrated
        s.screenHeightMm = 600
        // view covers half the screen: 300 mm at 600 mm = 28.0725 degrees
        let d = WalkFOV.verticalDeg(s, autoScreenHeightMm: 999, viewHeightPoints: 500, screenHeightPoints: 1000)
        #expect(abs(d - 28.0725) < 1e-3)
        s.screenHeightMm = nil
        let auto = WalkFOV.verticalDeg(s, autoScreenHeightMm: 600, viewHeightPoints: 500, screenHeightPoints: 1000)
        #expect(abs(auto - 28.0725) < 1e-3)
    }
}

// MARK: - Motion

@Suite("WalkMotion") struct WalkMotionTests {
    private func run(hz: Double, seconds: Double, input: WalkInput, settings: WalkSettings = WalkSettings()) -> WalkMotion {
        var m = WalkMotion(position: V2(0, 0))
        let n = Int((seconds * hz).rounded())
        for _ in 0..<n { m.advance(dt: 1 / hz, input: input, settings: settings, collider: nil) }
        return m
    }

    @Test func frameRateIndependent() {
        let input = WalkInput(forward: 1, yawDeg: 0, step: .normal)
        let a = run(hz: 30, seconds: 2, input: input), b = run(hz: 144, seconds: 2, input: input)
        let s = WalkSettings()
        let pa = a.renderedPosition(collider: nil, settings: s), pb = b.renderedPosition(collider: nil, settings: s)
        #expect(simd_length(pa - pb) <= 1.0, "30 Hz \(pa) vs 144 Hz \(pb)")
        #expect(pa.y > 1500) // actually moved north
    }

    @Test func acceleratesTowardsTargetAndBrakes() {
        var m = WalkMotion(position: .zero)
        let s = WalkSettings()
        let go = WalkInput(forward: 1, step: .normal)
        for _ in 0..<60 { m.advance(dt: 1 / 120, input: go, settings: s, collider: nil) } // 0.5 s at 3 m/s^2
        // contract: min(3 m/s^2 * 0.5 s, target speed)
        #expect(abs(m.speedMmPerSecond - min(3000 * 0.5, 1400)) < 5)
        for _ in 0..<240 { m.advance(dt: 1 / 120, input: go, settings: s, collider: nil) }
        #expect(abs(m.speedMmPerSecond - 1400) < 1)
        // braking is gradual, not instant
        m.advance(dt: 1 / 120, input: WalkInput(), settings: s, collider: nil)
        #expect(m.speedMmPerSecond > 1300)
        for _ in 0..<240 { m.advance(dt: 1 / 120, input: WalkInput(), settings: s, collider: nil) }
        #expect(m.speedMmPerSecond < 1e-6)
    }

    @Test func stepsChangeTopSpeed() {
        let s = WalkSettings()
        let slow = run(hz: 120, seconds: 3, input: WalkInput(forward: 1, step: .slow), settings: s)
        let fast = run(hz: 120, seconds: 3, input: WalkInput(forward: 1, step: .fast), settings: s)
        #expect(abs(slow.speedMmPerSecond - 800) < 1)
        #expect(abs(fast.speedMmPerSecond - 2500) < 1)
    }

    @Test func diagonalIsNotFaster() {
        let m = run(hz: 120, seconds: 3, input: WalkInput(forward: 1, strafe: 1))
        #expect(abs(m.speedMmPerSecond - 1400) < 1)
    }

    @Test func yawTurnsTheWalkDirection() {
        let m = run(hz: 120, seconds: 2, input: WalkInput(forward: 1, yawDeg: 90)) // 90 deg = west
        #expect(m.position.x < -1000 && abs(m.position.y) < 1)
    }

    @Test func crouchLowersEyeAndSlows() {
        let s = WalkSettings()
        let m = run(hz: 120, seconds: 2, input: WalkInput(forward: 1, crouch: true))
        #expect(abs(m.eyeHeightMm(settings: s) - 1638 * 0.6) < 1)
        #expect(abs(m.speedMmPerSecond - 700) < 1)
    }

    @Test func headBobOnlyWhenEnabledAndMoving() {
        var s = WalkSettings()
        var m = run(hz: 120, seconds: 2, input: WalkInput(forward: 1), settings: s)
        #expect(m.bobOffsetMm(settings: s) == 0)
        s.headBob = true
        var seen = 0.0
        for _ in 0..<120 {
            m.advance(dt: 1 / 120, input: WalkInput(forward: 1), settings: s, collider: nil)
            seen = max(seen, abs(m.bobOffsetMm(settings: s)))
        }
        #expect(seen > 5 && seen <= 25)
        let still = WalkMotion(position: .zero)
        #expect(still.bobOffsetMm(settings: s) == 0)
    }

    @Test func collisionSwitchOffWalksThroughWalls() {
        let (p, lvl, _) = wallProject([])
        let c = collider(p, lvl)
        var on = WalkMotion(position: V2(3000, -1000)), off = on
        var s = WalkSettings()
        let go = WalkInput(forward: 1, yawDeg: 0, step: .fast)
        for _ in 0..<600 { on.advance(dt: 1 / 120, input: go, settings: s, collider: c) }
        #expect(on.position.y < -250)
        s.collision = false
        for _ in 0..<600 { off.advance(dt: 1 / 120, input: go, settings: s, collider: c) }
        #expect(off.position.y > 1000)
    }
}

// MARK: - Collider

@Suite("WalkCollider") struct WalkColliderTests {
    private func walk(_ c: WalkCollider, from: V2, to: V2) -> V2 { c.move(from: from, to: to) }

    @Test func closedDoorBlocks() {
        let (p, lvl, ops) = wallProject([(.door, 3000, 800)])
        let c = collider(p, lvl)
        #expect(!c.isDoorOpen(ops[0].id))
        let end = walk(c, from: V2(3000, -1000), to: V2(3000, 1000))
        #expect(end.y <= -50 - 220 + 1 && end.y > -1000)
    }

    @Test func openDoorOf800IsPassable() {
        let (p, lvl, ops) = wallProject([(.door, 3000, 800)])
        let c = collider(p, lvl, open: [ops[0].id])
        let end = walk(c, from: V2(3000, -1000), to: V2(3000, 1000))
        #expect(abs(end.y - 1000) < 1)
    }

    @Test func gapOf350IsTooNarrow() {
        let (p, lvl, ops) = wallProject([(.door, 3000, 350)])
        let c = collider(p, lvl, open: [ops[0].id])
        let end = walk(c, from: V2(3000, -1000), to: V2(3000, 1000))
        #expect(end.y < 0, "stuck in front of the 350 mm gap, got \(end)")
        let plain = wallProject([(.opening, 3000, 350)])
        let c2 = collider(plain.0, plain.1)
        #expect(walk(c2, from: V2(3000, -1000), to: V2(3000, 1000)).y < 0)
    }

    @Test func plainOpeningIsPassableAndWindowBlocks() {
        let (p, lvl, _) = wallProject([(.opening, 1500, 900), (.window, 4500, 1200)])
        let c = collider(p, lvl)
        #expect(abs(walk(c, from: V2(1500, -1000), to: V2(1500, 1000)).y - 1000) < 1)
        #expect(walk(c, from: V2(4500, -1000), to: V2(4500, 1000)).y < 0)
    }

    @Test func slidesAlongWalls() {
        let (p, lvl, _) = wallProject([])
        let c = collider(p, lvl)
        let end = walk(c, from: V2(1000, -1000), to: V2(2000, 0)) // diagonal into the wall
        #expect(end.x > 1500, "should slide east, got \(end)")
        #expect(end.y <= -50 - 220 + 1)
    }

    @Test func openDoorLeafIsAnObstacle() {
        // Door at 3000 width 800 inward (south side is negative y; inward = left normal = +y). Leaf swings to +y.
        let (p, lvl, ops) = wallProject([(.door, 3000, 800)])
        let c = collider(p, lvl, open: [ops[0].id])
        // walking along the leaf line on the room side: leaf hinge at s0 = 2600 (not flipped), bar towards +y
        let end = walk(c, from: V2(2600 - 600, 800), to: V2(2600 + 600, 800))
        #expect(end.x < 2600, "the open leaf stops the walker, got \(end)")
    }

    @Test func furnitureBlocksRugDoesNot() {
        var p = Project.empty(name: "F")
        let lvl = p.levels[0].id
        let sofa = boxDef(2000, 900, 800), rug = boxDef(2000, 3000, 10), hanging = boxDef(1000, 500, 300)
        p.definitions = [sofa, rug, hanging]
        p.instances = [
            FurnitureInstance(definitionId: sofa.id, levelId: lvl, name: "sofa", position: P3(1000, 2000, 0)),
            FurnitureInstance(definitionId: rug.id, levelId: lvl, name: "rug", position: P3(5000, 1500, 0)),
            // starts above the eye: walk underneath
            FurnitureInstance(definitionId: hanging.id, levelId: lvl, name: "lamp", position: P3(8000, 1500, 2000)),
        ]
        let c = collider(p, lvl)
        let blocked = walk(c, from: V2(1000, 0), to: V2(1000, 3500))
        #expect(blocked.y <= 2000 - 450 - 220 + 1 && blocked.y > 800)
        #expect(abs(walk(c, from: V2(5000, 0), to: V2(5000, 3500)).y - 3500) < 1)
        #expect(abs(walk(c, from: V2(8000, 0), to: V2(8000, 3500)).y - 3500) < 1)
    }

    @Test func lampFurnitureBlocksOnlyWhileLampsAreShown() {
        var p = Project.empty(name: "L")
        let lvl = p.levels[0].id
        var lamp = boxDef(600, 600, 1800)
        lamp.lights = [LightEmitter(position: P3(0, 0, 1700))]
        p.definitions = [lamp]
        p.instances = [FurnitureInstance(definitionId: lamp.id, levelId: lvl, name: "lamp", position: P3(1000, 2000, 0))]
        let shown = WalkCollider(project: p, levelId: lvl, eyeHeightMm: 1638)
        #expect(walk(shown, from: V2(1000, 0), to: V2(1000, 3500)).y < 2000)
        let hidden = WalkCollider(project: p, levelId: lvl, eyeHeightMm: 1638, showLamps: false)
        #expect(abs(walk(hidden, from: V2(1000, 0), to: V2(1000, 3500)).y - 3500) < 1)
    }

    @Test func rotatedFurnitureUsesItsRotatedFootprint() {
        var p = Project.empty(name: "R")
        let lvl = p.levels[0].id
        let d = boxDef(2000, 200, 900)
        p.definitions = [d]
        p.instances = [FurnitureInstance(definitionId: d.id, levelId: lvl, name: "bar", position: P3(0, 0, 0), rotationDeg: 90)]
        let c = collider(p, lvl)
        // rotated 90: 200 wide in x, 2000 long in y. Walking along x at y = 800 hits it, at y = 1500 passes.
        #expect(walk(c, from: V2(-1000, 800), to: V2(1000, 800)).x < 0)
        #expect(abs(walk(c, from: V2(-1000, 1500), to: V2(1000, 1500)).x - 1000) < 1)
    }

    @Test func furnitureOnOtherLevelIgnored() {
        var p = Project.empty(name: "L")
        let lvl = p.levels[0].id
        let d = boxDef(2000, 900, 800)
        p.definitions = [d]
        p.instances = [FurnitureInstance(definitionId: d.id, levelId: UUID(), name: "x", position: P3(0, 0, 0))]
        #expect(abs(walk(collider(p, lvl), from: V2(0, -2000), to: V2(0, 2000)).y - 2000) < 1)
    }

    @Test func doorStateCanChange() {
        let (p, lvl, ops) = wallProject([(.door, 3000, 800)])
        var c = collider(p, lvl)
        c.setDoor(ops[0].id, open: true)
        #expect(c.isDoorOpen(ops[0].id))
        #expect(abs(walk(c, from: V2(3000, -1000), to: V2(3000, 1000)).y - 1000) < 1)
        c.setDoor(ops[0].id, open: false)
        #expect(walk(c, from: V2(3000, -1000), to: V2(3000, 1000)).y < 0)
        #expect(c.doorIds == [ops[0].id])
    }
}

// MARK: - Measure

@Suite("WalkMeasure") struct WalkMeasureTests {
    @Test func eyeAboveWorktop() throws {
        var p = Project.empty(name: "M")
        let lvl = p.levels[0].id
        let top = boxDef(2000, 600, 900)
        p.definitions = [top]
        let inst = FurnitureInstance(definitionId: top.id, levelId: lvl, name: "worktop", position: P3(0, 0, 0))
        p.instances = [inst]
        let m = try WalkMeasure.eyeAboveSurface(eyeHeightMm: 1638, project: p, furnitureId: inst.id)
        #expect(m.valueMm == 738)
        // the plan's reference case: eye 1800 over a 900 worktop is exactly 900
        #expect(try WalkMeasure.eyeAboveSurface(eyeHeightMm: 1800, project: p, furnitureId: inst.id).valueMm == 900)
    }

    @Test func windowSillAndDoorClear() throws {
        let (p, _, ops) = wallProject([(.window, 1500, 1200), (.door, 4000, 900)])
        #expect(try WalkMeasure.windowSill(project: p, openingId: ops[0].id).valueMm == 900)
        let r = try WalkMeasure.doorClear(project: p, openingId: ops[1].id)
        #expect(r.width.valueMm == 800) // 900 - 2 * 50
        #expect(r.height == 2050) // 2100 - 50
        #expect(throws: WalkMeasureError.self) { try WalkMeasure.windowSill(project: p, openingId: ops[1].id) }
        #expect(throws: WalkMeasureError.self) { try WalkMeasure.doorClear(project: p, openingId: ops[0].id) }
    }

    @Test func gapBetweenSofaAndCoffeeTable() throws {
        var p = Project.empty(name: "G")
        let lvl = p.levels[0].id
        let sofa = boxDef(2000, 900, 800), table = boxDef(1000, 500, 400)
        p.definitions = [sofa, table]
        let a = FurnitureInstance(definitionId: sofa.id, levelId: lvl, name: "sofa", position: P3(0, 0, 0))
        // sofa front edge at y = 450, table near edge at y = 450 + 400
        let b = FurnitureInstance(definitionId: table.id, levelId: lvl, name: "table", position: P3(0, 450 + 400 + 250, 0))
        let c = FurnitureInstance(definitionId: table.id, levelId: lvl, name: "touching", position: P3(0, 450 + 250 - 100, 0))
        p.instances = [a, b, c]
        #expect(abs(try WalkMeasure.gap(project: p, a: a.id, b: b.id).valueMm - 400) < 1e-6)
        #expect(try WalkMeasure.gap(project: p, a: a.id, b: c.id).valueMm == 0)
    }

    @Test func gapOfDiagonalCornersIsEuclidean() {
        let a = [V2(0, 0), V2(100, 0), V2(100, 100), V2(0, 100)]
        let b = [V2(400, 500), V2(500, 500), V2(500, 600), V2(400, 600)]
        #expect(abs(WalkMeasure.polygonDistance(a, b) - 500) < 1e-9) // (300, 400)
    }
}

// MARK: - Walk safety

@Suite("WalkSafety") struct WalkSafetyTests {
    @Test func doorClosesOnTheWalker() {
        let (p, lvl, ops) = wallProject([(.door, 3000, 900)])
        var c = collider(p, lvl, open: [ops[0].id])
        var m = WalkMotion(position: V2(3000, 0)) // standing in the open doorway
        let s = WalkSettings()
        c.setDoor(ops[0].id, open: false) // door closes on the figure
        let start = m.position
        var maxSpeed = 0.0
        for _ in 0..<120 {
            m.advance(dt: 1 / 120, input: WalkInput(forward: 1, step: .normal), settings: s, collider: c)
            maxSpeed = max(maxSpeed, m.speedMmPerSecond)
        }
        #expect(maxSpeed <= s.speedNormalMps * 1000 + 1e-6, "peak \(maxSpeed) mm/s")
        // push-out (at most wall half thickness + radius) plus one second of walking
        #expect(simd_length(m.position - start) <= 50 + 220 + s.speedNormalMps * 1000 + 1)
    }

    @Test func doorAtTheWallEndStaysClosedAcrossItsWholeWidth() {
        let (p, lvl, ops) = wallProject([(.door, 5550, 900)]) // jamb at the wall end (x = 6000)
        let c = collider(p, lvl)
        for x in stride(from: 5120.0, through: 5980.0, by: 80) {
            let end = c.move(from: V2(x, -600), to: V2(x, 600))
            #expect(end.y < 0, "walked through the closed door at x=\(x)")
        }
        _ = ops
    }
}

// MARK: - Door leaf mesh

@Suite("DoorLeaf") struct DoorLeafTests {
    @Test func frameWithoutLeafIsSmallerAndLeafIsLocal() {
        let (p, _, ops) = wallProject([(.door, 3000, 900)])
        let wall = p.walls[0]
        let full = Meshes.openingFrame(ops[0], wall: wall, baseZ: 0)
        let bare = Meshes.openingFrame(ops[0], wall: wall, baseZ: 0, includeLeaf: false)
        let leaf = Meshes.doorLeaf(ops[0], wall: wall, baseZ: 0)
        #expect(bare.positions.count + leaf.positions.count == full.positions.count)
        let xs = leaf.positions.map(\.x)
        #expect(abs((xs.max()! - xs.min()!) - 800) < 1e-6) // clear width between the jambs
        #expect(abs(xs.min()!) < 1e-6)
    }

    @Test func placementHonoursFlippedAndInward() throws {
        var (p, _, ops) = wallProject([(.door, 3000, 900)])
        let wall = p.walls[0]
        var o = ops[0]
        let a = try #require(Meshes.doorLeafPlacement(o, wall: wall, baseZ: 0))
        #expect(abs(a.hinge.x - 2600) < 1e-6) // 3000 - 450 + 50
        #expect(abs(a.closedYawDeg) < 1e-6 && abs(a.openYawDeg - 90) < 1e-6) // inward swings to +y
        func dir(_ deg: Double) -> V2 { V2(cos(deg * .pi / 180), sin(deg * .pi / 180)) }
        // not flipped: hinge at the low-x jamb, closed leaf points +x, open leaf points +y (inward)
        #expect(simd_length(dir(a.closedYawDeg) - V2(1, 0)) < 1e-6 && simd_length(dir(a.openYawDeg) - V2(0, 1)) < 1e-6)
        o.flipped = true
        let b = try #require(Meshes.doorLeafPlacement(o, wall: wall, baseZ: 0))
        #expect(abs(b.hinge.x - 3400) < 1e-6)
        // flipped: hinge at the high-x jamb, closed leaf points -x, open leaf still points +y
        #expect(simd_length(dir(b.closedYawDeg) - V2(-1, 0)) < 1e-6 && simd_length(dir(b.openYawDeg) - V2(0, 1)) < 1e-6)
        o.inward = false
        let c = try #require(Meshes.doorLeafPlacement(o, wall: wall, baseZ: 0))
        #expect(simd_length(dir(c.closedYawDeg) - V2(-1, 0)) < 1e-6 && simd_length(dir(c.openYawDeg) - V2(0, -1)) < 1e-6)
        p.openings = []
        #expect(Meshes.doorLeafPlacement(Opening(wallId: wall.id, kind: .window, offset: 1, width: 1, height: 1, sill: 0), wall: wall, baseZ: 0) == nil)
    }
}

// MARK: - walk.* tools

@MainActor
private final class FakeWalk: AgentWalkBridge {
    var settings = WalkSettings()
    var doors: Set<UUID> = []
    var live = true
    func walkState() -> AgentWalkState {
        AgentWalkState(settings: settings, active: true, eyeHeightMm: settings.eyeHeightMm, speedMps: 0, fovDeg: 60,
                       autoScreenHeightMm: 190, openDoors: Array(doors))
    }
    func applyWalkSettings(_ s: WalkSettings) -> AgentWalkState { settings = s; return walkState() }
    func setDoor(_ id: UUID, open: Bool?) throws -> Bool {
        guard live else { throw AgentError.unsupportedFeature("no live view") }
        let now = open ?? !doors.contains(id)
        if now { doors.insert(id) } else { doors.remove(id) }
        return now
    }
}

@MainActor
private final class WalkContext: AgentAppContext {
    var selection: Set<UUID> = []
    var activeLevelId: UUID
    var fileURL: URL?
    var appVersion = "test"
    var walk: FakeWalk?
    var viewBridge: AgentViewBridge? { nil }
    var walkBridge: AgentWalkBridge? { walk }
    init(activeLevelId: UUID) { self.activeLevelId = activeLevelId }
    func saveForAgent() throws -> String { "/tmp/test.roomsmith" }
}

@MainActor
private struct WRig {
    let store: DocumentStore
    let walk = FakeWalk()
    let registry: ToolRegistry
    let door: Opening
    let window: Opening

    init(write: Bool = true, bridge: Bool = true) {
        var (p, _, ops) = wallProject([(.door, 3000, 800), (.window, 1200, 1000)])
        let def = boxDef(2000, 600, 900)
        p.definitions = [def]
        p.instances = [FurnitureInstance(definitionId: def.id, levelId: p.levels[0].id, name: "top", position: P3(0, 2000, 0))]
        door = ops[0]; window = ops[1]
        store = DocumentStore(project: p)
        store.agentWriteEnabled = write
        let ctx = WalkContext(activeLevelId: p.levels[0].id)
        if bridge { ctx.walk = walk }
        registry = ToolRegistry(store: store, context: ctx)
    }

    func call(_ tool: String, _ args: JSONValue = .object([:])) async -> AgentResponse {
        await registry.call(AgentRequest(id: 1, token: "t", clientId: "test", tool: tool, arguments: args))
    }
    func ok(_ tool: String, _ args: JSONValue = .object([:])) async -> JSONValue {
        let r = await call(tool, args)
        #expect(r.ok, "\(tool) failed: \(r.error?.code ?? "?") \(r.error?.message ?? "")")
        return r.result ?? .null
    }
    func code(_ tool: String, _ args: JSONValue = .object([:])) async -> String? {
        let r = await call(tool, args)
        return r.ok ? nil : r.error?.code
    }
}

@MainActor
struct WalkToolTests {
    @Test func noBridgeIsUnsupported() async {
        let r = WRig(bridge: false)
        #expect(await r.code("walk.get") == "UNSUPPORTED")
        #expect(await r.code("walk.set", ["headBob": true]) == "UNSUPPORTED")
        #expect(await r.code("walk.toggle_door", ["openingId": .string(r.door.id.uuidString)]) == "UNSUPPORTED")
    }

    @Test func getReportsSettingsAndLiveValues() async {
        let r = WRig()
        let v = await r.ok("walk.get")
        #expect(v["bodyHeightMm"]?.doubleValue == 1750)
        #expect(v["eyeHeightMm"]?.doubleValue == 1638)
        #expect(v["collision"]?.boolValue == true)
        #expect(v["fovMode"]?["mode"]?.stringValue == "standard")
        #expect(v["autoScreenHeightMm"]?.doubleValue == 190)
    }

    @Test func setIsPartialAndValidated() async {
        let r = WRig()
        let v = await r.ok("walk.set", ["headBob": true, "speedFastMps": 3.0, "fovMode": ["mode": "calibrated"]])
        #expect(v["headBob"]?.boolValue == true)
        #expect(r.walk.settings.speedFastMps == 3 && r.walk.settings.fovMode == .calibrated)
        #expect(r.walk.settings.bodyHeightMm == 1750)
        #expect(await r.code("walk.set", ["bodyHeightMm": 90]) == "OUT_OF_RANGE")
        #expect(r.walk.settings.bodyHeightMm == 1750)
        #expect(await r.code("walk.set", [:]) != nil)
        _ = await r.ok("walk.set", ["eyeHeightOverrideMm": 1500])
        #expect(r.walk.settings.eyeHeightMm == 1500)
        _ = await r.ok("walk.set", ["eyeHeightOverrideMm": .null])
        #expect(r.walk.settings.eyeHeightOverrideMm == nil)
    }

    @Test func setNeedsWriteAccessAndLeavesRevision() async {
        let locked = WRig(write: false)
        #expect(await locked.code("walk.set", ["headBob": true]) == AgentError.writeLocked)
        #expect(await locked.code("walk.toggle_door", ["openingId": .string(locked.door.id.uuidString)]) == AgentError.writeLocked)
        #expect(await locked.code("walk.get") == nil)
        let r = WRig()
        let rev = r.store.contentRevision
        _ = await r.ok("walk.set", ["collision": false])
        #expect(r.store.contentRevision == rev)
    }

    @Test func toggleDoor() async {
        let r = WRig()
        let id = JSONValue.string(r.door.id.uuidString)
        #expect(await r.ok("walk.toggle_door", ["openingId": id])["open"]?.boolValue == true)
        #expect(await r.ok("walk.toggle_door", ["openingId": id])["open"]?.boolValue == false)
        #expect(await r.ok("walk.toggle_door", ["openingId": id, "open": true])["open"]?.boolValue == true)
        #expect(await r.code("walk.toggle_door", ["openingId": .string(r.window.id.uuidString)]) == "INVALID_ARGUMENT")
        #expect(await r.code("walk.toggle_door", ["openingId": .string(UUID().uuidString)]) == "NOT_FOUND")
        r.walk.live = false
        #expect(await r.code("walk.toggle_door", ["openingId": id]) == "UNSUPPORTED")
    }

    @Test func measureKinds() async {
        let r = WRig()
        let top = r.store.project.instances[0].id
        #expect(await r.ok("walk.measure", ["kind": "eye_above_surface", "ids": [.string(top.uuidString)]])["valueMm"]?.doubleValue == 738)
        #expect(await r.ok("walk.measure", ["kind": "window_sill", "ids": [.string(r.window.id.uuidString)]])["valueMm"]?.doubleValue == 900)
        let d = await r.ok("walk.measure", ["kind": "door_clear", "ids": [.string(r.door.id.uuidString)]])
        #expect(d["clearWidthMm"]?.doubleValue == 700 && d["clearHeightMm"]?.doubleValue == 2050)
        #expect(await r.code("walk.measure", ["kind": "gap", "ids": [.string(top.uuidString)]]) == "INVALID_ARGUMENT")
        #expect(await r.code("walk.measure", ["kind": "nope", "ids": [.string(top.uuidString)]]) == "INVALID_ARGUMENT")
        #expect(await r.code("walk.measure", ["kind": "window_sill", "ids": [.string(UUID().uuidString)]]) == "NOT_FOUND")
    }
}

// MARK: - Space held: walk through

@Suite("WalkPassThrough") struct WalkPassThroughTests {
    @Test func spaceTurnsTheColliderOffOnlyWhileHeld() {
        let (p, lvl, _) = wallProject([])
        let c = collider(p, lvl)
        #expect(WalkPassThrough.activeCollider(c, setting: true, spaceHeld: false) != nil)
        #expect(WalkPassThrough.activeCollider(c, setting: true, spaceHeld: true) == nil)
        #expect(WalkPassThrough.collides(setting: true, spaceHeld: false))
        #expect(!WalkPassThrough.collides(setting: true, spaceHeld: true))
    }

    @Test func collisionSettingOffStaysOffWhateverSpaceDoes() {
        let (p, lvl, _) = wallProject([])
        let c = collider(p, lvl)
        #expect(WalkPassThrough.activeCollider(c, setting: false, spaceHeld: false) == nil)
        #expect(WalkPassThrough.activeCollider(c, setting: false, spaceHeld: true) == nil)
    }

    @Test func releasedInsideAWallIsPushedToTheNearestFreeSpot() {
        let (p, lvl, _) = wallProject([])
        let c = collider(p, lvl)
        // Wall along y = 0 (default thickness), body radius 220: free from |y| >= half the thickness + 220.
        let freeY = Double(p.walls[0].thickness) / 2 + 220
        let inside = V2(3000, 20)
        #expect(c.isBlocked(inside))
        let out = WalkPassThrough.settled(inside, collider: c, setting: true)
        #expect(!c.isBlocked(out))
        #expect(abs(out.x - 3000) < 1)
        #expect(abs(out.y - freeY) < 5, "should leave by the near side, not jump further: \(out)")
        // In the open nothing moves; without collision nothing moves either.
        #expect(WalkPassThrough.settled(V2(3000, 2000), collider: c, setting: true) == V2(3000, 2000))
        #expect(WalkPassThrough.settled(inside, collider: c, setting: false) == inside)
    }
}
