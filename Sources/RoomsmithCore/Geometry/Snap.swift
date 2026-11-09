import Foundation
import simd

public enum SnapKind: String, Sendable {
    case none, grid, wallEndpoint, wallMidpoint, wallFace, wallAxis, roomVertex, angle, length, furnitureEdge
}

/// Helper line the editor draws while a snap is active.
public struct SnapGuide: Sendable, Equatable {
    public var from: V2
    public var to: V2
    public init(from: V2, to: V2) { self.from = from; self.to = to }
}

public struct SnapResult: Sendable, Equatable {
    public var point: P2
    public var kind: SnapKind
    public var guides: [SnapGuide]
    public var targetId: UUID?
    public init(point: P2, kind: SnapKind, guides: [SnapGuide] = [], targetId: UUID? = nil) {
        self.point = point; self.kind = kind; self.guides = guides; self.targetId = targetId
    }
}

/// Everything snapping needs from one level. Build once per drag with `make`, then call the engine per mouse move.
public struct SnapContext: Sendable {
    public var walls: [Wall]
    public var rooms: [Room]
    public var instances: [FurnitureInstance]
    public var definitions: [UUID: FurnitureDefinition]
    public var excludeIds: Set<UUID>
    /// Start point while drawing a wall (enables angle and length snapping).
    public var anchor: P2?

    public init(walls: [Wall] = [], rooms: [Room] = [], instances: [FurnitureInstance] = [],
                definitions: [UUID: FurnitureDefinition] = [:], excludeIds: Set<UUID> = [], anchor: P2? = nil) {
        self.walls = walls; self.rooms = rooms; self.instances = instances
        self.definitions = definitions; self.excludeIds = excludeIds; self.anchor = anchor
    }

    public static func make(project: Project, levelId: UUID, exclude: Set<UUID>) -> SnapContext {
        var defs: [UUID: FurnitureDefinition] = [:]
        let insts = project.instances.filter { $0.levelId == levelId && $0.visible && !exclude.contains($0.id) }
        for i in insts where defs[i.definitionId] == nil {
            if let d = project.definitions.first(where: { $0.id == i.definitionId }) { defs[d.id] = d }
        }
        return SnapContext(walls: project.walls.filter { $0.levelId == levelId && !exclude.contains($0.id) },
                           rooms: project.rooms.filter { $0.levelId == levelId && !exclude.contains($0.id) },
                           instances: insts, definitions: defs, excludeIds: exclude, anchor: nil)
    }
}

public enum SnapEngine {
    /// Point snapping for tools. `tolerance` in mm (the editor converts screen px to mm).
    /// Priority: wall endpoint > room vertex > midpoint > axis/face/furniture edge > angle/length from anchor > grid.
    public static func snapPoint(_ p: V2, context: SnapContext, settings: SnapSettings, tolerance: Double) -> SnapResult {
        let raw = P2(rounding: p)
        guard settings.enabled else { return SnapResult(point: raw, kind: .none) }

        struct Best { var rank: Int; var dist: Double; var point: V2; var kind: SnapKind; var guides: [SnapGuide]; var target: UUID? }
        var best: Best?
        func consider(_ rank: Int, _ point: V2, _ kind: SnapKind, _ guides: [SnapGuide] = [], _ target: UUID? = nil) {
            let dist = simd_length(point - p)
            guard dist <= tolerance else { return }
            if let b = best, (b.rank, b.dist) <= (rank, dist) { return }
            best = Best(rank: rank, dist: dist, point: point, kind: kind, guides: guides, target: target)
        }
        func consider(segment a: V2, _ b: V2, rank: Int, kind: SnapKind, target: UUID?) {
            let hit = Geo.pointSegment(p, a, b)
            consider(rank, hit.closest, kind, [SnapGuide(from: a, to: b)], target)
        }

        if settings.toWalls {
            for w in context.walls where !context.excludeIds.contains(w.id) {
                let a = w.start.v, b = w.end.v
                consider(0, a, .wallEndpoint, [], w.id)
                consider(0, b, .wallEndpoint, [], w.id)
                guard w.start != w.end else { continue }
                consider(2, (a + b) / 2, .wallMidpoint, [], w.id)
                consider(segment: a, b, rank: 3, kind: .wallAxis, target: w.id)
                let ax = Geo.axis(w.start, w.end)
                let off = ax.normal * (Double(w.thickness) / 2)
                consider(segment: a + off, b + off, rank: 3, kind: .wallFace, target: w.id)
                consider(segment: a - off, b - off, rank: 3, kind: .wallFace, target: w.id)
            }
            for r in context.rooms where !context.excludeIds.contains(r.id) {
                for pt in r.points { consider(1, pt.v, .roomVertex, [], r.id) }
            }
        }
        if settings.toObjects {
            for inst in context.instances where !context.excludeIds.contains(inst.id) {
                guard let def = context.definitions[inst.definitionId] else { continue }
                let c = FurnitureResolver.footprint(of: inst, definition: def).corners
                for i in c.indices { consider(segment: c[i], c[(i + 1) % c.count], rank: 3, kind: .furnitureEdge, target: inst.id) }
            }
        }
        if let b = best { return SnapResult(point: P2(rounding: b.point), kind: b.kind, guides: b.guides, targetId: b.target) }

        let grid = settings.grid > 0 ? settings.grid : 1
        if let anchor = context.anchor {
            let a = anchor.v
            let d = p - a
            let len = simd_length(d)
            if len > 0 {
                var dir = d / len
                var kind = SnapKind.length
                if settings.angleStep > 0 {
                    let deg = atan2(d.y, d.x) * 180 / .pi
                    let snapped = snapAngle(deg, step: settings.angleStep, enabled: true)
                    let r = snapped * .pi / 180
                    let sdir = V2(cos(r), sin(r))
                    // Only take the angle when the cursor is within tolerance of the snapped ray.
                    let perp = abs(d.x * sdir.y - d.y * sdir.x)
                    if perp <= tolerance { dir = sdir; kind = .angle }
                }
                let along = max(0, simd_dot(d, dir))
                let rounded = settings.toGrid ? Double(snapDelta(along, grid: grid, enabled: true)) : along.rounded(.toNearestOrAwayFromZero)
                let target = a + dir * rounded
                return SnapResult(point: P2(rounding: target), kind: kind, guides: [SnapGuide(from: a, to: target)], targetId: nil)
            }
        }
        if settings.toGrid {
            return SnapResult(point: P2(snapDelta(p.x, grid: grid, enabled: true), snapDelta(p.y, grid: grid, enabled: true)), kind: .grid)
        }
        return SnapResult(point: raw, kind: .none)
    }

