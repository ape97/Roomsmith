import Foundation
import Testing
@testable import RoomsmithCore

// Open/close state machine, collision of turned balcony doors, the default handle and the walk tool for windows.

private func sig(_ kind: OpeningKind = .window, movable: Bool = true, style: OpeningStyle = .tiltTurn1, width: MM = 1000) -> OpeningSignature {
    var w = Wall(levelId: UUID(), start: P2(0, 0), end: P2(4000, 0))
    w.thickness = 100
    var o = Opening(wallId: w.id, kind: kind, offset: 2000, width: width, height: 1200, sill: 900)
    o.style = style
    var s = OpeningSignature(o, wall: w)!
    s.movable = movable
    return s
}

struct OpeningMotionTests {
    @Test func startsClosed() {
        let m = OpeningMotion()
        let id = UUID()
        #expect(m.target(id) == .closed && m.pose(id).progress == 0 && m.isEmpty && m.turnedIds.isEmpty)
    }

    @Test func turnAnimatesToOpenAndTogglesBack() {
        var m = OpeningMotion(); let id = UUID(); let s = sig()
        #expect(m.request(id, mode: .turn, signature: s) == .turn)
        m.advance(dt: 0.25, seconds: 1)
        #expect(abs(m.pose(id).progress - 0.25) < 1e-9)
        m.advance(dt: 5, seconds: 1)
        #expect(m.pose(id).progress == 1 && m.turnedIds == [id])
        #expect(m.request(id, mode: .turn, signature: s) == .closed, "same mode again closes")
        #expect(m.turnedIds.isEmpty, "closing no longer counts as turned open")
        m.advance(dt: 5, seconds: 1)
        #expect(m.isEmpty)
    }

    @Test func otherModeClosesFirstThenOpens() {
        var m = OpeningMotion(); let id = UUID(); let s = sig()
        m.setPose(id, mode: .turn, progress: 1, signature: s)
        #expect(m.request(id, mode: .tilt, signature: s) == .tilt)
        #expect(m.pose(id).mode == .turn, "still showing the turned pose")
        m.advance(dt: 0.5, seconds: 1)
        #expect(m.pose(id) == (.turn, 0.5))
        m.advance(dt: 0.5, seconds: 1)
        #expect(m.pose(id).mode == .tilt && m.pose(id).progress == 0)
        m.advance(dt: 1, seconds: 1)
        #expect(m.pose(id) == (.tilt, 1) && m.turnedIds.isEmpty, "tilted stays solid")
    }

    @Test func explicitOpenAndCloseAreIdempotent() {
        var m = OpeningMotion(); let id = UUID(); let s = sig()
        #expect(m.request(id, mode: .turn, open: false, signature: s) == .closed && m.isEmpty)
        #expect(m.request(id, mode: .turn, open: true, signature: s) == .turn)
        #expect(m.request(id, mode: .turn, open: true, signature: s) == .turn)
        #expect(m.request(id, mode: .turn, open: false, signature: s) == .closed)
        #expect(m.request(id, mode: .turn, open: false, signature: s) == .closed)
    }

    @Test func closingCanBeReversed() {
        var m = OpeningMotion(); let id = UUID(); let s = sig()
        m.setPose(id, mode: .turn, progress: 1, signature: s)
        _ = m.request(id, mode: .turn, open: false, signature: s)
        m.advance(dt: 0.4, seconds: 1)
        #expect(m.request(id, mode: .turn, open: true, signature: s) == .turn)
        m.advance(dt: 0.1, seconds: 1)
        #expect(abs(m.pose(id).progress - 0.7) < 1e-9)
    }

    @Test func doorsOnlyTurnAndFixedOnesIgnoreRequests() {
        var m = OpeningMotion(); let id = UUID()
        #expect(m.request(id, mode: .tilt, signature: sig(.door, style: .smooth)) == .closed && m.isEmpty)
        #expect(m.request(id, mode: .turn, signature: sig(.door, style: .smooth)) == .turn)
        var n = OpeningMotion()
        #expect(n.request(id, mode: .turn, signature: sig(movable: false)) == .closed && n.isEmpty)
        #expect(n.request(id, mode: .closed, signature: sig()) == .closed && n.isEmpty)
    }

