import Foundation
import RealityKit
import RoomsmithCore
import Testing
@testable import Roomsmith

/// The draw-time rank of a room or rug depends on the other ones of its level, so moving one must re-rank the unchanged ones.
@MainActor
struct RenderRankSyncTests {
    private func square(_ x: MM, _ y: MM, _ s: MM) -> [P2] { [P2(x, y), P2(x + s, y), P2(x + s, y + s), P2(x, y + s)] }

    @Test func movingARoomOntoAnotherLiftsTheUnchangedOneAndBackDropsIt() throws {
        let model = AppModel()
        var a = UUID(), b = UUID()
        model.perform("Rooms") { p in
            a = try p.addRoom(levelId: model.activeLevelId, name: "A", points: square(0, 0, 3000))
            b = try p.addRoom(levelId: model.activeLevelId, name: "B", points: square(10_000, 0, 3000))
        }
        let scene = SceneRenderer(model: model, interactive: true)   // the live renderer syncs per change event
        scene.start()
        defer { scene.teardown() }
        func z(_ id: UUID) -> Float? { scene.roomNodes[id]?.floor?.position.z }
        #expect(z(b) == 0)
        model.perform("Move A onto B") { try $0.updateRoom(a, points: square(10_000, 0, 3000)) }
        #expect(z(b) == Float(RenderLayering.offsetMm(rank: 1)))   // B did not change itself, A (earlier in the list) did
        model.perform("Move A away") { try $0.updateRoom(a, points: square(0, 0, 3000)) }
        #expect(z(b) == 0)
    }

    @Test func movingARugOntoAnotherLiftsTheUnchangedOneAndBackDropsIt() throws {
        let model = AppModel()
        let rug = try #require(BuiltinCatalog.definition("rug.2000x3000"))
        var first = UUID(), second = UUID()
        model.perform("Rugs") { p in
            _ = p.addDefinition(rug)
            first = try p.addInstance(definitionId: rug.id, levelId: model.activeLevelId, position: P3(0, 0, 0))
            second = try p.addInstance(definitionId: rug.id, levelId: model.activeLevelId, position: P3(10_000, 0, 0))
        }
        let scene = SceneRenderer(model: model, interactive: true)   // the live renderer syncs per change event
        scene.start()
        defer { scene.teardown() }
        func z(_ id: UUID) -> Float? { scene.instNodes[id]?.root.transform.translation.z }
        #expect(z(second) == 0)
        model.perform("Move first onto second") { try $0.updateInstance(first) { $0.position = P3(10_000, 0, 0) } }
        #expect(z(second) == Float(RenderLayering.offsetMm(rank: 1)))
        model.perform("Move first away") { try $0.updateInstance(first) { $0.position = P3(0, 0, 0) } }
        #expect(z(second) == 0)
    }
}
