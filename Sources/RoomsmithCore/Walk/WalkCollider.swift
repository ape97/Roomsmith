import Foundation
import simd

/// Collision of the walking body (a circle in the floor plane) with the walls and furniture of one level.
/// Closed doors, windows, wall pieces and furniture block; open doors and plain openings are passable (an open door
/// leaf is a thin obstacle). Moving slides along obstacles. The door state is view state, passed in by the caller.
public struct WalkCollider: Sendable {
    /// Furniture at or below this height is walked over (rugs, mats).
    public static let walkOverHeightMm = 150.0
    static let leafThicknessMm = 40.0
    static let maxSubstepMm = 50.0
    /// A balcony door whose sill is at most this high is walked through when turned open (a threshold, default, not
    /// measured); a higher one stays a wall.
    public static let balconyStepOverMm: MM = 100

    struct Piece: Sendable {
        var poly: [V2]
        var lo: V2
        var hi: V2
        var doorId: UUID?
    }

    public let radius: Double
    public let eyeHeightMm: Double
    private var fixed: [Piece] = []
    /// Closed-door fillers, keyed by opening id; present only while the door is closed.
    private var doorFillers: [UUID: [Piece]] = [:]
    private var doorLeaves: [UUID: [Piece]] = [:]
    private var openDoors: Set<UUID>

