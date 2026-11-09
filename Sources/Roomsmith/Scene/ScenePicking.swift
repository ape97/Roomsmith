import Foundation
import RoomsmithCore
import simd

/// Ray picking against the document (no RealityKit collision shapes, so nothing has to be kept in sync).
///
/// Furniture is tested per component against its unit box, walls against their oriented box (an opening that
/// shows a frame or glass is returned instead of the wall when the ray enters through it), rooms against the floor plane.
@MainActor
final class PickIndex {
    struct Entry {
        var levelId: UUID
        var bounds: Bounds3
        /// World-to-unit-box matrices of the visible components.
        var inverses: [simd_double4x4]
    }

    private var entries: [UUID: Entry] = [:]

    func invalidate(_ id: UUID) { entries[id] = nil }
    func invalidateAll() { entries.removeAll(keepingCapacity: true) }

    func entry(for inst: FurnitureInstance, project: Project) -> Entry? {
        if let e = entries[inst.id] { return e }
        guard let def = project.definition(inst.definitionId) else { return nil }
        let elevation = project.level(inst.levelId)?.elevation ?? 0
        let comps = FurnitureResolver.resolve(inst, definition: def, levelElevation: elevation).filter(\.visible)
        var bounds: Bounds3?
        var inverses: [simd_double4x4] = []
        for c in comps {
            let m = c.worldMatrix
            guard abs(m.determinant) > 1e-12 else { continue }
            inverses.append(m.inverse)
            for ix in [-0.5, 0.5] { for iy in [-0.5, 0.5] { for iz in [-0.5, 0.5] {
                let q = m * SIMD4(ix, iy, iz, 1)
                let p = D3(q.x, q.y, q.z)
                if bounds == nil { bounds = .around(p) } else { bounds!.extend(p) }
            } } }
        }
        guard let b = bounds else { return nil }
        let e = Entry(levelId: inst.levelId, bounds: b, inverses: inverses)
        entries[inst.id] = e
        return e
    }

    // MARK: ray tests

    /// Ray against an axis-aligned box. Returns the entry distance (0 when starting inside).
    static func slab(_ o: D3, _ d: D3, lo: D3, hi: D3) -> Double? {
        var tmin = -Double.infinity, tmax = Double.infinity
        for a in 0..<3 {
            if abs(d[a]) < 1e-12 {
                if o[a] < lo[a] || o[a] > hi[a] { return nil }
            } else {
                var t1 = (lo[a] - o[a]) / d[a], t2 = (hi[a] - o[a]) / d[a]
                if t1 > t2 { swap(&t1, &t2) }
                tmin = max(tmin, t1); tmax = min(tmax, t2)
                if tmin > tmax { return nil }
            }
        }
        guard tmax >= 0 else { return nil }
        return max(tmin, 0)
    }

    struct Hit { var id: UUID; var t: Double; var levelId: UUID }

    /// Nearest object under the ray. `levelShown` filters hidden levels, `instanceShown` hidden pieces (lamps while off).
    func pick(origin: D3, dir: D3, project: Project, levelShown: (UUID) -> Bool,
              instanceShown: (FurnitureInstance) -> Bool = { _ in true }, includeFloors: Bool = true) -> Hit? {
        var best: Hit?
        func offer(_ id: UUID, _ t: Double, _ level: UUID) {
            if best == nil || t < best!.t { best = Hit(id: id, t: t, levelId: level) }
        }

        for inst in project.instances where inst.visible && levelShown(inst.levelId) && instanceShown(inst) {
            guard let e = entry(for: inst, project: project) else { continue }
            guard Self.slab(origin, dir, lo: e.bounds.lo, hi: e.bounds.hi) != nil else { continue }
            for inv in e.inverses {
                let o4 = inv * SIMD4(origin.x, origin.y, origin.z, 1)
                let d4 = inv * SIMD4(dir.x, dir.y, dir.z, 0)
                if let t = Self.slab(D3(o4.x, o4.y, o4.z), D3(d4.x, d4.y, d4.z), lo: D3(repeating: -0.5), hi: D3(repeating: 0.5)) {
                    offer(inst.id, t, inst.levelId)
                }
            }
        }

        var openingsByWall: [UUID: [Opening]] = [:]
        for o in project.openings { openingsByWall[o.wallId, default: []].append(o) }
        for w in project.walls where levelShown(w.levelId) {
            guard let level = project.level(w.levelId) else { continue }
            let ax = Geo.axis(w.start, w.end)
            guard ax.length > 0 else { continue }
            let elev = Double(level.elevation)
            let rel = D3(origin.x - Double(w.start.x), origin.y - Double(w.start.y), origin.z - elev)
            let lo = D3(rel.x * ax.dir.x + rel.y * ax.dir.y, rel.x * ax.normal.x + rel.y * ax.normal.y, rel.z)
            let ld = D3(dir.x * ax.dir.x + dir.y * ax.dir.y, dir.x * ax.normal.x + dir.y * ax.normal.y, dir.z)
            let half = max(Double(w.thickness) / 2, 1)
            guard let t = Self.slab(lo, ld, lo: D3(0, -half, 0), hi: D3(ax.length, half, Double(w.height))) else { continue }
            let p = lo + ld * t
            var passes = false
            for o in openingsByWall[w.id] ?? [] {
                let s0 = Double(o.offset) - Double(o.width) / 2, s1 = Double(o.offset) + Double(o.width) / 2
                let z0 = Double(o.sill), z1 = Double(o.sill + o.height)
                guard p.x >= s0, p.x <= s1, p.z >= z0, p.z <= z1 else { continue }
                if o.kind == .opening { passes = true } else { offer(o.id, t, w.levelId); passes = true }
            }
            if !passes { offer(w.id, t, w.levelId) }
        }

        if includeFloors, abs(dir.z) > 1e-9 {
            for r in project.rooms where r.showFloor && levelShown(r.levelId) && r.points.count >= 3 {
                let elev = Double(project.level(r.levelId)?.elevation ?? 0)
                let t = (elev - origin.z) / dir.z
                guard t > 0 else { continue }
                if let b = best, b.t <= t { continue }
                let x = origin.x + dir.x * t, y = origin.y + dir.y * t
                if Self.contains(r.points, x, y) { offer(r.id, t, r.levelId) }
            }
        }
        return best
    }

    static func contains(_ pts: [P2], _ x: Double, _ y: Double) -> Bool {
        var inside = false
        var j = pts.count - 1
        for i in 0..<pts.count {
            let a = pts[i], b = pts[j]
            let ay = Double(a.y), by = Double(b.y)
            if (ay > y) != (by > y) {
                let xi = (Double(b.x) - Double(a.x)) * (y - ay) / (by - ay) + Double(a.x)
                if x < xi { inside.toggle() }
            }
            j = i
        }
        return inside
    }
}