    @Test func openListIsSortedAndSkipsClosing() {
        var m = OpeningMotion()
        let a = UUID(), b = UUID(), c = UUID(); let s = sig()
        m.setPose(a, mode: .turn, progress: 1, signature: s)
        m.setPose(b, mode: .tilt, progress: 0.5, signature: s)
        m.setPose(c, mode: .turn, progress: 1, signature: s)
        _ = m.request(c, mode: .turn, open: false, signature: s)
        #expect(m.openList.map(\.id) == [a, b].sorted { $0.uuidString < $1.uuidString })
        #expect(m.openList.first { $0.id == b }?.mode == .tilt)
    }

    @Test func pruneDropsChangedGoneAndImmovable() {
        var m = OpeningMotion()
        let keep = UUID(), changed = UUID(), gone = UUID(), fixed = UUID()
        let s = sig()
        for id in [keep, changed, gone, fixed] { m.setPose(id, mode: .turn, progress: 1, signature: s) }
        m.prune(current: [keep: s, changed: sig(width: 1100), fixed: sig(movable: false)])
        #expect(Set(m.entries.keys) == [keep])
    }

    @Test func signatureReflectsEverythingThatChangesThePose() {
        var w = Wall(levelId: UUID(), start: P2(0, 0), end: P2(4000, 0))
        var o = Opening(wallId: w.id, kind: .window, offset: 2000, width: 1000, height: 1200, sill: 900)
        o.style = .tiltTurn1
        let base = OpeningSignature(o, wall: w)!
        #expect(base.movable && base.sashCount == 1)
        func differs(_ edit: (inout Opening) -> Void) -> Bool { var c = o; edit(&c); return OpeningSignature(c, wall: w) != base }
        #expect(differs { $0.flipped.toggle() } && differs { $0.inward.toggle() } && differs { $0.width = 1100 })
        #expect(differs { $0.height = 1300 } && differs { $0.sill = 800 } && differs { $0.style = .tiltTurn2 })
        #expect(differs { $0.frameWidth = 80 })
        #expect(!differs { $0.offset = 1500 }, "sliding along the wall keeps the pose")
        w.thickness = 200
        #expect(OpeningSignature(o, wall: w) != base, "wall thickness changes the sash depth")
        #expect(OpeningSignature(o, wall: nil) == nil)
        o.kind = .opening
        #expect(OpeningSignature(o, wall: w) == nil)
    }

    @Test func mapCoversEveryOpening() {
        var p = Project.empty(name: "M")
        let wall = try! p.addWall(levelId: p.levels[0].id, start: P2(0, 0), end: P2(6000, 0))
        let d = try! p.addOpening(wallId: wall, kind: .door, offset: 1000, width: 900, height: 2100)
        let f = try! p.addOpening(wallId: wall, kind: .window, offset: 3000, width: 1200, height: 1200, style: .fixed)
        let t = try! p.addOpening(wallId: wall, kind: .window, offset: 5000, width: 1200, height: 1200, style: .tiltTurn1)
        let map = OpeningSignature.map(p)
        #expect(map[d]?.movable == true && map[f]?.movable == false && map[t]?.movable == true)
    }
}

// MARK: - Collision

private func collisionProject(style: OpeningStyle, width: MM, sill: MM, height: MM = 2100, inward: Bool = true) -> (Project, UUID, UUID) {
    var p = Project.empty(name: "C")
    let lvl = p.levels[0].id
    let wall = try! p.addWall(levelId: lvl, start: P2(0, 0), end: P2(6000, 0))
    let id = try! p.addOpening(wallId: wall, kind: .window, offset: 3000, width: width, height: height, sill: sill, style: style)
    try! p.updateOpening(id, inward: inward)
    return (p, lvl, id)
}

/// Walks from y = -1500 to +1500 along x and returns the final y; 1500 means the body got through.
private func walkThrough(_ c: WalkCollider, x: Double) -> Double {
    var pos = V2(x, -1500)
    for _ in 0..<60 { pos = c.move(from: pos, to: V2(x, min(pos.y + 50, 1500))) }
    return pos.y
}

