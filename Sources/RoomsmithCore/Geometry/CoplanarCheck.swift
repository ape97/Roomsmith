import Foundation
import simd

/// Finds faces that would flicker (z-fighting) when drawn: two faces of box parts of one definition that point the same
/// way, lie in the same plane and overlap. The renderer culls back faces, so opposite-facing coplanar faces (a part
/// resting on another) are harmless and are not reported. Pure geometry; no rendering involved.
public enum CoplanarCheck {
    /// Planes closer than this count as the same plane. The 24-bit depth buffer of the 3D view resolves about 0.06 mm at 10 m
    /// and about 1.5 mm at 50 m (rule of thumb), so surfaces closer than half a millimetre fight at ordinary room distances,
    /// while the smallest deliberate gap in the catalog (door to carcass, 2 mm) stays clear of it.
    public static let toleranceMm = 0.5
    /// Overlaps smaller than this (mm²) are touching edges, not surfaces.
    public static let minOverlapMm2 = 1.0

    public struct Hit: Equatable, Sendable {
        public var componentA: UUID
        public var componentB: UUID
        public var nameA: String
        public var nameB: String
        /// State in which the pair overlaps; nil = base pose.
        public var stateId: UUID?
        /// Distance between the two planes in mm.
        public var gapMm: Double
        public var overlapMm2: Double
    }

    /// Same-direction coplanar overlaps between the box-like parts (box, panel, rounded box) of a definition, in the base
    /// pose and in every state. Each pair is reported once. A rounded box counts as its full box: its flat faces lie in
    /// the box planes, so the check stays conservative. Cushion, cylindrical, tapered, spherical and mesh parts are skipped.
    public static func check(_ def: FurnitureDefinition) -> [Hit] {
        var out: [Hit] = []
        var seen = Set<[UUID]>()
        let states: [FurnitureState?] = [nil] + def.states.map { Optional($0) }
        for state in states {
            for hit in check(def, state: state) {
                let key = [hit.componentA, hit.componentB]
                if seen.insert(key).inserted { out.append(hit) }
            }
        }
        return out
    }

    // MARK: - Geometry

    private struct Face {
        var component: Int
        var normal: SIMD3<Double>
        var center: SIMD3<Double>
        var corners: [SIMD3<Double>]
        var lo: SIMD3<Double>
        var hi: SIMD3<Double>
    }

    private static func check(_ def: FurnitureDefinition, state: FurnitureState?) -> [Hit] {
        var faces: [Face] = []
        var parts: [Component] = []
        for c in def.components where c.shape == .box || c.shape == .panel || c.shape == .rounded {
            let pose = FurnitureResolver.pose(of: c, state: state)
            guard pose.visible else { continue }
            let m = FurnitureResolver.componentMatrix(position: pose.position, size: pose.size, rotation: pose.rotation, pivot: c.pivot)
            faces += boxFaces(m, index: parts.count)
            parts.append(c)
        }
        var out: [Hit] = []
        for i in 0..<faces.count {
            for j in (i + 1)..<faces.count where faces[i].component != faces[j].component {
                let a = faces[i], b = faces[j]
                guard simd_dot(a.normal, b.normal) > 1 - 1e-6 else { continue }
                let gap = abs(simd_dot(a.normal, a.center - b.center))
                guard gap < toleranceMm else { continue }
                // Boxes that are apart (by more than the tolerance) in any axis cannot overlap.
                guard all(a.lo .<= b.hi + toleranceMm), all(b.lo .<= a.hi + toleranceMm) else { continue }
                let area = overlapArea(a, b)
                guard area > minOverlapMm2 else { continue }
                let (p, q) = faces[i].component < faces[j].component ? (a.component, b.component) : (b.component, a.component)
                out.append(Hit(componentA: parts[p].id, componentB: parts[q].id, nameA: parts[p].name, nameB: parts[q].name,
                               stateId: state?.id, gapMm: gap, overlapMm2: area))
            }
        }
        return out
    }

