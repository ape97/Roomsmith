import Foundation
import simd

// Magnetic contact for dragged furniture: a moving piece stops flush at furniture, walls, door zones and door swings
// (the things the collision check paints red), is pulled flush when it ends up close to one, and pushes through when
// it is dragged clearly further. Pure geometry, shared by the 2D plan and the 3D view.

/// Footprint (and height range) of one dragged piece at its start position.
public struct ContactBody: Sendable, Equatable {
    public var rect: OrientedRect
    public var z0: Double
    public var z1: Double
    /// Outline of a round piece (convex, counter-clockwise). nil: the piece is its rectangle.
    public var polygon: [V2]?
    /// A swinging part of the piece (open door); it passes through the swinging parts of other pieces.
    public var swings: Bool
    public init(rect: OrientedRect, z0: Double, z1: Double, polygon: [V2]? = nil, swings: Bool = false) {
        self.rect = rect; self.z0 = z0; self.z1 = z1; self.polygon = polygon; self.swings = swings
    }
}

/// A convex obstacle in the floor plane with its height range. `id` is the furniture, wall or opening it belongs to.
public struct ContactObstacle: Sendable, Equatable {
    public var polygon: [V2]
    public var z0: Double
    public var z1: Double
    public var id: UUID?
    /// A swinging part of a piece in a moving state (open door).
    public var swings: Bool
    var lo: V2
    var hi: V2
    var normals: [V2]

    public init(polygon: [V2], z0: Double, z1: Double, id: UUID? = nil, swings: Bool = false) {
        self.polygon = polygon; self.z0 = z0; self.z1 = z1; self.id = id; self.swings = swings
        var lo = polygon.first ?? V2(0, 0), hi = lo
        for q in polygon.dropFirst() { lo = simd_min(lo, q); hi = simd_max(hi, q) }
        self.lo = lo; self.hi = hi
        self.normals = MoveContact.unitNormals(of: polygon)
    }
}

public struct ContactResult: Sendable, Equatable {
    /// Displacement in whole millimetres.
    public var delta: V2
    /// The piece stopped at or was pulled flush onto something.
    public var contact: Bool
    /// The faces it touches, for the plan to draw.
    public var guides: [SnapGuide]
    public init(delta: V2, contact: Bool, guides: [SnapGuide]) { self.delta = delta; self.contact = contact; self.guides = guides }
}

public enum MoveContact {
    /// Intervals closer than this count as touching (floating point noise).
    static let touch = 1e-6
    /// Overlap that the collision check ignores (`penetration`).
    static let margin = 0.5
    static let maxSlides = 3

    // MARK: Inputs from a project

    /// Footprints of the pieces that take part in a move. Free pieces (`allowsOverlap`, flat floor pieces) have no
    /// contact and are left out. Group ids expand to their members.
    public static func bodies(project p: Project, levelId: UUID, ids: Set<UUID>) -> [ContactBody] {
        var all = ids
        for g in p.groups where ids.contains(g.id) { all.formUnion(g.memberIds) }
        var out: [ContactBody] = []
        for inst in p.instances where all.contains(inst.id) && inst.levelId == levelId && inst.visible {
            guard let def = p.definition(inst.definitionId), !CollisionChecker.isFree(inst, definition: def) else { continue }
            let size = FurnitureResolver.size(of: inst, definition: def)
            let rect = FurnitureResolver.footprint(of: inst, definition: def)
            let z0 = Double(inst.position.z), z1 = Double(inst.position.z + size.height)
            // A piece in a moving state moves as its real parts (open doors), not as one rectangle around them.
            if let parts = FurnitureResolver.collisionParts(of: inst, definition: def) {
                for part in parts { out.append(ContactBody(rect: rect, z0: z0, z1: z1, polygon: part.outline, swings: part.swings)) }
            } else {
                out.append(ContactBody(rect: rect, z0: z0, z1: z1, polygon: FurnitureResolver.footprintPolygon(of: inst, definition: def)))
            }
        }
        return out
    }

