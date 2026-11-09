import Foundation
import simd
import RoomsmithCore

// Derived, drawable geometry of one level. Built once per document revision (and per drag preview) so that
// panning, zooming and hovering never recompute outlines, footprints or the spatial index.

struct PlanRoomItem {
    var room: Room
    var polygon: [V2]
    var areaM2: Double
    var labelPoint: V2
    var floor: RGBColor?
    var lo: V2, hi: V2
}

struct PlanWallItem {
    var wall: Wall
    var outline: WallOutline
    /// Wall body polygons between the openings (the whole outline when there are none).
    var pieces: [[V2]]
    /// Line segments to stroke (pairs): long faces of every piece plus caps at free wall ends.
    var edges: [(V2, V2)]
    var lo: V2, hi: V2
}

struct PlanOpeningItem {
    var opening: Opening
    var wallIndex: Int
    var s0: Double, s1: Double
    /// Corners of the gap on the right/left face at the start (0) and end (1) of the opening.
    var r0: V2, r1: V2, l0: V2, l1: V2
    var a0: V2, a1: V2
    var dir: V2, normal: V2
    var thickness: Double
    var lo: V2, hi: V2
}

struct PlanFootItem {
    var instance: FurnitureInstance
    var rect: OrientedRect
    var corners: [V2]
    var lo: V2, hi: V2
    /// Components seen from above, lowest first.
    var top: FurnitureTopView
}

struct PlanGroupItem {
    var group: FurnitureGroup
    var rect: OrientedRect
    var corners: [V2]
    var lo: V2, hi: V2
}

struct PlanDimItem {
    var dimension: RoomsmithCore.Dimension
    var a: V2, b: V2
    /// End points of the dimension line (offset from a/b).
    var a2: V2, b2: V2
    var length: MM
    var lo: V2, hi: V2
}

struct PlanRef {
    enum Kind: Int { case room, wall, opening, foot, group, dim }
    var kind: Kind
    var index: Int
    var id: UUID
    var lo: V2, hi: V2
}

struct PlanSceneKey: Equatable {
    var projectId: UUID
    var revision: Int64
    var levelId: UUID
}

struct PlanScene {
    /// Top views per instance, shared by all scene builds (also the light ones of drag previews).
    nonisolated(unsafe) static let topViewCache = FurnitureTopViewCache()
    var key: PlanSceneKey
    var rooms: [PlanRoomItem] = []
    var walls: [PlanWallItem] = []
    var openings: [PlanOpeningItem] = []
    var feet: [PlanFootItem] = []
    var groups: [PlanGroupItem] = []
    var dims: [PlanDimItem] = []
    /// All items in draw order: rooms, walls, openings, furniture, groups, dimensions.
    var refs: [PlanRef] = []
    var index: SpatialIndex?
    var byId: [UUID: PlanRef] = [:]
    var colliding: Set<UUID> = []
    var snapContext = SnapContext()
    /// All wall outline corners (room tool snaps to these).
    var corners: [V2] = []
    /// Outlines of the level below (drawn faint).
    var ghostWalls: [[V2]] = []
    var definitions: [UUID: FurnitureDefinition] = [:]
    var bounds: (lo: V2, hi: V2)?

