import Foundation
import Testing
@testable import RoomsmithCore

// Dimension chains: exact millimetre numbers for wall faces, openings, slanted walls, free points, undo and the agent tool.

@MainActor
private final class ChainContext: AgentAppContext {
    var selection: Set<UUID> = []
    var activeLevelId: UUID
    var fileURL: URL?
    var appVersion = "test"
    init(activeLevelId: UUID) { self.activeLevelId = activeLevelId }
    func saveForAgent() throws -> String { "/tmp/test.roomsmith" }
}

private struct Fixture {
    var p = Project.empty(name: "Chain")
    var level: UUID { p.levels[0].id }
    var wall = UUID()

    /// Wall from `a` to `b` with thickness `t`.
    init(_ a: P2 = P2(0, 0), _ b: P2 = P2(5000, 0), thickness: MM = 240) {
        wall = try! p.addWall(levelId: p.levels[0].id, start: a, end: b, thickness: thickness)
    }

    @discardableResult
    mutating func open(_ kind: OpeningKind, centre: MM, width: MM) -> UUID {
        try! p.addOpening(wallId: wall, kind: kind, offset: centre, width: width, height: 1000, sill: 0)
    }
}

private func lengths(_ pts: [P2]) -> [MM] {
    zip(pts, pts.dropFirst()).map { DimensionChains.length($0, $1) }
}

struct DimensionChainTests {
    // MARK: Wall chains

    /// A 100 mm wall between two 240 mm walls of a U: the mitres eat its inner face (100 - 2 * 120 < 0).
    /// That face has no length and must be refused, never measured as a positive number; the outer face is exact.
    @Test func shortWallWithCrossedMitresRefusesItsHiddenFace() throws {
        var p = Project.empty(name: "U")
        let l = p.levels[0].id
        _ = try p.addWall(levelId: l, start: P2(0, 2000), end: P2(0, 0), thickness: 240)
        let b = try p.addWall(levelId: l, start: P2(0, 0), end: P2(100, 0), thickness: 240)
        _ = try p.addWall(levelId: l, start: P2(100, 0), end: P2(100, 2000), thickness: 240)
        #expect(throws: CommandError.self) { try DimensionChains.wallChain(p, wallId: b, side: .left) }
        let outer = try DimensionChains.wallChain(p, wallId: b, side: .right)
        #expect(lengths(outer.points) == [340])
        #expect(outer.points == [P2(-120, -120), P2(220, -120)])
    }

    @Test func wallWithDoorAndWindowGivesExactParts() throws {
        var f = Fixture()
        f.open(.door, centre: 1450, width: 900)     // edges 1000...1900
        f.open(.window, centre: 3600, width: 1200)  // edges 3000...4200
        let c = try DimensionChains.wallChain(f.p, wallId: f.wall, side: .left)
        #expect(lengths(c.points) == [1000, 900, 1100, 1200, 800])
        #expect(lengths(c.points).reduce(0, +) == 5000)
        // Points sit on the left face: axis y 0 + 240 / 2, not on the axis.
        #expect(c.points == [P2(0, 120), P2(1000, 120), P2(1900, 120), P2(3000, 120), P2(4200, 120), P2(5000, 120)])
        #expect(c.side == .left && c.offset == 500)
        let r = try DimensionChains.wallChain(f.p, wallId: f.wall, side: .right, offset: 700)
        #expect(r.points.map(\.y) == Array(repeating: -120, count: 6))
        #expect(r.points.map(\.x) == [0, 1000, 1900, 3000, 4200, 5000])
        #expect(r.offset == -700 && r.side == .right)
    }

    @Test func openingsCanBeLeftOut() throws {
        var f = Fixture()
        f.open(.door, centre: 1450, width: 900)
        let c = try DimensionChains.wallChain(f.p, wallId: f.wall, side: .left, includeOpenings: false)
        #expect(c.points == [P2(0, 120), P2(5000, 120)])
    }

