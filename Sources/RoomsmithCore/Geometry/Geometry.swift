import Foundation
import simd

/// Floating-point point in mm, used only for derived geometry (outlines, rendering, hit tests).
/// Stored document values are always integer `P2`/`P3`.
public typealias V2 = SIMD2<Double>

public extension P2 {
    var v: V2 { V2(Double(x), Double(y)) }
    /// Rounds half away from zero – the single rounding rule used everywhere a derived value is stored.
    /// Never traps: a non-finite value or one beyond ±4e18 saturates to ±4e18 (NaN to +4e18). That is far outside
    /// `coordinateLimit`, so the validator rejects the result with OUT_OF_RANGE, yet ±1 neighbour searches cannot overflow.
    init(rounding v: V2) { self.init(MM.saturatingRounded(v.x), MM.saturatingRounded(v.y)) }
}

extension Int64 {
    /// Saturation bound for derived values that are rounded to whole mm (see `P2.init(rounding:)`).
    static let roundingSaturation: Int64 = 4_000_000_000_000_000_000

    /// Half away from zero; non-finite or beyond ±`roundingSaturation` saturates, never traps.
    static func saturatingRounded(_ d: Double) -> Int64 {
        if d.isNaN { return roundingSaturation }
        let limit = Double(roundingSaturation)
        if d >= limit { return roundingSaturation }
        if d <= -limit { return -roundingSaturation }
        return Int64(d.rounded(.toNearestOrAwayFromZero))
    }
}

public extension P2 {
    /// The integer point near `origin + dir * length` whose distance from `origin` is closest to `length`.
    /// Searches the 3x3 integer points around the exact point (ties: nearest to the exact point), so the
    /// stored length error stays at or below 0.5 mm; axis-parallel directions are exact. `dir` must be a unit vector.
    init(origin: P2, direction dir: V2, length: Double) {
        let exact = origin.v + dir * length
        let base = P2(rounding: exact)
        var best = base
        var bestErr = Double.infinity, bestDist = Double.infinity
        for dx in -1...1 {
            for dy in -1...1 {
                let c = P2(base.x + MM(dx), base.y + MM(dy))
                let err = abs(simd_length(c.v - origin.v) - length)
                let dist = simd_length(c.v - exact)
                if err < bestErr - 1e-9 || (abs(err - bestErr) <= 1e-9 && dist < bestDist) {
                    best = c; bestErr = err; bestDist = dist
                }
            }
        }
        self = best
    }
}

