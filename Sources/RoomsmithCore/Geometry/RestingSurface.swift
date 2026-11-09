import Foundation
import simd

// Pieces that stand on other furniture (a tray on a table, a plant on a shelf). The height a piece rests at is derived
// from the furniture below it; it is stored as the instance's ordinary `position.z`, so there is no new model field.
// Pure geometry, shared by the 2D plan drag, the 3D drag and both library drops.

/// The top of one component of a piece of furniture, as something another piece can stand on.
public struct RestingSurface: Sendable, Equatable {
    /// The furniture this surface belongs to.
    public var carrierId: UUID
    /// Outline of the component seen from above (convex, counter-clockwise).
    public var hull: [V2]
    /// Height of the top above the level floor, mm.
    public var top: Double
    /// Lowest point of the whole carrier instance above the level floor, mm (0 for furniture on the floor).
    public var carrierBottom: Double = 0

    /// A piece counts as resting when its underside is this close to a surface top (mm).
    public static let zTolerance = 1.0
    /// How far a footprint may stick out over the edge of a surface and still count as inside it (mm). Round hulls
    /// are polygons with different corner counts, so exactly equal circles need a little room.
    public static let fitTolerance = 2.0
    /// Lowest top that counts as a carrier (mm above the floor). Rugs and mats are lower and are walked over, so nothing
    /// is put "on" them automatically; a piece can still be lifted there by hand.
    public static let minCarrierTop = 150.0
    /// Highest top that counts as a carrier (mm). Above reach, the top of a tall cabinet is not a place to drop a piece
    /// onto automatically; a piece can still be lifted there by hand.
    public static let maxCarrierTop = 1500.0
    /// A carrier whose underside is at most this high stands on the floor (mm); a higher one hangs (wall shelf, wall
    /// cabinet). Standing carriers win over hanging ones, so a wall cabinet never beats the worktop below it.
    public static let standingCarrierBottom = 300.0

    /// Every component top of an instance, with the instance's current position, size, state and rotation.
    /// Tops at the floor (below 1 mm) are no surfaces.
    public static func surfaces(of inst: FurnitureInstance, definition def: FurnitureDefinition) -> [RestingSurface] {
        surfaces(of: inst.id, shapes: FurnitureTopView.make(inst, definition: def, colors: [:], levelElevation: 0).shapes)
    }

    /// Surfaces from the already computed component shapes of one instance.
    static func surfaces(of id: UUID, shapes: [TopViewShape]) -> [RestingSurface] {
        let bottom = shapes.map(\.bottomZ).min() ?? 0
        return shapes.compactMap {
            $0.topZ > 1 ? RestingSurface(carrierId: id, hull: $0.points, top: $0.topZ, carrierBottom: bottom) : nil
        }
    }

    /// True when a component that reaches into the height range `z0...z1` has an outline that overlaps `outline`.
    /// The component the piece stands on (its top is at `z0`) does not count, nor one that starts at `z1`.
    static func intrudes(_ outline: [V2], z0: Double, z1: Double, shapes: [TopViewShape]) -> Bool {
        shapes.contains { $0.bottomZ < z1 - zTolerance && $0.topZ > z0 + zTolerance && penetration(outline, $0.points) != nil }
    }

    /// True when `outline` lies inside the hull (within `fitTolerance`).
    func contains(_ outline: [V2]) -> Bool {
        guard hull.count >= 3 else { return false }
        for i in hull.indices {
            let a = hull[i], b = hull[(i + 1) % hull.count]
            let e = b - a
            let len = simd_length(e)
            guard len > 1e-9 else { continue }
            for q in outline where (e.x * (q.y - a.y) - e.y * (q.x - a.x)) / len < -Self.fitTolerance { return false }
        }
        return true
    }

    /// The surface a piece with this outline and underside height stands on (underside within `zTolerance` of the
    /// top and the outline inside the hull), if any; the highest one wins.
    static func supporting(_ outline: [V2], z0: Double, among surfaces: [RestingSurface]) -> RestingSurface? {
        surfaces.filter { abs($0.top - z0) <= zTolerance && $0.contains(outline) }.max { $0.top < $1.top }
    }

    // MARK: Pure function used by every placing path

