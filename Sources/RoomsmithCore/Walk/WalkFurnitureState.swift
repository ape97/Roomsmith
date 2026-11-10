import Foundation
import simd

/// Walk mode: which furniture piece with several states the walker works with E, and which state comes next.
/// Pure logic; the app applies the result through the command engine (`activateState`).
public enum WalkFurnitureState {
    /// Closer than this the piece counts as in view whatever the look direction (same as doors).
    public static let alwaysInViewMm = 400.0
    /// Minimum dot product of the look direction and the direction to the piece centre beyond `alwaysInViewMm`.
    public static let viewCone = 0.34

    /// Distance in mm from `eye` to the footprint rectangle (0 when inside) and whether it is in view.
    /// `forward` must be a unit vector.
    static func reachInfo(of rect: OrientedRect, eye: V2, forward: V2) -> (distance: Double, inView: Bool) {
        let (ax, ay) = rect.axes
        let d = eye - rect.center
        let lx = max(abs(simd_dot(d, ax)) - rect.halfSize.x, 0), ly = max(abs(simd_dot(d, ay)) - rect.halfSize.y, 0)
        let dist = (lx * lx + ly * ly).squareRoot()
        let toMid = rect.center - eye
        let len = simd_length(toMid)
        if len > alwaysInViewMm, simd_dot(toMid / len, forward) < viewCone { return (dist, false) }
        return (dist, true)
    }

    /// The nearest visible piece on `levelId` with at least two states within `reachMm` of `eye` and in view: id and
    /// distance. Locked pieces (also by group or level) are skipped:
    /// switching a state is an edit and would be refused, and the piece must not shadow an opening behind it.
    public static func nearest(project: Project, levelId: UUID, eye: V2, forward: V2, reachMm: Double) -> (id: UUID, distance: Double)? {
        var best: (id: UUID, distance: Double)?
        for inst in project.instances where inst.levelId == levelId && inst.visible && !project.isLocked(inst.id) {
            guard let def = project.definition(inst.definitionId), def.states.count >= 2 else { continue }
            let info = reachInfo(of: FurnitureResolver.footprint(of: inst, definition: def), eye: eye, forward: forward)
            guard info.distance <= reachMm, info.inView else { continue }
            if best == nil || info.distance < best!.distance { best = (inst.id, info.distance) }
        }
        return best
    }

    /// The state after the current one, in definition order, wrapping around. A piece in the base pose (or in a state
    /// that no longer exists) goes to the first state. Nil when the design has fewer than two states.
    public static func nextStateId(for inst: FurnitureInstance, definition def: FurnitureDefinition) -> UUID? {
        guard def.states.count >= 2 else { return nil }
        guard let cur = inst.stateId, let i = def.states.firstIndex(where: { $0.id == cur }) else { return def.states[0].id }
        return def.states[(i + 1) % def.states.count].id
    }
}