struct BalconyCollisionTests {
    private func collider(_ p: Project, _ lvl: UUID, open: Set<UUID>) -> WalkCollider {
        WalkCollider(project: p, levelId: lvl, eyeHeightMm: 1638, bodyRadiusMm: 220, openDoors: open)
    }

    @Test func lowBalconyDoorIsPassableOnlyWhenTurnedOpen() {
        for (style, width) in [(OpeningStyle.balconyDoor, MM(1000)), (.balconyDoor2, 1800)] {
            for sill: MM in [0, 100] {
                let (p, lvl, id) = collisionProject(style: style, width: width, sill: sill)
                #expect(walkThrough(collider(p, lvl, open: []), x: 3000) < 0, "\(style) closed blocks")
                #expect(walkThrough(collider(p, lvl, open: [id]), x: 3000) > 1400, "\(style) sill \(sill) open lets through")
            }
        }
    }

    @Test func highSillStaysAWall() {
        for sill: MM in [101, 900] {
            let (p, lvl, id) = collisionProject(style: .balconyDoor, width: 1000, sill: sill, height: 1200)
            #expect(walkThrough(collider(p, lvl, open: [id]), x: 3000) < 0, "sill \(sill)")
        }
    }

    @Test func openSashBlocksTheSwingSideEdge() {
        // One sash hinged at the left edge, swung into the room: the leaf is a bar from the hinge, the right part is free.
        let (p, lvl, id) = collisionProject(style: .balconyDoor, width: 1000, sill: 0)
        let c = collider(p, lvl, open: [id])
        let hinge = Meshes.windowSashes(p.opening(id)!, wall: p.walls[0], baseZ: 0)[0].placement.pivot
        #expect(walkThrough(c, x: hinge.x) < 1400, "the leaf stands where the hinge side is")
        #expect(walkThrough(c, x: 3050) > 1400, "the middle of the opening is free")
    }

    @Test func tiltedStaysSolidBecauseOnlyTurnedIdsOpenTheCollider() {
        var m = OpeningMotion()
        let (p, lvl, id) = collisionProject(style: .balconyDoor, width: 1000, sill: 0)
        let s = OpeningSignature(p.opening(id)!, wall: p.walls[0])!
        m.setPose(id, mode: .tilt, progress: 1, signature: s)
        #expect(walkThrough(collider(p, lvl, open: m.turnedIds), x: 3000) < 0)
        m.setPose(id, mode: .turn, progress: 1, signature: s)
        #expect(walkThrough(collider(p, lvl, open: m.turnedIds), x: 3000) > 1400)
    }

    @Test func ordinaryWindowNeverOpensTheCollider() {
        let (p, lvl, id) = collisionProject(style: .tiltTurn1, width: 1000, sill: 0, height: 1200)
        #expect(walkThrough(collider(p, lvl, open: [id]), x: 3000) < 0, "a window is not a door even at sill 0")
    }
}

// MARK: - Default handle and persistence

struct OpenableDetailTests {
    private func base() -> (Project, UUID) {
        var p = Project.empty(name: "H")
        let wall = try! p.addWall(levelId: p.levels[0].id, start: P2(0, 0), end: P2(6000, 0))
        return (p, wall)
    }

    @Test func movableStyleGetsALeverUnlessTheCallerChoses() throws {
        var (p, wall) = base()
        let a = try p.addOpening(wallId: wall, kind: .window, offset: 1000, width: 1000, height: 1200, style: .tiltTurn1)
        #expect(p.opening(a)?.handle == .lever)
        let b = try p.addOpening(wallId: wall, kind: .window, offset: 2500, width: 1000, height: 1200, style: .tiltTurn1, handle: OpeningHandle.none)
        #expect(p.opening(b)?.handle == OpeningHandle.none, "explicit none stays")
        let c = try p.addOpening(wallId: wall, kind: .window, offset: 4000, width: 150, height: 1200, style: .tiltTurn1)
        #expect(p.opening(c)?.handle == OpeningHandle.none, "too small to open, nothing to grip")
        let d = try p.addOpening(wallId: wall, kind: .window, offset: 5000, width: 800, height: 1200, style: .fixed)
        #expect(p.opening(d)?.handle == OpeningHandle.none)
    }