    /// What a piece cannot be moved into: exactly the shapes the collision check reports (see `CollisionChecker`).
    /// `excluding` are the moving objects (groups expand; pieces of the same group never block each other).
    /// Built once per drag, not per mouse event.
    public static func obstacles(project p: Project, levelId: UUID, excluding: Set<UUID>) -> [ContactObstacle] {
        CollisionChecker.contactObstacles(p, levelId: levelId, excluding: excluding)
    }

    /// Like `obstacles(project:levelId:excluding:)`, limited to what the snap settings allow: walls, openings and door
    /// swings follow `toWalls`, other furniture follows `toObjects`. With `showLamps` false, lamp pieces are no obstacle
    /// (the 3D view hides them, see `Project.isInstanceShown`).
    public static func obstacles(project p: Project, levelId: UUID, excluding: Set<UUID>, toWalls: Bool, toObjects: Bool,
                                 showLamps: Bool = true) -> [ContactObstacle] {
        guard toWalls || toObjects else { return [] }
        let all = obstacles(project: p, levelId: levelId, excluding: excluding)
        if toWalls && toObjects && showLamps { return all }
        return all.filter { o in
            guard let inst = o.id.flatMap({ p.instance($0) }) else { return toWalls }
            return toObjects && p.isInstanceShown(inst, showLamps: showLamps)
        }
    }

    // MARK: Resolve

    /// Resolves a wanted displacement `raw` of the pieces `moving` against `obstacles`.
    ///
    /// - A piece stops flush where it would first touch an obstacle (swept separating-axis test). With `slide` the
    ///   rest of the movement continues along the touched face (at most 3 faces).
    /// - A piece that ends up within `tolerance` of a face, side by side, is pulled flush onto it.
    /// - Pushing further than `breakThrough` mm beyond the touching position goes through: the obstacle is ignored
    ///   and the piece follows `raw`. This is stateless; pulling back below the threshold snaps again.
    /// - Obstacles that already overlap the start position by more than the collision margin never block.
    /// - With `axis` the movement stays on that line (gizmo): faces whose normal is perpendicular to it neither
    ///   stop nor attract, and the result is always `t * axis`. `slide` is off then.
    public static func resolve(moving: [ContactBody], raw: V2, obstacles: [ContactObstacle], tolerance: Double,
                               breakThrough: Double = 200, slide: Bool, constrainedTo axis: V2? = nil) -> ContactResult {
        var ax: V2?
        if let a = axis, simd_length(a) > 1e-12 { ax = simd_normalize(a) }
        let rawV = ax.map { $0 * simd_dot(raw, $0) } ?? raw
        func rounded(_ d: V2) -> V2 {
            if let ax { return ax * simd_dot(d, ax).rounded() }
            return V2(d.x.rounded(), d.y.rounded())
        }
        guard !moving.isEmpty, !obstacles.isEmpty, simd_length(rawV) > 1e-9 else {
            return ContactResult(delta: rounded(rawV), contact: false, guides: [])
        }
        var solver = Solver(moving: moving, raw: rawV, obstacles: obstacles, tolerance: tolerance, breakThrough: breakThrough,
                            slide: slide && ax == nil, axis: ax)
        return solver.run(rounded: rounded)
    }

    // MARK: Solver

    private struct Body {
        var corners: [V2]
        var axes: [V2]
        var z0: Double
        var z1: Double
        var center: V2
        var swings: Bool
    }

    private struct Pair {
        var body: Int
        var obstacle: Int
    }

    private struct Hit {
        var t: Double
        var n: V2
        var pair: Int
        var fromObstacle: Bool
    }

    /// Where a pair of convex shapes would first touch, or nil.
    private struct Sweep {
        var t: Double
        var n: V2
        var fromObstacle: Bool
    }

    private struct Solver {
        var bodies: [Body] = []
        var obstacles: [ContactObstacle]
        var pairs: [Pair] = []
        var raw: V2
        var tolerance: Double
        var breakThrough: Double
        var slide: Bool
        var axis: V2?
        var ignored = Set<Int>()
        var disp = V2(0, 0)
        var contacts: [(pair: Int, n: V2, fromObstacle: Bool)] = []