    /// `full` also builds the spatial index, the snap context, collisions and the faint level below.
    /// Drag previews use the light variant (rebuilt on every mouse move).
    static func build(_ p: Project, revision: Int64, levelId: UUID, full: Bool) -> PlanScene {
        var s = PlanScene(key: PlanSceneKey(projectId: p.id, revision: revision, levelId: levelId))
        var floorColors: [UUID: RGBColor] = [:]
        for m in p.materials { floorColors[m.id] = m.color }
        let levelWalls = p.walls.filter { $0.levelId == levelId }
        let outlines = WallOutline.compute(levelWalls, levelId: levelId)

        // Rooms
        for r in p.rooms where r.levelId == levelId && r.points.count >= 3 {
            let poly = r.points.map(\.v)
            let (lo, hi) = bbox(poly)
            s.rooms.append(PlanRoomItem(room: r, polygon: poly, areaM2: Geo.area(r.points) / 1_000_000,
                                        labelPoint: labelPoint(poly, lo: lo, hi: hi),
                                        floor: r.floorMaterialId.flatMap { floorColors[$0] }, lo: lo, hi: hi))
        }

        // Walls and their openings
        var endpointCount: [P2: Int] = [:]
        for w in levelWalls { endpointCount[w.start, default: 0] += 1; endpointCount[w.end, default: 0] += 1 }
        var openingsByWall: [UUID: [Opening]] = [:]
        for o in p.openings { openingsByWall[o.wallId, default: []].append(o) }
        for w in levelWalls {
            guard let ol = outlines[w.id] else { continue }
            let ax = Geo.axis(w.start, w.end)
            let ops = (openingsByWall[w.id] ?? []).sorted { $0.offset < $1.offset }
            // Cut intervals along the axis.
            var cuts: [(Double, Double)] = []
            for o in ops {
                let a = max(0, Double(o.offset) - Double(o.width) / 2), b = min(ax.length, Double(o.offset) + Double(o.width) / 2)
                guard b > a else { continue }
                if let last = cuts.last, a <= last.1 { cuts[cuts.count - 1].1 = max(last.1, b) } else { cuts.append((a, b)) }
            }
            var spans: [(Double, Double)] = []
            var cursor = 0.0
            for c in cuts { if c.0 - cursor > 0.5 { spans.append((cursor, c.0)) }; cursor = c.1 }
            if ax.length - cursor > 0.5 || spans.isEmpty && cuts.isEmpty { spans.append((cursor, ax.length)) }
            var pieces: [[V2]] = []
            var edges: [(V2, V2)] = []
            for (sa, sb) in spans {
                let r0 = ol.facePoint(wall: w, s: sa, left: false), r1 = ol.facePoint(wall: w, s: sb, left: false)
                let l0 = ol.facePoint(wall: w, s: sa, left: true), l1 = ol.facePoint(wall: w, s: sb, left: true)
                pieces.append([r0, r1, l1, l0])
                edges.append((r0, r1)); edges.append((l0, l1))
                if sa <= 0.5, endpointCount[w.start, default: 0] == 1 { edges.append((l0, r0)) }
                if sb >= ax.length - 0.5, endpointCount[w.end, default: 0] == 1 { edges.append((r1, l1)) }
            }
            if pieces.isEmpty { pieces = [ol.polygon] }
            let (lo, hi) = bbox(ol.polygon)
            s.walls.append(PlanWallItem(wall: w, outline: ol, pieces: pieces, edges: edges, lo: lo, hi: hi))
            s.corners.append(contentsOf: ol.polygon)
        }
        var wallIndex: [UUID: Int] = [:]
        for (i, w) in s.walls.enumerated() { wallIndex[w.wall.id] = i }
        for o in p.openings {
            guard let wi = wallIndex[o.wallId] else { continue }
            s.openings.append(makeOpeningItem(o, wall: s.walls[wi].wall, outline: s.walls[wi].outline, wallIndex: wi))
        }

        // Furniture
        var defs: [UUID: FurnitureDefinition] = [:]
        for d in p.definitions { defs[d.id] = d }
        var footById: [UUID: Int] = [:]
        let matSignature = FurnitureTopViewCache.signature(of: p.materials)
        let elevations = Dictionary(p.levels.map { ($0.id, $0.elevation) }, uniquingKeysWith: { a, _ in a })
        for inst in p.instances where inst.levelId == levelId && inst.visible {
            guard let def = defs[inst.definitionId] else { continue }
            let rect = FurnitureResolver.footprint(of: inst, definition: def)
            let corners = rect.corners
            let (lo, hi) = bbox(corners)
            footById[inst.id] = s.feet.count
            let top = topViewCache.view(inst, definition: def, colors: floorColors, signature: matSignature,
                                        levelElevation: elevations[inst.levelId] ?? 0)
            s.feet.append(PlanFootItem(instance: inst, rect: rect, corners: corners, lo: lo, hi: hi, top: top))
        }
        s.definitions = defs

        // Groups: oriented bounding box of the visible members in the group's frame.
        for g in p.groups where g.levelId == levelId {
            var local: [V2] = []
            let o = g.origin.xy.v
            for m in g.memberIds { if let fi = footById[m] { for c in s.feet[fi].corners { local.append(Geo.rotate(c - o, deg: -g.rotationDeg)) } } }
            guard !local.isEmpty else { continue }
            let (llo, lhi) = bbox(local)
            let pad = 40.0
            let centerLocal = (llo + lhi) / 2
            let center = o + Geo.rotate(centerLocal, deg: g.rotationDeg)
            let rect = OrientedRect(center: center, halfSize: (lhi - llo) / 2 + V2(pad, pad), rotationDeg: g.rotationDeg)
            let corners = rect.corners
            let (lo, hi) = bbox(corners)
            s.groups.append(PlanGroupItem(group: g, rect: rect, corners: corners, lo: lo, hi: hi))
        }

        // Dimensions
        for d in p.dimensions where d.levelId == levelId {
            let ax = Geo.axis(d.a, d.b)
            let off = ax.normal * Double(d.offset)
            let a = d.a.v, b = d.b.v
            let (lo, hi) = bbox([a, b, a + off, b + off])
            s.dims.append(PlanDimItem(dimension: d, a: a, b: b, a2: a + off, b2: b + off,
                                      length: MM(ax.length.rounded(.toNearestOrAwayFromZero)), lo: lo, hi: hi))
        }

        // Draw-ordered references and lookup
        func add(_ kind: PlanRef.Kind, _ index: Int, _ id: UUID, _ lo: V2, _ hi: V2) {
            let r = PlanRef(kind: kind, index: index, id: id, lo: lo, hi: hi)
            s.refs.append(r)
            s.byId[id] = r
        }
        for (i, x) in s.rooms.enumerated() { add(.room, i, x.room.id, x.lo, x.hi) }
        for (i, x) in s.walls.enumerated() { add(.wall, i, x.wall.id, x.lo, x.hi) }
        for (i, x) in s.openings.enumerated() { add(.opening, i, x.opening.id, x.lo, x.hi) }
        for (i, x) in s.feet.enumerated() { add(.foot, i, x.instance.id, x.lo, x.hi) }
        for (i, x) in s.groups.enumerated() { add(.group, i, x.group.id, x.lo, x.hi) }
        for (i, x) in s.dims.enumerated() { add(.dim, i, x.dimension.id, x.lo, x.hi) }

        if full {
            var idx = SpatialIndex(cellSize: 1000)
            for (i, r) in s.refs.enumerated() { idx.insert(i, min: r.lo, max: r.hi) }
            s.index = idx
        }
        if let f = s.refs.first {
            var lo = f.lo, hi = f.hi
            for r in s.refs { lo = simd_min(lo, r.lo); hi = simd_max(hi, r.hi) }
            s.bounds = (lo, hi)
        }

        guard full else { return s }
        s.snapContext = SnapContext.make(project: p, levelId: levelId, exclude: [])
        if p.settings.collisionWarnings { s.colliding = collidingIds(p, levelId: levelId, only: nil) }

        // Level below, faint.
        if let level = p.level(levelId) {
            let below = p.levels.filter { $0.id != levelId && $0.visible && $0.elevation < level.elevation }
                .max { $0.elevation < $1.elevation }
            if let below {
                s.ghostWalls = WallOutline.compute(p.walls, levelId: below.id).values.map(\.polygon)
            }
        }
        return s
    }

