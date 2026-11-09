import Foundation
import simd

/// Which face of a wall a dimension chain follows. `left` and `right` are seen from the wall's start towards its end
/// (`left` is the side of the +90 degree normal, the side positive dimension offsets point to).
public enum ChainSide: String, Sendable, CaseIterable {
    /// Outer face when it can be determined, else `left`.
    case auto
    /// Face that is not enclosed by a closed wall loop or a room. Fails when it cannot be determined.
    case outer
    /// The enclosed face (opposite of `outer`). Fails when it cannot be determined.
    case inner
    case left
    case right
}

/// Points of a dimension chain along one wall face plus the signed dimension-line offset that puts the line outside it.
public struct WallDimensionChain: Sendable, Equatable {
    public var wallId: UUID
    /// The face that was used: always `.left` or `.right`.
    public var side: ChainSide
    /// True when `side` is the outer face of the building (known only for `.outer` / `.auto` with a determinable outside).
    public var isOuter: Bool
    /// Chain points on the wall face from the wall start to the wall end (at least 2).
    public var points: [P2]
    /// Signed offset for `Project.addDimensionChain`: positive = left of the start to end direction.
    public var offset: MM
}

/// Pure geometry of dimension chains (rows of adjacent dimensions on one line, as in CAD programs).
///
/// Rounding rules (all values are whole millimetres):
/// - Every length is the distance of the two stored points, rounded half away from zero. This is exactly the number
///   the plan view and the plan export print, so the reported numbers equal what is drawn.
/// - On axis-parallel walls every point is exact. On slanted walls the intermediate points are the integer points
///   closest to the ideal distance from the first point (error at most 0.5 mm), the last point is the rounded wall end.
/// - Opening edges lie at `offset +- width / 2`; an odd width gives a half millimetre, which is rounded half away from zero.
public enum DimensionChains {
    /// Distance between the total dimension line and the part line: the total sits `totalGap` further out.
    public static let totalGap: MM = 400
    public static let maxPoints = 1000

    /// Printed length of a dimension between two points: rounded half away from zero.
    public static func length(_ a: P2, _ b: P2) -> MM {
        MM(Geo.distance(a, b).rounded(.toNearestOrAwayFromZero))
    }

    /// Offset of the total dimension for the offset of the parts: `totalGap` further out, same sign (0 counts as positive).
    public static func totalOffset(for offset: MM) -> MM {
        if offset < 0 {
            let (v, o) = offset.subtractingReportingOverflow(totalGap)
            return o ? MM.min : v
        }
        let (v, o) = offset.addingReportingOverflow(totalGap)
        return o ? MM.max : v
    }

    // MARK: Free points

    /// Orders arbitrary points along the line from the first to the last point.
    ///
    /// Rule: the line runs through the first and the last point (they must differ). Every point is always projected
    /// orthogonally onto that line and rounded half away from zero (the first and the last point stay as given), so a
    /// sideways offset never enters a dimension; collinear input (and the output of `wallChain`) is not altered. The
    /// result is sorted by position along the line, so the input order does not matter. Points beyond the first or last
    /// point extend the chain. Throws INVALID_ARGUMENT for fewer than two points, more than `maxPoints`, identical first
    /// and last point, or two points whose projections coincide (same position along the line rounded to whole mm; a
    /// dimension of 0 mm is meaningless, so it is an error, never skipped);
    /// OUT_OF_RANGE for coordinates beyond +-100 km.
    public static func pointsChain(_ points: [P2]) throws -> [P2] {
        guard points.count >= 2 else { throw CommandError.invalid("A dimension chain needs at least 2 points") }
        guard points.count <= maxPoints else { throw CommandError.invalid("A dimension chain has at most \(maxPoints) points") }
        guard points.allSatisfy(\.isInRange) else { throw CommandError.range("Chain points must lie within +-100 km") }
        let first = points[0], last = points[points.count - 1]
        guard first != last else {
            throw CommandError.invalid("The first and the last point are identical; they define the line of the chain")
        }
        let ax = Geo.axis(first, last)
        var rows: [(t: Double, p: P2, index: Int)] = []
        for (i, p) in points.enumerated() {
            let d = p.v - first.v
            let t = simd_dot(d, ax.dir)
            let q: P2
            if i == 0 { q = first } else if i == points.count - 1 { q = last } else { q = P2(rounding: first.v + ax.dir * t) }
            rows.append((t, q, i))
        }
        var seen: [P2: Int] = [:]
        var seenT: [Int64: Int] = [:]
        for r in rows {
            let tKey = Int64(r.t.rounded(.toNearestOrAwayFromZero))
            if let other = seen[r.p] ?? seenT[tKey] {
                throw CommandError.invalid("Points \(other) and \(r.index) end up at the same place; a dimension needs two different points")
            }
            seen[r.p] = r.index
            seenT[tKey] = r.index
        }
        rows.sort { $0.t != $1.t ? $0.t < $1.t : $0.index < $1.index }
        return rows.map(\.p)
    }

    // MARK: Walls

