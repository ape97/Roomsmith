import Foundation
import simd

/// Which parts of a lamp light up while it is switched on: for every emitter the largest visible part whose box (grown by
/// `margin`) holds the emitter, usually the shade or the bulb around it. Pure data; the renderer gives those parts an
/// emissive glow in the averaged lamp colour.
public enum LampGlow {
    /// Slack around a part's box, so an emitter placed right at a shade's opening still finds the shade.
    public static let margin = 20.0

    public struct Glow: Equatable, Sendable {
        public var componentIds: Set<UUID>
        /// Mean emitter colour, linear-ish RGB 0...1.
        public var color: SIMD3<Double>
    }

    /// nil when the definition has no emitters or no visible part holds one. `state` is the instance's current state.
    public static func glow(definition def: FurnitureDefinition, state: FurnitureState?) -> Glow? {
        guard !def.lights.isEmpty else { return nil }
        var boxes: [(id: UUID, lo: SIMD3<Double>, hi: SIMD3<Double>, volume: Double)] = []
        for c in def.components {
            let p = FurnitureResolver.pose(of: c, state: state)
            guard p.visible else { continue }
            let m = FurnitureResolver.componentMatrix(position: p.position, size: p.size, rotation: p.rotation, pivot: c.pivot)
            var lo = SIMD3(repeating: Double.infinity), hi = SIMD3(repeating: -Double.infinity)
            for ix in [-0.5, 0.5] { for iy in [-0.5, 0.5] { for iz in [-0.5, 0.5] {
                let q = m * SIMD4(ix, iy, iz, 1)
                lo = simd_min(lo, SIMD3(q.x, q.y, q.z)); hi = simd_max(hi, SIMD3(q.x, q.y, q.z))
            } } }
            boxes.append((c.id, lo - SIMD3(repeating: margin), hi + SIMD3(repeating: margin),
                          Double(p.size.width) * Double(p.size.depth) * Double(p.size.height)))
        }
        var ids = Set<UUID>()
        var sum = SIMD3<Double>(repeating: 0)
        var lit = 0
        for e in def.lights {
            let q = SIMD3(Double(e.position.x), Double(e.position.y), Double(e.position.z))
            var best: (id: UUID, volume: Double)?
            for b in boxes where all(q .>= b.lo) && all(q .<= b.hi) && b.volume > (best?.volume ?? -1) {
                best = (b.id, b.volume)
            }
            guard let best else { continue }
            ids.insert(best.id)
            sum += e.rgb
            lit += 1
        }
        guard lit > 0 else { return nil }
        return Glow(componentIds: ids, color: sum / Double(lit))
    }
}