    @Test func wallRunningWestAndOddThicknessStayExact() throws {
        // Default thickness 115: the face lies at +-57.5 mm, rounded half away from zero; lengths stay exact.
        var f = Fixture(P2(5000, 0), P2(0, 0), thickness: 115)
        f.open(.door, centre: 4000, width: 900)  // from the start (x = 5000): edges 3550...4450 -> x 1450...550
        let c = try DimensionChains.wallChain(f.p, wallId: f.wall, side: .left)
        // Direction west: the left normal points south (-y).
        #expect(c.points.map(\.y) == Array(repeating: -58, count: 4))
        #expect(c.points.map(\.x) == [5000, 1450, 550, 0])
        #expect(lengths(c.points) == [3550, 900, 550])
        #expect(c.points[0] == P2(5000, -58) && c.points.last == P2(0, -58))
        #expect(lengths(c.points).reduce(0, +) == 5000)
    }

    @Test func slantedWallUsesExactDistances() throws {
        var f = Fixture(P2(0, 0), P2(3000, 4000))   // length 5000, direction (0.6, 0.8), left normal (-0.8, 0.6)
        f.open(.door, centre: 2500, width: 1000)    // 2000...3000
        let c = try DimensionChains.wallChain(f.p, wallId: f.wall, side: .left)
        #expect(c.points == [P2(-96, 72), P2(1104, 1672), P2(1704, 2472), P2(2904, 4072)])
        #expect(lengths(c.points) == [2000, 1000, 2000])
        #expect(DimensionChains.length(c.points[0], c.points[3]) == 5000)
    }

    @Test func openingBeyondWallEndIsClamped() throws {
        var f = Fixture()
        f.open(.door, centre: 4800, width: 1000)   // 4300...5300 -> clamped to 5000
        f.open(.window, centre: 200, width: 800)   // -200...600 -> clamped to 0
        f.open(.window, centre: 7000, width: 500)  // completely outside: ignored
        let c = try DimensionChains.wallChain(f.p, wallId: f.wall, side: .left)
        #expect(c.points.map(\.x) == [0, 600, 4300, 5000])
        #expect(lengths(c.points) == [600, 3700, 700])
    }

    @Test func overlappingAndTouchingOpeningsShareEdges() throws {
        var f = Fixture()
        f.open(.door, centre: 1450, width: 900)    // 1000...1900
        f.open(.window, centre: 2000, width: 1000) // 1500...2500 overlaps the door
        f.open(.window, centre: 3000, width: 1000) // 2500...3500 touches the previous one
        let c = try DimensionChains.wallChain(f.p, wallId: f.wall, side: .left)
        #expect(c.points.map(\.x) == [0, 1000, 1500, 1900, 2500, 3500, 5000])
    }

    @Test func oddOpeningWidthRoundsHalfAwayFromZero() throws {
        var f = Fixture()
        f.open(.door, centre: 1450, width: 901)    // 999.5...1900.5 -> 1000...1901
        let c = try DimensionChains.wallChain(f.p, wallId: f.wall, side: .left)
        #expect(c.points.map(\.x) == [0, 1000, 1901, 5000])
    }

    @Test func outerSideOfARoom() throws {
        var p = Project.empty(name: "House")
        let l = p.levels[0].id
        let corners = [P2(0, 0), P2(4000, 0), P2(4000, 3000), P2(0, 3000)]
        var ids: [UUID] = []
        for i in 0..<4 { ids.append(try p.addWall(levelId: l, start: corners[i], end: corners[(i + 1) % 4], thickness: 240)) }
        // Counter-clockwise loop: the room is on the left of every wall, so the outside is on the right.
        for id in ids {
            let w = p.wall(id)!
            #expect(DimensionChains.outerSide(of: w, in: p) == .right)
        }
        let south = try DimensionChains.wallChain(p, wallId: ids[0], side: .auto)
        #expect(south.side == .right && south.isOuter && south.offset == -500)
        #expect(south.points == [P2(-120, -120), P2(4120, -120)])
        let inner = try DimensionChains.wallChain(p, wallId: ids[0], side: .inner)
        #expect(inner.side == .left && !inner.isOuter && inner.points == [P2(120, 120), P2(3880, 120)])
        let outer = try DimensionChains.wallChain(p, wallId: ids[1], side: .outer)  // east wall, runs north
        #expect(outer.side == .right && outer.points == [P2(4120, -120), P2(4120, 3120)])
    }

