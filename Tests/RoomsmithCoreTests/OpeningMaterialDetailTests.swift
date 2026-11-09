import Foundation
import Testing
@testable import RoomsmithCore

// MARK: - Helpers

private let lvl = UUID()

private func wallAlongX() -> Wall { Wall(levelId: lvl, start: P2(0, 0), end: P2(4000, 0), thickness: 100, height: 2500) }

private func opening(_ w: Wall, _ kind: OpeningKind, style: OpeningStyle? = nil, handle: OpeningHandle = .none,
                     cols: Int = 0, rows: Int = 0, flipped: Bool = false, inward: Bool = true) -> Opening {
    var o = Opening(wallId: w.id, kind: kind, offset: 2000, width: kind == .door ? 900 : 1200, height: kind == .door ? 2100 : 1200,
                    sill: kind == .door ? 0 : 900)
    o.style = style ?? OpeningStyle.defaultStyle(for: kind)
    o.handle = handle; o.mullionCols = cols; o.mullionRows = rows; o.flipped = flipped; o.inward = inward
    return o
}

private func points(_ m: MeshData, role: MeshRole) -> [SIMD3<Double>] {
    var out: [SIMD3<Double>] = []
    for part in m.parts where part.role == role {
        for i in part.indexRange { out.append(m.positions[Int(m.indices[i])]) }
    }
    return out
}

private func centroid(_ pts: [SIMD3<Double>]) -> SIMD3<Double> { pts.reduce(.zero, +) / Double(max(pts.count, 1)) }

// MARK: - Geometry

struct OpeningDetailMeshTests {
    @Test func everyStyleBuildsInsideTheOpening() {
        let w = wallAlongX()
        for kind in [OpeningKind.door, .window] {
            for style in OpeningStyle.styles(for: kind) {
              for handle in OpeningHandle.allCases {
                for flipped in [false, true] {
                    let o = opening(w, kind, style: style, handle: handle, cols: 1, rows: 1, flipped: flipped)
                    let m = Meshes.openingFrame(o, wall: w, baseZ: 0)
                    #expect(!m.isEmpty, "\(style)")
                    let x0 = 2000 - Double(o.width) / 2, x1 = 2000 + Double(o.width) / 2
                    let z0 = Double(o.sill), z1 = z0 + Double(o.height)
                    for p in m.positions {
                        #expect(p.x >= x0 - 1e-6 && p.x <= x1 + 1e-6 && p.z >= z0 - 1e-6 && p.z <= z1 + 1e-6, "\(style) \(handle) \(p)")
                        #expect(abs(p.y) <= 120, "\(style) \(handle) \(p)")
                    }
                }
              }
            }
        }
    }

    @Test func mullionsAddEqualGeometryPerBar() {
        let w = wallAlongX()
        func count(_ cols: Int, _ rows: Int, _ style: OpeningStyle) -> Int {
            Meshes.openingFrame(opening(w, .window, style: style, cols: cols, rows: rows), wall: w, baseZ: 0).indices.count
        }
        for style in [OpeningStyle.fixed, .tiltTurn1] {
            let base = count(0, 0, style), one = count(1, 0, style), two = count(2, 0, style)
            #expect(one > base && two - one == one - base, "\(style)")
            let r1 = count(0, 1, style), r2 = count(0, 2, style)
            #expect(r1 > base && r2 - r1 == r1 - base, "\(style)")
        }
    }

    @Test func stylesDiffer() {
        let w = wallAlongX()
        var seen = Set<Int>()
        for style in OpeningStyle.doorStyles {
            seen.insert(Meshes.openingFrame(opening(w, .door, style: style), wall: w, baseZ: 0).indices.count)
        }
        #expect(seen.count >= 4)
        let one = Meshes.openingFrame(opening(w, .window, style: .tiltTurn1), wall: w, baseZ: 0).indices.count
        let two = Meshes.openingFrame(opening(w, .window, style: .tiltTurn2), wall: w, baseZ: 0).indices.count
        let fixed = Meshes.openingFrame(opening(w, .window, style: .fixed), wall: w, baseZ: 0).indices.count
        #expect(one != two && fixed != one)
    }

    @Test func glassTypeSelectsRole() {
        let w = wallAlongX()
        for (g, role) in [(OpeningGlass.clear, MeshRole.glass), (.frosted, .glassFrosted), (.tinted, .glassTinted)] {
            var o = opening(w, .window); o.glassType = g
            let m = Meshes.openingFrame(o, wall: w, baseZ: 0)
            #expect(m.parts.contains { $0.role == role })
            for other in [MeshRole.glass, .glassFrosted, .glassTinted] where other != role {
                #expect(!m.parts.contains { $0.role == other })
            }
        }
    }