    /// The height (level-relative mm) `inst` gets when its footprint centre is at `xy`:
    /// - over a surface that holds the whole footprint: the top of the best such surface (see `RestingField`: carriers
    ///   are the other non-free, shown furniture of the level except `excluding` and the piece's own group; the piece
    ///   must fit between the surface and whatever is above it, and under the ceiling);
    /// - `allowsOverlap` pieces are never put onto furniture: they keep their height;
    /// - otherwise 0 when the piece was resting before (`wasResting`, derived from its current position when nil), so
    ///   that dragging it off a table puts it back on the floor;
    /// - otherwise the current `position.z`: a piece that was lifted by hand keeps its height.
    public static func z(for inst: FurnitureInstance, at xy: P2, in project: Project, excluding: Set<UUID> = [],
                         wasResting: Bool? = nil, showLamps: Bool = true) -> MM {
        guard !inst.allowsOverlap, let def = project.definition(inst.definitionId) else { return inst.position.z }
        let field = RestingField(project: project, levelId: inst.levelId, excluding: excluding.union([inst.id]),
                                 group: inst.groupId, showLamps: showLamps)
        let resting = wasResting ?? field.isResting(inst, definition: def)
        var moved = inst
        moved.position = P3(xy.x, xy.y, inst.position.z)
        return field.z(outline: FurnitureResolver.collisionOutline(of: moved, definition: def),
                       height: Double(FurnitureResolver.size(of: inst, definition: def).height), current: inst.position.z,
                       wasResting: resting)
    }

    /// Where the view ray (origin, direction in world mm; `elevation` is the level's floor height) first meets the top of a
    /// surface of `field`, as plan point and surface; the nearest hit in front of the eye wins. Used by the 3D drop to
    /// place a piece onto a table instead of behind it. Nil when nothing is hit, or when the piece (`piece`, upright
    /// and unrotated, centred on the hit) does not fit on the surface it hits: the caller then uses the floor point.
    public static func rayHit(origin: SIMD3<Double>, direction: SIMD3<Double>, elevation: Double, field: RestingField,
                              piece: Size3, maxDistance: Double = DropPoint.maxDistance) -> (xy: V2, top: Double)? {
        guard direction.z < -1e-9 else { return nil }
        var best: (t: Double, xy: V2, top: Double)?
        for s in field.surfaces {
            let t = (elevation + s.top - origin.z) / direction.z
            guard t > 0, t <= maxDistance else { continue }
            let hit = V2(origin.x + direction.x * t, origin.y + direction.y * t)
            guard s.contains([hit]) else { continue }
            if best == nil || t < best!.t { best = (t, hit, s.top) }
        }
        guard let best else { return nil }
        let hw = Double(piece.width) / 2, hd = Double(piece.depth) / 2
        let outline = [V2(-hw, -hd), V2(hw, -hd), V2(hw, hd), V2(-hw, hd)].map { $0 + best.xy }
        return field.carrier(of: outline, height: Double(piece.height)) == nil ? nil : (best.xy, best.top)
    }
}

/// All surfaces a piece could stand on at one moment, collected once (per drag or per drop).
public struct RestingField: Sendable {
    /// Surfaces that qualify as carriers regardless of the piece: shown, not a lamp, not free, between
    /// `minCarrierTop` and `maxCarrierTop` and below the ceiling.
    public private(set) var surfaces: [RestingSurface] = []
    /// Every component of every shown piece (also free ones and lamps), to see what is in the way above a surface.
    private var obstacles: [TopViewShape] = []
    /// Level height, mm: a piece has to end below it.
    public let ceiling: Double

    /// Surfaces of the non-free furniture of the level that `Project.isInstanceShown` shows, without `excluding` and
    /// without members of `group`. Lamps are never carriers.
    public init(project p: Project, levelId: UUID, excluding: Set<UUID>, group: UUID?, showLamps: Bool = true) {
        ceiling = Double(p.level(levelId)?.height ?? 0)
        var moving = excluding
        for g in p.groups where excluding.contains(g.id) { moving.formUnion(g.memberIds) }
        for inst in p.instances where inst.levelId == levelId && inst.visible && !moving.contains(inst.id) {
            if let g = group, inst.groupId == g { continue }
            guard let def = p.definition(inst.definitionId), p.isInstanceShown(inst, showLamps: showLamps) else { continue }
            let shapes = FurnitureTopView.make(inst, definition: def, colors: [:], levelElevation: 0).shapes
            obstacles.append(contentsOf: shapes)
            guard !def.isLamp, !CollisionChecker.isFree(inst, definition: def) else { continue }
            surfaces.append(contentsOf: RestingSurface.surfaces(of: inst.id, shapes: shapes).filter {
                $0.top >= RestingSurface.minCarrierTop && $0.top <= RestingSurface.maxCarrierTop && $0.top < ceiling
            })
        }
    }

