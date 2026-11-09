import Foundation
import simd

// The Z arrow of the gizmo: a piece pulled up or down is drawn onto the tops of the furniture below it, against the
// undersides above it and onto the floor. Pure geometry; the 3D view asks it once per drag.

/// Heights a dragged selection can stop at while it moves straight up or down. The footprint does not change during
/// such a drag, so the stops are collected once at the start.
///
/// Unlike `RestingField` this is what happens when somebody lifts a piece by hand: a top counts at any height (also
/// above `RestingSurface.maxCarrierTop`) and the piece only has to overlap it, not to fit on it.
public struct VerticalContact: Sendable, Equatable {
    /// Displacements from the start in whole mm, ascending, without duplicates.
    public let stops: [MM]

    init(stops: [MM]) { self.stops = stops }

    /// Stops of the pieces `moving` (groups expand) against every other shown piece of the level. Lamps and rugs do not
    /// count; a stop that would push the piece through the floor is left out.
    public init(project p: Project, levelId: UUID, moving: Set<UUID>) {
        var ids = moving
        for g in p.groups where moving.contains(g.id) { ids.formUnion(g.memberIds) }
        var bodies: [(outline: [V2], z0: Double, z1: Double)] = []
        var faces: [TopViewShape] = []
        for inst in p.instances where inst.levelId == levelId && inst.visible {
            guard let def = p.definition(inst.definitionId) else { continue }
            if ids.contains(inst.id) {
                let height = Double(FurnitureResolver.size(of: inst, definition: def).height)
                bodies.append((FurnitureResolver.collisionOutline(of: inst, definition: def),
                               Double(inst.position.z), Double(inst.position.z) + height))
            } else if !def.isLamp, !CollisionChecker.isFlatOnFloor(inst, definition: def) {
                faces.append(contentsOf: FurnitureTopView.make(inst, definition: def, colors: [:], levelElevation: 0).shapes)
            }
        }
        var found = Set<MM>()
        for b in bodies {
            for f in faces where penetration(b.outline, f.points) != nil {
                if f.topZ > 1 { found.insert(MM((f.topZ - b.z0).rounded())) }
                if f.bottomZ > 1, f.bottomZ >= b.z1 - b.z0 { found.insert(MM((f.bottomZ - b.z1).rounded())) }
            }
        }
        if let lowest = bodies.map(\.z0).min() { found.insert(MM((-lowest).rounded())) }
        stops = found.sorted()
    }

    /// The stop closest to the displacement `raw` when it is within `tolerance` (mm), else nil.
    public func stop(near raw: Double, tolerance: Double) -> MM? {
        guard let best = stops.min(by: { abs(Double($0) - raw) < abs(Double($1) - raw) }),
              abs(Double(best) - raw) <= tolerance else { return nil }
        return best
    }
}
