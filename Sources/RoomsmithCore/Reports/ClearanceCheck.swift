import Foundation
import simd

/// Rule set of the clearance check. All lengths in mm.
public struct ClearanceRules: Codable, Sendable, Equatable {
    /// Gaps between two pieces, or a piece and a wall, narrower than this are reported (walkway too tight).
    public var minWalkwayMM: Double = 600
    /// Depth of the free strip required in front of each door opening (door width wide), on both sides. On the swing
    /// side the strip is skipped when the swing sector (radius = door width) already reaches this depth.
    public var doorApproachMM: Double = 900
    /// Report furniture inside the door swing: a quarter-circle sector of radius door width on the swing side,
    /// hinged at the wall face (same hinge/leaf convention as the plan export).
    public var checkDoorSwing: Bool = true
    /// Gaps below this are treated as flush (touching) and not reported. Raise it to ignore dead gaps too.
    public var ignoreGapBelowMM: Double = 1
    public init() {}
}

public struct ClearanceFinding: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case furnitureGap, wallGap, doorApproach, doorSwing }
    public enum OtherKind: String, Codable, Sendable { case furniture, wall, door }
    public var kind: Kind
    public var levelId: UUID
    /// The furniture instance the finding is about.
    public var instanceId: UUID
    /// Other instance, wall or door (opening) id, see `otherKind`.
    public var otherId: UUID
    public var otherKind: OtherKind
    /// Shortest distance between the footprint and the other object (0 when overlapping).
    public var distanceMM: Double
    /// The limit that was undercut.
    public var limitMM: Double
    /// True when the footprint overlaps the other object (or the door zone) instead of just being close.
    public var overlaps: Bool
    /// Where it happens: midpoint of the closest points (rounded to mm).
    public var position: P2
}

/// Exact distance between convex polygons (corner lists in mm).
public enum ClearanceGeometry {
    public struct Result: Sendable, Equatable {
        public var distance: Double
        public var overlaps: Bool
        public var pointA: V2
        public var pointB: V2
    }

    /// Convex polygons: overlap by separating axis test (touching is not overlap), otherwise the minimum of all
    /// vertex-to-edge distances, which is exact for disjoint convex polygons.
    public static func distance(_ a: [V2], _ b: [V2], epsilon: Double = 1e-6) -> Result {
        if overlap(a, b, epsilon: epsilon) {
            let ca = centroid(a), cb = centroid(b)
            return Result(distance: 0, overlaps: true, pointA: ca, pointB: cb)
        }
        var best = Result(distance: .infinity, overlaps: false, pointA: a[0], pointB: b[0])
        func scan(_ pts: [V2], _ poly: [V2], flip: Bool) {
            for p in pts {
                for i in poly.indices {
                    let r = Geo.pointSegment(p, poly[i], poly[(i + 1) % poly.count])
                    if r.distance < best.distance {
                        best = Result(distance: r.distance, overlaps: false, pointA: flip ? r.closest : p, pointB: flip ? p : r.closest)
                    }
                }
            }
        }
        scan(a, b, flip: false)
        scan(b, a, flip: true)
        return best
    }

    public static func distance(_ a: OrientedRect, _ b: OrientedRect) -> Result { distance(a.corners, b.corners) }

    static func overlap(_ a: [V2], _ b: [V2], epsilon: Double) -> Bool {
        for poly in [a, b] {
            for i in poly.indices {
                let e = poly[(i + 1) % poly.count] - poly[i]
                guard simd_length_squared(e) > 0 else { continue }
                let axis = simd_normalize(V2(-e.y, e.x))
                let pa = a.map { simd_dot($0, axis) }, pb = b.map { simd_dot($0, axis) }
                if pa.max()! <= pb.min()! + epsilon || pb.max()! <= pa.min()! + epsilon { return false }
            }
        }
        return true
    }

    static func centroid(_ pts: [V2]) -> V2 { pts.reduce(V2.zero, +) / Double(pts.count) }

    /// Distance between segment s0–s1 and a convex polygon (0 when they intersect).
    static func segmentDistance(_ s0: V2, _ s1: V2, _ poly: [V2]) -> Result {
        func cross(_ o: V2, _ p: V2, _ q: V2) -> Double { (p.x - o.x) * (q.y - o.y) - (p.y - o.y) * (q.x - o.x) }
        var hit = Geo.contains(poly, s0) || Geo.contains(poly, s1)
        if !hit {
            for i in poly.indices {
                let c = poly[i], d = poly[(i + 1) % poly.count]
                if cross(s0, s1, c) * cross(s0, s1, d) < 0 && cross(c, d, s0) * cross(c, d, s1) < 0 { hit = true; break }
            }
        }
        if hit { return Result(distance: 0, overlaps: true, pointA: (s0 + s1) / 2, pointB: centroid(poly)) }
        var best = Result(distance: .infinity, overlaps: false, pointA: s0, pointB: poly[0])
        for p in [s0, s1] {
            for i in poly.indices {
                let r = Geo.pointSegment(p, poly[i], poly[(i + 1) % poly.count])
                if r.distance < best.distance { best = Result(distance: r.distance, overlaps: false, pointA: p, pointB: r.closest) }
            }
        }
        for p in poly {
            let r = Geo.pointSegment(p, s0, s1)
            if r.distance < best.distance { best = Result(distance: r.distance, overlaps: false, pointA: r.closest, pointB: p) }
        }
        return best
    }
}