    private func room(_ w: MM = 4000, _ h: MM = 3000, thickness: MM = 240) -> (Project, [UUID]) {
        var p = Project.empty(name: "Room")
        let l = p.levels[0].id
        let c = [P2(0, 0), P2(w, 0), P2(w, h), P2(0, h)]
        let ids = (0..<4).map { try! p.addWall(levelId: l, start: c[$0], end: c[($0 + 1) % 4], thickness: thickness) }
        return (p, ids)
    }

    @Test func roomOuterAndInnerTotalsOnAllFourWalls() throws {
        let (p, ids) = room()
        for (i, id) in ids.enumerated() {
            let axis: MM = i % 2 == 0 ? 4000 : 3000
            let o = try DimensionChains.wallChain(p, wallId: id, side: .outer)
            let n = try DimensionChains.wallChain(p, wallId: id, side: .inner)
            #expect(DimensionChains.length(o.points[0], o.points.last!) == axis + 240)
            #expect(DimensionChains.length(n.points[0], n.points.last!) == axis - 240)
        }
    }

    @Test func oddThicknessRoomTotalsAreExactInBothDirections() throws {
        for t: MM in [239, 241, 75] {
            for reversed in [false, true] {
                var p = Project.empty(name: "Room")
                let l = p.levels[0].id
                var c = [P2(0, 0), P2(4000, 0), P2(4000, 3000), P2(0, 3000)]
                if reversed { c.reverse() }
                let ids = (0..<4).map { try! p.addWall(levelId: l, start: c[$0], end: c[($0 + 1) % 4], thickness: t) }
                for id in ids {
                    let axis = DimensionChains.length(p.wall(id)!.start, p.wall(id)!.end)
                    let o = try DimensionChains.wallChain(p, wallId: id, side: .outer)
                    let n = try DimensionChains.wallChain(p, wallId: id, side: .inner)
                    #expect(DimensionChains.length(o.points[0], o.points.last!) == axis + t)
                    #expect(DimensionChains.length(n.points[0], n.points.last!) == axis - t)
                    #expect(lengths(o.points).reduce(0, +) == axis + t)
                }
            }
        }
    }

    @Test func freeSingleWallTotalIsAxisLength() throws {
        let f = Fixture()
        let c = try DimensionChains.wallChain(f.p, wallId: f.wall, side: .left)
        #expect(DimensionChains.length(c.points[0], c.points.last!) == 5000)
    }

    @Test func openingNearMiteredCornerIsMeasuredFromTheFaceCorner() throws {
        var (p, ids) = room()
        // South wall, axis 0...4000; door 100...700 (centre 400, width 600) starts inside the outer mitre (-120).
        _ = try p.addOpening(wallId: ids[0], kind: .door, offset: 400, width: 600, height: 2000, sill: 0)
        let o = try DimensionChains.wallChain(p, wallId: ids[0], side: .outer)
        #expect(o.points.map(\.x) == [-120, 100, 700, 4120])
        #expect(lengths(o.points) == [220, 600, 3420])
        let n = try DimensionChains.wallChain(p, wallId: ids[0], side: .inner)
        // Inner face runs 120...3880; the door starts at 100, which is before the inner corner: clamped to it.
        #expect(n.points.map(\.x) == [120, 700, 3880])
        #expect(lengths(n.points) == [580, 3180])
    }

