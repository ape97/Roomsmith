import Foundation
import simd

/// A non-blocking warning about furniture. `a` is always a furniture instance.
public struct CollisionIssue: Sendable, Equatable, Codable {
    public enum Kind: String, Codable, Sendable { case furnitureOverlap, furnitureWall, blocksOpening, outsideRooms }
    public var kind: Kind
    public var a: UUID
    /// Other furniture, wall (furnitureWall) or opening (blocksOpening); nil for outsideRooms.
    public var b: UUID?
    /// Approximate penetration depth in mm.
    public var depth: Double
    public init(kind: Kind, a: UUID, b: UUID? = nil, depth: Double) { self.kind = kind; self.a = a; self.b = b; self.depth = depth }
}

public enum CollisionChecker {
    /// Free pieces neither report nor receive collision warnings and never block a dragged piece: pieces flagged
    /// `allowsOverlap` and flat floor pieces such as rugs (underside on the floor, at most
    /// `WalkCollider.walkOverHeightMm` high). `outsideRooms` is not affected.
    static func isFree(_ inst: FurnitureInstance, definition: FurnitureDefinition) -> Bool {
        if inst.allowsOverlap { return true }
        return isFlatOnFloor(inst, definition: definition)
    }

    /// A flat piece lying on the floor (rug, mat): free without any flag. Computed, not stored.
    public static func isFlatOnFloor(_ inst: FurnitureInstance, definition: FurnitureDefinition) -> Bool {
        let size = FurnitureResolver.size(of: inst, definition: definition)
        return isFlatOnFloor(z: Double(inst.position.z), height: Double(size.height))
    }

    static func isFlatOnFloor(z: Double, height: Double) -> Bool { z <= 0 && height <= WalkCollider.walkOverHeightMm }

    /// Furniture ids that count as warned (tinted): overlap, wall and blocked-opening issues only.
    /// `outsideRooms` alone never warns. `b` is added only if it is a furniture instance of the project.
    public static func warnedIds(_ issues: [CollisionIssue], in p: Project) -> Set<UUID> {
        var out = Set<UUID>()
        for issue in issues {
            switch issue.kind {
            case .furnitureOverlap, .furnitureWall, .blocksOpening:
                out.insert(issue.a)
                if let b = issue.b, p.instance(b) != nil { out.insert(b) }
            case .outsideRooms: break
            }
        }
        return out
    }

    /// Collision warnings for one level. With `only`, just issues involving those ids (furniture, walls or openings)
    /// are computed, without building indexes for the whole level.
    public static func check(_ p: Project, levelId: UUID, only ids: Set<UUID>? = nil) -> [CollisionIssue] {
        Engine(project: p, levelId: levelId, only: ids).run()
    }
}

// MARK: - Engine

private struct FootItem {
    var id: UUID
    var groupId: UUID?
    /// Outline the piece collides with: the rectangle corners, or the polygon of a round piece (`FurnitureResolver.collisionOutline`).
    var corners: [V2]
    var lo: V2
    var hi: V2
    var z0: Double
    var z1: Double
    /// Never collides (see `CollisionChecker.isFree`).
    var free: Bool
}

private struct WallSeg {
    var opening: Opening?
    var bands: [WallBand]
    var poly: [V2]
    var lo: V2
    var hi: V2
}

private struct Swing {
    var opening: Opening
    var poly: [V2]
    var lo: V2
    var hi: V2
}

private struct WallInfo {
    var wall: Wall
    var segs: [WallSeg]
    var swings: [Swing]
    var lo: V2
    var hi: V2
}

private struct IssueKey: Hashable { var kind: CollisionIssue.Kind; var a: UUID; var b: UUID? }

private func bounds(of pts: [V2]) -> (lo: V2, hi: V2) {
    var lo = pts[0], hi = pts[0]
    for q in pts.dropFirst() { lo = simd_min(lo, q); hi = simd_max(hi, q) }
    return (lo, hi)
}

