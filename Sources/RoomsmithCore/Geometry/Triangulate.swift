import Foundation
import simd

public enum Triangulate {
    /// Ear clipping of a simple polygon (any orientation, collinear and duplicate points tolerated).
    /// Returns triples of indices into `polygon`; every triangle is counter-clockwise in the plane.
    /// Collinear/duplicate vertices produce no triangle of their own, so the summed triangle area equals the polygon area.
    public static func earClip(_ polygon: [V2]) -> [Int] {
        let n = polygon.count
        guard n >= 3 else { return [] }
        var area2 = 0.0
        for i in 0..<n {
            let a = polygon[i], b = polygon[(i + 1) % n]
            area2 += a.x * b.y - b.x * a.y
        }
        guard area2 != 0 else { return [] }
        var idx = Array(0..<n)
        if area2 < 0 { idx.reverse() }

        let extent = polygon.reduce(0.0) { max($0, max(abs($1.x), abs($1.y))) }
        let eps = 1e-12 * max(1, extent * extent)
        func cross(_ a: V2, _ b: V2, _ c: V2) -> Double { (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) }
        func inside(_ p: V2, _ a: V2, _ b: V2, _ c: V2) -> Bool {
            cross(a, b, p) >= -eps && cross(b, c, p) >= -eps && cross(c, a, p) >= -eps
        }

        var out: [Int] = []
        out.reserveCapacity((n - 2) * 3)
        while idx.count > 3 {
            let m = idx.count
            var done = false
            // 1. a convex vertex whose triangle contains no other vertex
            for k in 0..<m {
                let ip = idx[(k + m - 1) % m], ic = idx[k], inx = idx[(k + 1) % m]
                let a = polygon[ip], b = polygon[ic], c = polygon[inx]
                if cross(a, b, c) <= eps { continue }
                var blocked = false
                for j in idx where j != ip && j != ic && j != inx {
                    let p = polygon[j]
                    if p == a || p == b || p == c { continue }
                    if inside(p, a, b, c) { blocked = true; break }
                }
                if !blocked {
                    out += [ip, ic, inx]
                    idx.remove(at: k)
                    done = true
                    break
                }
            }
            if done { continue }
            // 2. a collinear / duplicate vertex: drop it without a triangle
            for k in 0..<m {
                let a = polygon[idx[(k + m - 1) % m]], b = polygon[idx[k]], c = polygon[idx[(k + 1) % m]]
                if abs(cross(a, b, c)) <= eps {
                    idx.remove(at: k)
                    done = true
                    break
                }
            }
            if done { continue }
            // 3. self-intersecting input: clip the most convex vertex regardless of blockers
            var best = -1
            var bestCross = eps
            for k in 0..<m {
                let c = cross(polygon[idx[(k + m - 1) % m]], polygon[idx[k]], polygon[idx[(k + 1) % m]])
                if c > bestCross { bestCross = c; best = k }
            }
            if best < 0 { best = 0 } else {
                out += [idx[(best + m - 1) % m], idx[best], idx[(best + 1) % m]]
            }
            idx.remove(at: best)
        }
        if idx.count == 3, cross(polygon[idx[0]], polygon[idx[1]], polygon[idx[2]]) > eps {
            out += idx
        }
        return out
    }
}
