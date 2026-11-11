import Foundation
import simd

/// A furniture component after applying the instance's state, size, option selection and material overrides.
public struct ResolvedComponent: Sendable, Equatable {
    public var componentId: UUID
    public var name: String
    public var shape: PrimitiveShape
    /// Local (definition space, mm) centre, size, rotation and pivot after the state pose.
    public var position: P3
    public var size: Size3
    public var rotation: R3
    public var pivot: P3?
    public var materialId: UUID?
    public var meshAssetId: UUID?
    public var visible: Bool
    /// Transform from the unit primitive (centred at the origin, spanning -0.5…0.5 on every axis) to world mm.
    public var worldMatrix: simd_double4x4
}

public enum Transform {
    public static func translation(_ x: Double, _ y: Double, _ z: Double) -> simd_double4x4 {
        var m = matrix_identity_double4x4
        m.columns.3 = SIMD4(x, y, z, 1)
        return m
    }
    public static func scale(_ x: Double, _ y: Double, _ z: Double) -> simd_double4x4 {
        simd_double4x4(diagonal: SIMD4(x, y, z, 1))
    }
    /// Rotation by Euler degrees: X first, then Y, then Z.
    public static func rotation(_ r: R3) -> simd_double4x4 {
        func rad(_ d: Double) -> Double { d * .pi / 180 }
        let qx = simd_quatd(angle: rad(r.x), axis: SIMD3(1, 0, 0))
        let qy = simd_quatd(angle: rad(r.y), axis: SIMD3(0, 1, 0))
        let qz = simd_quatd(angle: rad(r.z), axis: SIMD3(0, 0, 1))
        return simd_double4x4(qz * qy * qx)
    }
    public static func rotationZ(_ deg: Double) -> simd_double4x4 { rotation(R3(0, 0, deg)) }
    public static func translation(_ p: P3) -> simd_double4x4 { translation(Double(p.x), Double(p.y), Double(p.z)) }
}

/// One convex outline of a piece in a moving state (see `FurnitureResolver.collisionParts`).
public struct CollisionPart: Sendable, Equatable {
    /// Convex outline in world mm, counter-clockwise.
    public var outline: [V2]
    /// A part that sticks out of the closed footprint (door, drawer, folded-down bed). False: the body.
    public var swings: Bool
    /// World position of the hinge (pivot) of a swinging part; nil for the body.
    public var hinge: V2? = nil
}

public enum FurnitureResolver {
    /// Effective size of an instance (exact mm).
    public static func size(of inst: FurnitureInstance, definition def: FurnitureDefinition) -> Size3 {
        if let s = inst.size { return s }
        if let sid = inst.stateId, let st = def.states.first(where: { $0.id == sid }), let s = st.size { return s }
        return def.size
    }

    /// Footprint rectangle of an instance in its own frame (before rotation and translation), relative to `position`.
    /// Without a state pose it is the size rectangle centred on the position. A state that moves components can
    /// grow to one side (wall bed, open drawer), so its rectangle is the XY hull of the visible components in that
    /// state (a part hidden by an option does not count), scaled like the instance. Falls back to the centred size
    /// rectangle when nothing is visible.
    public static func localFootprint(of inst: FurnitureInstance, definition def: FurnitureDefinition) -> (center: V2, half: V2) {
        let s = size(of: inst, definition: def)
        let centred = (center: V2.zero, half: V2(Double(s.width) / 2, Double(s.depth) / 2))
        guard let sid = inst.stateId, let state = def.states.first(where: { $0.id == sid }), !state.poses.isEmpty else { return centred }
        let base = inst.size ?? def.size
        let sx = Double(base.width) / Double(max(def.size.width, 1))
        let sy = Double(base.depth) / Double(max(def.size.depth, 1))
        var lo = V2(.infinity, .infinity), hi = V2(-.infinity, -.infinity)
        let options = optionOutcome(of: inst, definition: def)
        for c in def.components {
            let p = pose(of: c, state: state)
            guard p.visible, !options.hidden.contains(c.id) else { continue }
            let m = componentMatrix(position: p.position, size: p.size, rotation: p.rotation, pivot: c.pivot)
            for ix in [-0.5, 0.5] { for iy in [-0.5, 0.5] { for iz in [-0.5, 0.5] {
                let q = m * SIMD4(ix, iy, iz, 1)
                lo = V2(min(lo.x, q.x * sx), min(lo.y, q.y * sy))
                hi = V2(max(hi.x, q.x * sx), max(hi.y, q.y * sy))
            } } }
        }
        guard lo.x.isFinite, hi.x.isFinite, hi.x > lo.x, hi.y > lo.y else { return centred }
        return (center: (lo + hi) / 2, half: (hi - lo) / 2)
    }