    @Test func handleSitsOnFreeEdgeAndFlipsWithTheDoor() {
        let w = wallAlongX()
        let a = Meshes.openingFrame(opening(w, .door, handle: .lever), wall: w, baseZ: 0)
        let b = Meshes.openingFrame(opening(w, .door, handle: .lever, flipped: true), wall: w, baseZ: 0)
        let ha = points(a, role: .hardware), hb = points(b, role: .hardware)
        #expect(!ha.isEmpty && !hb.isEmpty)
        // Opposite sides of the opening centre (x = 2000).
        #expect((centroid(ha).x - 2000) * (centroid(hb).x - 2000) < 0)
        // Mirror image: the handle is on both faces of the leaf.
        #expect(ha.map(\.y).min()! < -20 && ha.map(\.y).max()! > 20)
        // No handle, no hardware besides hinges: the handle adds geometry.
        let none = Meshes.openingFrame(opening(w, .door, handle: .none), wall: w, baseZ: 0)
        #expect(a.indices.count > none.indices.count)
    }

    @Test func allHandleKindsAddHardware() {
        let w = wallAlongX()
        let base = Meshes.openingFrame(opening(w, .door), wall: w, baseZ: 0).indices.count
        for h in [OpeningHandle.lever, .knob, .bar] {
            #expect(Meshes.openingFrame(opening(w, .door, handle: h), wall: w, baseZ: 0).indices.count > base, "\(h)")
        }
        let win = Meshes.openingFrame(opening(w, .window, style: .tiltTurn1, handle: .lever), wall: w, baseZ: 0)
        #expect(win.parts.contains { $0.role == .windowHardware })
        #expect(!win.parts.contains { $0.role == .hardware }, "window hardware has its own role")
        let fixed = Meshes.openingFrame(opening(w, .window, style: .fixed, handle: .lever), wall: w, baseZ: 0)
        let fixedNone = Meshes.openingFrame(opening(w, .window, style: .fixed, handle: .none), wall: w, baseZ: 0)
        #expect(fixed.indices.count == fixedNone.indices.count)
    }

    @Test func leafIsBuiltHingeLocalSoItRotatesAsOne() throws {
        let w = wallAlongX()
        for style in [OpeningStyle.smooth, .panel2, .panel4, .glass] {
            let o = opening(w, .door, style: style, handle: .knob, cols: 1)
            let leaf = Meshes.doorLeaf(o, wall: w, baseZ: 0)
            #expect(!leaf.isEmpty)
            let placement = try #require(Meshes.doorLeafPlacement(o, wall: w, baseZ: 0))
            let xs = leaf.positions.map(\.x), zs = leaf.positions.map(\.z)
            #expect(xs.min()! >= -1e-6 && xs.max()! <= placement.leafWidth + 1e-6, "\(style)")
            #expect(zs.min()! >= -1e-6 && zs.max()! <= Double(o.height) + 1e-6)
            // The hinge is the rotation axis: all leaf geometry stays on one side of x = 0.
            #expect(leaf.parts.contains { $0.role == .hardware })
        }
    }

    @Test func slidingDoorDoesNotSwing() throws {
        let w = wallAlongX()
        let o = opening(w, .door, style: .sliding, handle: .bar)
        let p = try #require(Meshes.doorLeafPlacement(o, wall: w, baseZ: 0))
        #expect(p.openYawDeg == p.closedYawDeg)
    }
}

// MARK: - Commands and persistence

@MainActor
struct OpeningDetailCommandTests {
    @Test func detailDefaultsDependOnKind() throws {
        let w = CTWorld()
        let wall = try w.wall(P2(0, 0), P2(4000, 0))
        let d = try w.opening(wall, offset: 1000)
        let win = try w.opening(wall, offset: 3000, kind: .window)
        #expect(w.p.opening(d)?.style == .smooth && w.p.opening(d)?.handle == OpeningHandle.none)
        #expect(w.p.opening(win)?.style == .fixed)
        #expect(w.p.opening(d)?.frameWidth == 50 && w.p.opening(d)?.glassType == .clear)
    }