/// Clearance and walkway check on the 2D footprints (exact rotated rectangles).
///
/// - Furniture to furniture and furniture to wall: gap in `(ignoreGapBelowMM, minWalkwayMM)` is reported as
///   `furnitureGap` / `wallGap`; an overlap is reported with distance 0 and `overlaps = true`; flush contact and
///   gaps at or above the limit are silent. Pieces only count against each other when their height ranges overlap
///   (a wall cabinet above a table is no obstacle) and not inside one furniture group.
/// - Walls are solid except where a door or sill-free opening cuts them (windows stay solid).
/// - Doors: a strip of door width × `doorApproachMM` on each side, plus the swing sector (quarter circle, radius door
///   width, hinge on the wall face at the start or, when flipped, the end of the opening) on the swing side. The
///   sector is a 24-segment polygon circumscribing the circle, so it never under-reports. Furniture that reaches into
///   a zone gets the distance to the door line (`distanceMM`, 0 when it touches the door line). `overlaps` is always
///   true for a swing finding (the piece stands in the swing area) and for an approach finding only when the piece
///   reaches the door line itself. A piece already reported as swing for a door is not also reported as approach for
///   the same door and side.
public enum ClearanceCheck {
    public static func run(_ p: Project, rules: ClearanceRules = ClearanceRules(), levelId: UUID? = nil) -> [ClearanceFinding] {
        var out: [ClearanceFinding] = []
        for level in p.levels where levelId == nil || level.id == levelId {
            out.append(contentsOf: runLevel(p, level: level, rules: rules))
        }
        out.sort {
            ($0.distanceMM, $0.instanceId.uuidString, $0.otherId.uuidString, $0.kind.rawValue)
                < ($1.distanceMM, $1.instanceId.uuidString, $1.otherId.uuidString, $1.kind.rawValue)
        }
        return out
    }

    private struct Item {
        var inst: FurnitureInstance
        var corners: [V2]
        var lo: V2, hi: V2
        var z0: Double, z1: Double
    }

