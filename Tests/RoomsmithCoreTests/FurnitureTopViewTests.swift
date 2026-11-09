import Testing
import Foundation
import simd
@testable import RoomsmithCore

@Suite("FurnitureTopView") struct FurnitureTopViewTests {
    func project(_ comps: [Component], size: Size3 = Size3(1000, 500, 800)) -> (Project, FurnitureDefinition) {
        var p = Project.empty(name: "T")
        let def = FurnitureDefinition(name: "D", category: "x", size: size, components: comps)
        p.addDefinition(def)
        return (p, def)
    }

    @Test func rotatedBoxCornersAreExactMillimetres() throws {
        let box = Component(name: "b", shape: .box, position: P3(0, 0, 400), size: Size3(1000, 500, 800))
        var (p, def) = project([box])
        let id = try p.addInstance(definitionId: def.id, levelId: p.levels[0].id, position: P3(2000, 3000, 0), rotationDeg: 90)
        let view = FurnitureTopView.shapes(p.instance(id)!, in: p)
        #expect(view.shapes.count == 1)
        let pts = view.shapes[0].points
        #expect(pts.count == 4)
        // 1000 x 500 turned by 90 degrees spans x 1750...2250, y 2500...3500.
        let expected: Set<[Int]> = [[1750, 2500], [2250, 2500], [2250, 3500], [1750, 3500]]
        let got = Set(pts.map { [Int($0.x.rounded()), Int($0.y.rounded())] })
        #expect(got == expected)
        for q in pts { #expect(abs(q.x - q.x.rounded()) < 1e-6 && abs(q.y - q.y.rounded()) < 1e-6) }
        #expect(abs(view.shapes[0].topZ - 800) < 1e-9)
    }

    @Test func cylinderRadiusMatches() throws {
        let cyl = Component(name: "c", shape: .cylinder, position: P3(100, 0, 300), size: Size3(600, 600, 600))
        var (p, def) = project([cyl], size: Size3(800, 600, 600))
        let id = try p.addInstance(definitionId: def.id, levelId: p.levels[0].id, position: P3(1000, 1000, 0), rotationDeg: 37)
        let s = FurnitureTopView.shapes(p.instance(id)!, in: p).shapes[0]
        for q in s.points { #expect(abs(simd_length(q - s.center) - 300) < 1e-6) }
        let r = 37.0 * .pi / 180
        #expect(abs(s.center.x - (1000 + 100 * cos(r))) < 1e-6)
        #expect(abs(s.center.y - (1000 + 100 * sin(r))) < 1e-6)
    }

    @Test func sortedByHeightAndColoured() throws {
        let m = Material(name: "red", color: RGBColor(200, 10, 20))
        let tall = Component(name: "tall", shape: .box, position: P3(0, 0, 500), size: Size3(200, 200, 1000), materialId: m.id)
        let low = Component(name: "low", shape: .box, position: P3(0, 0, 50), size: Size3(1000, 500, 100))
        var (p, def) = project([tall, low])
        p.materials.append(m)
        let id = try p.addInstance(definitionId: def.id, levelId: p.levels[0].id, position: P3(0, 0, 0))
        let v = FurnitureTopView.shapes(p.instance(id)!, in: p)
        #expect(v.shapes.map(\.topZ) == [100, 1000])
        #expect(v.shapes[1].color == RGBColor(200, 10, 20))
        #expect(v.shapes[0].color == nil)
    }

    @Test func dragPayloadRoundTripsAndPlacesExactly() throws {
        let id = UUID()
        #expect(FurnitureDragSource(payload: FurnitureDragSource.definition(id).payload) == .definition(id))
        #expect(FurnitureDragSource(payload: FurnitureDragSource.catalog("sofa-3").payload) == .catalog("sofa-3"))
        #expect(FurnitureDragSource(payload: "hello") == nil)

        var p = Project.empty(name: "T")
        let level = p.levels[0].id
        let key = try #require(BuiltinCatalog.entries.first?.key)
        let a = try p.placeDragged(.catalog(key), levelId: level, at: P2(1234, -5678))
        #expect(p.instance(a)?.position == P3(1234, -5678, 0))
        let b = try p.placeDragged(.catalog(key), levelId: level, at: P2(10, 20))
        #expect(p.instance(a)?.definitionId == p.instance(b)?.definitionId)
        #expect(p.definitions.count == 1)
    }

    @Test func topViewAreaMatchesMeshSilhouette() throws {
        let cases: [(String, PrimitiveShape, R3)] = [
            ("cushion", .cushion, R3(0, 0, 0)), ("cyl-lying", .cylinder, R3(90, 0, 0)), ("cyl-tilt", .cylinder, R3(0, 25, 0)),
            ("sphere", .sphere, R3(30, 40, 0)), ("box", .box, R3(20, 30, 0))]
        for (n, shape, rot) in cases {
            let comp = Component(name: n, shape: shape, position: P3(0, 0, 400), size: Size3(600, 300, 500), rotation: rot)
            let def = FurnitureDefinition(name: n, category: "x", size: Size3(600, 300, 800), components: [comp])
            let inst = FurnitureInstance(definitionId: def.id, levelId: UUID(), name: n, position: P3(1000, 1000, 0), rotationDeg: 30)
            let rc = FurnitureResolver.resolve(inst, definition: def)[0]
            let mesh = Meshes.unitPrimitive(rc.shape, component: rc.componentId).transformed(rc.worldMatrix)
            let expected = FurnitureTopView.polygonArea(FurnitureTopView.convexHull(mesh.positions.map { V2($0.x, $0.y) }))
            let got = FurnitureTopView.make(inst, definition: def, colors: [:]).shapes[0].area
            #expect(expected > 0)
            #expect(abs(got - expected) / expected < 0.005, "\(n): \(got) vs \(expected)")
        }
    }

    @Test func analyticAreasAndZeroWidthDropped() throws {
        let box = Component(name: "b", shape: .box, position: P3(0, 0, 400), size: Size3(600, 300, 800))
        var (p, def) = project([box])
        let id = try p.addInstance(definitionId: def.id, levelId: p.levels[0].id, position: P3(0, 0, 0), rotationDeg: 30)
        let s = FurnitureTopView.shapes(p.instance(id)!, in: p).shapes[0]
        #expect(abs(s.area - 180_000) < 1e-3)
        #expect(s.points.count == 4)

        let cyl = Component(name: "c", shape: .cylinder, position: P3(0, 0, 300), size: Size3(400, 400, 600))
        let (p2, d2) = project([cyl])
        let r = 200.0
        let v = FurnitureTopView.make(FurnitureInstance(definitionId: d2.id, levelId: p2.levels[0].id, name: "c", position: P3(5, 7, 0)),
                                      definition: d2, colors: [:])
        #expect(abs(v.shapes[0].area - 16 * r * r * sin(2 * Double.pi / 32)) < 1e-3)

        let flat = Component(name: "f", shape: .box, position: P3(0, 0, 400), size: Size3(0, 300, 800))
        let (p3, d3) = project([flat])
        let v3 = FurnitureTopView.make(FurnitureInstance(definitionId: d3.id, levelId: p3.levels[0].id, name: "f", position: P3(0, 0, 0)),
                                       definition: d3, colors: [:])
        #expect(v3.shapes.isEmpty)
    }
}