private func boxesOverlap(_ alo: V2, _ ahi: V2, _ blo: V2, _ bhi: V2) -> Bool {
    alo.x <= bhi.x && blo.x <= ahi.x && alo.y <= bhi.y && blo.y <= ahi.y
}

/// Height band of a wall segment: solid wall, or the passage of a door/opening (`solid == false`).
private struct WallBand {
    var z0: Double
    var z1: Double
    var opening: Opening?
    var solid: Bool
    func overlaps(z0 a: Double, z1 b: Double) -> Bool { a < z1 && z0 < b }
}

/// The bands of one wall segment, shared by the collision check and the drag obstacles so both agree on what is
/// solid. A plain segment is solid up to the wall height; an opening segment is solid below the sill and above the
/// head, a door or plain opening is a passage in between, a window leaves nothing to collide with there.
private func wallBands(opening: Opening?, wallHeight wh: Double) -> [WallBand] {
    guard let o = opening else { return [WallBand(z0: -.infinity, z1: wh, opening: nil, solid: true)] }
    let sill = Double(o.sill), top = Double(o.sill + o.height)
    var out = [WallBand(z0: 0, z1: sill, opening: o, solid: true)]
    if o.kind != .window { out.append(WallBand(z0: sill, z1: top, opening: o, solid: false)) }
    out.append(WallBand(z0: top, z1: wh, opening: o, solid: true))
    return out
}

/// Smallest overlap along all SAT axes (≈ penetration depth); nil when separated or only touching.
func penetration(_ a: [V2], _ b: [V2], margin: Double = 0.5) -> Double? {
    var minOverlap = Double.infinity
    for poly in [a, b] {
        for i in poly.indices {
            let e = poly[(i + 1) % poly.count] - poly[i]
            let l2 = simd_length_squared(e)
            guard l2 > 0 else { continue }
            let axis = V2(-e.y, e.x) / l2.squareRoot()
            var amin = Double.infinity, amax = -Double.infinity, bmin = Double.infinity, bmax = -Double.infinity
            for q in a { let t = simd_dot(q, axis); amin = min(amin, t); amax = max(amax, t) }
            for q in b { let t = simd_dot(q, axis); bmin = min(bmin, t); bmax = max(bmax, t) }
            let ov = min(amax, bmax) - max(amin, bmin)
            if ov <= margin { return nil }
            minOverlap = min(minOverlap, ov)
        }
    }
    return minOverlap.isFinite ? minOverlap : nil
}

/// Convex pieces of a quad (wall segments are convex unless a mitre folds over; then split at the reflex vertex).
private func convexPieces(_ q: [V2]) -> [[V2]] {
    guard q.count == 4 else { return [q] }
    var sign = 0.0, reflex: Int?
    for i in 0..<4 {
        let a = q[i], b = q[(i + 1) % 4], c = q[(i + 2) % 4]
        let cr = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
        if abs(cr) < 1e-9 { continue }
        if sign == 0 { sign = cr.sign == .minus ? -1 : 1 }
        else if (cr < 0) != (sign < 0) { reflex = (i + 1) % 4 }
    }
    guard let k = reflex else { return [q] }
    return [[q[k], q[(k + 1) % 4], q[(k + 2) % 4]], [q[k], q[(k + 2) % 4], q[(k + 3) % 4]]]
}

private final class Engine {
    let p: Project
    let levelId: UUID
    let only: Set<UUID>?

    var defs: [UUID: FurnitureDefinition] = [:]
    /// Indices into `p.instances` of visible level instances with a definition.
    var recs: [Int] = []
    var cache: [Int: FootItem] = [:]
    var groupOf: [UUID: UUID] = [:]

    var wallInfos: [WallInfo] = []
    var wallIndex = SpatialIndex()
    var instIndex = SpatialIndex()
    var rooms: [Room] = []
    var issues: [IssueKey: Double] = [:]