    private static func runLevel(_ p: Project, level: Level, rules: ClearanceRules) -> [ClearanceFinding] {
        let defs = Dictionary(p.definitions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var items: [Item] = []
        for inst in p.instances where inst.levelId == level.id && inst.visible {
            guard let def = defs[inst.definitionId] else { continue }
            let size = FurnitureResolver.size(of: inst, definition: def)
            let c = FurnitureResolver.footprint(of: inst, definition: def).corners
            items.append(Item(inst: inst, corners: c,
                              lo: V2(c.map(\.x).min()!, c.map(\.y).min()!), hi: V2(c.map(\.x).max()!, c.map(\.y).max()!),
                              z0: Double(inst.position.z), z1: Double(inst.position.z + size.height)))
        }
        var out: [ClearanceFinding] = []
        func mid(_ r: ClearanceGeometry.Result) -> P2 { P2(rounding: (r.pointA + r.pointB) / 2) }
        func near(_ i: Item, _ lo: V2, _ hi: V2, _ m: Double) -> Bool {
            !(i.hi.x + m < lo.x || hi.x + m < i.lo.x || i.hi.y + m < lo.y || hi.y + m < i.lo.y)
        }
        let limit = rules.minWalkwayMM

        // Furniture pairs
        for i in items.indices {
            for j in items.indices where j > i {
                let a = items[i], b = items[j]
                if let g = a.inst.groupId, g == b.inst.groupId { continue }
                guard a.z0 < b.z1, b.z0 < a.z1, near(a, b.lo, b.hi, limit) else { continue }
                let r = ClearanceGeometry.distance(a.corners, b.corners)
                guard r.overlaps || (r.distance >= rules.ignoreGapBelowMM && r.distance < limit) else { continue }
                out.append(ClearanceFinding(kind: .furnitureGap, levelId: level.id, instanceId: a.inst.id, otherId: b.inst.id,
                                            otherKind: .furniture, distanceMM: r.distance, limitMM: limit, overlaps: r.overlaps, position: mid(r)))
            }
        }

        // Walls
        let walls = p.walls.filter { $0.levelId == level.id }
        let outlines = WallOutline.compute(walls, levelId: level.id)
        var openingsByWall: [UUID: [Opening]] = [:]
        for o in p.openings { openingsByWall[o.wallId, default: []].append(o) }
        for w in walls {
            guard let outline = outlines[w.id] else { continue }
            let pieces = solidPieces(w, outline: outline, openings: openingsByWall[w.id] ?? [])
            for it in items {
                var best: ClearanceGeometry.Result?
                for piece in pieces {
                    let pl = V2(piece.map(\.x).min()!, piece.map(\.y).min()!), ph = V2(piece.map(\.x).max()!, piece.map(\.y).max()!)
                    guard near(it, pl, ph, limit) else { continue }
                    let r = ClearanceGeometry.distance(it.corners, piece)
                    if best == nil || r.distance < best!.distance { best = r }
                }
                guard let r = best, r.overlaps || (r.distance >= rules.ignoreGapBelowMM && r.distance < limit) else { continue }
                out.append(ClearanceFinding(kind: .wallGap, levelId: level.id, instanceId: it.inst.id, otherId: w.id,
                                            otherKind: .wall, distanceMM: r.distance, limitMM: limit, overlaps: r.overlaps, position: mid(r)))
            }
        }

        // Doors
        let wallById = Dictionary(walls.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for o in p.openings where o.kind == .door {
            guard let w = wallById[o.wallId] else { continue }
            let ax = Geo.axis(w.start, w.end)
            guard ax.length > 0 else { continue }
            let h = Double(w.thickness) / 2
            let s0 = Double(o.offset) - Double(o.width) / 2, s1 = Double(o.offset) + Double(o.width) / 2
            let swingSide = o.inward ? 1.0 : -1.0
            for side in [1.0, -1.0] {
                let n = ax.normal * side
                let a = w.start.v + ax.dir * s0 + n * h, b = w.start.v + ax.dir * s1 + n * h
                var zones: [(ClearanceFinding.Kind, Double)] = []
                let isSwing = side == swingSide && rules.checkDoorSwing
                if isSwing { zones.append((.doorSwing, Double(o.width))) }
                if !(isSwing && Double(o.width) >= rules.doorApproachMM), rules.doorApproachMM > 0 {
                    zones.append((.doorApproach, rules.doorApproachMM))
                }
                var swingHits = Set<UUID>()
                for (kind, depth) in zones {
                    let zone: [V2]
                    if kind == .doorSwing {
                        let hinge = o.flipped ? b : a
                        let closed = o.flipped ? -ax.dir : ax.dir
                        zone = swingSector(hinge: hinge, closed: closed, open: n, radius: Double(o.width))
                    } else {
                        zone = [a, b, b + n * depth, a + n * depth]
                    }
                    for it in items {
                        guard it.z0 < Double(o.sill + o.height), it.z1 > Double(o.sill) else { continue }
                        if kind == .doorApproach, swingHits.contains(it.inst.id) { continue }
                        guard ClearanceGeometry.overlap(it.corners, zone, epsilon: 1e-6) else { continue }
                        if kind == .doorSwing { swingHits.insert(it.inst.id) }
                        let r = ClearanceGeometry.segmentDistance(a, b, it.corners)
                        out.append(ClearanceFinding(kind: kind, levelId: level.id, instanceId: it.inst.id, otherId: o.id, otherKind: .door,
                                                    distanceMM: r.distance, limitMM: depth, overlaps: kind == .doorSwing || r.overlaps, position: mid(r)))
                    }
                }
            }
        }
        return out
    }

    /// Convex quarter-circle sector: the hinge plus 25 points from the closed leaf direction to the open direction.
    /// The radius is enlarged by 1/cos(half a segment) so the polygon circumscribes the true circle.
    private static func swingSector(hinge: V2, closed: V2, open: V2, radius: Double) -> [V2] {
        let segments = 24
        let r = radius / cos(Double.pi / Double(4 * segments))
        let sweep = (closed.x * open.y - closed.y * open.x) > 0 ? 90.0 : -90.0
        var pts = [hinge]
        for i in 0...segments { pts.append(hinge + Geo.rotate(closed, deg: sweep * Double(i) / Double(segments)) * r) }
        return pts
    }

    /// Wall quads without the stretches cut by doors and sill-free openings.
    private static func solidPieces(_ w: Wall, outline: WallOutline, openings: [Opening]) -> [[V2]] {
        let ax = Geo.axis(w.start, w.end)
        func quad(_ s0: Double, _ s1: Double) -> [V2] {
            [outline.facePoint(wall: w, s: s0, left: false), outline.facePoint(wall: w, s: s1, left: false),
             outline.facePoint(wall: w, s: s1, left: true), outline.facePoint(wall: w, s: s0, left: true)]
        }
        let cuts = openings.filter { $0.kind != .window && $0.sill <= 0 }
            .map { (max(0, Double($0.offset) - Double($0.width) / 2), min(ax.length, Double($0.offset) + Double($0.width) / 2)) }
            .sorted { $0.0 < $1.0 }
        var pieces: [[V2]] = []
        var cursor = 0.0
        for (c0, c1) in cuts where c1 > c0 {
            if c0 > cursor { pieces.append(quad(cursor, c0)) }
            cursor = max(cursor, c1)
        }
        if cursor < ax.length || pieces.isEmpty && cuts.isEmpty { pieces.append(quad(cursor, ax.length)) }
        return pieces
    }
}