    /// The surface a piece with this outline and height would be placed on, if any. A surface counts when it holds
    /// the whole outline, the piece fits under the ceiling and no component of any piece reaches into the piece's
    /// volume above it. Carriers standing on the floor win over hanging ones; within a class the highest wins.
    public func carrier(of outline: [V2], height: Double) -> RestingSurface? {
        func standing(_ s: RestingSurface) -> Bool { s.carrierBottom <= RestingSurface.standingCarrierBottom }
        return surfaces.filter {
            $0.contains(outline) && $0.top + height <= ceiling
                && !RestingSurface.intrudes(outline, z0: $0.top, z1: $0.top + height, shapes: obstacles)
        }.max { a, b in standing(a) != standing(b) ? standing(b) : a.top < b.top }
    }

    /// Height for a footprint: the top of its carrier (whole mm), else 0 for a piece that was resting, else `current`.
    public func z(outline: [V2], height: Double, current: MM, wasResting: Bool) -> MM {
        if let s = carrier(of: outline, height: height) { return MM(s.top.rounded()) }
        return wasResting ? 0 : current
    }

    /// Does the instance stand on one of the surfaces right now?
    public func isResting(_ inst: FurnitureInstance, definition def: FurnitureDefinition) -> Bool {
        guard inst.position.z > 0 else { return false }
        let outline = FurnitureResolver.collisionOutline(of: inst, definition: def)
        return RestingSurface.supporting(outline, z0: Double(inst.position.z), among: surfaces) != nil
    }
}

/// Resting heights while one piece is dragged. Built once at the start of the drag (the other furniture does not
/// change during it); the height is a pure function of where the piece currently is.
public struct RestingDrag: Sendable {
    public let id: UUID
    public let startZ: MM
    public let wasResting: Bool
    public let height: Double
    let field: RestingField
    /// Footprint at the start of the drag; translated by the drag delta.
    let outline: [V2]

    /// Nil unless exactly one furniture piece outside a group is dragged (a selection moves as it was: shared z).
    /// Pieces with `allowsOverlap` are never put onto furniture either.
    public init?(project p: Project, levelId: UUID, ids: Set<UUID>, showLamps: Bool = true) {
        guard ids.count == 1, let id = ids.first, let inst = p.instance(id), inst.levelId == levelId, inst.groupId == nil,
              !inst.allowsOverlap,
              !p.groups.contains(where: { $0.memberIds.contains(id) }), let def = p.definition(inst.definitionId) else { return nil }
        self.id = id
        field = RestingField(project: p, levelId: levelId, excluding: [id], group: nil, showLamps: showLamps)
        startZ = inst.position.z
        wasResting = field.isResting(inst, definition: def)
        height = Double(FurnitureResolver.size(of: inst, definition: def).height)
        outline = FurnitureResolver.collisionOutline(of: inst, definition: def)
    }

    func moved(_ delta: V2) -> [V2] { outline.map { $0 + delta } }

    /// The carrier at this displacement from the start.
    public func carrier(at delta: V2) -> RestingSurface? { field.carrier(of: moved(delta), height: height) }

    /// Height of the piece at this displacement from the start.
    public func z(at delta: V2) -> MM { field.z(outline: moved(delta), height: height, current: startZ, wasResting: wasResting) }

    /// `MoveContact.resolve` for a piece that may climb onto furniture: the piece is tested at the height it will have
    /// (resolved in at most three passes, because the contact moves it and the height depends on where it ends), and
    /// its carrier never blocks it. Returns the contact result and the height change against the start.
    public func resolve(moving: [ContactBody], raw: V2, obstacles: [ContactObstacle], tolerance: Double,
                        slide: Bool) -> (result: ContactResult, dz: MM) {
        var target = raw
        var res = ContactResult(delta: raw, contact: false, guides: [])
        for _ in 0..<3 {
            let z = self.z(at: target)
            let carrierId = carrier(at: target)?.carrierId
            let lift = Double(z - startZ)
            let shifted = moving.map { b -> ContactBody in
                var c = b; c.z0 += lift; c.z1 += lift; return c
            }
            let open = carrierId == nil ? obstacles : obstacles.filter { $0.id != carrierId }
            res = MoveContact.resolve(moving: shifted, raw: raw, obstacles: open, tolerance: tolerance, slide: slide)
            if self.z(at: res.delta) == z { return (res, z - startZ) }
            target = res.delta
        }
        return (res, z(at: res.delta) - startZ)
    }
}