public enum Geo {
    /// Exact orientation of c relative to a→b: >0 left, <0 right, 0 collinear.
    /// Inputs are within ±1e8 mm, so differences fit 2e8 and products 4e16 – safely inside Int64.
    public static func orient(_ a: P2, _ b: P2, _ c: P2) -> Int64 {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    /// Exact segment intersection test (including touching endpoints).
    public static func segmentsIntersect(_ p1: P2, _ p2: P2, _ q1: P2, _ q2: P2) -> Bool {
        let d1 = orient(q1, q2, p1).signum(), d2 = orient(q1, q2, p2).signum()
        let d3 = orient(p1, p2, q1).signum(), d4 = orient(p1, p2, q2).signum()
        if d1 * d2 < 0 && d3 * d4 < 0 { return true }
        func onSeg(_ a: P2, _ b: P2, _ c: P2) -> Bool {
            min(a.x, b.x) <= c.x && c.x <= max(a.x, b.x) && min(a.y, b.y) <= c.y && c.y <= max(a.y, b.y)
        }
        if d1 == 0 && onSeg(q1, q2, p1) { return true }
        if d2 == 0 && onSeg(q1, q2, p2) { return true }
        if d3 == 0 && onSeg(p1, p2, q1) { return true }
        if d4 == 0 && onSeg(p1, p2, q2) { return true }
        return false
    }

    /// Exact squared distance between two points.
    public static func distanceSquared(_ a: P2, _ b: P2) -> Int64 {
        let dx = b.x - a.x, dy = b.y - a.y
        return dx * dx + dy * dy
    }

    public static func distance(_ a: P2, _ b: P2) -> Double { Double(distanceSquared(a, b)).squareRoot() }
    public static func distance(_ a: P3, _ b: P3) -> Double {
        let dx = Double(b.x - a.x), dy = Double(b.y - a.y), dz = Double(b.z - a.z)
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }

    /// Twice the signed area of a polygon, exact (Int128 avoids overflow for large plans).
    public static func twiceSignedArea(_ pts: [P2]) -> Int128 {
        guard pts.count >= 3 else { return 0 }
        var s: Int128 = 0
        for i in pts.indices {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            s += Int128(a.x) * Int128(b.y) - Int128(b.x) * Int128(a.y)
        }
        return s
    }

    /// Area in square millimetres (exact to 0.5 mm²).
    public static func area(_ pts: [P2]) -> Double { Double(abs(twiceSignedArea(pts))) / 2 }

    /// Polygon perimeter in mm.
    public static func perimeter(_ pts: [P2]) -> Double {
        guard pts.count >= 2 else { return 0 }
        var s = 0.0
        for i in pts.indices { s += distance(pts[i], pts[(i + 1) % pts.count]) }
        return s
    }

    /// True if the polygon edges do not cross each other (adjacent edges may share their vertex).
    public static func isSimplePolygon(_ pts: [P2]) -> Bool {
        let n = pts.count
        guard n >= 3 else { return false }
        if twiceSignedArea(pts) == 0 { return false }
        for i in 0..<n {
            let a1 = pts[i], a2 = pts[(i + 1) % n]
            if a1 == a2 { return false }
            for j in (i + 1)..<n {
                if j == i || (j + 1) % n == i || (i + 1) % n == j { continue }
                if segmentsIntersect(a1, a2, pts[j], pts[(j + 1) % n]) { return false }
            }
        }
        return true
    }

    /// Point in polygon (even-odd rule). Points exactly on the boundary count as inside.
    public static func contains(_ pts: [P2], _ p: P2) -> Bool {
        guard pts.count >= 3 else { return false }
        var inside = false
        var j = pts.count - 1
        for i in pts.indices {
            let a = pts[i], b = pts[j]
            if orient(a, b, p) == 0 && min(a.x, b.x) <= p.x && p.x <= max(a.x, b.x) && min(a.y, b.y) <= p.y && p.y <= max(a.y, b.y) { return true }
            if (a.y > p.y) != (b.y > p.y) {
                // x of edge at p.y compared exactly: (p.x - a.x) * (b.y - a.y) < (b.x - a.x) * (p.y - a.y), sign-adjusted
                let lhs = Int128(p.x - a.x) * Int128(b.y - a.y)
                let rhs = Int128(b.x - a.x) * Int128(p.y - a.y)
                if (b.y - a.y > 0) ? (lhs < rhs) : (lhs > rhs) { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    public static func contains(_ pts: [V2], _ p: V2) -> Bool {
        guard pts.count >= 3 else { return false }
        var inside = false
        var j = pts.count - 1
        for i in pts.indices {
            let a = pts[i], b = pts[j]
            if (a.y > p.y) != (b.y > p.y) {
                let x = a.x + (p.y - a.y) * (b.x - a.x) / (b.y - a.y)
                if p.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// Distance from p to segment a–b and the parameter t (0…1) of the closest point.
    public static func pointSegment(_ p: V2, _ a: V2, _ b: V2) -> (distance: Double, t: Double, closest: V2) {
        let ab = b - a
        let len2 = simd_length_squared(ab)
        let t = len2 > 0 ? max(0, min(1, simd_dot(p - a, ab) / len2)) : 0
        let c = a + ab * t
        return (simd_length(p - c), t, c)
    }

    /// Rotates v (mm) by `deg` counter-clockwise around the origin.
    public static func rotate(_ v: V2, deg: Double) -> V2 {
        let r = deg * .pi / 180
        let c = cos(r), s = sin(r)
        return V2(v.x * c - v.y * s, v.x * s + v.y * c)
    }

    /// Rotates an integer point around a pivot and rounds with the shared rounding rule.
    /// Multiples of 90° are handled exactly without trigonometry.
    public static func rotate(_ p: P2, around pivot: P2, deg: Double) -> P2 {
        let d = p - pivot
        let n = Angle.normalized(deg)
        let r: P2
        switch n {
        case 0: r = d
        case 90: r = P2(-d.y, d.x)
        case 180: r = P2(-d.x, -d.y)
        case 270: r = P2(d.y, -d.x)
        default: r = P2(rounding: rotate(d.v, deg: n))
        }
        return pivot + r
    }

    /// Unit direction and left normal of a wall axis.
    public static func axis(_ a: P2, _ b: P2) -> (dir: V2, normal: V2, length: Double) {
        let d = b.v - a.v
        let len = simd_length(d)
        guard len > 0 else { return (V2(1, 0), V2(0, 1), 0) }
        let dir = d / len
        return (dir, V2(-dir.y, dir.x), len)
    }

    /// Intersection of two infinite lines p + t*r and q + u*s. nil when parallel.
    public static func lineIntersection(_ p: V2, _ r: V2, _ q: V2, _ s: V2) -> V2? {
        let den = r.x * s.y - r.y * s.x
        guard abs(den) > 1e-12 else { return nil }
        let t = ((q.x - p.x) * s.y - (q.y - p.y) * s.x) / den
        return p + r * t
    }
}

/// Oriented rectangle in the floor plane (furniture footprint), in mm.
public struct OrientedRect: Sendable, Equatable {
    public var center: V2
    public var halfSize: V2
    public var rotationDeg: Double
    public init(center: V2, halfSize: V2, rotationDeg: Double) {
        self.center = center; self.halfSize = halfSize; self.rotationDeg = rotationDeg
    }
    public var axes: (V2, V2) {
        let r = rotationDeg * .pi / 180
        return (V2(cos(r), sin(r)), V2(-sin(r), cos(r)))
    }
    /// Corners counter-clockwise.
    public var corners: [V2] {
        let (ax, ay) = axes
        let ex = ax * halfSize.x, ey = ay * halfSize.y
        return [center - ex - ey, center + ex - ey, center + ex + ey, center - ex + ey]
    }
    public var bounds: (min: V2, max: V2) {
        let c = corners
        return (V2(c.map(\.x).min()!, c.map(\.y).min()!), V2(c.map(\.x).max()!, c.map(\.y).max()!))
    }
    public func contains(_ p: V2) -> Bool {
        let (ax, ay) = axes
        let d = p - center
        return abs(simd_dot(d, ax)) <= halfSize.x + 1e-9 && abs(simd_dot(d, ay)) <= halfSize.y + 1e-9
    }

    /// Separating axis test against a convex polygon. `margin` > 0 shrinks the overlap (touching does not count).
    public func overlaps(polygon other: [V2], margin: Double = 0.5) -> Bool {
        let mine = corners
        var axesToTest: [V2] = []
        for poly in [mine, other] {
            for i in poly.indices {
                let e = poly[(i + 1) % poly.count] - poly[i]
                if simd_length_squared(e) > 0 { axesToTest.append(simd_normalize(V2(-e.y, e.x))) }
            }
        }
        for axis in axesToTest {
            let a = mine.map { simd_dot($0, axis) }, b = other.map { simd_dot($0, axis) }
            if a.max()! <= b.min()! + margin || b.max()! <= a.min()! + margin { return false }
        }
        return true
    }
    public func overlaps(_ other: OrientedRect, margin: Double = 0.5) -> Bool { overlaps(polygon: other.corners, margin: margin) }
}