    /// Footprint of an instance in world mm. `position` is the footprint centre for the base pose; states that
    /// grow one-sidedly offset the rectangle centre (see `localFootprint`).
    public static func footprint(of inst: FurnitureInstance, definition def: FurnitureDefinition) -> OrientedRect {
        let local = localFootprint(of: inst, definition: def)
        let r = inst.rotationDeg * .pi / 180
        let offset = V2(cos(r) * local.center.x - sin(r) * local.center.y, sin(r) * local.center.x + cos(r) * local.center.y)
        return OrientedRect(center: inst.position.xy.v + offset, halfSize: local.half, rotationDeg: inst.rotationDeg)
    }

    /// Convex outlines (world mm, counter-clockwise) a piece in a moving state really occupies, instead of the one
    /// rectangle around everything (`footprint`). The parts that stay inside the closed size rectangle (carcass,
    /// shelves) form one rectangle; every part that sticks out of it (a swung-open door, a pulled drawer, a folded-down
    /// bed) is its own convex outline. Two cabinets side by side with open doors therefore touch only where a door
    /// really reaches the neighbour. Nil when the footprint is a single shape: no state pose, a round piece, or nothing
    /// sticks out (then `collisionOutline` is already exact).
    public static func collisionParts(of inst: FurnitureInstance, definition def: FurnitureDefinition) -> [CollisionPart]? {
        guard let sid = inst.stateId, let state = def.states.first(where: { $0.id == sid }), !state.poses.isEmpty,
              footprintPolygon(of: inst, definition: def) == nil else { return nil }
        let base = inst.size ?? def.size
        let sx = Double(base.width) / Double(max(def.size.width, 1))
        let sy = Double(base.depth) / Double(max(def.size.depth, 1))
        let hx = Double(base.width) / 2 + 1, hy = Double(base.depth) / 2 + 1
        let options = optionOutcome(of: inst, definition: def)
        var bodyLo = V2(.infinity, .infinity), bodyHi = V2(-.infinity, -.infinity)
        var extras: [(outline: [V2], hinge: V2)] = []
        for c in def.components {
            let p = pose(of: c, state: state)
            guard p.visible, !options.hidden.contains(c.id) else { continue }
            let m = componentMatrix(position: p.position, size: p.size, rotation: p.rotation, pivot: c.pivot)
            var pts: [V2] = []
            for ix in [-0.5, 0.5] { for iy in [-0.5, 0.5] { for iz in [-0.5, 0.5] {
                let q = m * SIMD4(ix, iy, iz, 1)
                pts.append(V2(q.x * sx, q.y * sy))
            } } }
            if pts.allSatisfy({ abs($0.x) <= hx && abs($0.y) <= hy }) {
                for q in pts { bodyLo = V2(min(bodyLo.x, q.x), min(bodyLo.y, q.y)); bodyHi = V2(max(bodyHi.x, q.x), max(bodyHi.y, q.y)) }
            } else {
                let hull = FurnitureTopView.convexHull(pts)
                let pv = c.pivot ?? c.position
                if hull.count >= 3 { extras.append((hull, V2(Double(pv.x) * sx, Double(pv.y) * sy))) }
            }
        }
        guard !extras.isEmpty else { return nil }
        var local = extras.map { CollisionPart(outline: $0.outline, swings: true, hinge: $0.hinge) }
        if bodyLo.x.isFinite, bodyHi.x > bodyLo.x, bodyHi.y > bodyLo.y {
            local.insert(CollisionPart(outline: [bodyLo, V2(bodyHi.x, bodyLo.y), bodyHi, V2(bodyLo.x, bodyHi.y)], swings: false), at: 0)
        }
        let r = inst.rotationDeg * .pi / 180
        let c = cos(r), s = sin(r), origin = inst.position.xy.v
        return local.map { part in
            func world(_ q: V2) -> V2 { origin + V2(c * q.x - s * q.y, s * q.x + c * q.y) }
            return CollisionPart(outline: part.outline.map(world), swings: part.swings, hinge: part.hinge.map(world))
        }
    }