    @Test func changingTheStyleAddsTheLeverOnce() throws {
        var (p, wall) = base()
        let a = try p.addOpening(wallId: wall, kind: .window, offset: 3000, width: 1000, height: 1200)
        #expect(p.opening(a)?.handle == OpeningHandle.none)
        try p.updateOpening(a, style: .balconyDoor2)
        #expect(p.opening(a)?.handle == .lever)
        try p.updateOpening(a, handle: .knob)
        try p.updateOpening(a, style: .tiltTurn2)
        #expect(p.opening(a)?.handle == .knob, "an existing handle is kept")
        try p.updateOpening(a, handle: OpeningHandle.none)
        try p.updateOpening(a, offset: 3100)
        #expect(p.opening(a)?.handle == OpeningHandle.none, "only a style change adds the lever")
    }

    @Test func twoSashBalconyDoorSurvivesSaveAndLoad() throws {
        var (p, wall) = base()
        let a = try p.addOpening(wallId: wall, kind: .window, offset: 3000, width: 1800, height: 2100, sill: 0, style: .balconyDoor2)
        let (back, warnings) = try RoomsmithMarkdown.decode(RoomsmithMarkdown.encode(p))
        #expect(warnings.isEmpty, "\(warnings)")
        #expect(back == p && back.opening(a)?.style == .balconyDoor2 && back.opening(a)?.handle == .lever)
    }

    @Test func balconyStyleOnADoorFallsBackToTheDefaultLook() throws {
        var (p, wall) = base()
        let d = try p.addOpening(wallId: wall, kind: .door, offset: 3000, width: 900, height: 2100, style: .panel2)
        let text = RoomsmithMarkdown.encode(p)
        #expect(text.contains("panel2"))
        let (back, _) = try RoomsmithMarkdown.decode(text.replacingOccurrences(of: "panel2", with: "balconyDoor2"))
        #expect(back.opening(d)?.style == OpeningStyle.defaultStyle(for: .door))
    }

    @Test func styleListsStaySeparate() {
        #expect(OpeningStyle.styles(for: .window).contains(.balconyDoor2))
        #expect(!OpeningStyle.styles(for: .door).contains(.balconyDoor2))
        #expect(OpeningStyle.windowStyles.contains(.balconyDoor2))
    }
}

// MARK: - walk.toggle_door for windows

@MainActor
final class OpenBridge: AgentWalkBridge {
    var settings = WalkSettings()
    var motion = OpeningMotion()
    var project: Project
    init(_ p: Project) { project = p }
    func walkState() -> AgentWalkState {
        AgentWalkState(settings: settings, active: true, eyeHeightMm: 1638, speedMps: 0, fovDeg: 60, autoScreenHeightMm: nil, openDoors: [],
                       openOpenings: motion.openList.map { .init(id: $0.id, mode: $0.mode) })
    }
    func applyWalkSettings(_ s: WalkSettings) -> AgentWalkState { settings = s; return walkState() }
    func setDoor(_ id: UUID, open: Bool?) throws -> Bool { try setOpening(id, open: open, mode: .turn) != .closed }
    func setOpening(_ id: UUID, open: Bool?, mode: OpeningMode) throws -> OpeningMode {
        let o = project.opening(id)!
        return motion.request(id, mode: mode, open: open, signature: OpeningSignature(o, wall: project.wall(o.wallId))!)
    }
}

@MainActor
final class OpenContext: AgentAppContext {
    var selection: Set<UUID> = []
    var activeLevelId: UUID
    var fileURL: URL?
    var appVersion = "test"
    fileprivate let bridge: OpenBridge
    var viewBridge: AgentViewBridge? { nil }
    var walkBridge: AgentWalkBridge? { bridge }
    init(level: UUID, bridge: OpenBridge) { activeLevelId = level; self.bridge = bridge }
    func saveForAgent() throws -> String { "/tmp/test.roomsmith" }
}