    @Test func updateAndUndo() throws {
        let w = CTWorld()
        let wall = try w.wall(P2(0, 0), P2(4000, 0))
        let d = try w.opening(wall, offset: 2000)
        try w.store.run("Detail") {
            try $0.updateOpening(d, style: .panel4, handle: .lever, frameWidth: 80, mullionCols: 2, mullionRows: 3, glassType: .frosted)
        }
        let o = try #require(w.p.opening(d))
        #expect(o.style == .panel4 && o.handle == .lever && o.frameWidth == 80 && o.mullionCols == 2 && o.mullionRows == 3 && o.glassType == .frosted)
        try w.store.undo()
        let u = try #require(w.p.opening(d))
        #expect(u.style == .smooth && u.handle == .none && u.frameWidth == 50 && u.mullionCols == 0 && u.glassType == .clear)
    }

    @Test func invalidDetailIsRejectedWithoutChange() throws {
        let w = CTWorld()
        let wall = try w.wall(P2(0, 0), P2(4000, 0))
        let d = try w.opening(wall, offset: 2000)
        let before = w.p
        #expect(throws: (any Error).self) { try w.store.run("x") { try $0.updateOpening(d, style: .tiltTurn1) } }
        #expect(throws: (any Error).self) { try w.store.run("x") { try $0.updateOpening(d, frameWidth: 10) } }
        #expect(throws: (any Error).self) { try w.store.run("x") { try $0.updateOpening(d, frameWidth: 400) } }
        #expect(throws: (any Error).self) { try w.store.run("x") { try $0.updateOpening(d, mullionCols: 7) } }
        #expect(throws: (any Error).self) { try w.store.run("x") { try $0.updateOpening(d, mullionRows: -1) } }
        #expect(w.p.opening(d) == before.opening(d))
    }

    @Test func changingKindResetsAnInvalidStyle() throws {
        let w = CTWorld()
        let wall = try w.wall(P2(0, 0), P2(4000, 0))
        let d = try w.opening(wall, offset: 2000)
        try w.store.run("Style") { try $0.updateOpening(d, style: .sliding) }
        try w.store.run("Kind") { try $0.updateOpening(d, kind: .window) }
        #expect(w.p.opening(d)?.style == .fixed)
        try w.store.run("Both") { try $0.updateOpening(d, kind: .door, style: .glass) }
        #expect(w.p.opening(d)?.style == .glass)
    }

    @Test func detailSurvivesSaveAndLoad() throws {
        var p = Project.empty(name: "Detail")
        let wall = try p.addWall(levelId: p.levels[0].id, start: P2(0, 0), end: P2(4000, 0))
        let d = try p.addOpening(wallId: wall, kind: .door, width: 900, height: 2100, style: .glass, handle: .bar, frameWidth: 70,
                                 mullionCols: 1, mullionRows: 2, glassType: .tinted)
        let win = try p.addOpening(wallId: wall, kind: .window, width: 1000, height: 1000, style: .balconyDoor, handle: .knob)
        let (back, warnings) = try RoomsmithMarkdown.decode(RoomsmithMarkdown.encode(p))
        #expect(warnings.isEmpty, "\(warnings)")
        #expect(back == p)
        #expect(back.opening(d)?.style == .glass && back.opening(d)?.glassType == .tinted && back.opening(d)?.mullionRows == 2)
        #expect(back.opening(win)?.style == .balconyDoor && back.opening(win)?.handle == .knob)
    }

    @Test func outOfRangeDetailInAFileIsClamped() throws {
        var p = Project.empty(name: "Wild")
        let wall = try p.addWall(levelId: p.levels[0].id, start: P2(0, 0), end: P2(4000, 0))
        let d = try p.addOpening(wallId: wall, kind: .window, width: 1000, height: 1000)
        var m = Material(name: "Wild", color: RGBColor(1, 2, 3)); m.pattern = .tiles
        _ = p.addMaterial(m)
        var text = RoomsmithMarkdown.encode(p)
        // Poison the new columns with the cell values of the encoded rows.
        text = Self.rewriteCells(text, ["frameWidth": "9999999", "mullionCols": "1000000", "mullionRows": "-4",
                                        "clearcoat": "50", "specular": "-3", "grout": "5000", "patternSize": "0"])
        let (back, _) = try RoomsmithMarkdown.decode(text)
        let o = try #require(back.opening(d))
        #expect(o.frameWidth == 150 && o.mullionCols == 6 && o.mullionRows == 0)
        let mat = try #require(back.materials.first)
        #expect(mat.clearcoat == 1 && mat.specular == 0 && mat.grout == 100 && mat.patternSize == 1)
        // The validator also refuses such an opening if it gets into a project another way.
        var bad = p
        bad.openings[0].mullionCols = 1_000_000
        #expect(throws: (any Error).self) { try Validator.checkOpenings(of: bad.walls[0], in: bad) }
    }