    /// Number of corners of the polygon that stands for a round footprint (inscribed, so a circle never reaches further
    /// than the real one).
    static let roundSegments = 48

    /// A piece whose footprint is a circle or ellipse: it has a visible, upright cylinder that fills the whole design
    /// size and is centred on the position (or a taper, upright or upside down), and every other visible part of the base
    /// pose lies inside that ellipse. Round tables, trays, pots and stools qualify; a cylinder with a square leg frame sticking out of it does not.
    public static func isRound(definition def: FurnitureDefinition) -> Bool {
        let w = Double(def.size.width), d = Double(def.size.depth)
        guard w >= 1, d >= 1 else { return false }
        // An upright cylinder or taper, or a taper turned upside down (a pot): its widest ellipse is width × depth.
        func upright(_ c: Component) -> Bool {
            switch c.shape {
            case .cylinder: c.rotation.x == 0 && c.rotation.y == 0
            case .taper: c.rotation.y == 0 && (c.rotation.x == 0 || abs(c.rotation.x) == 180)
            default: false
            }
        }
        func fills(_ c: Component) -> Bool {
            guard upright(c), c.visible else { return false }
            if c.rotation.z != 0, abs(w - d) > 1 { return false }
            return abs(Double(c.size.width) - w) <= 1 && abs(Double(c.size.depth) - d) <= 1
                && abs(Double(c.position.x)) <= 1 && abs(Double(c.position.y)) <= 1
        }
        guard def.components.contains(where: fills) else { return false }
        let a = w / 2 + 1, b = d / 2 + 1
        for c in def.components where c.visible {
            let m = componentMatrix(position: c.position, size: c.size, rotation: c.rotation, pivot: c.pivot)
            // An upright cylinder or taper is checked along its widest rim, every other part by its box corners.
            let rim = upright(c) && c.rotation.z == 0
            let pts: [(Double, Double)] = rim
                ? (0..<16).map { (0.5 * cos(Double.pi / 8 * Double($0)), 0.5 * sin(Double.pi / 8 * Double($0))) }
                : [(-0.5, -0.5), (0.5, -0.5), (0.5, 0.5), (-0.5, 0.5)]
            for (ix, iy) in pts {
                let q = m * SIMD4(ix, iy, 0, 1)
                if (q.x / a) * (q.x / a) + (q.y / b) * (q.y / b) > 1 + 1e-9 { return false }
            }
        }
        return true
    }

    /// Footprint polygon of a round instance in world mm (counter-clockwise, `roundSegments` corners inscribed in the
    /// ellipse of the instance size). Nil for every other piece, and for a state that moves components (its footprint
    /// is the hull of the parts, not an ellipse): those collide as their rectangle (`footprint(of:definition:)`).
    public static func footprintPolygon(of inst: FurnitureInstance, definition def: FurnitureDefinition) -> [V2]? {
        guard isRound(definition: def) else { return nil }
        let local = localFootprint(of: inst, definition: def)
        guard abs(local.center.x) < 1e-9, abs(local.center.y) < 1e-9 else { return nil }
        let r = footprint(of: inst, definition: def)
        let (ax, ay) = r.axes
        return (0..<roundSegments).map { i in
            let t = 2 * Double.pi * Double(i) / Double(roundSegments)
            return r.center + ax * (cos(t) * r.halfSize.x) + ay * (sin(t) * r.halfSize.y)
        }
    }