    init(project: Project, levelId: UUID, only: Set<UUID>?) {
        self.p = project; self.levelId = levelId; self.only = only
    }

    // MARK: footprints

    func item(_ ri: Int) -> FootItem {
        if let c = cache[ri] { return c }
        let inst = p.instances[recs[ri]]
        let def = defs[inst.definitionId]!
        let size = FurnitureResolver.size(of: inst, definition: def)
        let cs = FurnitureResolver.collisionOutline(of: inst, definition: def)
        let b = bounds(of: cs)
        let it = FootItem(id: inst.id, groupId: inst.groupId ?? groupOf[inst.id], corners: cs, lo: b.lo, hi: b.hi,
                          z0: Double(inst.position.z), z1: Double(inst.position.z + size.height),
                          free: CollisionChecker.isFree(inst, definition: def))
        cache[ri] = it
        return it
    }

    /// Cheap conservative box (no trigonometry) used by the brute-force broad phase.
    func looseBox(_ ri: Int) -> (V2, V2) {
        let inst = p.instances[recs[ri]]
        let l = FurnitureResolver.localFootprint(of: inst, definition: defs[inst.definitionId]!)
        let r = (l.half.x * l.half.x + l.half.y * l.half.y).squareRoot() + simd_length(l.center)
        let c = inst.position.xy.v
        return (c - V2(r, r), c + V2(r, r))
    }

    // MARK: walls

    func buildWallInfo(_ w: Wall, outline: WallOutline, openings: [Opening]) -> WallInfo {
        let ax = Geo.axis(w.start, w.end)
        let h = Double(w.thickness) / 2
        func seg(_ s0: Double, _ s1: Double, _ o: Opening?) -> WallSeg {
            let poly = s0 <= 0 && s1 >= ax.length && o == nil ? outline.polygon : [
                outline.facePoint(wall: w, s: s0, left: false), outline.facePoint(wall: w, s: s1, left: false),
                outline.facePoint(wall: w, s: s1, left: true), outline.facePoint(wall: w, s: s0, left: true)]
            let b = bounds(of: poly)
            return WallSeg(opening: o, bands: wallBands(opening: o, wallHeight: Double(w.height)), poly: poly, lo: b.lo, hi: b.hi)
        }
        var segs: [WallSeg] = []
        var cursor = 0.0
        let sorted = openings.sorted { $0.offset - $0.width / 2 < $1.offset - $1.width / 2 }
        for o in sorted {
            let s0 = max(cursor, min(ax.length, Double(o.offset) - Double(o.width) / 2))
            let s1 = max(s0, min(ax.length, Double(o.offset) + Double(o.width) / 2))
            if s0 > cursor { segs.append(seg(cursor, s0, nil)) }
            if s1 > s0 { segs.append(seg(s0, s1, o)) }
            cursor = max(cursor, s1)
        }
        if cursor < ax.length || segs.isEmpty { segs.append(seg(cursor, ax.length, nil)) }

        var swings: [Swing] = []
        for o in openings where o.kind == .door {
            let side = o.inward ? 1.0 : -1.0
            let n = ax.normal * side
            let s0 = Double(o.offset) - Double(o.width) / 2, s1 = Double(o.offset) + Double(o.width) / 2
            let a = w.start.v + ax.dir * s0 + n * h, b = w.start.v + ax.dir * s1 + n * h
            let depth = n * Double(o.width)
            let poly = [a, b, b + depth, a + depth]
            let bb = bounds(of: poly)
            swings.append(Swing(opening: o, poly: poly, lo: bb.lo, hi: bb.hi))
        }
        var all = outline.polygon
        for s in swings { all.append(contentsOf: s.poly) }
        let bb = bounds(of: all)
        return WallInfo(wall: w, segs: segs, swings: swings, lo: bb.lo, hi: bb.hi)
    }

    func openingsByWall() -> [UUID: [Opening]] {
        var m: [UUID: [Opening]] = [:]
        for o in p.openings { m[o.wallId, default: []].append(o) }
        return m
    }