    private static func rewriteCells(_ text: String, _ values: [String: String]) -> String {
        var lines = text.components(separatedBy: "\n")
        var cols: [String] = []
        for i in lines.indices {
            let line = lines[i]
            guard line.hasPrefix("|") else { cols = []; continue }
            var c = Self.cells(line)
            if i > 0, !lines[i - 1].hasPrefix("|") { cols = c.map { $0.trimmingCharacters(in: .whitespaces) } }
            else if !cols.isEmpty, !line.contains("---") {
                for (k, name) in cols.enumerated() { if let v = values[name], k < c.count { c[k] = " \(v) " } }
            }
            lines[i] = "|" + c.joined(separator: "|") + "|"
        }
        return lines.joined(separator: "\n")
    }

    @Test func oldFileWithoutNewColumnsGetsDefaults() throws {
        var p = Project.empty(name: "Old")
        let wall = try p.addWall(levelId: p.levels[0].id, start: P2(0, 0), end: P2(4000, 0))
        let d = try p.addOpening(wallId: wall, kind: .door, width: 900, height: 2100, style: .glass, handle: .bar, frameWidth: 70)
        let m = Material(name: "Old oak", color: RGBColor(10, 20, 30))
        _ = p.addMaterial(m)
        // Remove the new columns from every table by rewriting the text through the encoder's own header names.
        let text = RoomsmithMarkdown.encode(p)
        let stripped = Self.dropColumns(text, ["style", "handle", "frameWidth", "mullionCols", "mullionRows", "glass",
                                               "preset", "finish", "pattern", "color2", "patternSize", "patternAngle", "grout",
                                               "clearcoat", "specular"])
        #expect(stripped != text)
        let (old, warnings) = try RoomsmithMarkdown.decode(stripped)
        #expect(warnings.isEmpty, "\(warnings)")
        let o = try #require(old.opening(d))
        #expect(o.style == .smooth && o.handle == .none && o.frameWidth == 50 && o.mullionCols == 0 && o.glassType == .clear)
        let mat = try #require(old.material(m.id))
        #expect(mat.finish == .matte && mat.pattern == .none && mat.preset == nil && mat.color2 == nil)
        #expect(mat.clearcoat == 0 && mat.specular == 0.5 && mat.patternSize == 100 && mat.grout == 3)
    }

    /// Removes the named columns from every Markdown table row (header, separator and data), splitting on unescaped pipes.
    private static func dropColumns(_ text: String, _ names: Set<String>) -> String {
        var lines = text.components(separatedBy: "\n")
        var drop: [Int] = []
        for i in lines.indices {
            let line = lines[i]
            guard line.hasPrefix("|") else { drop = []; continue }
            var cells = Self.cells(line)
            if i > 0, !lines[i - 1].hasPrefix("|") {
                drop = cells.indices.filter { names.contains(cells[$0].trimmingCharacters(in: .whitespaces)) }
            }
            for k in drop.reversed() where k < cells.count { cells.remove(at: k) }
            lines[i] = "|" + cells.joined(separator: "|") + "|"
        }
        return lines.joined(separator: "\n")
    }

    private static func cells(_ line: String) -> [String] {
        var out: [String] = [], cur = "", escaped = false
        let body = line.dropFirst()
        for ch in body {
            if escaped { cur.append(ch); escaped = false; continue }
            if ch == "\\" { cur.append(ch); escaped = true; continue }
            if ch == "|" { out.append(cur); cur = ""; continue }
            cur.append(ch)
        }
        return out
    }

    @Test func materialPresetAppliesAndUndoes() throws {
        let w = CTWorld()
        var id = UUID()
        try w.store.run("Mat") { id = $0.addMaterial(Material(name: "Floor", color: RGBColor(1, 2, 3))) }
        try w.store.run("Preset") { try $0.applyMaterialPreset(id, preset: "tiles-white") }
        let m = try #require(w.p.material(id))
        #expect(m.pattern == .tiles && m.finish == .polished && m.preset == "tiles-white" && m.clearcoat > 0)
        try w.store.undo()
        let u = try #require(w.p.material(id))
        #expect(u.pattern == .none && u.preset == nil && u.color == RGBColor(1, 2, 3))
        #expect(throws: (any Error).self) { try w.store.run("Bad") { try $0.applyMaterialPreset(id, preset: "nope") } }
    }

