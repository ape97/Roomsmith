import Foundation
import Testing
@testable import RoomsmithCore

// Agent input must never trap the app: every length, coordinate, delta and offset is checked at the API boundary.

@MainActor
private final class LimitContext: AgentAppContext {
    var selection: Set<UUID> = []
    var activeLevelId: UUID
    var fileURL: URL?
    var appVersion = "test"
    init(activeLevelId: UUID) { self.activeLevelId = activeLevelId }
    func saveForAgent() throws -> String { "/tmp/test.roomsmith" }
}

@MainActor
private struct LimitRig {
    let store: DocumentStore
    let registry: ToolRegistry

    init() {
        let project = Project.empty(name: "Limits")
        store = DocumentStore(project: project)
        store.agentWriteEnabled = true
        registry = ToolRegistry(store: store, context: LimitContext(activeLevelId: project.levels[0].id))
    }

    func call(_ tool: String, _ args: JSONValue = .object([:])) async -> AgentResponse {
        await registry.call(AgentRequest(id: 1, token: "t", clientId: "test", tool: tool, arguments: args))
    }
    func ok(_ tool: String, _ args: JSONValue = .object([:])) async -> JSONValue {
        let r = await call(tool, args)
        #expect(r.ok, "\(tool) failed: \(r.error?.code ?? "?") \(r.error?.message ?? "")")
        return r.result ?? .null
    }
    func code(_ tool: String, _ args: JSONValue) async -> String? {
        let r = await call(tool, args)
        return r.ok ? nil : r.error?.code
    }
}

private func xy(_ x: Int64, _ y: Int64) -> JSONValue { ["x": .int(x), "y": .int(y)] }
private func xyz(_ x: Int64, _ y: Int64, _ z: Int64 = 0) -> JSONValue { ["x": .int(x), "y": .int(y), "z": .int(z)] }

@MainActor
struct AgentLimitTests {
    static let out = AgentError.outOfRange

    @Test func createWallRejectsExtremeCoordinates() async {
        let rig = LimitRig()
        for v in [Int64.min, Int64.max, coordinateLimit + 1, -coordinateLimit - 1] {
            #expect(await rig.code("geometry.create_wall", ["start": xy(v, 0), "end": xy(1000, 0)]) == Self.out)
            #expect(await rig.code("geometry.create_wall", ["start": xy(0, 0), "end": xy(0, v)]) == Self.out)
        }
        #expect(rig.store.project.walls.isEmpty)
        // The documented limit itself is still accepted as a coordinate.
        #expect(await rig.code("geometry.create_wall", ["start": xy(0, 0), "end": xy(coordinateLimit, 0)]) != Self.out)
    }

    @Test func moveObjectsRejectsExtremeDelta() async {
        let rig = LimitRig()
        let wall = await rig.ok("geometry.create_wall", ["start": xy(0, 0), "end": xy(4000, 0)])["id"]?.stringValue ?? ""
        let before = rig.store.project
        for v in [Int64.max, Int64.min] {
            #expect(await rig.code("scene.move_objects", ["ids": [.string(wall)], "delta": xyz(v, 0)]) == Self.out)
            #expect(await rig.code("scene.move_objects", ["ids": [.string(wall)], "to": xy(0, v)]) == Self.out)
        }
        // Two in-limit values whose sum leaves the range: structured error, no trap.
        let big = coordinateLimit
        let r = await rig.call("scene.move_objects", ["ids": [.string(wall)], "delta": xyz(big, big)])
        #expect(!r.ok)
        #expect(rig.store.project.revision == before.revision)
    }

    @Test func rotateObjectsRejectsExtremePivot() async {
        let rig = LimitRig()
        let wall = await rig.ok("geometry.create_wall", ["start": xy(0, 0), "end": xy(4000, 0)])["id"]?.stringValue ?? ""
        #expect(await rig.code("scene.rotate_objects", ["ids": [.string(wall)], "degrees": 180, "pivot": xy(9_000_000_000_000_000_000, 0)]) == Self.out)
        #expect(await rig.code("scene.rotate_objects", ["ids": [.string(wall)], "degrees": 180, "pivot": xy(Int64.min, 0)]) == Self.out)
        // In range pivot, but the rotated wall would leave the allowed range: rejected, never trapped.
        #expect(await rig.code("scene.rotate_objects", ["ids": [.string(wall)], "degrees": 45, "pivot": xy(coordinateLimit, coordinateLimit)]) == Self.out)
    }

