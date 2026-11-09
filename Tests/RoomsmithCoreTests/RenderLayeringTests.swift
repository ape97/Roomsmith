import Foundation
import Testing
@testable import RoomsmithCore

@Suite struct RenderLayeringTests {
    private func square(_ x: MM, _ y: MM, _ s: MM) -> [P2] { [P2(x, y), P2(x + s, y), P2(x + s, y + s), P2(x, y + s)] }

    @Test func offsetIsTinyAndCapped() {
        #expect(RenderLayering.offsetMm(rank: 0) == 0)
        #expect(RenderLayering.offsetMm(rank: 1) == 0.5)
        #expect(RenderLayering.offsetMm(rank: 1000) == Double(RenderLayering.maxRank) * RenderLayering.stepMm)
        #expect(RenderLayering.offsetMm(rank: -3) == 0)
    }

    @Test func overlappingRoomsRankInArrayOrderAndLeaveStoredDataAlone() throws {
        var p = Project.empty(name: "t")
        let level = try #require(p.levels.first)
        let a = try p.addRoom(levelId: level.id, name: "A", points: square(0, 0, 4000))
        let b = try p.addRoom(levelId: level.id, name: "B", points: square(2000, 2000, 4000))
        let c = try p.addRoom(levelId: level.id, name: "C", points: square(8000, 0, 3000))
        let before = p.rooms
        #expect(RenderLayering.roomRank(try #require(p.room(a)), in: p) == 0)
        #expect(RenderLayering.roomRank(try #require(p.room(b)), in: p) == 1)
        #expect(RenderLayering.roomRank(try #require(p.room(c)), in: p) == 0)   // apart from both
        #expect(p.rooms == before)
    }

    @Test func overlappingRugsRankAndFurnitureStaysAtZero() throws {
        var p = Project.empty(name: "t")
        let level = try #require(p.levels.first)
        let rug = try #require(BuiltinCatalog.definition("rug.2000x3000"))
        let table = try #require(BuiltinCatalog.definition("table.dining.1600"))
        _ = p.addDefinition(rug)
        _ = p.addDefinition(table)
        let r1 = try p.addInstance(definitionId: rug.id, levelId: level.id, position: P3(0, 0, 0))
        let r2 = try p.addInstance(definitionId: rug.id, levelId: level.id, position: P3(500, 0, 0))
        let t = try p.addInstance(definitionId: table.id, levelId: level.id, position: P3(0, 0, 0))
        #expect(RenderLayering.flatPieceRank(try #require(p.instance(r1)), in: p) == 0)
        #expect(RenderLayering.flatPieceRank(try #require(p.instance(r2)), in: p) == 1)
        #expect(RenderLayering.flatPieceRank(try #require(p.instance(t)), in: p) == 0)
    }
}