    @Test func presetsAreUniqueAndSelfConsistent() {
        let ids = MaterialPresets.all.map(\.id)
        #expect(Set(ids).count == ids.count && ids.count >= 15)
        for pr in MaterialPresets.all {
            #expect(MaterialPresets.preset(pr.id)?.id == pr.id)
            var m = Material(name: "t", color: RGBColor(100, 100, 100))
            MaterialPresets.apply(pr, to: &m)
            #expect(m.roughness >= 0 && m.roughness <= 1 && m.clearcoat >= 0 && m.clearcoat <= 1 && m.specular >= 0 && m.specular <= 1)
            #expect(m.patternSize >= 1 && m.grout >= 0)
        }
        #expect(MaterialPresets.preset("TILES-WHITE")?.id == "tiles-white")
        #expect(MaterialPresets.preset("Wood, oak")?.id == "wood-oak")
        #expect(MaterialPresets.preset("missing") == nil)
    }

    @Test func materialDetailSurvivesSaveAndLoad() throws {
        var p = Project.empty(name: "Mat")
        var m = Material(name: "Brushed | steel", color: RGBColor(120, 125, 130))
        m.preset = "metal-brushed"; m.finish = .brushed; m.pattern = .grid; m.color2 = RGBColor(9, 8, 7)
        m.patternSize = 250; m.patternAngleDeg = 45.5; m.grout = 6; m.clearcoat = 0.25; m.specular = 0.75
        _ = p.addMaterial(m)
        let (back, warnings) = try RoomsmithMarkdown.decode(RoomsmithMarkdown.encode(p))
        #expect(warnings.isEmpty, "\(warnings)")
        #expect(back.materials.first == m)
    }
}

// MARK: - Procedural texture

struct ProceduralTextureTests {
    @Test func isDeterministicAndDependsOnParameters() {
        for pattern in MaterialPattern.allCases where pattern != .none {
            let a = ProceduralTexture.Params(pattern: pattern, color1: RGBColor(200, 180, 150), color2: RGBColor(90, 60, 30),
                                             tileMM: 1000, cellMM: 100, groutMM: 4)
            let f1 = ProceduralTexture.fingerprint(ProceduralTexture.render(a))
            let f2 = ProceduralTexture.fingerprint(ProceduralTexture.render(a))
            #expect(f1 == f2, "\(pattern)")
            var b = a; b.color1 = RGBColor(10, 20, 30)
            #expect(ProceduralTexture.fingerprint(ProceduralTexture.render(b)) != f1, "\(pattern)")
            #expect(ProceduralTexture.cgImage(ProceduralTexture.render(a)) != nil)
        }
    }

    @Test func tilesShowGroutAndStripesAlternate() {
        let c1 = RGBColor(240, 240, 240), c2 = RGBColor(10, 10, 10)
        let tiles = ProceduralTexture.render(.init(pattern: .tiles, color1: c1, color2: c2, tileMM: 1000, cellMM: 250, groutMM: 20))
        #expect(tiles.pixel(0, 0).r == 10)
        #expect(tiles.pixel(tiles.width / 8, tiles.height / 8).r > 150)
        let stripes = ProceduralTexture.render(.init(pattern: .stripes, color1: c1, color2: c2, tileMM: 1000, cellMM: 500, groutMM: 0))
        #expect(stripes.pixel(10, 5).r == 240 && stripes.pixel(stripes.width / 2 - 10, 5).r == 10)
    }

    @Test func noPatternHasNoParameters() {
        let m = Material(name: "Plain", color: RGBColor(1, 2, 3))
        #expect(ProceduralTexture.params(for: m) == nil)
        var p = m; p.pattern = .wood
        #expect(ProceduralTexture.params(for: p)?.pattern == .wood)
    }

    @Test func fabricWeaveRepeatsWithinTheTile() {
        let px = ProceduralTexture.render(.init(pattern: .fabric, color1: RGBColor(200, 160, 110), color2: RGBColor(100, 70, 40),
                                                tileMM: 1000, cellMM: 125, groutMM: 0))
        for (x, y) in [(5, 5), (40, 70), (100, 300)] {
            #expect(abs(Int(px.pixel(x, y).r) - Int(px.pixel(x + 128, y).r)) < 20)
            #expect(abs(Int(px.pixel(x, y).r) - Int(px.pixel(x, y + 128).r)) < 20)
        }
    }