    // MARK: pair checks

    func record(_ kind: CollisionIssue.Kind, _ a: UUID, _ b: UUID?, _ depth: Double) {
        let k = IssueKey(kind: kind, a: a, b: b)
        if let old = issues[k], old >= depth { return }
        issues[k] = depth
    }

    func checkWall(_ it: FootItem, _ info: WallInfo) {
        guard !it.free, boxesOverlap(it.lo, it.hi, info.lo, info.hi) else { return }
        let w = info.wall
        let wh = Double(w.height)
        if it.z0 < wh {
            var wallDepth: Double?
            for s in info.segs where boxesOverlap(it.lo, it.hi, s.lo, s.hi) {
                var solid = false, passage = false
                for b in s.bands where b.overlaps(z0: it.z0, z1: it.z1) { if b.solid { solid = true } else { passage = true } }
                guard solid || passage else { continue }
                for piece in convexPieces(s.poly) {
                    guard let d = penetration(it.corners, piece) else { continue }
                    if solid { wallDepth = max(wallDepth ?? 0, d) }
                    else if let o = s.opening { record(.blocksOpening, it.id, o.id, d) }
                }
            }
            if let d = wallDepth { record(.furnitureWall, it.id, w.id, d) }
        }
        checkSwings(it, info)
    }

    func checkSwings(_ it: FootItem, _ info: WallInfo) {
        for s in info.swings where boxesOverlap(it.lo, it.hi, s.lo, s.hi) {
            let o = s.opening
            guard it.z0 < Double(o.sill + o.height), it.z1 > Double(o.sill) else { continue }
            if let d = penetration(it.corners, s.poly) { record(.blocksOpening, it.id, o.id, d) }
        }
    }

    func checkPair(_ x: FootItem, _ y: FootItem, _ ix: Int, _ iy: Int) {
        if x.free || y.free { return }
        if let g = x.groupId, g == y.groupId { return }
        guard x.z0 < y.z1, y.z0 < x.z1, boxesOverlap(x.lo, x.hi, y.lo, y.hi) else { return }
        guard let d = penetration(x.corners, y.corners) else { return }
        // A piece standing on the other one (underside on a component top, footprint inside it) is not an overlap.
        if stands(x, on: iy, y) || stands(y, on: ix, x) { return }
        if ix < iy { record(.furnitureOverlap, x.id, y.id, d) } else { record(.furnitureOverlap, y.id, x.id, d) }
    }

    /// Components of an instance for the "standing on" test, computed once per piece and only when needed.
    var shapeCache: [Int: [TopViewShape]] = [:]

    func shapes(_ ri: Int) -> [TopViewShape] {
        if let c = shapeCache[ri] { return c }
        let inst = p.instances[recs[ri]]
        let s = FurnitureTopView.make(inst, definition: defs[inst.definitionId]!, colors: [:], levelElevation: 0).shapes
        shapeCache[ri] = s
        return s
    }

    /// `upper` rests on the instance `ri` (item `lower`): its underside lies within 1 mm of a top of `lower` and its
    /// outline is inside that top. Resting excuses the overlap only when the outline also clears every other component
    /// of `lower` that reaches into the height range of `upper` (a lid above, a side panel the piece sticks into).
    func stands(_ upper: FootItem, on ri: Int, _ lower: FootItem) -> Bool {
        guard upper.z0 > lower.z0 + RestingSurface.zTolerance, upper.z0 < lower.z1 + RestingSurface.zTolerance else { return false }
        let parts = shapes(ri)
        let surfaces = RestingSurface.surfaces(of: lower.id, shapes: parts)
        guard RestingSurface.supporting(upper.corners, z0: upper.z0, among: surfaces) != nil else { return false }
        return !RestingSurface.intrudes(upper.corners, z0: upper.z0, z1: upper.z1, shapes: parts)
    }