    @Test func openingWiderThanWallCoversWholeFace() throws {
        var f = Fixture()
        f.open(.window, centre: 2500, width: 9000)
        let c = try DimensionChains.wallChain(f.p, wallId: f.wall, side: .left)
        #expect(c.points == [P2(0, 120), P2(5000, 120)])
    }

    @Test func overlappingOpeningsWithEqualEdgesGiveEachEdgeOnce() throws {
        var f = Fixture()
        f.open(.door, centre: 1450, width: 900)
        f.open(.window, centre: 1450, width: 900)
        f.open(.window, centre: 1550, width: 700)  // 1200...1900, shares the end edge
        let c = try DimensionChains.wallChain(f.p, wallId: f.wall, side: .left)
        #expect(c.points.map(\.x) == [0, 1000, 1200, 1900, 5000])
    }

    @Test func slantedWallWithOddSlopeDeviatesByAtMostOneMillimetre() throws {
        var f = Fixture(P2(0, 0), P2(7000, 3000), thickness: 100)
        f.open(.door, centre: 3000, width: 900)
        let c = try DimensionChains.wallChain(f.p, wallId: f.wall, side: .left)
        let l = lengths(c.points)
        #expect(l.count == 3)
        #expect(abs(l[1] - 900) <= 1)
        #expect(abs(l[0] - (3000 - 450)) <= 1)
        #expect(abs(l[0] + l[1] + l[2] - 7616) <= 1)  // sqrt(7000^2 + 3000^2) = 7615.77
    }

    @Test func lonelyWallHasNoOutsideAndAutoFallsBackToLeft() throws {
        let f = Fixture()
        #expect(DimensionChains.outerSide(of: f.p.wall(f.wall)!, in: f.p) == nil)
        let auto = try DimensionChains.wallChain(f.p, wallId: f.wall)
        #expect(auto.side == .left && !auto.isOuter)
        #expect(throws: CommandError.self) { try DimensionChains.wallChain(f.p, wallId: f.wall, side: .outer) }
        #expect(throws: CommandError.self) { try DimensionChains.wallChain(f.p, wallId: f.wall, side: .inner) }
    }

    @Test func wallChainErrors() throws {
        var f = Fixture()
        #expect(throws: CommandError.self) { try DimensionChains.wallChain(f.p, wallId: UUID()) }
        #expect(throws: CommandError.self) { try DimensionChains.wallChain(f.p, wallId: f.wall, offset: -1) }
        let zero = try f.p.addWall(levelId: f.level, start: P2(10, 10), end: P2(10, 10))
        #expect(throws: CommandError.self) { try DimensionChains.wallChain(f.p, wallId: zero) }
    }

    // MARK: Free points

    @Test func pointsChainKeepsCollinearPointsAndSortsThem() throws {
        let pts = [P2(0, 0), P2(2000, 0), P2(1000, 0), P2(3000, 0)]
        #expect(try DimensionChains.pointsChain(pts) == [P2(0, 0), P2(1000, 0), P2(2000, 0), P2(3000, 0)])
        // A slanted but exactly collinear row is not altered.
        let s = [P2(0, 0), P2(600, 800), P2(1800, 2400), P2(3000, 4000)]
        #expect(try DimensionChains.pointsChain(s) == s)
    }

    @Test func pointsChainProjectsOffLinePoints() throws {
        let r = try DimensionChains.pointsChain([P2(0, 0), P2(1000, 30), P2(2500, -40), P2(4000, 0)])
        #expect(r == [P2(0, 0), P2(1000, 0), P2(2500, 0), P2(4000, 0)])
        // Even 2 mm beside the line a point is projected.
        #expect(try DimensionChains.pointsChain([P2(0, 0), P2(1000, 2), P2(4000, 0)])[1] == P2(1000, 0))
        #expect(try DimensionChains.pointsChain([P2(0, 0), P2(1000, 1), P2(4000, 0)])[1] == P2(1000, 0))
        // Vertical line.
        #expect(try DimensionChains.pointsChain([P2(0, 0), P2(60, 1500), P2(0, 3000)]) == [P2(0, 0), P2(0, 1500), P2(0, 3000)])
    }