    public init(project: Project, levelId: UUID, eyeHeightMm: Double, bodyRadiusMm: Double = 220, openDoors: Set<UUID> = [],
                showLamps: Bool = true) {
        self.radius = bodyRadiusMm
        self.eyeHeightMm = eyeHeightMm
        self.openDoors = openDoors
        let walls = project.walls.filter { $0.levelId == levelId }
        let outlines = WallOutline.compute(walls, levelId: levelId)
        var byWall: [UUID: [Opening]] = [:]
        for o in project.openings { byWall[o.wallId, default: []].append(o) }

        for w in walls {
            guard let outline = outlines[w.id] else { continue }
            let ax = Geo.axis(w.start, w.end)
            guard ax.length > 0 else { continue }
            func quad(_ s0: Double, _ s1: Double) -> [V2] {
                [outline.facePoint(wall: w, s: s0, left: false), outline.facePoint(wall: w, s: s1, left: false),
                 outline.facePoint(wall: w, s: s1, left: true), outline.facePoint(wall: w, s: s0, left: true)]
            }
            var cursor = 0.0
            let ops = (byWall[w.id] ?? []).sorted { $0.offset - $0.width / 2 < $1.offset - $1.width / 2 }
            for o in ops {
                let s0 = max(cursor, min(ax.length, Double(o.offset) - Double(o.width) / 2))
                let s1 = max(s0, min(ax.length, Double(o.offset) + Double(o.width) / 2))
                if s0 > cursor { Self.add(quad(cursor, s0), to: &fixed) }
                if s1 > s0 {
                    switch o.kind {
                    case .window:
                        let sashes = Self.passableBalcony(o) ? Meshes.windowSashes(o, wall: w, baseZ: 0) : []
                        if sashes.isEmpty {
                            Self.add(quad(s0, s1), to: &fixed)
                        } else {
                            // Turned open, the sashes swing into the room like door leaves; tilted ones stay closed.
                            var filler: [Piece] = []
                            Self.add(quad(s0, s1), to: &filler)
                            doorFillers[o.id] = filler.map { var p = $0; p.doorId = o.id; return p }
                            let openDir = ax.normal * (o.inward ? 1.0 : -1.0)
                            let t = ax.dir * (Self.leafThicknessMm / 2)
                            var bars: [Piece] = []
                            for sash in sashes {
                                let hinge = V2(sash.placement.pivot.x, sash.placement.pivot.y)
                                let tip = hinge + openDir * sash.placement.width
                                var one: [Piece] = []
                                Self.add([hinge - t, tip - t, tip + t, hinge + t], to: &one)
                                bars += one.map { var p = $0; p.doorId = o.id; return p }
                            }
                            doorLeaves[o.id] = bars
                        }
                    case .opening:
                        break
                    case .door:
                        var filler: [Piece] = []
                        Self.add(quad(s0, s1), to: &filler)
                        if !filler.isEmpty { doorFillers[o.id] = filler.map { var p = $0; p.doorId = o.id; return p } }
                        // Open leaf: a thin bar from the hinge, swung 90 degrees to the opening side.
                        let side = o.inward ? 1.0 : -1.0
                        let openDir = ax.normal * side
                        let hinge = w.start.v + ax.dir * (o.flipped ? s1 : s0)
                        let tip = hinge + openDir * Double(o.width)
                        let t = ax.dir * (Self.leafThicknessMm / 2)
                        var leaf: [Piece] = []
                        Self.add([hinge - t, tip - t, tip + t, hinge + t], to: &leaf)
                        if let l = leaf.first { var p = l; p.doorId = o.id; doorLeaves[o.id] = [p] }
                    }
                }
                cursor = max(cursor, s1)
            }
            if cursor < ax.length || ops.isEmpty { Self.add(quad(cursor, ax.length), to: &fixed) }
        }

        let defs = Dictionary(project.definitions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for inst in project.instances where inst.levelId == levelId && inst.visible {
            guard let def = defs[inst.definitionId], showLamps || !def.isLamp else { continue }
            let size = FurnitureResolver.size(of: inst, definition: def)
            let z0 = Double(inst.position.z), z1 = z0 + Double(size.height)
            guard z1 > Self.walkOverHeightMm, z0 < eyeHeightMm else { continue }
            Self.add(FurnitureResolver.footprint(of: inst, definition: def).corners, to: &fixed)
        }
    }

    /// Balcony doors that can be turned open and have a low enough sill to walk through.
    private static func passableBalcony(_ o: Opening) -> Bool {
        (o.style == .balconyDoor || o.style == .balconyDoor2) && o.sill <= balconyStepOverMm
    }

    private static func add(_ poly: [V2], to list: inout [Piece]) {
        guard poly.count >= 3 else { return }
        for part in convexPieces(poly) {
            let xs = part.map(\.x), ys = part.map(\.y)
            list.append(Piece(poly: part, lo: V2(xs.min()!, ys.min()!), hi: V2(xs.max()!, ys.max()!), doorId: nil))
        }
    }

    /// Splits a quad with a folded mitre at the reflex vertex into two triangles.
    private static func convexPieces(_ q: [V2]) -> [[V2]] {
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

    public func isDoorOpen(_ id: UUID) -> Bool { openDoors.contains(id) }
    /// Ids of the doors on this level.
    public var doorIds: [UUID] { Array(doorFillers.keys) }

    public mutating func setDoor(_ id: UUID, open: Bool) {
        if open { openDoors.insert(id) } else { openDoors.remove(id) }
    }

    public mutating func setOpenDoors(_ ids: Set<UUID>) { openDoors = ids }

    private func forEachObstacle(near p: V2, _ body: (Piece) -> Void) {
        let r = radius
        func near(_ pc: Piece) -> Bool {
            p.x + r >= pc.lo.x && p.x - r <= pc.hi.x && p.y + r >= pc.lo.y && p.y - r <= pc.hi.y
        }
        for pc in fixed where near(pc) { body(pc) }
        for (id, pcs) in doorFillers where !openDoors.contains(id) { for pc in pcs where near(pc) { body(pc) } }
        for (id, pcs) in doorLeaves where openDoors.contains(id) { for pc in pcs where near(pc) { body(pc) } }
    }

    /// Pushes a circle at `p` out of one convex polygon (counter-clockwise or clockwise). nil = no contact.
    private static func pushOut(_ p: V2, radius r: Double, _ poly: [V2]) -> V2? {
        let n = poly.count
        var area = 0.0
        for i in 0..<n { let a = poly[i], b = poly[(i + 1) % n]; area += a.x * b.y - b.x * a.y }
        let ccw = area >= 0
        var inside = true
        var bestDepth = Double.infinity, bestNormal = V2.zero
        var closest = V2.zero, closestDist = Double.infinity
        for i in 0..<n {
            let a = poly[i], b = poly[(i + 1) % n]
            let e = b - a
            let len = simd_length(e)
            guard len > 1e-9 else { continue }
            let outward = ccw ? V2(e.y, -e.x) / len : V2(-e.y, e.x) / len
            let dist = simd_dot(p - a, outward)
            if dist > 0 { inside = false }
            if -dist < bestDepth { bestDepth = -dist; bestNormal = outward }
            let t = min(max(simd_dot(p - a, e) / (len * len), 0), 1)
            let c = a + e * t
            let d = simd_length(p - c)
            if d < closestDist { closestDist = d; closest = c }
        }
        if inside { return p + bestNormal * (bestDepth + r) }
        guard closestDist < r else { return nil }
        let dir = closestDist > 1e-9 ? (p - closest) / closestDist : bestNormal
        return closest + dir * r
    }

    /// Moves a point out of every obstacle.
    public func resolve(_ position: V2) -> V2 {
        var p = position
        for _ in 0..<4 {
            var moved = false
            forEachObstacle(near: p) { pc in
                if let q = Self.pushOut(p, radius: radius, pc.poly) { p = q; moved = true }
            }
            if !moved { break }
        }
        return p
    }

    /// Walks from `from` towards `to` in small steps, sliding along obstacles.
    public func move(from: V2, to: V2) -> V2 {
        let d = to - from
        let dist = simd_length(d)
        guard dist > 0 else { return resolve(from) }
        let n = max(1, Int((dist / Self.maxSubstepMm).rounded(.up)))
        let step = d / Double(n)
        var p = resolve(from)
        for _ in 1...n { p = resolve(p + step) }
        return p
    }

    /// Whether the circle at `p` overlaps an obstacle.
    public func isBlocked(_ p: V2) -> Bool {
        var hit = false
        forEachObstacle(near: p) { pc in if !hit, Self.pushOut(p, radius: radius, pc.poly) != nil { hit = true } }
        return hit
    }
}