    @Test func cameraRejectsExtremeTarget() async {
        let rig = LimitRig()
        #expect(await rig.code("camera.set_state", ["target": xyz(Int64.min, 0)]) == Self.out)
        #expect(await rig.code("camera.set_state", ["target": xyz(0, 0, Int64.max)]) == Self.out)
        #expect(await rig.code("camera.set_state", ["distanceMm": .int(Int64.max)]) == Self.out)
    }

    @Test func levelDimensionAndOpeningRejectExtremeLengths() async {
        let rig = LimitRig()
        #expect(await rig.code("geometry.create_level", ["name": "L", "elevationMm": .int(Int64.min)]) == Self.out)
        #expect(await rig.code("geometry.create_level", ["name": "L", "heightMm": .int(Int64.max)]) == Self.out)
        #expect(await rig.code("geometry.create_dimension", ["a": xy(0, 0), "b": xy(1000, 0), "offsetMm": .int(Int64.min)]) == Self.out)
        let wall = await rig.ok("geometry.create_wall", ["start": xy(0, 0), "end": xy(4000, 0)])["id"]?.stringValue ?? ""
        #expect(await rig.code("geometry.create_wall", ["start": xy(0, 0), "end": xy(1000, 0), "thicknessMm": .int(Int64.max)]) == Self.out)
        #expect(await rig.code("geometry.add_opening", ["wallId": .string(wall), "type": "door", "offsetMm": .int(Int64.min)]) == Self.out)
        #expect(await rig.code("geometry.add_opening", ["wallId": .string(wall), "type": "door", "widthMm": .int(Int64.max)]) == Self.out)
        #expect(rig.store.project.levels.count == 1 && rig.store.project.dimensions.isEmpty && rig.store.project.openings.isEmpty)
    }

    @Test func measureDistanceRejectsExtremePoints() async {
        let rig = LimitRig()
        #expect(await rig.code("geometry.measure_distance", ["from": xy(Int64.max, 0), "to": xy(Int64.min, 0)]) == Self.out)
        #expect(await rig.code("geometry.measure_distance", ["from": xy(0, 0), "to": xy(0, Int64.min)]) == Self.out)
    }

    @Test func nonIntegerMillimetresAreInvalidNotRounded() async {
        let rig = LimitRig()
        #expect(await rig.code("geometry.create_wall", ["start": xy(0, 0), "end": ["x": .number(1000.5), "y": .int(0)]]) == AgentError.invalidArgument)
        #expect(await rig.code("geometry.create_level", ["name": "L", "elevationMm": .number(1.5)]) == AgentError.invalidArgument)
    }

    @Test func listCursorIsBounded() async {
        let rig = LimitRig()
        #expect(await rig.code("scene.list_objects", ["cursor": "9223372036854775807"]) == AgentError.invalidArgument)
        #expect(await rig.code("scene.list_objects", ["cursor": "-1"]) == AgentError.invalidArgument)
        _ = await rig.ok("scene.list_objects", ["cursor": "5"])
    }

    @Test func batchStepRejectsDryRunAndExpectedRevision() async {
        let rig = LimitRig()
        let before = rig.store.project.revision
        for key in ["dryRun", "expectedRevision"] {
            let value: JSONValue = key == "dryRun" ? .bool(true) : .int(before)
            let r = await rig.call("app.batch", ["steps": [
                ["tool": "scene.create_object",
                 "arguments": ["kind": "wall", "start": xy(0, 0), "end": xy(3000, 0), .init(key): value]],
            ]])
            #expect(!r.ok)
            #expect(r.error?.code == AgentError.invalidArgument, "\(key)")
        }
        #expect(rig.store.project.walls.isEmpty)
        // Without the shared keys the same step works.
        _ = await rig.ok("app.batch", ["steps": [
            ["tool": "scene.create_object", "arguments": ["kind": "wall", "start": xy(0, 0), "end": xy(3000, 0)]],
        ]])
        #expect(rig.store.project.walls.count == 1)
        // The other tools already rejected the keys.
        let r = await rig.call("app.batch", ["steps": [
            ["tool": "geometry.create_wall", "arguments": ["start": xy(0, 500), "end": xy(3000, 500), "dryRun": true]],
        ]])
        #expect(r.error?.code == AgentError.invalidArgument)
    }

