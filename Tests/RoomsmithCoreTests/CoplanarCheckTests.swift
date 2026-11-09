import Foundation
import Testing
@testable import RoomsmithCore

@Suite struct CoplanarCheckTests {
    private func box(_ name: String, x: ClosedRange<MM>, y: ClosedRange<MM>, z: ClosedRange<MM>) -> Component {
        Component(name: name, shape: .box,
                  position: P3((x.lowerBound + x.upperBound) / 2, (y.lowerBound + y.upperBound) / 2, (z.lowerBound + z.upperBound) / 2),
                  size: Size3(x.upperBound - x.lowerBound, y.upperBound - y.lowerBound, z.upperBound - z.lowerBound))
    }

    private func definition(_ parts: [Component]) -> FurnitureDefinition {
        FurnitureDefinition(name: "Fixture", category: "Test", size: Size3(1000, 500, 800), components: parts)
    }

    /// The old carcass: the top covered the sides, so its outer faces lay in the same planes as the sides' faces.
    @Test func topOverSidesIsReported() {
        let def = definition([
            box("Side left", x: -500 ... -482, y: -250 ... 250, z: 0 ... 800),
            box("Side right", x: 482 ... 500, y: -250 ... 250, z: 0 ... 800),
            box("Top", x: -500 ... 500, y: -250 ... 250, z: 782 ... 800),
        ])
        let hits = CoplanarCheck.check(def)
        let pairs = Set(hits.map { Set([$0.nameA, $0.nameB]) })
        #expect(pairs == [Set(["Side left", "Top"]), Set(["Side right", "Top"])])
        #expect(hits.allSatisfy { $0.gapMm < CoplanarCheck.toleranceMm && $0.overlapMm2 > 0 })
    }

    @Test func topBetweenSidesIsClean() {
        let def = definition([
            box("Side left", x: -500 ... -482, y: -250 ... 250, z: 0 ... 800),
            box("Side right", x: 482 ... 500, y: -250 ... 250, z: 0 ... 800),
            box("Top", x: -482 ... 482, y: -250 ... 250, z: 782 ... 800),
        ])
        #expect(CoplanarCheck.check(def).isEmpty)
    }

    /// Stacked boxes touch with opposite-facing faces; back faces are culled, so nothing flickers.
    @Test func stackedBoxesAreClean() {
        let def = definition([
            box("Lower", x: -500 ... 500, y: -250 ... 250, z: 0 ... 400),
            box("Upper", x: -500 ... 500, y: -250 ... 250, z: 400 ... 800),
        ])
        // The side faces are flush and point the same way, but they only share an edge (z = 400), not an area.
        #expect(CoplanarCheck.check(def).isEmpty)
    }

    @Test func touchingEdgesOnlyAreClean() {
        let def = definition([
            box("A", x: 0 ... 100, y: 0 ... 100, z: 0 ... 100),
            box("B", x: 100 ... 200, y: 100 ... 200, z: 0 ... 100),
        ])
        #expect(CoplanarCheck.check(def).isEmpty)
    }

    @Test func gapBeyondToleranceIsClean() {
        let def = definition([
            box("A", x: 0 ... 100, y: 0 ... 100, z: 0 ... 100),
            box("B", x: 0 ... 100, y: 0 ... 100, z: 102 ... 202),
        ])
        // Top of A (z = 100) and top of B (z = 202) are 102 mm apart; the side faces are flush but disjoint in height.
        #expect(CoplanarCheck.check(def).isEmpty)
    }

    @Test func everyBuiltinCatalogEntryIsClean() {
        for e in BuiltinCatalog.entries {
            let hits = CoplanarCheck.check(e.make())
            #expect(hits.isEmpty, "\(e.key): \(hits.map { "\($0.nameA) / \($0.nameB)" })")
        }
    }

    @Test func duplicatePlacementIsReportedNotFixed() throws {
        var p = Project.empty(name: "Dup")
        let level = try #require(p.levels.first)
        let def = definition([box("A", x: 0 ... 100, y: 0 ... 100, z: 0 ... 100)])
        _ = p.addDefinition(def)
        let a = try p.addInstance(definitionId: def.id, levelId: level.id, position: P3(0, 0, 0))
        let b = try p.addInstance(definitionId: def.id, levelId: level.id, position: P3(0, 0, 0))
        _ = try p.addInstance(definitionId: def.id, levelId: level.id, position: P3(500, 0, 0))
        let hits = DuplicatePlacementCheck.check(p)
        #expect(hits == [DuplicatePlacementCheck.Hit(a: a, b: b, definitionId: def.id)])
        #expect(p.instances.count == 3)
    }
}
