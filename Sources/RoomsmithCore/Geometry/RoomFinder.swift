import Foundation

/// Finds the closed wall loop around a point (half-edge walk over the wall end points).
/// Shared by the plan tool (UI) and `geometry.create_room_from_walls` (agent).
public enum RoomFinder {
    public static func face(containing m: V2, walls: [Wall]) -> [P2]? {
        struct Edge: Hashable { var from: P2, to: P2 }
        var thickness: [Edge: MM] = [:]
        var out: [P2: [P2]] = [:]
        // Walls that end in the middle of another wall (T-junctions) split that wall there.
        let endpoints = Set(walls.flatMap { [$0.start, $0.end] })
        for w in walls {
            var chain: [(t: Double, p: P2)] = [(0, w.start), (1, w.end)]
            for q in endpoints where q != w.start && q != w.end {
                let hit = Geo.pointSegment(q.v, w.start.v, w.end.v)
                if hit.distance <= 1, hit.t > 0, hit.t < 1 { chain.append((hit.t, q)) }
            }
            chain.sort { $0.t < $1.t }
            for k in 0..<(chain.count - 1) {
                let a = chain[k].p, b = chain[k + 1].p
                guard a != b else { continue }
                out[a, default: []].append(b)
                out[b, default: []].append(a)
                thickness[Edge(from: a, to: b)] = w.thickness
                thickness[Edge(from: b, to: a)] = w.thickness
            }
        }
        func angle(_ a: P2, _ b: P2) -> Double { atan2(Double(b.y - a.y), Double(b.x - a.x)) }
        func next(_ e: Edge) -> Edge? {
            guard let cands = out[e.to] else { return nil }
            let back = angle(e.to, e.from)
            var best: (Edge, Double)?
            for c in cands {
                var delta = back - angle(e.to, c)
                while delta <= 1e-9 { delta += 2 * .pi }
                while delta > 2 * .pi + 1e-9 { delta -= 2 * .pi }
                if best == nil || delta < best!.1 { best = (Edge(from: e.to, to: c), delta) }
            }
            return best?.0
        }
        var visited = Set<Edge>()
        var bestFace: (verts: [P2], area: Double)?
        for start in thickness.keys where !visited.contains(start) {
            var loop: [Edge] = []
            var cur = start
            var closed = false
            for _ in 0..<(thickness.count + 1) {
                if visited.contains(cur) { closed = cur == start; break }
                visited.insert(cur)
                loop.append(cur)
                guard let n = next(cur) else { break }
                cur = n
                if cur == start { closed = true; break }
            }
            guard closed, loop.count >= 3 else { continue }
            let verts = loop.map(\.from)
            var a2 = 0.0
            for i in verts.indices {
                let p = verts[i], q = verts[(i + 1) % verts.count]
                a2 += Double(p.x) * Double(q.y) - Double(q.x) * Double(p.y)
            }
            guard a2 > 0 else { continue } // counter-clockwise = inner face
            guard Geo.contains(verts.map(\.v), m) else { continue }
            if bestFace == nil || a2 / 2 < bestFace!.area { bestFace = (verts, a2 / 2) }
        }
        guard let face = bestFace else { return nil }
        // Inset every edge by half its wall thickness (interior is on the left).
        let verts = face.verts
        let n = verts.count
        var lines: [(p: V2, d: V2)] = []
        for i in 0..<n {
            let a = verts[i], b = verts[(i + 1) % n]
            let t = Double(thickness[Edge(from: a, to: b)] ?? 0)
            let ax = Geo.axis(a, b)
            lines.append((a.v + ax.normal * (t / 2), b.v - a.v))
        }
        var poly: [P2] = []
        for i in 0..<n {
            let l0 = lines[(i + n - 1) % n], l1 = lines[i]
            if let x = Geo.lineIntersection(l0.p, l0.d, l1.p, l1.d) { poly.append(P2(rounding: x)) }
            else { poly.append(P2(rounding: l1.p)) }
        }
        var clean: [P2] = []
        for p in poly where p != clean.last { clean.append(p) }
        guard clean.count >= 3, Geo.isSimplePolygon(clean) else { return nil }
        return clean
    }
}