    @Test func pointsChainErrors() {
        #expect(throws: CommandError.self) { try DimensionChains.pointsChain([]) }
        #expect(throws: CommandError.self) { try DimensionChains.pointsChain([P2(0, 0)]) }
        #expect(throws: CommandError.self) { try DimensionChains.pointsChain([P2(5, 5), P2(5, 5)]) }
        #expect(throws: CommandError.self) { try DimensionChains.pointsChain([P2(0, 0), P2(1000, 0), P2(1000, 0), P2(2000, 0)]) }
        // Different places that project onto the same spot.
        #expect(throws: CommandError.self) { try DimensionChains.pointsChain([P2(0, 0), P2(1000, 0), P2(1000, 50), P2(2000, 0)]) }
        // 2 mm beside the line, same position along it: duplicate, not a dimension "2".
        #expect(throws: CommandError.self) { try DimensionChains.pointsChain([P2(0, 0), P2(1000, 0), P2(1000, 2), P2(2000, 0)]) }
        #expect(throws: CommandError.self) { try DimensionChains.pointsChain([P2(0, 0), P2(0, 2), P2(2000, 0)]) }
        #expect(throws: CommandError.self) { try DimensionChains.pointsChain([P2(0, 0), P2(coordinateLimit + 1, 0)]) }
        #expect(throws: CommandError.self) {
            try DimensionChains.pointsChain((0...DimensionChains.maxPoints).map { P2(MM($0) * 10, 0) })
        }
    }

    // MARK: Command

    @Test func addDimensionChainCreatesPartsAndTotal() throws {
        var p = Project.empty(name: "C")
        let l = p.levels[0].id
        let pts = [P2(0, 120), P2(1000, 120), P2(1900, 120), P2(3000, 120), P2(4200, 120), P2(5000, 120)]
        let ids = try p.addDimensionChain(levelId: l, points: pts, offset: 500, includeTotal: true)
        #expect(ids.count == 6)
        let dims = ids.map { p.dimension($0)! }
        #expect(dims.map { DimensionChains.length($0.a, $0.b) } == [1000, 900, 1100, 1200, 800, 5000])
        #expect(dims.map(\.offset) == [500, 500, 500, 500, 500, 900])
        #expect(dims[5].a == P2(0, 120) && dims[5].b == P2(5000, 120))
        #expect(dims.allSatisfy { $0.levelId == l })
        #expect(p.dimensions.count == 6)
    }

    @Test func totalOffsetKeepsTheSign() throws {
        var p = Project.empty(name: "C")
        let l = p.levels[0].id
        let ids = try p.addDimensionChain(levelId: l, points: [P2(0, 0), P2(1000, 0), P2(3000, 0)], offset: -500)
        #expect(ids.map { p.dimension($0)!.offset } == [-500, -500, -900])
        let zero = try p.addDimensionChain(levelId: l, points: [P2(0, 0), P2(1000, 0), P2(3000, 0)], offset: 0)
        #expect(zero.map { p.dimension($0)!.offset } == [0, 0, 400])
    }

    @Test func totalIsOptionalAndSkippedForTwoPoints() throws {
        var p = Project.empty(name: "C")
        let l = p.levels[0].id
        #expect(try p.addDimensionChain(levelId: l, points: [P2(0, 0), P2(1000, 0), P2(3000, 0)], includeTotal: false).count == 2)
        #expect(try p.addDimensionChain(levelId: l, points: [P2(0, 0), P2(3000, 0)], includeTotal: true).count == 1)
        #expect(p.dimensions.count == 3)
    }

    @Test func hugeOffsetIsRejectedWithoutOverflow() throws {
        var p = Project.empty(name: "C")
        let l = p.levels[0].id
        for o in [MM.max, MM.min, MM.max - 100, MM.min + 100] {
            #expect(throws: CommandError.self) { try p.addDimensionChain(levelId: l, points: [P2(0, 0), P2(1000, 0), P2(3000, 0)], offset: o) }
        }
        #expect(DimensionChains.totalOffset(for: MM.max) == MM.max && DimensionChains.totalOffset(for: MM.min) == MM.min)
    }

    @Test func commandErrorsLeaveTheProjectUntouched() throws {
        var p = Project.empty(name: "C")
        let l = p.levels[0].id
        #expect(throws: CommandError.self) { try p.addDimensionChain(levelId: l, points: [P2(0, 0)]) }
        #expect(throws: CommandError.self) { try p.addDimensionChain(levelId: l, points: [P2(0, 0), P2(0, 0)]) }
        #expect(throws: CommandError.self) { try p.addDimensionChain(levelId: l, points: [P2(0, 0), P2(1000, 0), P2(1000, 0), P2(3000, 0)]) }
        #expect(throws: CommandError.self) { try p.addDimensionChain(levelId: UUID(), points: [P2(0, 0), P2(1000, 0)]) }
        #expect(throws: CommandError.self) { try p.addDimensionChain(levelId: l, points: [P2(0, 0), P2(1000, 0)], offset: coordinateLimit) }
        try p.updateLevel(l, locked: true)
        let locked = p
        #expect(throws: CommandError.self) { try p.addDimensionChain(levelId: l, points: [P2(0, 0), P2(1000, 0)]) }
        #expect(p.dimensions.isEmpty && p == locked)
    }

    @Test @MainActor func chainIsOneUndoStep() throws {
        let store = DocumentStore(project: Project.empty(name: "U"))
        let l = store.project.levels[0].id
        var ids: [UUID] = []
        try store.run("Add Dimension Chain") { p in
            ids = try p.addDimensionChain(levelId: l, points: [P2(0, 0), P2(1000, 0), P2(2500, 0), P2(5000, 0)])
        }
        #expect(ids.count == 4 && store.project.dimensions.count == 4)
        #expect(store.undoDepth == 1)
        try store.undo()
        #expect(store.project.dimensions.isEmpty && store.undoDepth == 0)
        try store.redo()
        #expect(store.project.dimensions.count == 4)
    }

    // MARK: Agent tool

    @MainActor
    private struct ToolRig {
        let store: DocumentStore
        let env: ToolEnv
        let handler: ToolSpec.WriteHandler
        let spec: ToolSpec
        let registry: ToolRegistry

        init(project: Project) {
            store = DocumentStore(project: project)
            store.agentWriteEnabled = true
            let ctx = ChainContext(activeLevelId: project.levels[0].id)
            registry = ToolRegistry(store: store, context: ctx)
            env = ToolEnv(store: store, context: ctx, clientId: "test", registry: registry)
            spec = DimensionTools.specs()[0]
            guard case .write(let h) = spec.handler else { fatalError("write tool expected") }
            handler = h
        }

        func call(_ json: JSONValue, dryRun: Bool = false) throws -> JSONValue {
            let args = try registry.prepareArgs(spec, json, extraKeys: ToolSpec.commonKeys)
            var out: JSONValue = .null
            try store.run("Agent: dimension chain", options: CommandOptions(origin: .agent("test"), dryRun: dryRun)) { p in
                out = try handler(&p, env, args)
            }
            return out
        }
    }

    private func wallProject() -> (Project, UUID) {
        var f = Fixture()
        f.open(.door, centre: 1450, width: 900)
        f.open(.window, centre: 3600, width: 1200)
        return (f.p, f.wall)
    }

    @Test @MainActor func toolSpecIsNamedAndRegistered() {
        let specs = DimensionTools.specs()
        #expect(specs.map(\.name) == ["geometry.dimension_chain"])
        #expect(specs[0].isWrite)
        let store = DocumentStore(project: Project.empty(name: "R"))
        let registry = ToolRegistry(store: store, context: ChainContext(activeLevelId: store.project.levels[0].id))
        #expect(registry.spec("geometry.dimension_chain") != nil)
    }

    @Test @MainActor func toolDimensionsAWallWithExactNumbers() throws {
        let (p, wall) = wallProject()
        let rig = ToolRig(project: p)
        let r = try rig.call(["wallId": .string(wall.uuidString.lowercased()), "side": "left"])
        #expect(r["partsMm"]?.arrayValue?.compactMap(\.int64Value) == [1000, 900, 1100, 1200, 800])
        #expect(r["sumOfPartsMm"]?.int64Value == 5000)
        #expect(r["totalLengthMm"]?.int64Value == 5000)
        #expect(r["side"]?.stringValue == "left")
        #expect(r["ids"]?.arrayValue?.count == 6)
        let dims = r["dimensions"]?.arrayValue ?? []
        #expect(dims.count == 6)
        #expect(dims.compactMap { $0["lengthMm"]?.int64Value } == [1000, 900, 1100, 1200, 800, 5000])
        #expect(dims.compactMap { $0["offsetMm"]?.int64Value } == [500, 500, 500, 500, 500, 900])
        #expect(r["totalId"]?.stringValue == dims[5]["id"]?.stringValue)
        #expect(rig.store.project.dimensions.count == 6)
        #expect(rig.store.undoDepth == 1)
        try rig.store.undo()
        #expect(rig.store.project.dimensions.isEmpty)
    }

    @Test @MainActor func toolWithPointsAndRightOffset() throws {
        let rig = ToolRig(project: Project.empty(name: "T"))
        let r = try rig.call(["points": [["x": 0, "y": 0], ["x": 1200, "y": 0], ["x": 3000, "y": 0]], "offsetMm": -300, "includeTotal": false])
        #expect(r["partsMm"]?.arrayValue?.compactMap(\.int64Value) == [1200, 1800])
        #expect(r["totalId"]?.isNull == true)
        #expect(r["dimensions"]?.arrayValue?.compactMap { $0["offsetMm"]?.int64Value } == [-300, -300])
        #expect(rig.store.project.dimensions.count == 2)
    }

    @Test @MainActor func toolDryRunChangesNothing() throws {
        let (p, wall) = wallProject()
        let rig = ToolRig(project: p)
        let r = try rig.call(["wallId": .string(wall.uuidString.lowercased())], dryRun: true)
        #expect(r["partsMm"]?.arrayValue?.count == 5)
        #expect(rig.store.project.dimensions.isEmpty && rig.store.undoDepth == 0)
    }

    @Test @MainActor func toolRejectsBadInput() throws {
        let (p, wall) = wallProject()
        let rig = ToolRig(project: p)
        let w = JSONValue.string(wall.uuidString.lowercased())
        let pts: JSONValue = [["x": 0, "y": 0], ["x": 1000, "y": 0]]
        #expect(throws: (any Error).self) { try rig.call([:]) }
        #expect(throws: (any Error).self) { try rig.call(["wallId": w, "points": pts]) }
        #expect(throws: (any Error).self) { try rig.call(["wallId": .string(UUID().uuidString.lowercased())]) }
        #expect(throws: (any Error).self) { try rig.call(["wallId": w, "side": "outer"]) }
        #expect(throws: (any Error).self) { try rig.call(["wallId": w, "offsetMm": -5]) }
        #expect(throws: (any Error).self) { try rig.call(["wallId": w, "levelId": .string(UUID().uuidString.lowercased())]) }
        #expect(throws: (any Error).self) { try rig.call(["points": [["x": 0, "y": 0]]]) }
        #expect(throws: (any Error).self) { try rig.call(["points": [["x": 0, "y": 0], ["x": 0, "y": 0]]]) }
        #expect(throws: (any Error).self) { try rig.call(["points": pts, "side": "left"]) }
        #expect(throws: (any Error).self) { try rig.call(["points": pts, "bogus": 1]) }
        #expect(rig.store.project.dimensions.isEmpty && rig.store.undoDepth == 0)
    }
}