    func checkOutside(_ it: FootItem, _ inst: FurnitureInstance) {
        guard !rooms.isEmpty else { return }
        let c = inst.position.xy
        var dist = Double.infinity
        for r in rooms {
            if Geo.contains(r.points, c) { return }
            for i in r.points.indices {
                dist = min(dist, Geo.pointSegment(c.v, r.points[i].v, r.points[(i + 1) % r.points.count].v).distance)
            }
        }
        record(.outsideRooms, it.id, nil, dist)
    }

    // MARK: run

    /// Definitions, the visible level instances and the group lookup.
    func prepare() {
        for d in p.definitions { defs[d.id] = d }
        for (i, inst) in p.instances.enumerated() where inst.levelId == levelId && inst.visible && defs[inst.definitionId] != nil {
            recs.append(i)
        }
        for g in p.groups { for m in g.memberIds { groupOf[m] = g.id } }
    }

    func run() -> [CollisionIssue] {
        prepare()
        rooms = p.rooms.filter { $0.levelId == levelId && $0.points.count >= 3 }
        let openings = openingsByWall()
        let levelWalls = p.walls.filter { $0.levelId == levelId && $0.start != $0.end }
        var swingPad = 0.0
        for o in p.openings where o.kind == .door { swingPad = max(swingPad, Double(o.width)) }
        let maxThick = Double(levelWalls.map(\.thickness).max() ?? 0)
        let pad = V2(repeating: swingPad + maxThick)

        if let only {
            runPartial(only, levelWalls: levelWalls, openings: openings, pad: pad, mitrePad: 2 * maxThick)
        } else {
            let outlines = WallOutline.compute(levelWalls)
            for w in levelWalls {
                guard let ol = outlines[w.id] else { continue }
                let info = buildWallInfo(w, outline: ol, openings: openings[w.id] ?? [])
                wallIndex.insert(wallInfos.count, min: info.lo, max: info.hi)
                wallInfos.append(info)
            }
            for ri in recs.indices { let it = item(ri); instIndex.insert(ri, min: it.lo, max: it.hi) }
            for ri in recs.indices {
                let it = item(ri)
                for rj in instIndex.query(min: it.lo, max: it.hi) where rj > ri { checkPair(it, item(rj), ri, rj) }
                for wi in wallIndex.query(min: it.lo - pad, max: it.hi + pad) { checkWall(it, wallInfos[wi]) }
                checkOutside(it, p.instances[recs[ri]])
            }
        }
        return issues.map { CollisionIssue(kind: $0.key.kind, a: $0.key.a, b: $0.key.b, depth: $0.value) }.sorted {
            ($0.kind.rawValue, $0.a.uuidString, $0.b?.uuidString ?? "") < ($1.kind.rawValue, $1.a.uuidString, $1.b?.uuidString ?? "")
        }
    }

