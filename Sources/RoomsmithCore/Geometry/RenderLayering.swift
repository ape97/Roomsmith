import Foundation

/// Tiny draw-time height steps that keep equally high, overlapping flat surfaces (room floors, rugs) from flickering.
/// Nothing here is stored: the renderer lifts a surface by `offsetMm(rank:)` only while drawing; the document, collisions,
/// exports and measurements keep the exact heights. The order is the order of the project arrays, so it is deterministic.
public enum RenderLayering {
    /// One step. Half a millimetre is about 8 times the depth resolution of the 3D view at 10 m (rule of thumb) and cannot be
    /// seen at room scale; the largest lift is `maxRank * stepMm`.
    public static let stepMm = 0.5
    public static let maxRank = 8

    public static func offsetMm(rank: Int) -> Double { Double(min(max(rank, 0), maxRank)) * stepMm }

    /// Number of earlier rooms of the same level whose outline area overlaps this room's (bounding boxes, a safe over-estimate).
    public static func roomRank(_ room: Room, in p: Project) -> Int {
        guard let me = bounds(room.points) else { return 0 }
        var rank = 0
        for other in p.rooms {
            if other.id == room.id { break }
            guard other.levelId == room.levelId, other.showFloor, let b = bounds(other.points), overlaps(me, b) else { continue }
            rank += 1
        }
        return rank
    }

    /// Same for flat floor pieces (rugs): earlier flat pieces of the same level whose footprints overlap. Other furniture gets 0.
    public static func flatPieceRank(_ inst: FurnitureInstance, in p: Project) -> Int {
        guard let me = footprint(inst, in: p), CollisionChecker.isFlatOnFloor(inst, definition: me.def) else { return 0 }
        var rank = 0
        for other in p.instances {
            if other.id == inst.id { break }
            guard other.levelId == inst.levelId, let f = footprint(other, in: p), CollisionChecker.isFlatOnFloor(other, definition: f.def),
                  overlaps(me.box, f.box) else { continue }
            rank += 1
        }
        return rank
    }

    private typealias Box = (lo: P2, hi: P2)

    private static func bounds(_ pts: [P2]) -> Box? {
        guard let f = pts.first else { return nil }
        var lo = f, hi = f
        for q in pts { lo = P2(min(lo.x, q.x), min(lo.y, q.y)); hi = P2(max(hi.x, q.x), max(hi.y, q.y)) }
        return (lo, hi)
    }

    private static func overlaps(_ a: Box, _ b: Box) -> Bool {
        a.lo.x < b.hi.x && b.lo.x < a.hi.x && a.lo.y < b.hi.y && b.lo.y < a.hi.y
    }

    /// Axis-aligned box around the rotated footprint.
    private static func footprint(_ inst: FurnitureInstance, in p: Project) -> (def: FurnitureDefinition, box: Box)? {
        guard let def = p.definition(inst.definitionId) else { return nil }
        let s = FurnitureResolver.size(of: inst, definition: def)
        let a = inst.rotationDeg * .pi / 180
        let hw = Double(s.width) / 2, hd = Double(s.depth) / 2
        let ex = abs(hw * cos(a)) + abs(hd * sin(a)), ey = abs(hw * sin(a)) + abs(hd * cos(a))
        let cx = Double(inst.position.x), cy = Double(inst.position.y)
        return (def, (P2(MM((cx - ex).rounded(.down)), MM((cy - ey).rounded(.down))), P2(MM((cx + ex).rounded(.up)), MM((cy + ey).rounded(.up)))))
    }
}
