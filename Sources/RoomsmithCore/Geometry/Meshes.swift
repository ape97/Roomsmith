import Foundation
import simd

typealias V3 = SIMD3<Double>

public enum MeshRole: Sendable, Hashable {
    case wallLeft, wallRight, wallTop, wallSide, floor, ceiling, openingFrame, glass, glassFrosted, glassTinted, hardware
    /// White window hardware (handles, hinges); door hardware stays `.hardware` (metal).
    case windowHardware
    case component(UUID)
}

public struct MeshPart: Sendable {
    public var role: MeshRole
    public var indexRange: Range<Int>
    public init(role: MeshRole, indexRange: Range<Int>) { self.role = role; self.indexRange = indexRange }
}

/// Renderer-independent triangle mesh. World mm, Z up, triangles counter-clockwise seen from outside.
public struct MeshData: Sendable {
    public var positions: [SIMD3<Double>]
    public var normals: [SIMD3<Double>]
    /// Texture coordinates in mm (the renderer divides by the material's tile size).
    public var uvs: [SIMD2<Double>]
    public var indices: [UInt32]
    public var parts: [MeshPart]

    public init(positions: [SIMD3<Double>] = [], normals: [SIMD3<Double>] = [], uvs: [SIMD2<Double>] = [],
                indices: [UInt32] = [], parts: [MeshPart] = []) {
        self.positions = positions; self.normals = normals; self.uvs = uvs; self.indices = indices; self.parts = parts
    }

    public var isEmpty: Bool { indices.isEmpty }

    // MARK: building

    mutating func addPart(_ role: MeshRole, from start: Int) {
        guard indices.count > start else { return }
        if let last = parts.last, last.role == role, last.indexRange.upperBound == start {
            parts[parts.count - 1].indexRange = last.indexRange.lowerBound..<indices.count
        } else {
            parts.append(MeshPart(role: role, indexRange: start..<indices.count))
        }
    }

    /// Flat quad with four own vertices. Winding is chosen so the front side faces `normal`.
    mutating func addQuad(_ q: [V3], normal n: V3, role: MeshRole, uAxis: V3? = nil, vAxis: V3? = nil) {
        let start = indices.count
        var u = uAxis ?? (q[1] - q[0])
        if simd_length(u) < 1e-12 { u = q[2] - q[0] }
        u = simd_length(u) > 0 ? simd_normalize(u) : V3(1, 0, 0)
        let v = vAxis ?? simd_cross(n, u)
        let base = UInt32(positions.count)
        for p in q {
            positions.append(p); normals.append(n)
            uvs.append(SIMD2(simd_dot(p, u), simd_dot(p, v)))
        }
        let c = simd_cross(q[2] - q[0], q[3] - q[1])
        if simd_dot(c, n) < 0 {
            indices += [base, base + 2, base + 1, base, base + 3, base + 2]
        } else {
            indices += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        addPart(role, from: start)
    }

    /// Triangle over existing vertices; winding follows the vertex normals. Degenerate triangles are skipped.
    mutating func addTriangle(_ a: UInt32, _ b: UInt32, _ c: UInt32) {
        let pa = positions[Int(a)], pb = positions[Int(b)], pc = positions[Int(c)]
        let cr = simd_cross(pb - pa, pc - pa)
        if simd_length_squared(cr) < 1e-18 { return }
        let n = normals[Int(a)] + normals[Int(b)] + normals[Int(c)]
        if simd_dot(cr, n) >= 0 { indices += [a, b, c] } else { indices += [a, c, b] }
    }

    mutating func addVertex(_ p: V3, _ n: V3, _ uv: SIMD2<Double>) -> UInt32 {
        positions.append(p); normals.append(n); uvs.append(uv)
        return UInt32(positions.count - 1)
    }

    public mutating func append(_ other: MeshData) {
        let base = UInt32(positions.count)
        let offset = indices.count
        positions += other.positions; normals += other.normals; uvs += other.uvs
        indices += other.indices.map { $0 + base }
        for p in other.parts {
            parts.append(MeshPart(role: p.role, indexRange: (p.indexRange.lowerBound + offset)..<(p.indexRange.upperBound + offset)))
        }
    }

    /// Applies an affine transform (normals via the inverse transpose).
    public func transformed(_ m: simd_double4x4) -> MeshData {
        var r = self
        let l = simd_double3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                               SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                               SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        let nm = l.inverse.transpose
        r.positions = positions.map { p in
            let t = m * SIMD4(p.x, p.y, p.z, 1)
            return SIMD3(t.x, t.y, t.z)
        }
        r.normals = normals.map { n in
            let t = nm * n
            return simd_length(t) > 0 ? simd_normalize(t) : t
        }
        return r
    }

    /// Triangles of the same role end up contiguous (one part per role).
    func regrouped() -> MeshData {
        var order: [MeshRole] = []
        for p in parts where !order.contains(p.role) { order.append(p.role) }
        var r = self
        r.indices = []
        r.parts = []
        for role in order {
            let start = r.indices.count
            for p in parts where p.role == role { r.indices += indices[p.indexRange] }
            r.parts.append(MeshPart(role: role, indexRange: start..<r.indices.count))
        }
        return r
    }
}

public enum Meshes {
    /// Component id used by `unitPrimitive` when the caller passes none.
    public static let noComponent = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    // MARK: walls