    func runPartial(_ ids: Set<UUID>, levelWalls: [Wall], openings: [UUID: [Opening]], pad: V2, mitrePad: Double) {
        var wallIdsOfInterest = Set<UUID>()
        for w in levelWalls where ids.contains(w.id) { wallIdsOfInterest.insert(w.id) }
        for o in p.openings where ids.contains(o.id) { wallIdsOfInterest.insert(o.wallId) }
        let subjects = recs.indices.filter { ids.contains(p.instances[recs[$0]].id) }
        let wallSubjects = levelWalls.filter { wallIdsOfInterest.contains($0.id) }

        // Region of interest -> candidate walls (loose boxes), plus walls sharing their endpoints for correct mitres.
        var regions: [(V2, V2)] = []
        for ri in subjects { let it = item(ri); regions.append((it.lo - pad, it.hi + pad)) }
        for w in wallSubjects {
            let lo = simd_min(w.start.v, w.end.v) - pad, hi = simd_max(w.start.v, w.end.v) + pad
            regions.append((lo, hi))
        }
        guard !regions.isEmpty else { return }
        let m = V2(repeating: mitrePad)
        var candidates: [Wall] = []
        var points = Set<P2>()
        for w in levelWalls {
            let lo = simd_min(w.start.v, w.end.v) - m, hi = simd_max(w.start.v, w.end.v) + m
            if regions.contains(where: { boxesOverlap($0.0, $0.1, lo, hi) }) { candidates.append(w); points.insert(w.start); points.insert(w.end) }
        }
        let candIds = Set(candidates.map(\.id))
        var subset = candidates
        for w in levelWalls where !candIds.contains(w.id) && (points.contains(w.start) || points.contains(w.end)) { subset.append(w) }
        let outlines = WallOutline.compute(subset)
        for w in candidates {
            guard let ol = outlines[w.id] else { continue }
            wallInfos.append(buildWallInfo(w, outline: ol, openings: openings[w.id] ?? []))
        }

        for ri in subjects {
            let it = item(ri)
            for rj in recs.indices where rj != ri {
                let (lo, hi) = looseBox(rj)
                guard boxesOverlap(it.lo, it.hi, lo, hi) else { continue }
                checkPair(it, item(rj), ri, rj)
            }
            for info in wallInfos where boxesOverlap(it.lo - pad, it.hi + pad, info.lo, info.hi) { checkWall(it, info) }
            checkOutside(it, p.instances[recs[ri]])
        }
        for info in wallInfos where wallIdsOfInterest.contains(info.wall.id) {
            for rj in recs.indices {
                let (lo, hi) = looseBox(rj)
                guard boxesOverlap(info.lo, info.hi, lo, hi) else { continue }
                checkWall(item(rj), info)
            }
        }
    }
}

// MARK: - Drag obstacles

extension CollisionChecker {
    /// The shapes a dragged piece may not be moved into: exactly what `check` reports red. Solid wall bands (per
    /// convex piece), door/opening passages and door swings, and the footprints of all non-free furniture.
    /// `excluding` are the moving objects (groups expand to their members; pieces of the same group never block).
    static func contactObstacles(_ p: Project, levelId: UUID, excluding: Set<UUID>) -> [ContactObstacle] {
        let e = Engine(project: p, levelId: levelId, only: nil)
        e.prepare()
        var moving = excluding
        for g in p.groups where excluding.contains(g.id) { moving.formUnion(g.memberIds) }
        var movingGroups = Set<UUID>()
        for g in p.groups where g.memberIds.contains(where: { moving.contains($0) }) { movingGroups.insert(g.id) }
        for i in e.recs { if let g = p.instances[i].groupId { if moving.contains(p.instances[i].id) { movingGroups.insert(g) } } }

        var out: [ContactObstacle] = []
        for ri in e.recs.indices {
            let it = e.item(ri)
            if it.free || moving.contains(it.id) { continue }
            if let g = it.groupId, movingGroups.contains(g) { continue }
            out.append(ContactObstacle(polygon: it.corners, z0: it.z0, z1: it.z1, id: it.id))
        }

        let openings = e.openingsByWall()
        let levelWalls = p.walls.filter { $0.levelId == levelId && $0.start != $0.end }
        let outlines = WallOutline.compute(levelWalls)
        for w in levelWalls {
            guard let ol = outlines[w.id] else { continue }
            let info = e.buildWallInfo(w, outline: ol, openings: openings[w.id] ?? [])
            for s in info.segs {
                for b in s.bands where b.z1 > b.z0 {
                    let id = b.solid ? w.id : b.opening?.id
                    for piece in convexPieces(s.poly) {
                        out.append(ContactObstacle(polygon: piece, z0: b.z0, z1: b.z1, id: id))
                    }
                }
            }
            for sw in info.swings {
                let o = sw.opening
                let z0 = Double(o.sill), z1 = Double(o.sill + o.height)
                guard z1 > z0 else { continue }
                out.append(ContactObstacle(polygon: sw.poly, z0: z0, z1: z1, id: o.id))
            }
        }
        return out
    }
}
