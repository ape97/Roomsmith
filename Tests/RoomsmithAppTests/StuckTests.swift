import Foundation
import Testing
import RoomsmithCore

struct StuckTests {
    @Test func demoPiecesCanMoveSomewhere() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Examples/Demo Apartment.roomsmith")
        let (p, _) = try ProjectPackage.load(from: url)
        let snap = p.settings.snap
        var stuck = 0
        for inst in p.instances {
            let bodies = MoveContact.bodies(project: p, levelId: inst.levelId, ids: [inst.id])
            let obstacles = MoveContact.obstacles(project: p, levelId: inst.levelId, excluding: [inst.id], toWalls: snap.toWalls, toObjects: snap.toObjects)
            var any = false
            for d in [V2(300, 0), V2(-300, 0), V2(0, 300), V2(0, -300)] {
                let r = MoveContact.resolve(moving: bodies, raw: d, obstacles: obstacles, tolerance: 100, slide: true)
                if r.delta != V2(0, 0) { any = true }
            }
            if !any { stuck += 1 }
        }
        #expect(stuck == 0)
    }
}
