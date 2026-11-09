import Foundation
import simd

/// Where a dragged piece lands: the grid rounding shared by the plan, the 3D view and the library drop, as pure functions.
public enum DropPoint {
    /// Farthest floor hit from the eye (mm). Rays close to the horizon would otherwise throw furniture kilometres away.
    public static let maxDistance = 200_000.0

    /// Grid-snaps a point. `modifierOff` is the Option key: it turns snapping off, leaving plain mm rounding.
    /// Snapping needs `settings.enabled` and `settings.toGrid`.
    public static func snapped(_ x: Double, _ y: Double, settings: SnapSettings, modifierOff: Bool = false) -> P2 {
        let on = settings.enabled && settings.toGrid && !modifierOff
        return P2(SnapEngine.snapDelta(x, grid: settings.grid, enabled: on), SnapEngine.snapDelta(y, grid: settings.grid, enabled: on))
    }

    public static func snapped(_ p: P2, settings: SnapSettings, modifierOff: Bool = false) -> P2 {
        snapped(Double(p.x), Double(p.y), settings: settings, modifierOff: modifierOff)
    }

    /// Point (plan mm) where a view ray meets the floor plane at `elevation` (mm, the active level's height), snapped.
    /// Nil when the ray runs parallel to the floor, points away from it, hits it beyond `maxDistance`, or lands outside
    /// the allowed coordinate range.
    public static func onFloor(origin: SIMD3<Double>, direction: SIMD3<Double>, elevation: Double, settings: SnapSettings,
                               modifierOff: Bool = false) -> P2? {
        guard abs(direction.z) > 1e-9 else { return nil }
        let t = (elevation - origin.z) / direction.z
        guard t > 0, t <= maxDistance else { return nil }
        let hit = origin + direction * t
        let p = snapped(hit.x, hit.y, settings: settings, modifierOff: modifierOff)
        return p.isInRange ? p : nil
    }
}
