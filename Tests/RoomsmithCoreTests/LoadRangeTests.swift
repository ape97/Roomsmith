import Foundation
import Testing
@testable import RoomsmithCore

// A hand-edited project.md must not carry huge values into the wrapping geometry arithmetic.
struct LoadRangeTests {
    private func load(_ project: Project) throws -> (project: Project, warnings: [String]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rs-range-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = dir.appendingPathComponent("R.roomsmith")
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try Data(RoomsmithMarkdown.encode(project).utf8).write(to: pkg.appendingPathComponent("project.md"))
        return try ProjectPackage.load(from: pkg)
    }

    @Test func hugeWallCoordinateIsRejectedWithFieldName() throws {
        var p = Project.empty()
        p.walls = [Wall(levelId: p.levels[0].id, start: P2(0, 0), end: P2(9_000_000_000_000_000_000, 0))]
        do { _ = try load(p); Issue.record("expected error") } catch let e as PersistenceError {
            #expect(e.message.contains("wall"))
            #expect(e.message.contains("end.x"), "\(e.message)")
            #expect(e.path?.hasSuffix("project.md") == true)
        }
    }

    @Test func limitValuesStillLoad() throws {
        var p = Project.empty()
        p.walls = [Wall(levelId: p.levels[0].id, start: P2(-coordinateLimit, 0), end: P2(coordinateLimit, 0))]
        let loaded = try load(p)
        #expect(loaded.project.walls.count == 1)
    }

    @Test func hugeLevelElevationIsRejected() throws {
        var p = Project.empty()
        p.levels[0].elevation = coordinateLimit + 1
        do { _ = try load(p); Issue.record("expected error") } catch let e as PersistenceError {
            #expect(e.message.contains("elevation"), "\(e.message)")
        }
    }

    @Test func hugeRevisionIsRejected() throws {
        var p = Project.empty()
        p.revision = 2_000_000_000_000_000
        do { _ = try load(p); Issue.record("expected error") } catch let e as PersistenceError {
            #expect(e.message.contains("revision"), "\(e.message)")
        }
    }

    @Test func hugeEntityRevIsRejected() throws {
        var p = Project.empty()
        p.levels[0].rev = 2_000_000_000_000_000
        do { _ = try load(p); Issue.record("expected error") } catch let e as PersistenceError {
            #expect(e.message.contains("level") && e.message.contains("'rev'"), "\(e.message)")
        }
    }

    @Test func hugeStatePoseIsRejected() throws {
        var p = Project.empty()
        let comp = Component(name: "c", shape: .box, position: P3(0, 0, 0), size: Size3(100, 100, 100))
        var def = FurnitureDefinition(name: "D", category: "-", size: Size3(100, 100, 100), components: [comp])
        def.states = [FurnitureState(name: "s", poses: [comp.id: ComponentPose(position: P3(0, 0, 5_000_000_000))])]
        p.definitions = [def]
        do { _ = try load(p); Issue.record("expected error") } catch let e as PersistenceError {
            #expect(e.message.contains("state") && e.message.contains("position.z"), "\(e.message)")
        }
    }

    @Test func hugeGroupConfigurationIsRejected() throws {
        var p = Project.empty()
        var g = FurnitureGroup(name: "G", levelId: p.levels[0].id, origin: P3(0, 0, 0), memberIds: [])
        g.configurations = [GroupConfiguration(name: "c", poses: [UUID(): MemberPose(local: P3(5_000_000_000, 0, 0), rotationDeg: 0)])]
        p.groups = [g]
        do { _ = try load(p); Issue.record("expected error") } catch let e as PersistenceError {
            #expect(e.message.contains("configuration") && e.message.contains("local.x"), "\(e.message)")
        }
    }

    @Test func negativeRevIsRejected() throws {
        var p = Project.empty()
        p.levels[0].rev = -1
        do { _ = try load(p); Issue.record("expected error") } catch let e as PersistenceError {
            #expect(e.message.contains("'rev'"), "\(e.message)")
        }
    }

    @Test func revLimitIsInclusive() throws {
        var p = Project.empty()
        p.levels[0].rev = 1_000_000_000_000_000
        #expect(try load(p).project.levels[0].rev == 1_000_000_000_000_000)
    }

    @Test func hugeWallAndCameraRevAreRejected() throws {
        var p = Project.empty()
        p.walls = [Wall(levelId: p.levels[0].id, start: P2(0, 0), end: P2(1000, 0))]
        p.walls[0].rev = 1_000_000_000_000_001
        do { _ = try load(p); Issue.record("expected error") } catch let e as PersistenceError {
            #expect(e.message.contains("wall") && e.message.contains("'rev'"), "\(e.message)")
        }
        var q = Project.empty()
        var cam = SavedCamera(name: "c", state: q.camera)
        cam.rev = 2_000_000_000_000_000
        q.cameras = [cam]
        do { _ = try load(q); Issue.record("expected error") } catch let e as PersistenceError {
            #expect(e.message.contains("camera") && e.message.contains("'rev'"), "\(e.message)")
        }
    }