    /// Rounds to the nearest multiple of `grid` (ties away from zero). Disabled: plain mm rounding.
    public static func snapDelta(_ d: Double, grid: MM, enabled: Bool) -> MM {
        guard d.isFinite else { return 0 }
        guard enabled, grid > 1 else { return MM(d.rounded(.toNearestOrAwayFromZero)) }
        return MM((d / Double(grid)).rounded(.toNearestOrAwayFromZero)) * grid
    }

    /// Snaps an angle to multiples of `step` degrees; result normalised to [0, 360).
    public static func snapAngle(_ deg: Double, step: Double, enabled: Bool) -> Double {
        guard deg.isFinite else { return 0 }
        guard enabled, step > 0 else { return Angle.normalized(deg) }
        return Angle.normalized((deg / step).rounded(.toNearestOrAwayFromZero) * step)
    }

    /// Docks a footprint edge flush onto a wall face when it is within `tolerance` (corner touching counts when the
    /// piece is not parallel). With `alignRotation` the piece is first turned parallel to the wall (nearest 90° step).
    /// A second, perpendicular wall (room corner) is applied in a second pass. The returned position is integer mm,
    /// chosen among the neighbours of the exact value so the face distance stays as small as possible.
    public static func snapFurniture(_ inst: FurnitureInstance, definition: FurnitureDefinition, proposed: P2,
                                     context: SnapContext, tolerance: Double, alignRotation: Bool)
        -> (position: P2, rotationDeg: Double, kind: SnapKind, guides: [SnapGuide]) {
        let local = FurnitureResolver.localFootprint(of: inst, definition: definition)
        func corners(_ c: V2, _ rot: Double) -> [V2] {
            let r = rot * .pi / 180
            let offset = V2(cos(r) * local.center.x - sin(r) * local.center.y, sin(r) * local.center.x + cos(r) * local.center.y)
            return OrientedRect(center: c + offset, halfSize: local.half, rotationDeg: rot).corners
        }

        var pos = proposed.v
        var rot = inst.rotationDeg
        var constraints: [(f0: V2, n: V2)] = []
        var guides: [SnapGuide] = []

        for pass in 0..<2 {
            struct Hit { var d: Double; var f0: V2; var n: V2; var rot: Double; var guide: SnapGuide }
            var best: Hit?
            for w in context.walls where !context.excludeIds.contains(w.id) && w.start != w.end {
                let ax = Geo.axis(w.start, w.end)
                let h = Double(w.thickness) / 2
                for side in [1.0, -1.0] {
                    let n = ax.normal * side
                    if pass == 1, let first = constraints.first, abs(simd_dot(n, first.n)) > 1e-3 { continue }
                    let f0 = w.start.v + n * h
                    var candRot = rot
                    if alignRotation && pass == 0 {
                        let wallDeg = atan2(ax.dir.y, ax.dir.x) * 180 / .pi
                        var delta = (rot - wallDeg).truncatingRemainder(dividingBy: 90)
                        if delta > 45 { delta -= 90 } else if delta < -45 { delta += 90 }
                        candRot = Angle.normalized(rot - delta)
                    }
                    guard simd_dot(pos - f0, n) > 0 else { continue }
                    let cs = corners(pos, candRot)
                    let d = cs.map { simd_dot($0 - f0, n) }.min()!
                    guard abs(d) <= tolerance else { continue }
                    let ts = cs.map { simd_dot($0 - w.start.v, ax.dir) }
                    guard ts.max()! > 0, ts.min()! < ax.length else { continue }
                    if best == nil || abs(d) < abs(best!.d) {
                        best = Hit(d: d, f0: f0, n: n, rot: candRot, guide: SnapGuide(from: f0, to: f0 + ax.dir * ax.length))
                    }
                }
            }
            guard let hit = best else { break }
            if pass == 0 { rot = hit.rot }
            pos -= hit.n * hit.d
            constraints.append((hit.f0, hit.n))
            guides.append(hit.guide)
        }
        guard !constraints.isEmpty else { return (proposed, inst.rotationDeg, .none, []) }

        let finalRot = Angle.normalized(rot)
        func cost(_ c: P2) -> Double {
            let cs = corners(c.v, finalRot)
            var s = 0.0
            for k in constraints { s += abs(cs.map { simd_dot($0 - k.f0, k.n) }.min()!) }
            return s + 1e-3 * simd_length(c.v - pos)
        }
        let base = P2(rounding: pos)
        var bestP = base, bestC = cost(base)
        for dx in -1...1 {
            for dy in -1...1 where dx != 0 || dy != 0 {
                let c = P2(base.x + MM(dx), base.y + MM(dy))
                let k = cost(c)
                if k < bestC { bestC = k; bestP = c }
            }
        }
        return (bestP, finalRot, .wallFace, guides)
    }
}