    /// The outline an instance collides with: the round polygon, else the rectangle corners.
    public static func collisionOutline(of inst: FurnitureInstance, definition def: FurnitureDefinition) -> [V2] {
        footprintPolygon(of: inst, definition: def) ?? footprint(of: inst, definition: def).corners
    }

    /// Instance transform: definition space (mm) → world mm, including non-uniform scale to the instance size.
    /// `levelElevation` is added to Z.
    public static func instanceMatrix(_ inst: FurnitureInstance, definition def: FurnitureDefinition, levelElevation: MM = 0) -> simd_double4x4 {
        // Only an explicit instance size scales the design; state sizes describe the footprint, not a scale.
        let s = inst.size ?? def.size
        let base = def.size
        let sx = Double(s.width) / Double(max(base.width, 1))
        let sy = Double(s.depth) / Double(max(base.depth, 1))
        let sz = Double(s.height) / Double(max(base.height, 1))
        return Transform.translation(Double(inst.position.x), Double(inst.position.y), Double(inst.position.z + levelElevation))
            * Transform.rotationZ(inst.rotationDeg)
            * Transform.scale(sx, sy, sz)
    }

    /// Component pose for a state (nil state = base components).
    public static func pose(of c: Component, state: FurnitureState?) -> (position: P3, size: Size3, rotation: R3, visible: Bool) {
        let o = state?.poses[c.id]
        return (o?.position ?? c.position, o?.size ?? c.size, o?.rotation ?? c.rotation, o?.visible ?? c.visible)
    }

    /// Local matrix of a component for given pose values: unit primitive → definition space.
    public static func componentMatrix(position: P3, size: Size3, rotation: R3, pivot: P3?) -> simd_double4x4 {
        let scale = Transform.scale(Double(size.width), Double(size.depth), Double(size.height))
        if rotation.isZero { return Transform.translation(position) * scale }
        // Rotate around the pivot (definition space). Without pivot: around the part centre.
        let pv = pivot ?? position
        let toPivot = Transform.translation(pv)
        let fromPivot = Transform.translation(-Double(pv.x), -Double(pv.y), -Double(pv.z))
        return toPivot * Transform.rotation(rotation) * fromPivot * Transform.translation(position) * scale
    }

    public static func resolve(_ inst: FurnitureInstance, in project: Project, levelElevation: MM? = nil) -> [ResolvedComponent] {
        guard let def = project.definitions.first(where: { $0.id == inst.definitionId }) else { return [] }
        let elev = levelElevation ?? project.levels.first(where: { $0.id == inst.levelId })?.elevation ?? 0
        return resolve(inst, definition: def, levelElevation: elev)
    }

    public static func resolve(_ inst: FurnitureInstance, definition def: FurnitureDefinition, levelElevation: MM = 0) -> [ResolvedComponent] {
        let state = inst.stateId.flatMap { sid in def.states.first { $0.id == sid } }
        let m = instanceMatrix(inst, definition: def, levelElevation: levelElevation)
        let options = optionOutcome(of: inst, definition: def)
        return def.components.map { c in
            let p = pose(of: c, state: state)
            let local = componentMatrix(position: p.position, size: p.size, rotation: p.rotation, pivot: c.pivot)
            return ResolvedComponent(componentId: c.id, name: c.name, shape: c.shape, position: p.position, size: p.size,
                                     rotation: p.rotation, pivot: c.pivot,
                                     materialId: materialId(of: c, inst: inst, options: options), meshAssetId: c.meshAssetId,
                                     visible: p.visible && inst.visible && !options.hidden.contains(c.id), worldMatrix: m * local)
        }
    }
}