    static func makeOpeningItem(_ o: Opening, wall w: Wall, outline ol: WallOutline, wallIndex: Int) -> PlanOpeningItem {
        let ax = Geo.axis(w.start, w.end)
        let s0 = Double(o.offset) - Double(o.width) / 2, s1 = Double(o.offset) + Double(o.width) / 2
        let r0 = ol.facePoint(wall: w, s: s0, left: false), r1 = ol.facePoint(wall: w, s: s1, left: false)
        let l0 = ol.facePoint(wall: w, s: s0, left: true), l1 = ol.facePoint(wall: w, s: s1, left: true)
        let a0 = w.start.v + ax.dir * s0, a1 = w.start.v + ax.dir * s1
        let (lo, hi) = bbox([r0, r1, l0, l1])
        return PlanOpeningItem(opening: o, wallIndex: wallIndex, s0: s0, s1: s1, r0: r0, r1: r1, l0: l0, l1: l1,
                               a0: a0, a1: a1, dir: ax.dir, normal: ax.normal, thickness: Double(w.thickness), lo: lo, hi: hi)
    }

    /// Furniture involved in a collision warning (overlap, wall, blocked opening).
    static func collidingIds(_ p: Project, levelId: UUID, only: Set<UUID>?) -> Set<UUID> {
        CollisionChecker.warnedIds(CollisionChecker.check(p, levelId: levelId, only: only), in: p)
    }

    /// Indices into `refs` whose bounds intersect the rectangle, in draw order.
    func query(lo: V2, hi: V2) -> [Int] {
        if let index {
            return index.query(min: lo, max: hi).filter { i in
                let r = refs[i]
                return r.hi.x >= lo.x && r.lo.x <= hi.x && r.hi.y >= lo.y && r.lo.y <= hi.y
            }
        }
        return refs.indices.filter { i in
            let r = refs[i]
            return r.hi.x >= lo.x && r.lo.x <= hi.x && r.hi.y >= lo.y && r.lo.y <= hi.y
        }
    }

    // MARK: Helpers

    static func bbox(_ pts: [V2]) -> (V2, V2) {
        var lo = pts[0], hi = pts[0]
        for p in pts.dropFirst() { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        return (lo, hi)
    }

    private static func labelPoint(_ poly: [V2], lo: V2, hi: V2) -> V2 {
        var a = 0.0, cx = 0.0, cy = 0.0
        for i in poly.indices {
            let p = poly[i], q = poly[(i + 1) % poly.count]
            let cross = p.x * q.y - q.x * p.y
            a += cross; cx += (p.x + q.x) * cross; cy += (p.y + q.y) * cross
        }
        if abs(a) > 1e-6 {
            let c = V2(cx / (3 * a), cy / (3 * a))
            if Geo.contains(poly, c) { return c }
        }
        let mid = (lo + hi) / 2
        if Geo.contains(poly, mid) { return mid }
        return poly.reduce(V2(0, 0), +) / Double(poly.count)
    }
}