    @Test func woodAndLeatherTileSeamlessly() {
        for pattern in [MaterialPattern.wood, .leather] {
            let px = ProceduralTexture.render(.init(pattern: pattern, color1: RGBColor(200, 160, 110), color2: RGBColor(100, 70, 40),
                                                    tileMM: 1000, cellMM: 125, groutMM: 0))
            // Compare the seam (last and first column) with an ordinary neighbouring pair: it must not be a much harder edge.
            func diff(_ x0: Int, _ x1: Int) -> Double {
                var s = 0.0
                for y in 0..<px.height { s += abs(Double(px.pixel(x0, y).r) - Double(px.pixel(x1, y).r)) }
                return s / Double(px.height)
            }
            var typical = 0.0
            for x in stride(from: 8, to: px.width - 8, by: 37) { typical = max(typical, diff(x, x + 1)) }
            #expect(diff(px.width - 1, 0) <= typical + 12, "\(pattern)")
        }
    }

    @Test func flatImageGivesAStraightNormalAndFullRoughness() throws {
        let flat = ProceduralTexture.Pixels(width: 8, height: 8, rgba: [UInt8](repeating: 140, count: 8 * 8 * 4))
        let maps = try #require(ProceduralTexture.surfaceMaps(flat, pattern: .wood))
        for y in 0..<8 { for x in 0..<8 {
            let n = maps.normal.pixel(x, y)
            #expect(n.r == 128 && n.g == 128 && n.b == 255)
            #expect(maps.roughness.pixel(x, y).r == 255)
        } }
        #expect(ProceduralTexture.surfaceMaps(flat, pattern: .stripes) == nil)
        #expect(ProceduralTexture.surfaceMaps(flat, pattern: .grid) == nil)
        #expect(ProceduralTexture.surfaceMaps(flat, pattern: .none) == nil)
    }

    @Test func reliefFollowsBrightnessAndWrapsAround() throws {
        // A dark vertical groove in column 0 of a bright image. Right of it the surface rises towards +x, so the normal
        // leans to -x; across the wrap (last column) it leans to +x; the rows stay level.
        let w = 16
        var rgba = [UInt8](repeating: 220, count: w * w * 4)
        for y in 0..<w { for c in 0..<3 { rgba[(y * w) * 4 + c] = 20 } }
        let maps = try #require(ProceduralTexture.surfaceMaps(.init(width: w, height: w, rgba: rgba), pattern: .tiles))
        let right = maps.normal.pixel(1, 5), left = maps.normal.pixel(w - 1, 5), far = maps.normal.pixel(8, 5)
        #expect(right.r < 126 && left.r > 130, "\(right) \(left)")
        #expect(right.g == 128 && left.g == 128)
        #expect(far.r == 128 && far.b == 255)
        // The groove itself keeps the full roughness, bright surface is smoother.
        #expect(maps.roughness.pixel(0, 5).r == 255 && maps.roughness.pixel(8, 5).r < 255)
    }

    @Test func surfaceMapsAreDeterministicForEveryReliefPattern() throws {
        for pattern in [MaterialPattern.wood, .fabric, .leather, .tiles] {
            let p = ProceduralTexture.Params(pattern: pattern, color1: RGBColor(200, 160, 110), color2: RGBColor(100, 70, 40),
                                             tileMM: 1000, cellMM: 125, groutMM: 2)
            let px = ProceduralTexture.render(p, side: 64)
            let a = try #require(ProceduralTexture.surfaceMaps(px, pattern: pattern))
            #expect(a == ProceduralTexture.surfaceMaps(px, pattern: pattern))
            // There is relief somewhere.
            #expect(stride(from: 0, to: a.normal.rgba.count, by: 4).contains { a.normal.rgba[$0] != 128 }, "\(pattern)")
        }
    }
}

// MARK: - Shading

struct MaterialShadingTests {
    @Test func brushedMetalIsAnisotropicAndPolishedIsNot() {
        var m = Material(name: "m", color: RGBColor(150, 150, 150), roughness: 0.4, metallic: 1)
        m.finish = .brushed
        let brushed = MaterialShading.resolve(m)
        m.finish = .polished
        let polished = MaterialShading.resolve(m)
        #expect(brushed.anisotropy > 0 && polished.anisotropy == 0)
        #expect(abs(brushed.roughness - 0.4) < 1e-12 && abs(polished.roughness - 0.2) < 1e-12)
        #expect(polished.clearcoat >= 0.3 && brushed.clearcoat == 0)
        m.patternAngleDeg = 30
        #expect(MaterialShading.resolve(m).anisotropyAngleDeg == 30)
    }
}