@MainActor
struct WindowOpeningToolTests {
    let store: DocumentStore
    let registry: ToolRegistry
    fileprivate let bridge: OpenBridge
    let door, tilt, two, fixed, tiny, plain: UUID

    init() throws {
        var p = Project.empty(name: "T")
        let wall = try p.addWall(levelId: p.levels[0].id, start: P2(0, 0), end: P2(9000, 0))
        door = try p.addOpening(wallId: wall, kind: .door, offset: 500, width: 800, height: 2100)
        tilt = try p.addOpening(wallId: wall, kind: .window, offset: 2000, width: 1000, height: 1200, style: .tiltTurn1)
        two = try p.addOpening(wallId: wall, kind: .window, offset: 3500, width: 1800, height: 1200, style: .tiltTurn2)
        fixed = try p.addOpening(wallId: wall, kind: .window, offset: 5000, width: 1000, height: 1200, style: .fixed)
        tiny = try p.addOpening(wallId: wall, kind: .window, offset: 6000, width: 220, height: 1200, style: .tiltTurn1)
        plain = try p.addOpening(wallId: wall, kind: .opening, offset: 7000, width: 800, height: 2000)
        store = DocumentStore(project: p)
        store.agentWriteEnabled = true
        bridge = OpenBridge(p)
        registry = ToolRegistry(store: store, context: OpenContext(level: p.levels[0].id, bridge: bridge))
    }

    private func call(_ tool: String, _ args: JSONValue) async -> AgentResponse {
        await registry.call(AgentRequest(id: 1, token: "t", clientId: "test", tool: tool, arguments: args))
    }
    private func toggle(_ id: UUID, _ extra: [String: JSONValue] = [:]) async -> AgentResponse {
        var a = extra; a["openingId"] = .string(id.uuidString)
        return await call("walk.toggle_door", .object(a))
    }

    @Test func windowsTurnAndTiltAndReportTheirMode() async {
        let r1 = await toggle(tilt)
        #expect(r1.ok && r1.result?["mode"]?.stringValue == "turn" && r1.result?["open"]?.boolValue == true)
        let r2 = await toggle(tilt, ["mode": "tilt"])
        #expect(r2.result?["mode"]?.stringValue == "tilt" && r2.result?["open"]?.boolValue == true, "other mode: heads for tilt")
        let r3 = await toggle(tilt, ["mode": "tilt"])
        #expect(r3.result?["open"]?.boolValue == false && r3.result?["mode"]?.stringValue == "closed")
        let r4 = await toggle(two, ["open": true])
        #expect(r4.result?["mode"]?.stringValue == "turn")
    }

    @Test func getListsOpenOpenings() async {
        _ = await toggle(tilt, ["mode": "tilt"])
        _ = await toggle(door)
        let g = await call("walk.get", .object([:]))
        let list = g.result?["openOpenings"]?.arrayValue ?? []
        #expect(list.count == 2)
        #expect(list.contains { $0["id"]?.stringValue == tilt.uuidString && $0["mode"]?.stringValue == "tilt" })
        #expect(list.contains { $0["mode"]?.stringValue == "turn" })
    }

    @Test func refusesWhatCannotOpen() async {
        #expect((await toggle(fixed)).error?.code == "INVALID_ARGUMENT")
        #expect((await toggle(tiny)).error?.code == "INVALID_ARGUMENT")
        #expect((await toggle(plain)).error?.code == "INVALID_ARGUMENT")
        #expect((await toggle(door, ["mode": "tilt"])).error?.code == "INVALID_ARGUMENT", "doors only turn")
        #expect((await toggle(tilt, ["mode": "slide"])).error?.code == "INVALID_ARGUMENT")
        #expect((await toggle(tilt, ["mode": "closed"])).error?.code == "INVALID_ARGUMENT")
        #expect((await toggle(UUID())).error?.code == "NOT_FOUND")
        #expect(bridge.motion.isEmpty)
    }

    @Test func needsWriteAccess() async {
        store.agentWriteEnabled = false
        #expect((await toggle(tilt)).error?.code == AgentError.writeLocked)
    }
}