        init(moving: [ContactBody], raw: V2, obstacles: [ContactObstacle], tolerance: Double, breakThrough: Double,
             slide: Bool, axis: V2?) {
            self.obstacles = obstacles; self.raw = raw; self.tolerance = max(tolerance, 0)
            self.breakThrough = breakThrough; self.slide = slide; self.axis = axis
            for m in moving {
                // A round piece moves as its polygon, like the collision check sees it.
                let c = m.polygon ?? m.rect.corners
                let ax = m.rect.axes
                bodies.append(Body(corners: c, axes: m.polygon.map { MoveContact.unitNormals(of: $0) } ?? [ax.0, ax.1], z0: m.z0, z1: m.z1,
                                   center: c.reduce(V2(0, 0), +) / Double(c.count), swings: m.swings))
            }
            // Broad phase: everything within reach of the movement (the slide can leave the raw line).
            let reach = simd_length(raw) + self.tolerance + 1
            for (bi, b) in bodies.enumerated() {
                var lo = b.corners[0], hi = b.corners[0]
                for q in b.corners.dropFirst() { lo = simd_min(lo, q); hi = simd_max(hi, q) }
                lo -= V2(repeating: reach); hi += V2(repeating: reach)
                for (oi, o) in obstacles.enumerated() where o.polygon.count >= 3 {
                    guard b.z0 < o.z1, o.z0 < b.z1 else { continue }
                    if b.swings && o.swings { continue } // open doors of two pieces pass each other (the check still reports deep crossings)
                    guard lo.x <= o.hi.x, o.lo.x <= hi.x, lo.y <= o.hi.y, o.lo.y <= hi.y else { continue }
                    pairs.append(Pair(body: bi, obstacle: oi))
                }
            }
            // Obstacles that already overlap the start position never block (nothing may get stuck).
            for (pi, p) in pairs.enumerated() where penetration(bodies[p.body].corners, obstacles[p.obstacle].polygon) != nil {
                ignored.insert(pi)
            }
        }

        // MARK: Sweep

        func sweep(_ pi: Int, rem v: V2) -> Sweep? {
            let p = pairs[pi]
            let a = bodies[p.body]
            let o = obstacles[p.obstacle]
            var tEnter = -Double.infinity, tExit = Double.infinity
            var enterAxis = V2(0, 0), enterFromObstacle = false
            // Overlap per axis at the start, for the "already touching" case.
            var shallow = Double.infinity, shallowAxis = V2(0, 0), shallowSide = 0.0
            var any = false
            func visit(_ m: V2, fromObstacle: Bool) -> Bool {
                let (a0, a1) = MoveContact.range(a.corners, m, offset: simd_dot(disp, m))
                let (b0, b1) = MoveContact.range(o.polygon, m, offset: 0)
                let vel = simd_dot(v, m)
                let ov = min(a1, b1) - max(a0, b0)
                if abs(vel) < 1e-9 {
                    if a1 <= b0 + MoveContact.touch || b1 <= a0 + MoveContact.touch { return false }
                } else {
                    let tA = (b0 - a1) / vel, tB = (b1 - a0) / vel
                    let near = min(tA, tB), far = max(tA, tB)
                    if near > tEnter { tEnter = near; enterAxis = vel > 0 ? -m : m; enterFromObstacle = fromObstacle }
                    tExit = min(tExit, far)
                }
                if ov < shallow {
                    shallow = ov; shallowAxis = m
                    shallowSide = (a0 + a1) / 2 - (b0 + b1) / 2
                }
                any = true
                return true
            }
            for m in a.axes { if !visit(m, fromObstacle: false) { return nil } }
            for m in o.normals { if !visit(m, fromObstacle: true) { return nil } }
            guard any, tEnter.isFinite, tExit > 0 else { return nil }
            if tEnter >= 0 {
                guard tEnter < tExit, tEnter < 1 else { return nil }
                return Sweep(t: tEnter, n: enterAxis, fromObstacle: enterFromObstacle)
            }
            // Overlapping at the start by no more than the collision margin counts as touching: it blocks only
            // movement into the obstacle (never a slide along it).
            guard shallow <= MoveContact.margin else { return nil }
            var n = shallowAxis
            if abs(shallowSide) > MoveContact.touch { if shallowSide < 0 { n = -n } }
            else if simd_dot(v, n) > 0 { n = -n }
            guard simd_dot(v, n) < -1e-9 else { return nil }
            let fromObstacle = o.normals.contains { simd_length_squared($0 - shallowAxis) < 1e-12 }
            return Sweep(t: 0, n: n, fromObstacle: fromObstacle)
        }