    /// The six outward faces of the unit cube transformed by `m` (unit primitive to definition space).
    private static func boxFaces(_ m: simd_double4x4, index: Int) -> [Face] {
        func world(_ p: SIMD3<Double>) -> SIMD3<Double> {
            let v = m * SIMD4(p.x, p.y, p.z, 1)
            return SIMD3(v.x, v.y, v.z)
        }
        let centre = world(.zero)
        var out: [Face] = []
        for axis in 0..<3 {
            for sign in [-0.5, 0.5] {
                let u = (axis + 1) % 3, v = (axis + 2) % 3
                var corners: [SIMD3<Double>] = []
                for (du, dv) in [(-0.5, -0.5), (0.5, -0.5), (0.5, 0.5), (-0.5, 0.5)] {
                    var p = SIMD3<Double>.zero
                    p[axis] = sign; p[u] = du; p[v] = dv
                    corners.append(world(p))
                }
                var n = simd_cross(corners[1] - corners[0], corners[2] - corners[0])
                let len = simd_length(n)
                guard len > 1e-9 else { continue }   // a zero-thickness side has no area
                n /= len
                let fc = corners.reduce(SIMD3<Double>.zero, +) / 4
                if simd_dot(n, fc - centre) < 0 { n = -n }
                out.append(Face(component: index, normal: n, center: fc, corners: corners,
                                lo: corners.reduce(corners[0]) { simd_min($0, $1) }, hi: corners.reduce(corners[0]) { simd_max($0, $1) }))
            }
        }
        return out
    }

    /// Area of the intersection of two coplanar convex quads (Sutherland-Hodgman in the plane of `a`).
    private static func overlapArea(_ a: Face, _ b: Face) -> Double {
        let n = a.normal
        let helper: SIMD3<Double> = abs(n.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
        let u = simd_normalize(simd_cross(n, helper)), v = simd_cross(n, u)
        func project(_ f: Face) -> [SIMD2<Double>] {
            let p = f.corners.map { SIMD2(simd_dot($0 - a.center, u), simd_dot($0 - a.center, v)) }
            return signedArea(p) < 0 ? p.reversed() : p
        }
        var poly = project(a)
        let clip = project(b)
        for i in 0..<clip.count {
            let e0 = clip[i], e1 = clip[(i + 1) % clip.count]
            func inside(_ p: SIMD2<Double>) -> Bool { cross2(e1 - e0, p - e0) >= 0 }
            var next: [SIMD2<Double>] = []
            for k in 0..<poly.count {
                let p = poly[k], q = poly[(k + 1) % poly.count]
                let pin = inside(p), qin = inside(q)
                if pin { next.append(p) }
                if pin != qin {
                    let d = q - p
                    let denom = cross2(e1 - e0, d)
                    if abs(denom) > 1e-12 { next.append(p + d * (cross2(e1 - e0, e0 - p) / denom)) }
                }
            }
            poly = next
            if poly.isEmpty { return 0 }
        }
        return abs(signedArea(poly))
    }

    private static func cross2(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x * b.y - a.y * b.x }

    private static func signedArea(_ p: [SIMD2<Double>]) -> Double {
        var s = 0.0
        for i in 0..<p.count { s += cross2(p[i], p[(i + 1) % p.count]) }
        return s / 2
    }
}

/// Identical pieces placed on top of each other: report only, never fixed automatically.
public enum DuplicatePlacementCheck {
    public struct Hit: Equatable, Sendable {
        public var a: UUID
        public var b: UUID
        public var definitionId: UUID
    }

    /// Pairs of instances of one definition with the same level, position, rotation and state.
    public static func check(_ p: Project) -> [Hit] {
        struct Key: Hashable { var def: UUID; var level: UUID; var pos: P3; var rot: Double; var state: UUID? }
        var first: [Key: UUID] = [:]
        var out: [Hit] = []
        for inst in p.instances {
            let key = Key(def: inst.definitionId, level: inst.levelId, pos: inst.position, rot: inst.rotationDeg, state: inst.stateId)
            if let other = first[key] { out.append(Hit(a: other, b: inst.id, definitionId: inst.definitionId)) } else { first[key] = inst.id }
        }
        return out
    }
}
