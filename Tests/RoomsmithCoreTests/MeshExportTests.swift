import Testing
import Foundation
import CoreGraphics
import simd
@testable import RoomsmithCore

// MARK: helpers

private func triArea(_ pts: [V2], _ t: [Int]) -> Double {
    var s = 0.0
    var i = 0
    while i + 2 < t.count {
        let a = pts[t[i]], b = pts[t[i + 1]], c = pts[t[i + 2]]
        s += abs((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) / 2
        i += 3
    }
    return s
}

private func signedTriArea(_ pts: [V2], _ t: [Int]) -> Double {
    var s = 0.0
    var i = 0
    while i + 2 < t.count {
        let a = pts[t[i]], b = pts[t[i + 1]], c = pts[t[i + 2]]
        s += ((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) / 2
        i += 3
    }
    return s
}

private func tris(_ m: MeshData, role: MeshRole? = nil) -> [[SIMD3<Double>]] {
    var out: [[SIMD3<Double>]] = []
    for part in m.parts where role == nil || part.role == role {
        var i = part.indexRange.lowerBound
        while i + 2 < part.indexRange.upperBound {
            out.append((0..<3).map { m.positions[Int(m.indices[i + $0])] })
            i += 3
        }
    }
    return out
}

private extension Array where Element == [SIMD3<Double>] {
    var totalArea: Double { var s = 0.0; for t in self { s += area3(t) }; return s }
}

private func area3(_ t: [SIMD3<Double>]) -> Double { simd_length(simd_cross(t[1] - t[0], t[2] - t[0])) / 2 }

private func signedVolume(_ m: MeshData) -> Double {
    tris(m).reduce(0) { $0 + simd_dot($1[0], simd_cross($1[1], $1[2])) / 6 }
}

private func uniquePoints(_ m: MeshData) -> Set<[Int64]> {
    Set(m.positions.map { [Int64(($0.x * 1000).rounded()), Int64(($0.y * 1000).rounded()), Int64(($0.z * 1000).rounded())] })
}

private let level = UUID()

private func wall(_ a: P2, _ b: P2, t: MM = 100, h: MM = 2500) -> Wall {
    Wall(levelId: level, start: a, end: b, thickness: t, height: h)
}

private func inTri2(_ p: V2, _ a: V2, _ b: V2, _ c: V2) -> Bool {
    func cr(_ a: V2, _ b: V2, _ c: V2) -> Double { (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) }
    let d1 = cr(a, b, p), d2 = cr(b, c, p), d3 = cr(c, a, p)
    return !((d1 < 0 || d2 < 0 || d3 < 0) && (d1 > 0 || d2 > 0 || d3 > 0))
}

// MARK: earClip

@Suite struct EarClipTests {
    func check(_ pts: [P2]) {
        let v = pts.map(\.v)
        let t = Triangulate.earClip(v)
        #expect(t.count % 3 == 0)
        #expect(abs(triArea(v, t) - Geo.area(pts)) < 1e-6)
        #expect(abs(abs(signedTriArea(v, t)) - Geo.area(pts)) < 1e-6) // all triangles share one orientation
        #expect(signedTriArea(v, t) > 0) // CCW output
    }

    @Test func square() {
        let q = [P2(0, 0), P2(1000, 0), P2(1000, 1000), P2(0, 1000)]
        check(q); check(q.reversed())
        #expect(Triangulate.earClip(q.map(\.v)).count == 6)
    }
    @Test func lShape() {
        let l = [P2(0, 0), P2(4000, 0), P2(4000, 1500), P2(1500, 1500), P2(1500, 4000), P2(0, 4000)]
        check(l); check(l.reversed())
    }
    @Test func concave() {
        let c = [P2(0, 0), P2(5000, 0), P2(5000, 3000), P2(3000, 1000), P2(2000, 3000), P2(0, 3000)]
        check(c); check(c.reversed())
        let star = [P2(0, 3000), P2(1000, 1000), P2(3000, 0), P2(1000, -1000), P2(0, -3000), P2(-1000, -1000), P2(-3000, 0), P2(-1000, 1000)]
        check(star); check(star.reversed())
    }
    @Test func collinearPoints() {
        let c = [P2(0, 0), P2(1000, 0), P2(2000, 0), P2(3000, 0), P2(3000, 1000), P2(3000, 2000), P2(1500, 2000), P2(0, 2000), P2(0, 1000)]
        check(c); check(c.reversed())
        let dup = [P2(0, 0), P2(2000, 0), P2(2000, 0), P2(2000, 2000), P2(0, 2000)]
        check(dup)
    }
    @Test func degenerate() {
        #expect(Triangulate.earClip([V2(0, 0), V2(1, 0)]).isEmpty)
        #expect(Triangulate.earClip([V2(0, 0), V2(1, 0), V2(2, 0)]).isEmpty)
    }
}

// MARK: walls

@Suite struct WallMeshTests {
    @Test func plainWallHasEightExactCorners() {
        let w = wall(P2(0, 0), P2(4000, 0), t: 100, h: 2500)
        let ol = WallOutline.compute([w], levelId: level)[w.id]!
        let m = Meshes.wall(w, outline: ol, openings: [], baseZ: 100)
        var expected = Set<[Int64]>()
        for x in [0, 4000] as [Int64] { for y in [-50, 50] as [Int64] { for z in [100, 2600] as [Int64] { expected.insert([x * 1000, y * 1000, z * 1000]) } } }
        #expect(uniquePoints(m) == expected)
        #expect(expected.count == 8)
        // closed box: volume = 4000 * 100 * 2500
        #expect(abs(signedVolume(m) - 4000 * 100 * 2500) < 1)
        let left = tris(m, role: .wallLeft).totalArea
        #expect(abs(left - 4000 * 2500) < 1e-6)
        let top = tris(m, role: .wallTop).totalArea
        #expect(abs(top - 4000 * 100) < 1e-6)
        // normals: left face looks to +Y, right to -Y
        for r in [(MeshRole.wallLeft, 1.0), (.wallRight, -1.0)] {
            for t in tris(m, role: r.0) { #expect(simd_cross(t[1] - t[0], t[2] - t[0]).y * r.1 > 0) }
        }
    }

    @Test func doorLeavesExactHole() {
        let w = wall(P2(0, 0), P2(4000, 0))
        let ol = WallOutline.compute([w], levelId: level)[w.id]!
        let door = Opening(wallId: w.id, kind: .door, offset: 1000, width: 900, height: 2100, sill: 0)
        let m = Meshes.wall(w, outline: ol, openings: [door], baseZ: 0)
        let left = tris(m, role: .wallLeft)
        let total = left.totalArea
        #expect(abs(total - 8_110_000.0) < 1e-6)
        // sample the (x,z) plane: nothing covers the door, everything else is covered
        for xi in stride(from: 10.0, to: 4000, by: 37) {
            for zi in stride(from: 10.0, to: 2500, by: 41) {
                let p = V2(xi, zi)
                let covered = left.contains { inTri2(p, V2($0[0].x, $0[0].z), V2($0[1].x, $0[1].z), V2($0[2].x, $0[2].z)) }
                let inDoor = xi > 550 && xi < 1450 && zi < 2100
                #expect(covered != inDoor, "x=\(xi) z=\(zi)")
            }
        }
        // reveals exist: two jambs (2100 * 100 each) + lintel underside (900 * 100)
        let side = tris(m, role: .wallSide).totalArea
        let caps = 2 * (100.0 * 2500)
        let bottom = 4000.0 * 100
        let reveals = 2 * 2100.0 * 100 + 900 * 100
        #expect(abs(side - (caps + bottom - 90_000.0 + reveals)) < 1e-6)
    }

    @Test func windowWithSill() {
        let w = wall(P2(0, 0), P2(0, 3000)) // north-pointing wall
        let ol = WallOutline.compute([w], levelId: level)[w.id]!
        let win = Opening(wallId: w.id, kind: .window, offset: 1500, width: 1200, height: 1200, sill: 900)
        let m = Meshes.wall(w, outline: ol, openings: [win], baseZ: 0)
        let left = tris(m, role: .wallLeft)
        #expect(abs(left.totalArea - 6_060_000.0) < 1e-6)
        // wall points north: left face is at x = -50 and looks to -X; hole in (y, z)
        for t in left { #expect(simd_cross(t[1] - t[0], t[2] - t[0]).x < 0) }
        for yi in stride(from: 10.0, to: 3000, by: 53) {
            for zi in stride(from: 10.0, to: 2500, by: 43) {
                let p = V2(yi, zi)
                let covered = left.contains { inTri2(p, V2($0[0].y, $0[0].z), V2($0[1].y, $0[1].z), V2($0[2].y, $0[2].z)) }
                let inWindow = yi > 900 && yi < 2100 && zi > 900 && zi < 2100
                #expect(covered != inWindow)
            }
        }
        #expect(abs(signedVolume(m) - 606_000_000.0) < 1)
    }

    @Test func openingBeyondWallEndIsClipped() {
        let w = wall(P2(0, 0), P2(2000, 0))
        let ol = WallOutline.compute([w], levelId: level)[w.id]!
        let door = Opening(wallId: w.id, kind: .door, offset: 1800, width: 900, height: 2100, sill: 0) // 1350…2250 -> 1350…2000
        let m = Meshes.wall(w, outline: ol, openings: [door], baseZ: 0)
        let left = tris(m, role: .wallLeft).totalArea
        #expect(abs(left - 3_635_000.0) < 1e-6)
        #expect(m.positions.allSatisfy { $0.x >= -1e-9 && $0.x <= 2000 + 1e-9 })
        // an opening fully outside changes nothing
        let out = Opening(wallId: w.id, kind: .window, offset: 5000, width: 500, height: 500, sill: 800)
        let m2 = Meshes.wall(w, outline: ol, openings: [out], baseZ: 0)
        #expect(m2.indices.count == Meshes.wall(w, outline: ol, openings: [], baseZ: 0).indices.count)
        #expect(Meshes.openingFrame(out, wall: w, baseZ: 0).isEmpty)
    }

    @Test func mitredNonOrthogonalWallsMatchOutline() {
        let a = wall(P2(0, 0), P2(3464, 2000), t: 200)        // 30 degrees
        let b = wall(P2(3464, 2000), P2(3464, 5000), t: 150)
        let outlines = WallOutline.compute([a, b], levelId: level)
        for w in [a, b] {
            let ol = outlines[w.id]!
            let m = Meshes.wall(w, outline: ol, openings: [], baseZ: 0)
            let bottom = m.positions.filter { $0.z == 0 }
            for c in ol.polygon {
                #expect(bottom.contains { abs($0.x - c.x) < 1e-9 && abs($0.y - c.y) < 1e-9 })
            }
            #expect(uniquePoints(m).count == 8)
            #expect(signedVolume(m) > 0)
            let expectedVol = Geo.area(ol.polygon.map { P2(rounding: $0) }) * 2500
            #expect(abs(signedVolume(m) - expectedVol) / expectedVol < 1e-3)
        }
    }

    @Test func doorAndWindowFrames() {
        let w = wall(P2(0, 0), P2(4000, 0))
        let door = Opening(wallId: w.id, kind: .door, offset: 1000, width: 900, height: 2100, sill: 0)
        let win = Opening(wallId: w.id, kind: .window, offset: 3000, width: 1200, height: 1200, sill: 900)
        let d = Meshes.openingFrame(door, wall: w, baseZ: 0)
        let f = Meshes.openingFrame(win, wall: w, baseZ: 0)
        #expect(!d.isEmpty && !f.isEmpty)
        #expect(!d.parts.contains { $0.role == .glass })
        #expect(f.parts.contains { $0.role == .glass })
        for p in d.positions { #expect(p.x >= 550 - 1e-9 && p.x <= 1450 + 1e-9 && p.z >= 0 && p.z <= 2100 + 1e-9) }
        for p in f.positions { #expect(p.x >= 2400 - 1e-9 && p.x <= 3600 + 1e-9 && p.z >= 900 - 1e-9 && p.z <= 2100 + 1e-9) }
        #expect(signedVolume(d) > 0 && signedVolume(f) > 0)
    }

    @Test func roomFloorAndCeiling() {
        let r = Room(levelId: level, name: "L", points: [P2(0, 0), P2(4000, 0), P2(4000, 1500), P2(1500, 1500), P2(1500, 4000), P2(0, 4000)])
        let fl = Meshes.roomFloor(r, z: 250), ce = Meshes.roomCeiling(r, z: 2750)
        let area = Geo.area(r.points)
        #expect(abs(tris(fl).totalArea - area) < 1e-6)
        for t in tris(fl) { #expect(simd_cross(t[1] - t[0], t[2] - t[0]).z > 0 && t[0].z == 250) }
        for t in tris(ce) { #expect(simd_cross(t[1] - t[0], t[2] - t[0]).z < 0 && t[0].z == 2750) }
        // clockwise input gives the same upward facing floor
        var cw = r; cw.points.reverse()
        for t in tris(Meshes.roomFloor(cw, z: 0)) { #expect(simd_cross(t[1] - t[0], t[2] - t[0]).z > 0) }
    }
}

// MARK: primitives

@Suite struct PrimitiveMeshTests {
    @Test(arguments: PrimitiveShape.allCases)
    func unitBoundingBox(_ shape: PrimitiveShape) {
        let m = Meshes.unitPrimitive(shape)
        #expect(!m.isEmpty)
        let lo = m.positions.reduce(SIMD3<Double>(repeating: .infinity)) { simd_min($0, $1) }
        let hi = m.positions.reduce(SIMD3<Double>(repeating: -.infinity)) { simd_max($0, $1) }
        for k in 0..<3 {
            #expect(abs(lo[k] + 0.5) < 1e-12, "min \(shape) axis \(k) = \(lo[k])")
            #expect(abs(hi[k] - 0.5) < 1e-12, "max \(shape) axis \(k) = \(hi[k])")
        }
        #expect(m.indices.allSatisfy { Int($0) < m.positions.count })
        #expect(signedVolume(m) > 0.3) // outward winding
        #expect(m.parts.count == 1)
    }

    @Test func boxVolumeIsOne() {
        #expect(abs(signedVolume(Meshes.unitPrimitive(.box)) - 1) < 1e-12)
        let c = signedVolume(Meshes.unitPrimitive(.cushion))
        #expect(c > 0.8 && c < 0.95)
    }

    @Test func roundedHasOneRadiusInMillimetres() {
        let size = Size3(2000, 600, 40)
        let r = Meshes.roundedRadius(size)
        #expect(abs(r - 12) < 1e-12)
        let unit = Meshes.unitPrimitive(.rounded, size: size)
        #expect(unit.positions.count == 216)
        let world = unit.transformed(Transform.scale(2000, 600, 40))
        let lo = world.positions.reduce(V3(repeating: .infinity)) { simd_min($0, $1) }
        let hi = world.positions.reduce(V3(repeating: -.infinity)) { simd_max($0, $1) }
        #expect(simd_length(lo + V3(1000, 300, 20)) < 1e-9 && simd_length(hi - V3(1000, 300, 20)) < 1e-9)
        // Every vertex of the round zone lies on a sphere/cylinder of radius r around the flat core, in mm.
        let flat = V3(1000 - r, 300 - r, 20 - r)
        for (p, n) in zip(world.positions, world.normals) {
            let inner = simd_clamp(p, -flat, flat)
            let d = simd_length(p - inner)
            #expect(abs(d - r) < 1e-6, "point \(p) is \(d) mm off the core")
            #expect(abs(simd_length(n) - 1) < 1e-9)
            if d > 1e-9, simd_length(p - inner - n * r) > 1e-6 { Issue.record("normal \(n) at \(p) is not radial") }
        }
        let volume = signedVolume(world)
        let box = 2000.0 * 600 * 40
        #expect(volume < box && volume > 0.97 * box)
    }

    @Test func roundedThinPartsKeepAShallowerEdgeAndTinyOnesStayBoxes() {
        #expect(abs(Meshes.roundedRadius(Size3(600, 400, 18)) - 5.4) < 1e-12)
        #expect(Meshes.unitPrimitive(.rounded, size: Size3(600, 400, 3)).positions.count == 24)
        #expect(Meshes.unitPrimitive(.rounded).positions == Meshes.unitPrimitive(.box).positions)
    }

    @Test func taperNarrowsUpwards() {
        let m = Meshes.unitPrimitive(.taper, segments: 32)
        let topR = m.positions.filter { $0.z > 0.49 }.map { simd_length(SIMD2($0.x, $0.y)) }.max() ?? 0
        let bottomR = m.positions.filter { $0.z < -0.49 }.map { simd_length(SIMD2($0.x, $0.y)) }.max() ?? 0
        #expect(abs(topR - 0.5 * Meshes.taperTop) < 1e-12 && abs(bottomR - 0.5) < 1e-12)
        // Frustum volume pi h/3 (R² + R r + r²) of the 32-gon is close to the analytic one.
        let rT = 0.5 * Meshes.taperTop
        let exact = Double.pi / 3 * (0.25 + 0.5 * rT + rT * rT)
        #expect(abs(signedVolume(m) - exact) / exact < 0.02)
    }
}

// MARK: exports

private func samplePlan() -> (Project, Wall, UUID) {
    var p = Project.empty(name: "Test & <Plan>")
    let lv = p.levels[0]
    let w = Wall(levelId: lv.id, start: P2(0, 0), end: P2(4250, 0), thickness: 100, height: 2500)
    p.walls = [w]
    return (p, w, lv.id)
}

private func parseNumbers(_ s: Substring) -> [Double] {
    s.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Double($0) }
}

@Suite struct ExportTests {
    @Test func svgScaleAndSize() throws {
        let (p, _, lid) = samplePlan()
        let svg = PlanExport.svg(p, options: .init(levelId: lid, scale: 50))
        // wall outline polygon: x extent must be 85 paper mm
        let line = try #require(svg.split(separator: "\n").first { $0.contains("fill=\"#4D4D4D\"") && $0.contains("<polygon") })
        let pts = try #require(line.components(separatedBy: "points=\"").dropFirst().first?.components(separatedBy: "\"").first)
        let nums = parseNumbers(Substring(pts))
        let xs = stride(from: 0, to: nums.count, by: 2).map { nums[$0] }
        let ys = stride(from: 1, to: nums.count, by: 2).map { nums[$0] }
        #expect(abs((xs.max()! - xs.min()!) - 85) < 1e-9)
        #expect(abs((ys.max()! - ys.min()!) - 2) < 1e-9) // 100 mm thick at 1:50
        // paper: 85 + 2*10 wide, 2 + 2*10 + legend high
        #expect(svg.contains("width=\"105mm\""))
        #expect(svg.contains("height=\"36mm\""))
        #expect(svg.contains("viewBox=\"0 0 105 36\""))
        #expect(svg.contains(">1:50<"))
        // north up: the wall polygon starts inside the margin
        #expect(xs.min()! == 10)
    }

    @Test func svgNorthIsUpAndScaleBarFollowsScale() {
        var (p, _, lid) = samplePlan()
        p.walls.append(Wall(levelId: lid, start: P2(0, 0), end: P2(0, 3000), thickness: 100, height: 2500))
        let svg = PlanExport.svg(p, options: .init(levelId: lid, scale: 100))
        #expect(svg.contains(">1:100<"))
        let size = PlanExport.paperSize(p, options: .init(levelId: lid, scale: 100))
        #expect(abs(size.width - (4300 / 100.0 + 20)) < 1e-9) // 4250 + half thickness of the vertical wall on the left
    }

    @Test func svgEscapesText() {
        var (p, _, lid) = samplePlan()
        p.rooms = [Room(levelId: lid, name: "Bad <\"A&B\">", points: [P2(0, 0), P2(4000, 0), P2(4000, 3000), P2(0, 3000)])]
        let svg = PlanExport.svg(p, options: .init(levelId: lid))
        #expect(svg.contains("Bad &lt;&quot;A&amp;B&quot;&gt;"))
        #expect(!svg.contains("<\"A&B\">"))
        #expect(svg.contains("Test &amp; &lt;Plan&gt;"))
        #expect(svg.contains("12.00 m²"))
        #expect(!svg.contains("A&B"))
    }

    @Test func svgContentSwitches() {
        var (p, w, lid) = samplePlan()
        let def = FurnitureDefinition(name: "Tisch", category: "x", size: Size3(1000, 600, 750), components: [])
        p.definitions = [def]
        p.instances = [FurnitureInstance(definitionId: def.id, levelId: lid, name: "Esstisch", position: P3(2000, 1000, 0), rotationDeg: 30)]
        p.openings = [Opening(wallId: w.id, kind: .door, offset: 1000, width: 900, height: 2100, sill: 0),
                      Opening(wallId: w.id, kind: .window, offset: 3000, width: 1200, height: 1200, sill: 900)]
        p.dimensions = [Dimension(levelId: lid, a: P2(0, 0), b: P2(4250, 0), offset: 500)]
        let on = PlanExport.svg(p, options: .init(levelId: lid))
        #expect(on.contains("Esstisch"))
        #expect(on.contains(">425 cm<"))
        let off = PlanExport.svg(p, options: .init(levelId: lid, showDimensions: false, showFurniture: false, showRoomLabels: false))
        #expect(!off.contains("Esstisch") && !off.contains(">425 cm<"))
        let mm = PlanExport.svg(p, options: .init(levelId: lid, unit: .mm))
        #expect(mm.contains(">4250 mm<"))
    }

    @Test func furnitureNameStepsBackFromTheRoomName() {
        var (p, _, lid) = samplePlan()
        p.rooms = [Room(levelId: lid, name: "Living", points: [P2(0, 0), P2(4000, 0), P2(4000, 3000), P2(0, 3000)])]
        let def = FurnitureDefinition(name: "Sideboard", category: "x", size: Size3(1800, 900, 800), components: [])
        p.definitions = [def]
        // On the room centre the name would run into "Living" / "12.00 m²": only the outline is drawn.
        p.instances = [FurnitureInstance(definitionId: def.id, levelId: lid, name: "Sideboard", position: P3(2000, 1500, 0))]
        let centre = PlanExport.svg(p, options: .init(levelId: lid))
        #expect(centre.contains(">Living<") && !centre.contains("Sideboard"))
        // A metre away from the room name it is labelled again.
        p.instances[0].position = P3(2000, 500, 0)
        #expect(PlanExport.svg(p, options: .init(levelId: lid)).contains(">Sideboard<"))
    }

    @Test func pdfPageSize() throws {
        let (p, _, lid) = samplePlan()
        let opts = PlanExport.Options(levelId: lid, scale: 50)
        let data = PlanExport.pdf(p, options: opts)
        #expect(data.starts(with: Array("%PDF".utf8)))
        let provider = try #require(CGDataProvider(data: data as CFData))
        let doc = try #require(CGPDFDocument(provider))
        #expect(doc.numberOfPages == 1)
        let page = try #require(doc.page(at: 1))
        let box = page.getBoxRect(.mediaBox)
        let size = PlanExport.paperSize(p, options: opts)
        #expect(abs(box.width - 105 * 72 / 25.4) < 1e-3)
        #expect(abs(box.width - size.width * 72 / 25.4) < 1e-3)
        #expect(abs(box.height - size.height * 72 / 25.4) < 1e-3)
    }

    @Test func objVerticesAndGroups() throws {
        var (p, w, lid) = samplePlan()
        p.rooms = [Room(levelId: lid, name: "Zimmer", points: [P2(0, 0), P2(4000, 0), P2(4000, 3000), P2(0, 3000)])]
        let def = FurnitureDefinition(name: "Regal", category: "x", size: Size3(800, 300, 1800), components: [
            Component(name: "Korpus", shape: .box, position: P3(0, 0, 900), size: Size3(800, 300, 1800)),
            Component(name: "Kugel", shape: .sphere, position: P3(0, 0, 1900), size: Size3(200, 200, 200)),
        ])
        p.definitions = [def]
        p.instances = [FurnitureInstance(definitionId: def.id, levelId: lid, name: "Regal 1", position: P3(2000, 2000, 0))]
        p.openings = [Opening(wallId: w.id, kind: .window, offset: 3000, width: 1200, height: 1200, sill: 900)]
        let (obj, mtl) = SceneExport.obj(p)
        let lines = obj.split(separator: "\n")
        // wall: 1 + opening frame 1 + floor 1 + furniture 1
        #expect(lines.filter { $0.hasPrefix("o ") }.count == 4)
        let verts = lines.filter { $0.hasPrefix("v ") }.map { parseNumbers($0.dropFirst(2)) }
        // plan corner (4250, -50, 2500) mm -> (4.25, 2.5, 0.05) m
        #expect(verts.contains { abs($0[0] - 4.25) < 1e-9 && abs($0[1] - 2.5) < 1e-9 && abs($0[2] - 0.05) < 1e-9 })
        // furniture box top corner: x 2000+400, y 2000+150, z 1800
        #expect(verts.contains { abs($0[0] - 2.4) < 1e-9 && abs($0[1] - 1.8) < 1e-9 && abs($0[2] + 2.15) < 1e-9 })
        // every face index points to an existing vertex
        let count = verts.count
        for f in lines.filter({ $0.hasPrefix("f ") }) {
            for tok in f.dropFirst(2).split(separator: " ") { #expect(Int(tok.split(separator: "/")[0])! <= count) }
        }
        #expect(mtl.contains("newmtl default"))
        #expect(mtl.contains("newmtl glass"))
        #expect(mtl.contains("newmtl frame"))   // window frame without a material: painted joinery default
        #expect(mtl.contains("Kd 0.8 0.8 0.8"))
        #expect(obj.contains("mtllib scene.mtl"))
    }

    @Test func objRespectsVisibilityAndMaterials() {
        var (p, _, lid) = samplePlan()
        let mat = Material(name: "Rot Matt", color: RGBColor(255, 0, 0), roughness: 0.5, metallic: 0, opacity: 0.5)
        p.materials = [mat]
        p.walls[0].leftMaterialId = mat.id
        let (obj, mtl) = SceneExport.obj(p)
        #expect(obj.contains("usemtl Rot_Matt_"))
        #expect(mtl.contains("Kd 1 0 0") && mtl.contains("d 0.5") && mtl.contains("Ns 500"))
        p.levels[0].visible = false
        #expect(SceneExport.obj(p).obj.split(separator: "\n").filter { $0.hasPrefix("o ") }.isEmpty)
        #expect(SceneExport.obj(p, levelId: lid).obj.contains("o Wall_1"))
    }

    @Test func mtlCarriesMetallicAsPmAndARoughKs() {
        var (p, _, _) = samplePlan()
        let steel = Material(name: "Steel", color: RGBColor(255, 255, 255), roughness: 0.3, metallic: 0.8, opacity: 1)
        let paint = Material(name: "Paint", color: RGBColor(255, 0, 0), roughness: 0.5, metallic: 0, opacity: 1)
        p.materials = [steel, paint]
        p.walls[0].leftMaterialId = steel.id
        p.walls[0].rightMaterialId = paint.id
        let mtl = SceneExport.obj(p).mtl
        let blocks = mtl.components(separatedBy: "newmtl ").dropFirst()
        let steelBlock = blocks.first { $0.hasPrefix("Steel_") } ?? ""
        let paintBlock = blocks.first { $0.hasPrefix("Paint_") } ?? ""
        #expect(steelBlock.contains("Pm 0.8\n"))
        #expect(steelBlock.contains("Ks 0.808 0.808 0.808\n"))   // 0.04 + 0.8 * (1 - 0.04)
        #expect(paintBlock.contains("Pm 0\n"))
        #expect(paintBlock.contains("Ks 0.04 0.04 0.04\n"))   // dielectric, independent of the red base colour
    }

    @Test func writeSampleSVG() throws {
        var (p, w, lid) = samplePlan()
        p.walls += [Wall(levelId: lid, start: P2(4250, 0), end: P2(4250, 3000), thickness: 100, height: 2500),
                    Wall(levelId: lid, start: P2(4250, 3000), end: P2(0, 3000), thickness: 100, height: 2500),
                    Wall(levelId: lid, start: P2(0, 3000), end: P2(0, 0), thickness: 100, height: 2500)]
        p.rooms = [Room(levelId: lid, name: "Living room", points: [P2(50, 50), P2(4200, 50), P2(4200, 2950), P2(50, 2950)])]
        p.openings = [Opening(wallId: w.id, kind: .door, offset: 900, width: 900, height: 2100, sill: 0),
                      Opening(wallId: p.walls[2].id, kind: .window, offset: 2000, width: 1400, height: 1200, sill: 900)]
        let def = FurnitureDefinition(name: "Sofa", category: "x", size: Size3(2000, 900, 800), components: [])
        p.definitions = [def]
        p.instances = [FurnitureInstance(definitionId: def.id, levelId: lid, name: "Sofa", position: P3(2000, 2000, 0), rotationDeg: 15)]
        p.dimensions = [Dimension(levelId: lid, a: P2(0, 0), b: P2(4250, 0), offset: -500)]
        let opts = PlanExport.Options(levelId: lid, scale: 50)
        let svg = PlanExport.svg(p, options: opts)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roomsmith-svg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("plan.svg")
        try svg.write(to: file, atomically: true, encoding: .utf8)
        let read = try String(contentsOf: file, encoding: .utf8)
        #expect(read == svg)
        // scale 1:50 -> the page size in paper millimetres matches viewBox and width/height
        let size = PlanExport.paperSize(p, options: opts)
        func num(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }
        #expect(read.hasPrefix("<?xml"))
        #expect(read.contains("viewBox=\"0 0 \(num(size.width)) \(num(size.height))\""))
        #expect(read.contains("width=\"\(num(size.width))mm\" height=\"\(num(size.height))mm\""))
        #expect(read.contains(">1:50<"))
        #expect(read.contains("Sofa"))
        #expect(read.contains("</svg>"))
    }

    /// The door swing arc is the only 25-point polyline; its first point is the free end of the closed door.
    @Test func svgDoorArcFollowsFlipped() throws {
        func arc(flipped: Bool) throws -> [V2] {
            var (p, w, lid) = samplePlan()
            var door = Opening(wallId: w.id, kind: .door, offset: 900, width: 900, height: 2100, sill: 0)
            door.flipped = flipped
            p.openings = [door]
            let svg = PlanExport.svg(p, options: .init(levelId: lid, scale: 50))
            let lines = svg.split(separator: "\n").filter { $0.hasPrefix("<polyline") }
            let arcs = lines.compactMap { line -> [V2]? in
                guard let pts = line.components(separatedBy: "points=\"").dropFirst().first?.components(separatedBy: "\"").first else { return nil }
                let n = parseNumbers(Substring(pts))
                guard n.count == 50 else { return nil }
                return stride(from: 0, to: n.count, by: 2).map { V2(n[$0], n[$0 + 1]) }
            }
            #expect(arcs.count == 1, "one door arc")
            return try #require(arcs.first)
        }
        let plain = try arc(flipped: false), flipped = try arc(flipped: true)
        // 900 mm door at 1:50 = 18 paper mm; hinge at the start of the opening unless flipped
        #expect(abs((plain[0].x - plain[24].x) - 18) < 1e-6)
        #expect(abs((flipped[0].x - flipped[24].x) + 18) < 1e-6)
        // the swing side (inward = true) is the same for both: the arc bulges to the same y side
        #expect(plain[24].y == flipped[24].y)
        #expect(abs(abs(plain[24].y - plain[0].y) - 18) < 1e-6)
    }
}