        // MARK: Magnet

        /// Largest gap over all axes, its normal (obstacle towards piece) and the second largest gap.
        func separation(_ pi: Int, at d: V2) -> (gap: Double, n: V2, second: Double, fromObstacle: Bool) {
            let p = pairs[pi]
            let a = bodies[p.body]
            let o = obstacles[p.obstacle]
            var best = -Double.infinity, second = -Double.infinity
            var bestN = V2(0, 0), bestFromObstacle = false
            var seen: [V2] = []
            func visit(_ m: V2, fromObstacle: Bool) {
                // Parallel axes of the two shapes are one direction.
                if seen.contains(where: { abs($0.x * m.y - $0.y * m.x) < 1e-9 }) { return }
                seen.append(m)
                let (a0, a1) = MoveContact.range(a.corners, m, offset: simd_dot(d, m))
                let (b0, b1) = MoveContact.range(o.polygon, m, offset: 0)
                let up = a0 - b1, down = b0 - a1
                let g = max(up, down)
                if g > best { second = best; best = g; bestN = up >= down ? m : -m; bestFromObstacle = fromObstacle }
                else if g > second { second = g }
            }
            for m in a.axes { visit(m, fromObstacle: false) }
            for m in o.normals { visit(m, fromObstacle: true) }
            return (best, bestN, second, bestFromObstacle)
        }

        // MARK: Run

        mutating func run(rounded: (V2) -> V2) -> ContactResult {
            var rem = raw
            var contact = false
            for _ in 0..<MoveContact.maxSlides {
                var hits: [Hit] = []
                for pi in pairs.indices where !ignored.contains(pi) {
                    if let s = sweep(pi, rem: rem) { hits.append(Hit(t: s.t, n: s.n, pair: pi, fromObstacle: s.fromObstacle)) }
                }
                hits.sort { $0.t < $1.t }
                var chosen: Hit?
                for h in hits {
                    // How far the wanted end position lies behind the touching plane.
                    let touching = disp + rem * h.t
                    if -simd_dot(raw - touching, h.n) > breakThrough { ignored.insert(h.pair); continue }
                    chosen = h
                    break
                }
                guard let h = chosen else { disp += rem; rem = V2(0, 0); break }
                contact = true
                disp += rem * h.t
                contacts.append((h.pair, h.n, h.fromObstacle))
                guard slide else { rem = V2(0, 0); break }
                var r = rem * (1 - h.t)
                r -= h.n * simd_dot(r, h.n)
                if simd_length(r) < 1e-9 { rem = V2(0, 0); break }
                rem = r
            }
            if tolerance > 0, magnet() { contact = true }

            var out = rounded(disp)
            if contact { out = flush(out, unrounded: disp, rounded: rounded) }
            return ContactResult(delta: out, contact: contact, guides: contact ? guides(at: out) : [])
        }

        /// Pulls the piece flush onto faces it ends up close to (side by side, one separating axis). At most two
        /// faces that are not parallel to each other or to a face it already touches (room corner).
        mutating func magnet() -> Bool {
            var normals = contacts.map(\.n)
            var applied = false
            for _ in 0..<2 {
                struct Cand { var pair: Int; var n: V2; var fromObstacle: Bool; var path: Double; var move: V2 }
                var best: Cand?
                for pi in pairs.indices where !ignored.contains(pi) {
                    let s = separation(pi, at: disp)
                    guard s.gap > 1e-9, s.second <= 1e-9, s.gap.isFinite else { continue }
                    guard !normals.contains(where: { abs(simd_dot($0, s.n)) > 0.5 }) else { continue }
                    let move: V2, path: Double
                    if let ax = axis {
                        let c = simd_dot(ax, s.n)
                        guard abs(c) > 1e-6 else { continue }
                        path = s.gap / abs(c)
                        move = ax * (c < 0 ? path : -path)
                    } else {
                        path = s.gap
                        move = -s.n * s.gap
                    }
                    guard path <= tolerance else { continue }
                    if axis != nil {
                        // The slanted move must really close the gap without opening another one.
                        let after = separation(pi, at: disp + move)
                        guard after.gap <= 1e-6 else { continue }
                    }
                    if best == nil || path < best!.path {
                        best = Cand(pair: pi, n: s.n, fromObstacle: s.fromObstacle, path: path, move: move)
                    }
                }
                guard let b = best else { break }
                disp += b.move
                normals.append(b.n)
                contacts.append((b.pair, b.n, b.fromObstacle))
                applied = true
            }
            return applied
        }