    struct Cut { var s0: Double; var s1: Double; var z0: Double; var z1: Double }

    static func cuts(of wall: Wall, openings: [Opening], length: Double) -> [Cut] {
        let h = Double(wall.height)
        return openings.compactMap { o in
            guard o.wallId == wall.id else { return nil }
            let s0 = max(0, Double(o.offset) - Double(o.width) / 2)
            let s1 = min(length, Double(o.offset) + Double(o.width) / 2)
            let z0 = max(0, Double(o.sill))
            let z1 = min(h, Double(o.sill) + Double(o.height))
            guard s1 - s0 > 1e-9, z1 - z0 > 1e-9 else { return nil }
            return Cut(s0: s0, s1: s1, z0: z0, z1: z1)
        }
    }

    private static func merged(_ ranges: [(Double, Double)]) -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        for r in ranges.sorted(by: { $0.0 < $1.0 }) {
            if let last = out.last, r.0 <= last.1 + 1e-9 { out[out.count - 1].1 = max(last.1, r.1) } else { out.append(r) }
        }
        return out
    }

    /// Parts of `a` that are not in `b` (both sorted, disjoint).
    private static func subtract(_ a: [(Double, Double)], _ b: [(Double, Double)]) -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        for r in a {
            var cur = r.0
            for c in b where c.1 > cur && c.0 < r.1 {
                if c.0 > cur + 1e-9 { out.append((cur, c.0)) }
                cur = max(cur, c.1)
            }
            if r.1 > cur + 1e-9 { out.append((cur, r.1)) }
        }
        return out
    }

    /// Wall body with mitred ends, openings cut out and reveal faces (role .wallSide) inside the openings.
    public static func wall(_ w: Wall, outline: WallOutline, openings: [Opening], baseZ: MM) -> MeshData {
        let ax = Geo.axis(w.start, w.end)
        guard ax.length > 0, w.height > 0 else { return MeshData() }
        let length = ax.length, height = Double(w.height), z0 = Double(baseZ)
        let dir3 = V3(ax.dir.x, ax.dir.y, 0)
        let n3 = V3(ax.normal.x, ax.normal.y, 0)
        let up = V3(0, 0, 1)
        let cs = cuts(of: w, openings: openings, length: length)

        var breaks = [0, length]
        for c in cs { breaks += [c.s0, c.s1] }
        breaks.sort()
        var s: [Double] = []
        for b in breaks where s.isEmpty || b - s[s.count - 1] > 1e-9 { s.append(b) }
        if s.count < 2 { return MeshData() }

        func point(_ sv: Double, left: Bool, z: Double) -> V3 {
            let p = outline.facePoint(wall: w, s: sv, left: left)
            return V3(p.x, p.y, z0 + z)
        }
        // Solid z ranges of each interval between two break points.
        var solids: [[(Double, Double)]] = []
        for i in 0..<(s.count - 1) {
            let covering = cs.filter { $0.s0 <= s[i] + 1e-9 && $0.s1 >= s[i + 1] - 1e-9 }.map { ($0.z0, $0.z1) }
            solids.append(subtract([(0, height)], merged(covering)))
        }

        var mesh = MeshData()
        for i in 0..<(s.count - 1) {
            let sa = s[i], sb = s[i + 1]
            for (za, zb) in solids[i] {
                mesh.addQuad([point(sa, left: true, z: za), point(sb, left: true, z: za), point(sb, left: true, z: zb), point(sa, left: true, z: zb)],
                             normal: n3, role: .wallLeft, uAxis: dir3, vAxis: up)
                mesh.addQuad([point(sa, left: false, z: za), point(sb, left: false, z: za), point(sb, left: false, z: zb), point(sa, left: false, z: zb)],
                             normal: -n3, role: .wallRight, uAxis: dir3, vAxis: up)
                let topRole: MeshRole = zb >= height - 1e-9 ? .wallTop : .wallSide
                mesh.addQuad([point(sa, left: false, z: zb), point(sb, left: false, z: zb), point(sb, left: true, z: zb), point(sa, left: true, z: zb)],
                             normal: up, role: topRole, uAxis: dir3, vAxis: n3)
                mesh.addQuad([point(sa, left: false, z: za), point(sb, left: false, z: za), point(sb, left: true, z: za), point(sa, left: true, z: za)],
                             normal: -up, role: .wallSide, uAxis: dir3, vAxis: n3)
            }
        }
        // End caps (mitre planes).
        func cap(at sv: Double, ranges: [(Double, Double)], atEnd: Bool) {
            let r = outline.facePoint(wall: w, s: sv, left: false), l = outline.facePoint(wall: w, s: sv, left: true)
            let e = l - r
            var n = V3(e.y, -e.x, 0)
            if simd_length(n) == 0 { return }
            n = simd_normalize(n)
            if !atEnd { n = -n }
            for (za, zb) in ranges {
                mesh.addQuad([point(sv, left: false, z: za), point(sv, left: true, z: za), point(sv, left: true, z: zb), point(sv, left: false, z: zb)],
                             normal: n, role: .wallSide)
            }
        }
        cap(at: 0, ranges: solids[0], atEnd: false)
        cap(at: length, ranges: solids[solids.count - 1], atEnd: true)
        // Reveals between neighbouring intervals.
        for i in 1..<(s.count - 1) {
            let a = solids[i - 1], b = solids[i]
            for (za, zb) in subtract(a, b) {
                mesh.addQuad([point(s[i], left: false, z: za), point(s[i], left: true, z: za), point(s[i], left: true, z: zb), point(s[i], left: false, z: zb)],
                             normal: dir3, role: .wallSide)
            }
            for (za, zb) in subtract(b, a) {
                mesh.addQuad([point(s[i], left: false, z: za), point(s[i], left: true, z: za), point(s[i], left: true, z: zb), point(s[i], left: false, z: zb)],
                             normal: -dir3, role: .wallSide)
            }
        }
        return mesh.regrouped()
    }

    // MARK: rooms

    private static func horizontal(_ r: Room, z: MM, up: Bool, role: MeshRole) -> MeshData {
        let pts = r.points.map(\.v)
        let tri = Triangulate.earClip(pts)
        guard !tri.isEmpty else { return MeshData() }
        var m = MeshData()
        let n = V3(0, 0, up ? 1 : -1)
        for p in pts { m.positions.append(V3(p.x, p.y, Double(z))); m.normals.append(n); m.uvs.append(p) }
        var t = 0
        while t < tri.count {
            if up { m.indices += [UInt32(tri[t]), UInt32(tri[t + 1]), UInt32(tri[t + 2])] }
            else { m.indices += [UInt32(tri[t]), UInt32(tri[t + 2]), UInt32(tri[t + 1])] }
            t += 3
        }
        m.parts = [MeshPart(role: role, indexRange: 0..<m.indices.count)]
        return m
    }

    /// Floor polygon at absolute height `z`, facing up.
    public static func roomFloor(_ r: Room, z: MM) -> MeshData { horizontal(r, z: z, up: true, role: .floor) }
    /// Ceiling polygon at absolute height `z`, facing down.
    public static func roomCeiling(_ r: Room, z: MM) -> MeshData { horizontal(r, z: z, up: false, role: .ceiling) }

    // MARK: primitives

    /// Unit body spanning -0.5…0.5 on every axis (UVs in unit space; the world matrix scales it).
    /// `.cylinder` and `.taper` stand on Z, `.mesh` has no geometry of its own and falls back to the box. `.rounded`
    /// needs the part's `size` (mm) for its edge radius; without it (or when the radius would be under 1 mm) it is the box.
    public static func unitPrimitive(_ shape: PrimitiveShape, segments: Int = 32, component: UUID = noComponent,
                                     size: Size3? = nil) -> MeshData {
        let seg = max(segments, 4)
        var m: MeshData
        switch shape {
        case .box, .panel, .mesh: m = box()
        case .cushion: m = cushion(grid: max(2, seg / 8))
        case .cylinder: m = cylinder(segments: seg)
        case .sphere: m = sphere(segments: seg)
        case .taper: m = taper(segments: seg)
        case .rounded:
            if let size, roundedRadius(size) >= 1 { m = rounded(size) } else { m = box() }
        }
        m.parts = [MeshPart(role: .component(component), indexRange: 0..<m.indices.count)]
        return m
    }

    /// Top radius of `.taper` as a share of its bottom radius.
    public static let taperTop = 0.6
    /// Edge radius (mm) of a `.rounded` part of this size.
    public static func roundedRadius(_ size: Size3) -> Double {
        min(12, 0.3 * Double(max(min(size.width, size.depth, size.height), 0)))
    }

    /// Box with every edge and corner rounded by one radius in mm. Built in mm (same projection as the cushion), then
    /// divided by the size, so the world matrix brings it back; normals are pre-multiplied by the size so the merge's
    /// inverse-transpose turns them into the true mm normals. 6 × 6 grid per face: 216 vertices, 150 quads.
    private static func rounded(_ size: Size3) -> MeshData {
        let s = V3(Double(size.width), Double(size.depth), Double(size.height))
        let r = roundedRadius(size)
        let half = s * 0.5, flat = half - V3(repeating: r)
        func coords(_ a: Int) -> [Double] { [-half[a], -half[a] + r / 2, -flat[a], flat[a], half[a] - r / 2, half[a]] }
        var m = MeshData()
        for a in 0..<3 {
            let b = (a + 1) % 3, c = (a + 2) % 3
            for sign in [-1.0, 1.0] {
                var ids: [[UInt32]] = []
                for ub in coords(b) {
                    var row: [UInt32] = []
                    for vc in coords(c) {
                        let p = axisVector(a, half[a] * sign) + axisVector(b, ub) + axisVector(c, vc)
                        let inner = simd_clamp(p, -flat, flat)
                        let d = p - inner
                        let n = simd_length(d) > 1e-9 ? simd_normalize(d) : axisVector(a, sign)
                        let q = (inner + n * r) / s
                        row.append(m.addVertex(q, simd_normalize(n * s), SIMD2(q[b], q[c])))
                    }
                    ids.append(row)
                }
                for i in 0..<5 {
                    for j in 0..<5 {
                        m.addTriangle(ids[i][j], ids[i + 1][j], ids[i + 1][j + 1])
                        m.addTriangle(ids[i][j], ids[i + 1][j + 1], ids[i][j + 1])
                    }
                }
            }
        }
        return m
    }

    /// Frustum on Z: radius 0.5 at the bottom, `taperTop` × 0.5 at the top, with caps.
    private static func taper(segments: Int) -> MeshData {
        var m = MeshData()
        let rTop = 0.5 * taperTop
        var bottom: [UInt32] = [], top: [UInt32] = []
        for i in 0...segments {
            let t = Double(i) / Double(segments)
            let th = 2 * Double.pi * t
            let c = cos(th), s = sin(th)
            let n = simd_normalize(V3(c, s, 0.5 - rTop))
            bottom.append(m.addVertex(V3(0.5 * c, 0.5 * s, -0.5), n, SIMD2(t, 0)))
            top.append(m.addVertex(V3(rTop * c, rTop * s, 0.5), n, SIMD2(t, 1)))
        }
        for i in 0..<segments {
            m.addTriangle(bottom[i], bottom[i + 1], top[i + 1])
            m.addTriangle(bottom[i], top[i + 1], top[i])
        }
        for (z, nz, r) in [(0.5, 1.0, rTop), (-0.5, -1.0, 0.5)] {
            let centre = m.addVertex(V3(0, 0, z), V3(0, 0, nz), SIMD2(0.5, 0.5))
            var ring: [UInt32] = []
            for i in 0...segments {
                let th = 2 * Double.pi * Double(i) / Double(segments)
                ring.append(m.addVertex(V3(r * cos(th), r * sin(th), z), V3(0, 0, nz), SIMD2(0.5 + 0.5 * cos(th), 0.5 + 0.5 * sin(th))))
            }
            for i in 0..<segments { m.addTriangle(centre, ring[i], ring[i + 1]) }
        }
        return m
    }

    private static func axisVector(_ a: Int, _ v: Double) -> V3 {
        var r = V3(0, 0, 0)
        r[a] = v
        return r
    }

    private static func box() -> MeshData {
        var m = MeshData()
        for a in 0..<3 {
            let b = (a + 1) % 3, c = (a + 2) % 3
            for sign in [-1.0, 1.0] {
                func p(_ ub: Double, _ vc: Double) -> V3 { axisVector(a, 0.5 * sign) + axisVector(b, ub) + axisVector(c, vc) }
                m.addQuad([p(-0.5, -0.5), p(0.5, -0.5), p(0.5, 0.5), p(-0.5, 0.5)], normal: axisVector(a, sign), role: .wallSide,
                          uAxis: axisVector(b, 1), vAxis: axisVector(c, 1))
            }
        }
        return m
    }

    private static func cylinder(segments: Int) -> MeshData {
        var m = MeshData()
        var bottom: [UInt32] = [], top: [UInt32] = []
        for i in 0...segments {
            let t = Double(i) / Double(segments)
            let th = 2 * Double.pi * t
            let c = cos(th), s = sin(th)
            bottom.append(m.addVertex(V3(0.5 * c, 0.5 * s, -0.5), V3(c, s, 0), SIMD2(t, 0)))
            top.append(m.addVertex(V3(0.5 * c, 0.5 * s, 0.5), V3(c, s, 0), SIMD2(t, 1)))
        }
        for i in 0..<segments {
            m.addTriangle(bottom[i], bottom[i + 1], top[i + 1])
            m.addTriangle(bottom[i], top[i + 1], top[i])
        }
        for (z, nz) in [(0.5, 1.0), (-0.5, -1.0)] {
            let centre = m.addVertex(V3(0, 0, z), V3(0, 0, nz), SIMD2(0.5, 0.5))
            var ring: [UInt32] = []
            for i in 0...segments {
                let th = 2 * Double.pi * Double(i) / Double(segments)
                ring.append(m.addVertex(V3(0.5 * cos(th), 0.5 * sin(th), z), V3(0, 0, nz), SIMD2(0.5 + 0.5 * cos(th), 0.5 + 0.5 * sin(th))))
            }
            for i in 0..<segments { m.addTriangle(centre, ring[i], ring[i + 1]) }
        }
        return m
    }

    private static func sphere(segments: Int) -> MeshData {
        var m = MeshData()
        let rings = max(segments / 2, 2)
        var grid: [[UInt32]] = []
        for j in 0...rings {
            let theta = Double.pi * Double(j) / Double(rings)
            var row: [UInt32] = []
            for i in 0...segments {
                let phi = 2 * Double.pi * Double(i) / Double(segments)
                let n = V3(sin(theta) * cos(phi), sin(theta) * sin(phi), cos(theta))
                row.append(m.addVertex(n * 0.5, n, SIMD2(Double(i) / Double(segments), 1 - Double(j) / Double(rings))))
            }
            grid.append(row)
        }
        for j in 0..<rings {
            for i in 0..<segments {
                m.addTriangle(grid[j][i], grid[j + 1][i], grid[j + 1][i + 1])
                m.addTriangle(grid[j][i], grid[j + 1][i + 1], grid[j][i + 1])
            }
        }
        return m
    }

    /// Box with rounded edges and corners (radius 1/4 of the unit size).
    private static func cushion(grid k: Int) -> MeshData {
        let r = 0.25, flat = 0.5 - r
        var coords: [Double] = []
        for i in 0...k { coords.append(-0.5 + r * Double(i) / Double(k)) }
        for i in 0...k { coords.append(flat + r * Double(i) / Double(k)) }
        var m = MeshData()
        for a in 0..<3 {
            let b = (a + 1) % 3, c = (a + 2) % 3
            for sign in [-1.0, 1.0] {
                var ids: [[UInt32]] = []
                for ub in coords {
                    var row: [UInt32] = []
                    for vc in coords {
                        let p = axisVector(a, 0.5 * sign) + axisVector(b, ub) + axisVector(c, vc)
                        let inner = simd_clamp(p, V3(repeating: -flat), V3(repeating: flat))
                        let d = p - inner
                        let n = simd_length(d) > 1e-12 ? simd_normalize(d) : axisVector(a, sign)
                        row.append(m.addVertex(inner + n * r, n, SIMD2(p[b], p[c])))
                    }
                    ids.append(row)
                }
                for i in 0..<(coords.count - 1) {
                    for j in 0..<(coords.count - 1) {
                        m.addTriangle(ids[i][j], ids[i + 1][j], ids[i + 1][j + 1])
                        m.addTriangle(ids[i][j], ids[i + 1][j + 1], ids[i][j + 1])
                    }
                }
            }
        }
        return m
    }

    // MARK: door leaf

    /// Placement of a separate, swinging door leaf. `hinge` is the pivot in world mm (centre line of the wall, at the
    /// leaf edge next to the hinge jamb, z = `baseZ`); the leaf mesh is built around the origin with its local +x along
    /// the closed leaf direction, so a rotation about Z by `closedYawDeg` shows it closed and by `openYawDeg` open
    /// (90 degrees to the swing side, honouring `flipped` and `inward`).
    public struct DoorLeafPlacement: Sendable, Equatable {
        public var hinge: SIMD3<Double>
        public var closedYawDeg: Double
        public var openYawDeg: Double
        public var leafWidth: Double
    }

    /// Frame thickness (jamb / head) of an opening in mm, as used by `openingFrame`.
    public static func frameThickness(for o: Opening) -> Double {
        min(Double(o.frameWidth), Double(o.width) / 3, Double(o.height) / 3)
    }

    public static func doorLeafPlacement(_ o: Opening, wall: Wall, baseZ: MM) -> DoorLeafPlacement? {
        guard o.kind == .door else { return nil }
        let ax = Geo.axis(wall.start, wall.end)
        guard ax.length > 0, let cut = cuts(of: wall, openings: [o], length: ax.length).first else { return nil }
        let ft = min(Double(o.frameWidth), (cut.s1 - cut.s0) / 3, (cut.z1 - cut.z0) / 3)
        let sH = o.flipped ? cut.s1 - ft : cut.s0 + ft
        let closed = o.flipped ? -ax.dir : ax.dir
        let openDir = ax.normal * (o.inward ? 1.0 : -1.0)
        let closedYaw = atan2(closed.y, closed.x) * 180 / .pi
        let cross = closed.x * openDir.y - closed.y * openDir.x
        let p = wall.start.v + ax.dir * sH
        return DoorLeafPlacement(hinge: V3(p.x, p.y, Double(baseZ)), closedYawDeg: closedYaw,
                                 openYawDeg: o.style == .sliding ? closedYaw : closedYaw + (cross >= 0 ? 90 : -90), leafWidth: cut.s1 - cut.s0 - 2 * ft)
    }

    /// The door leaf alone, in hinge-local coordinates (see `DoorLeafPlacement`). Empty for non-doors.
    public static func doorLeaf(_ o: Opening, wall: Wall, baseZ: MM) -> MeshData {
        let ax = Geo.axis(wall.start, wall.end)
        guard o.kind == .door, ax.length > 0, let cut = cuts(of: wall, openings: [o], length: ax.length).first,
              let pl = doorLeafPlacement(o, wall: wall, baseZ: baseZ) else { return MeshData() }
        let ft = min(Double(o.frameWidth), (cut.s1 - cut.s0) / 3, (cut.z1 - cut.z0) / 3)
        let w = pl.leafWidth, z0 = cut.z0, z1 = cut.z1 - ft
        guard w > 0, z1 > z0 else { return MeshData() }
        var m = MeshData()
        OpeningDetail.addDoorLeaf(&m, o, local: .identity, width: w, z0: z0, z1: z1, swing: leafSwing(o))
        return m.regrouped()
    }

    /// +1 when the leaf swings toward its local +y side, otherwise -1.
    static func leafSwing(_ o: Opening) -> Double { (o.inward ? 1.0 : -1.0) * (o.flipped ? -1.0 : 1.0) }

    // MARK: opening frames

    /// Simple frame: door = jambs + head + closed leaf plate; window = frame + glass pane (role .glass).
    /// A plain `.opening` has no frame and returns an empty mesh.
    public static func openingFrame(_ o: Opening, wall: Wall, baseZ: MM, includeLeaf: Bool = true, includeSashes: Bool = true) -> MeshData {
        guard o.kind != .opening else { return MeshData() }
        let ax = Geo.axis(wall.start, wall.end)
        guard ax.length > 0 else { return MeshData() }
        guard let cut = cuts(of: wall, openings: [o], length: ax.length).first else { return MeshData() }
        let dir3 = V3(ax.dir.x, ax.dir.y, 0), n3 = V3(ax.normal.x, ax.normal.y, 0), up = V3(0, 0, 1)
        let origin = V3(Double(wall.start.x), Double(wall.start.y), Double(baseZ))
        let half = Double(wall.thickness) / 2
        let ft = min(Double(o.frameWidth), (cut.s1 - cut.s0) / 3, (cut.z1 - cut.z0) / 3)

        var m = MeshData()
        func box(_ s0: Double, _ s1: Double, _ n0: Double, _ n1: Double, _ z0: Double, _ z1: Double, _ role: MeshRole) {
            func c(_ s: Double, _ n: Double, _ z: Double) -> V3 { origin + dir3 * s + n3 * n + up * z }
            m.addQuad([c(s0, n0, z0), c(s0, n1, z0), c(s0, n1, z1), c(s0, n0, z1)], normal: -dir3, role: role)
            m.addQuad([c(s1, n0, z0), c(s1, n1, z0), c(s1, n1, z1), c(s1, n0, z1)], normal: dir3, role: role)
            m.addQuad([c(s0, n0, z0), c(s1, n0, z0), c(s1, n0, z1), c(s0, n0, z1)], normal: -n3, role: role)
            m.addQuad([c(s0, n1, z0), c(s1, n1, z0), c(s1, n1, z1), c(s0, n1, z1)], normal: n3, role: role)
            m.addQuad([c(s0, n0, z0), c(s1, n0, z0), c(s1, n1, z0), c(s0, n1, z0)], normal: -up, role: role)
            m.addQuad([c(s0, n0, z1), c(s1, n0, z1), c(s1, n1, z1), c(s0, n1, z1)], normal: up, role: role)
        }
        let s0 = cut.s0, s1 = cut.s1, z0 = cut.z0, z1 = cut.z1
        switch o.kind {
        case .door:
            let d = half + 10
            box(s0, s0 + ft, -d, d, z0, z1 - ft, .openingFrame)
            box(s1 - ft, s1, -d, d, z0, z1 - ft, .openingFrame)
            box(s0, s1, -d, d, z1 - ft, z1, .openingFrame)
            if includeLeaf {
                let closed = o.flipped ? -dir3 : dir3
                let sH = o.flipped ? s1 - ft : s0 + ft
                let l = OpeningDetail.Local(o: origin + dir3 * sH, x: closed, y: V3(-closed.y, closed.x, 0), z: up)
                OpeningDetail.addDoorLeaf(&m, o, local: l, width: s1 - s0 - 2 * ft, z0: z0, z1: z1 - ft, swing: leafSwing(o))
            }
        case .window:
            let l = OpeningDetail.Local(o: origin, x: dir3, y: n3, z: up)
            OpeningDetail.addWindow(&m, o, local: l, s0: s0, s1: s1, z0: z0, z1: z1, ft: ft, depth: min(half, WindowProfile.maxFrameHalfDepth),
                                       includeSashes: includeSashes)
        case .opening:
            break
        }
        return m.regrouped()
    }
}