    /// The face of the wall that faces away from the building: `.left` or `.right`, nil when it cannot be told.
    ///
    /// A side counts as enclosed when a point 10 mm beyond the face (at the middle of the wall) lies in a room of the
    /// level or inside a closed loop of walls. Exactly one enclosed side makes the other one the outside.
    public static func outerSide(of wall: Wall, in p: Project) -> ChainSide? {
        let ax = Geo.axis(wall.start, wall.end)
        guard ax.length > 0 else { return nil }
        let mid = (wall.start.v + wall.end.v) / 2
        let reach = Double(wall.thickness) / 2 + 10
        let levelWalls = p.walls.filter { $0.levelId == wall.levelId && $0.start != $0.end }
        let rooms = p.rooms.filter { $0.levelId == wall.levelId }
        func enclosed(_ sign: Double) -> Bool {
            let probe = mid + ax.normal * (sign * reach)
            if rooms.contains(where: { Geo.contains($0.points.map(\.v), probe) }) { return true }
            return RoomFinder.face(containing: probe, walls: levelWalls) != nil
        }
        let left = enclosed(1), right = enclosed(-1)
        if left == right { return nil }
        return left ? .right : .left
    }

    /// Chain points along one face of a wall: wall start, both edges of every opening (sorted by position), wall end.
    ///
    /// The points lie on the visible wall face as the plan draws it (`WallOutline.facePoint`): the first and the last
    /// point are the mitred face corners (the outer face reaches further at a corner, the inner face ends earlier;
    /// a free wall end is square), the openings lie on the face at axis position + normal * thickness / 2. `offset` is
    /// the distance of the dimension line from the face (not negative); the returned chain holds it signed for `side`.
    /// Openings reaching past the ends of the face are clamped to them; openings completely outside it are
    /// ignored; overlapping openings share their edges (every edge becomes a point once). Throws for a missing or
    /// zero-length wall, a negative offset, a face hidden by the mitres of the joining walls, or `.outer` / `.inner`
    /// on a wall whose outside cannot be determined.
    public static func wallChain(_ p: Project, wallId: UUID, side: ChainSide = .auto, offset: MM = 500,
                                 includeOpenings: Bool = true) throws -> WallDimensionChain {
        guard let w = p.wall(wallId) else { throw CommandError.notFound("Wall", wallId) }
        guard offset >= 0 else { throw CommandError.invalid("The distance from the wall must not be negative", ids: [wallId]) }
        let ax = Geo.axis(w.start, w.end)
        guard ax.length > 0 else { throw CommandError.invalid("The wall has no length", ids: [wallId]) }

        let outer = outerSide(of: w, in: p)
        let used: ChainSide
        switch side {
        case .left, .right: used = side
        case .auto: used = outer ?? .left
        case .outer:
            guard let outer else { throw CommandError.invalid("The outer side of this wall cannot be determined; use left or right", ids: [wallId]) }
            used = outer
        case .inner:
            guard let outer else { throw CommandError.invalid("The inner side of this wall cannot be determined; use left or right", ids: [wallId]) }
            used = outer == .left ? .right : .left
        }
        let left = used == .left
        let sign: Double = left ? 1 : -1
        let shift = ax.normal * (sign * Double(w.thickness) / 2)
        let outline = WallOutline.compute(p.walls, levelId: w.levelId)[wallId]
        let a: V2 = outline?.facePoint(wall: w, s: 0, left: left) ?? (w.start.v + shift)
        let b: V2 = outline?.facePoint(wall: w, s: ax.length, left: left) ?? (w.end.v + shift)
        let first = P2(rounding: a)
        // Axis positions of the face ends (mitres move them beyond 0 / length or inwards).
        let faceStart = w.start.v + shift
        let sLo = simd_dot(a - faceStart, ax.dir), sHi = simd_dot(b - faceStart, ax.dir)
        let faceLength = sHi - sLo
        // A short wall between two mitred corners can lose this face completely (the mitres cross): there is
        // nothing to measure, and a negative length would come out as a made-up positive number.
        guard faceLength > 0 else {
            throw CommandError.invalid("This side of the wall is covered by the walls joining it; dimension the other side", ids: [wallId])
        }
        let total = MM(faceLength.rounded(.toNearestOrAwayFromZero))
        // The end is placed from the start, not rounded on its own: with an odd thickness both mitred corners lie on
        // half millimetres and separate rounding would add 1 mm to the total (4241 measured as 4242).
        let last = P2(origin: first, direction: ax.dir, length: Double(total))
        var stations = Set<MM>()
        if includeOpenings {
            for o in p.openings where o.wallId == wallId {
                let lo = Double(o.offset) - Double(o.width) / 2, hi = Double(o.offset) + Double(o.width) / 2
                if hi <= sLo || lo >= sHi { continue }
                for e in [max(lo, sLo), min(hi, sHi)] {
                    let s = MM((e - sLo).rounded(.toNearestOrAwayFromZero))
                    if s > 0 && s < total { stations.insert(s) }
                }
            }
        }
        var points = [first]
        for s in stations.sorted() {
            let q = P2(origin: first, direction: ax.dir, length: Double(s))
            if q != points[points.count - 1] && q != last { points.append(q) }
        }
        if last != points[points.count - 1] { points.append(last) }
        guard points.count >= 2 else { throw CommandError.invalid("The wall is too short for a dimension", ids: [wallId]) }
        return WallDimensionChain(wallId: wallId, side: used, isOuter: outer == used, points: points,
                                  offset: used == .left ? offset : -offset)
    }
}