        // MARK: Rounding

        func penetrates(_ d: V2) -> Bool {
            for pi in pairs.indices where !ignored.contains(pi) {
                let p = pairs[pi]
                let moved = bodies[p.body].corners.map { $0 + d }
                if penetration(moved, obstacles[p.obstacle].polygon) != nil { return true }
            }
            return false
        }

        /// Whole millimetres must not turn a flush position into an overlap that the collision check reports:
        /// when plain rounding does, take the nearest neighbouring millimetre position that does not.
        func flush(_ plain: V2, unrounded u: V2, rounded: (V2) -> V2) -> V2 {
            guard penetrates(plain) else { return plain }
            var candidates: [V2] = []
            if let ax = axis {
                let t = simd_dot(u, ax)
                candidates = [ax * t.rounded(.down), ax * t.rounded(.up)]
            } else {
                for x in [u.x.rounded(.down), u.x.rounded(.up)] { for y in [u.y.rounded(.down), u.y.rounded(.up)] { candidates.append(V2(x, y)) } }
            }
            candidates.sort { simd_length_squared($0 - u) < simd_length_squared($1 - u) }
            return candidates.first { !penetrates($0) } ?? plain
        }

        // MARK: Guides

        func guides(at d: V2) -> [SnapGuide] {
            var out: [SnapGuide] = []
            for c in contacts {
                let p = pairs[c.pair]
                let o = obstacles[p.obstacle]
                if let g = MoveContact.face(of: o.polygon, facing: c.n, minimum: 0.99) {
                    out.append(g)
                } else {
                    let moved = bodies[p.body].corners.map { $0 + d }
                    if let g = MoveContact.face(of: moved, facing: -c.n, minimum: 0) { out.append(g) }
                }
            }
            return out
        }
    }

    // MARK: Helpers

    /// Unit edge normals of a convex polygon, parallel ones once.
    static func unitNormals(of poly: [V2]) -> [V2] {
        var out: [V2] = []
        for i in poly.indices {
            let e = poly[(i + 1) % poly.count] - poly[i]
            let l = simd_length(e)
            guard l > 1e-9 else { continue }
            let n = V2(-e.y, e.x) / l
            if out.contains(where: { abs($0.x * n.y - $0.y * n.x) < 1e-9 }) { continue }
            out.append(n)
        }
        return out
    }

    static func range(_ pts: [V2], _ m: V2, offset: Double) -> (Double, Double) {
        var lo = Double.infinity, hi = -Double.infinity
        for q in pts { let t = simd_dot(q, m); lo = min(lo, t); hi = max(hi, t) }
        return (lo + offset, hi + offset)
    }

    /// The edge of a convex polygon whose outward normal points most towards `dir`.
    static func face(of poly: [V2], facing dir: V2, minimum: Double) -> SnapGuide? {
        guard poly.count >= 2 else { return nil }
        let centroid = poly.reduce(V2(0, 0), +) / Double(poly.count)
        var best: (score: Double, guide: SnapGuide)?
        for i in poly.indices {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            let e = b - a
            let l = simd_length(e)
            guard l > 1e-9 else { continue }
            var n = V2(-e.y, e.x) / l
            if simd_dot(n, (a + b) / 2 - centroid) < 0 { n = -n }
            let s = simd_dot(n, dir)
            if best == nil || s > best!.score { best = (s, SnapGuide(from: a, to: b)) }
        }
        guard let b = best, b.score >= minimum else { return nil }
        return b.guide
    }
}
