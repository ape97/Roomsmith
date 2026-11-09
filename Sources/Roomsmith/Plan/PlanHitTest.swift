import AppKit
import simd
import RoomsmithCore

extension PlanNSView {
    /// Selected ids plus the members of selected groups.
    func expandedIds(_ ids: [UUID]) -> [UUID] {
        var out = ids
        var seen = Set(ids)
        for id in ids {
            if let g = project.group(id) { for m in g.memberIds where seen.insert(m).inserted { out.append(m) } }
        }
        return out
    }

    func handleBusyIds(_ h: PlanHandle) -> [UUID] {
        switch h {
        case .wallStart(let id), .wallEnd(let id), .roomVertex(let id, _), .dimA(let id), .dimB(let id),
             .dimOffset(let id), .rotate(let id):
            return expandedIds([id])
        }
    }

    // MARK: Object hit test

    /// Topmost object under a view point: opening, furniture/group, dimension, wall, smallest room.
    func hitObject(at pt: CGPoint) -> UUID? {
        let sc = baseScene
        let m = vp.model(pt)
        let tol = vp.mm(6)
        let lo = m - V2(tol, tol), hi = m + V2(tol, tol)
        var opening: UUID?, foot: UUID?, dim: UUID?, wall: UUID?
        var room: (id: UUID, area: Double)?
        for i in sc.query(lo: lo, hi: hi).reversed() {
            let r = sc.refs[i]
            switch r.kind {
            case .opening:
                guard opening == nil else { continue }
                let o = sc.openings[r.index]
                if Geo.pointSegment(m, o.a0, o.a1).distance <= o.thickness / 2 + tol { opening = r.id }
            case .foot:
                guard foot == nil else { continue }
                let f = sc.feet[r.index]
                var rect = f.rect
                rect.halfSize += V2(tol / 2, tol / 2)
                if rect.contains(m) {
                    if let gid = f.instance.groupId, sc.byId[gid] != nil { foot = gid } else { foot = r.id }
                }
            case .dim:
                guard dim == nil else { continue }
                let d = sc.dims[r.index]
                let dist = min(Geo.pointSegment(m, d.a2, d.b2).distance, Geo.pointSegment(m, d.a, d.a2).distance,
                               Geo.pointSegment(m, d.b, d.b2).distance)
                if dist <= tol { dim = r.id }
            case .wall:
                guard wall == nil else { continue }
                let w = sc.walls[r.index]
                if Geo.pointSegment(m, w.wall.start.v, w.wall.end.v).distance <= Double(w.wall.thickness) / 2 + tol { wall = r.id }
            case .room:
                let rm = sc.rooms[r.index]
                if Geo.contains(rm.polygon, m), room == nil || rm.areaM2 < room!.area { room = (r.id, rm.areaM2) }
            case .group:
                continue
            }
        }
        return opening ?? foot ?? dim ?? wall ?? room?.id
    }

    // MARK: Handles

    /// Handles of a single selected object, in model coordinates.
    func handles(for id: UUID, in sc: PlanScene) -> [(PlanHandle, V2)] {
        guard let ref = sc.byId[id] else { return [] }
        switch ref.kind {
        case .wall:
            let w = sc.walls[ref.index].wall
            return [(.wallStart(id), w.start.v), (.wallEnd(id), w.end.v)]
        case .room:
            return sc.rooms[ref.index].room.points.enumerated().map { (.roomVertex(id, $0.offset), $0.element.v) }
        case .dim:
            let d = sc.dims[ref.index]
            return [(.dimA(id), d.a), (.dimB(id), d.b), (.dimOffset(id), (d.a2 + d.b2) / 2)]
        case .foot:
            let f = sc.feet[ref.index]
            guard f.instance.groupId == nil || sc.byId[f.instance.groupId!] == nil else { return [] }
            return [(.rotate(id), rotateHandlePoint(f.rect))]
        case .group:
            return [(.rotate(id), rotateHandlePoint(sc.groups[ref.index].rect))]
        case .opening:
            return []
        }
    }

    func rotateHandlePoint(_ r: OrientedRect) -> V2 {
        let ay = r.axes.1
        return r.center + ay * (r.halfSize.y + vp.mm(26))
    }

    func handleHit(at pt: CGPoint) -> PlanHandle? {
        guard model.selection.count == 1, let id = model.selection.first else { return nil }
        let sc = baseScene
        var best: (PlanHandle, Double)?
        for (h, p) in handles(for: id, in: sc) {
            let s = vp.screen(p)
            let d = hypot(Double(s.x - pt.x), Double(s.y - pt.y))
            if d <= 9, best == nil || d < best!.1 { best = (h, d) }
        }
        return best?.0
    }

    /// Pivot (model point) used by the rotation handle of an object.
    func rotationPivot(of id: UUID) -> (pivot: V2, rotation: Double)? {
        if let i = project.instance(id) { return (i.position.xy.v, i.rotationDeg) }
        if let g = project.group(id) { return (g.origin.xy.v, g.rotationDeg) }
        return nil
    }

    // MARK: Rectangle selection

    func objects(inLo lo: V2, hi: V2) -> [UUID] {
        let sc = baseScene
        var out: [UUID] = []
        var seen = Set<UUID>()
        func add(_ id: UUID) { if seen.insert(id).inserted { out.append(id) } }
        let rectCorners = [lo, V2(hi.x, lo.y), hi, V2(lo.x, hi.y)]
        var wallsSelected = Set<UUID>()
        var openingIds: [(UUID, UUID)] = []
        for i in sc.query(lo: lo, hi: hi) {
            let r = sc.refs[i]
            switch r.kind {
            case .room:
                if r.lo.x >= lo.x, r.lo.y >= lo.y, r.hi.x <= hi.x, r.hi.y <= hi.y { add(r.id) }
            case .wall:
                let w = sc.walls[r.index].wall
                if Self.segmentHitsRect(w.start.v, w.end.v, lo, hi) { add(r.id); wallsSelected.insert(r.id) }
            case .opening:
                openingIds.append((r.id, sc.openings[r.index].opening.wallId))
            case .foot:
                let f = sc.feet[r.index]
                if f.rect.overlaps(polygon: rectCorners, margin: -0.5) {
                    if let gid = f.instance.groupId, sc.byId[gid] != nil { add(gid) } else { add(r.id) }
                }
            case .dim:
                let d = sc.dims[r.index]
                if Self.segmentHitsRect(d.a2, d.b2, lo, hi) || Self.segmentHitsRect(d.a, d.b, lo, hi) { add(r.id) }
            case .group:
                continue
            }
        }
        for (oid, wid) in openingIds where !wallsSelected.contains(wid) { add(oid) }
        return out
    }

    /// Liang-Barsky clip: does the segment touch the rectangle?
    static func segmentHitsRect(_ a: V2, _ b: V2, _ lo: V2, _ hi: V2) -> Bool {
        var t0 = 0.0, t1 = 1.0
        let d = b - a
        for (p, q) in [(-d.x, a.x - lo.x), (d.x, hi.x - a.x), (-d.y, a.y - lo.y), (d.y, hi.y - a.y)] {
            if p == 0 { if q < 0 { return false } }
            else {
                let t = q / p
                if p < 0 { if t > t1 { return false }; t0 = max(t0, t) }
                else { if t < t0 { return false }; t1 = min(t1, t) }
            }
        }
        return true
    }
}