    @Test func batchHasStepLimit() async {
        let rig = LimitRig()
        func steps(_ n: Int) -> JSONValue {
            .array((0..<n).map { i in
                ["tool": "geometry.create_wall", "arguments": ["start": xy(0, Int64(i) * 100), "end": xy(1000, Int64(i) * 100)]]
            })
        }
        let tooMany = await rig.call("app.batch", ["steps": steps(101)])
        #expect(tooMany.error?.code == AgentError.invalidArgument)
        #expect(rig.store.project.walls.isEmpty)
        _ = await rig.ok("app.batch", ["steps": steps(100)])
        #expect(rig.store.project.walls.count == 100)
    }

    @Test func multiStepUndoIsAtomic() async {
        let rig = LimitRig()
        for i in 0..<2 {
            _ = await rig.ok("geometry.create_wall", ["start": xy(0, Int64(i) * 1000), "end": xy(3000, Int64(i) * 1000)])
        }
        let undoable = rig.store.undoDepth
        #expect(undoable >= 2)
        let before = rig.store.project
        let r = await rig.call("history.undo", ["steps": .int(Int64(undoable + 1))])
        #expect(r.error?.code == AgentError.invalidArgument)
        #expect(rig.store.project.walls.count == before.walls.count)
        #expect(rig.store.undoDepth == undoable)
        let redo = await rig.call("history.redo", ["steps": 2])
        #expect(redo.error?.code == AgentError.invalidArgument)
        // Exactly the available count works.
        let done = await rig.ok("history.undo", ["steps": .int(Int64(undoable))])
        #expect(done["performed"]?.int64Value == Int64(undoable))
    }

    @Test func multiStepUndoRefusedWhileUserEdits() async {
        let rig = LimitRig()
        let wall = await rig.ok("geometry.create_wall", ["start": xy(0, 0), "end": xy(3000, 0)])["id"]?.stringValue ?? ""
        _ = await rig.ok("geometry.create_wall", ["start": xy(0, 1000), "end": xy(3000, 1000)])
        rig.store.beginInteraction([UUID(uuidString: wall)!], reason: "drag")
        let r = await rig.call("history.undo", ["steps": 2])
        #expect(r.error?.code == AgentError.busy)
        #expect(rig.store.project.walls.count == 2)
    }

    @Test func auditSummaryRedactsSecrets() {
        let s = AuditLog.summary(of: ["token": "abc123", "nested": ["Password": "pw", "x": 1]])
        #expect(!s.contains("abc123") && !s.contains("\"pw\""))
        #expect(s.contains("<redacted>"))
    }

    @Test func outputConversionNeverCapsAndNeverFakesZero() {
        #expect(J.mm(.infinity) == .null)
        #expect(J.mm(.nan) == .null)
        #expect(J.mm(1e300) == .null)
        #expect(J.mm(-1e300) == .null)
        #expect(J.mm(2e8) == .int(200_000_000))
        #expect(J.mm(-282_842_712.4) == .int(-282_842_712))
        #expect(J.mm(0.5) == .int(1))
        #expect(P2(Int64.min, Int64.max).isInRange == false)
        #expect(P3(Int64.min, 0, 0).isInRange == false)
    }

    @Test func computedLengthsAreReportedUncapped() async {
        let rig = LimitRig()
        let limit = coordinateLimit
        let w1 = await rig.ok("geometry.create_wall", ["start": xy(-limit, 0), "end": xy(limit, 0)])["id"]?.stringValue ?? ""
        let w2 = await rig.ok("geometry.create_wall", ["start": xy(-limit, -limit), "end": xy(limit, limit)])["id"]?.stringValue ?? ""
        let walls = await rig.ok("scene.get_object", ["id": .string(w1)])
        #expect(walls.jsonString().contains("200000000"), "\(walls.jsonString())")
        let diag = await rig.ok("scene.get_object", ["id": .string(w2)])
        #expect(diag.jsonString().contains("282842712"), "\(diag.jsonString())")
        let m = await rig.ok("geometry.measure_distance", ["from": xy(-limit, -limit), "to": xy(limit, limit)])
        #expect(m["distanceMm"] == .int(282_842_712))
        #expect(m["exactMm"]?.doubleValue.map { Int64($0.rounded()) } == 282_842_712)
        let m2 = await rig.ok("geometry.measure_distance", ["from": xy(-limit, 0), "to": xy(limit, 0)])
        #expect(m2["distanceMm"] == .int(200_000_000))
        #expect(m2["exactMm"]?.doubleValue == 200_000_000)
    }
}