    @Test func roundingNeverTraps() {
        #expect(P2(rounding: V2(.infinity, -.infinity)) == P2(4_000_000_000_000_000_000, -4_000_000_000_000_000_000))
        #expect(P2(rounding: V2(.nan, 1e300)).x == 4_000_000_000_000_000_000)
        #expect(P2(rounding: V2(2.5, -2.5)) == P2(3, -3))
        // Saturated values are rejected by the range check, and the 3x3 search cannot overflow.
        let far = P2(origin: P2(0, 0), direction: V2(1, 0), length: 1e300)
        #expect(!far.isInRange)
    }
}

struct AuthFailureThrottleTests {
    @Test func onePerSecondPerClientWithSuppressedCount() {
        var t = AuthFailureThrottle()
        let t0 = Date(timeIntervalSince1970: 1000)
        #expect(t.admit(clientId: "a", at: t0) == 0)
        #expect(t.admit(clientId: "a", at: t0.addingTimeInterval(0.2)) == nil)
        #expect(t.admit(clientId: "a", at: t0.addingTimeInterval(0.9)) == nil)
        #expect(t.admit(clientId: "b", at: t0.addingTimeInterval(0.9)) == 0)
        #expect(t.admit(clientId: "a", at: t0.addingTimeInterval(1.0)) == 2)
        #expect(t.admit(clientId: "a", at: t0.addingTimeInterval(2.1)) == 0)
    }

    @Test func clipsLongTextAndBoundsMemory() {
        #expect(AuthFailureThrottle.clip(String(repeating: "x", count: 500)).count == 100)
        var t = AuthFailureThrottle()
        var now = Date(timeIntervalSince1970: 5000)
        for i in 0..<1000 { _ = t.admit(clientId: "c\(i)", at: now) }
        // same long id with different tails beyond 100 chars is one client
        now = now.addingTimeInterval(5)
        let base = String(repeating: "y", count: 100)
        #expect(t.admit(clientId: base + "1", at: now) != nil)
        #expect(t.admit(clientId: base + "2", at: now) == nil)
    }

    @Test func changingClientIdsAreLimitedGlobally() {
        var t = AuthFailureThrottle()
        let t0 = Date(timeIntervalSince1970: 1000)
        var admitted = 0
        for i in 0..<1000 where t.admit(clientId: "id\(i)", at: t0) != nil { admitted += 1 }
        #expect(admitted <= 10)
        let s = t.admit(clientId: "later", at: t0.addingTimeInterval(1))
        #expect((s ?? 0) >= 990, "\(String(describing: s))")
    }

    @Test func globalBucketRefillsAtRate() {
        var t = AuthFailureThrottle()
        let t0 = Date(timeIntervalSince1970: 1000)
        for i in 0..<10 { #expect(t.admit(clientId: "d\(i)", at: t0) != nil) }
        #expect(t.admit(clientId: "x", at: t0) == nil)
        let t1 = t0.addingTimeInterval(0.5)  // 0.5 s * 10/s = 5 tokens
        var n = 0
        for i in 0..<20 where t.admit(clientId: "e\(i)", at: t1) != nil { n += 1 }
        #expect(n == 5)
    }

    @Test func globalBucketIsCappedAtBurst() {
        var t = AuthFailureThrottle()
        let t0 = Date(timeIntervalSince1970: 1000)
        _ = t.admit(clientId: "a", at: t0)
        let t1 = t0.addingTimeInterval(3600)
        var n = 0
        for i in 0..<50 where t.admit(clientId: "f\(i)", at: t1) != nil { n += 1 }
        #expect(n == 10)
    }

    @Test func clockGoingBackwardsGivesNoTokens() {
        var t = AuthFailureThrottle()
        let t0 = Date(timeIntervalSince1970: 1000)
        for i in 0..<10 { _ = t.admit(clientId: "g\(i)", at: t0) }
        let back = t0.addingTimeInterval(-100)
        for i in 0..<5 { #expect(t.admit(clientId: "h\(i)", at: back) == nil) }
    }

    @Test func evictedClientKeepsItsSuppressedCount() {
        var t = AuthFailureThrottle(interval: 1000, globalRate: 1000, globalBurst: 1000)
        let t0 = Date(timeIntervalSince1970: 1000)
        _ = t.admit(clientId: "victim", at: t0)
        for k in 1...3 { _ = t.admit(clientId: "victim", at: t0.addingTimeInterval(Double(k) * 0.001)) }
        var last: Int?
        for i in 0..<AuthFailureThrottle.maxTrackedClients {
            last = t.admit(clientId: "n\(i)", at: t0.addingTimeInterval(1 + Double(i) * 0.001))
        }
        // "victim" was the oldest and is forgotten when the table is full; its 3 suppressed attempts come out with that entry.
        let s = last
        #expect((s ?? 0) >= 3, "\(String(describing: s))")
    }

    @Test func clipCountsUnicodeScalars() {
        let s = "a" + String(repeating: "\u{0301}", count: 100_000)
        let c = AuthFailureThrottle.clip(s)
        #expect(c.unicodeScalars.count <= 100)
        #expect(c.utf8.count <= 400)
    }
}
