import Foundation
import RealityKit
import RoomsmithCore
import simd

/// Animated transition of one furniture instance between two states, following the definition's `AnimationTrack`.
/// The final pose is not taken from the animation: when it ends, the renderer re-syncs the instance from
/// `FurnitureResolver`, so the end transforms are exactly the resolved ones.
struct StateAnimation {
    /// Pose of one component in double precision (mm, degrees).
    struct Pose: Equatable {
        var position: D3
        var size: D3
        var rotation: D3
        var visible: Bool

        init(position: D3, size: D3, rotation: D3, visible: Bool) {
            self.position = position; self.size = size; self.rotation = rotation; self.visible = visible
        }
        init(_ p: (position: P3, size: Size3, rotation: R3, visible: Bool)) {
            position = D3(Double(p.position.x), Double(p.position.y), Double(p.position.z))
            size = D3(Double(p.size.width), Double(p.size.depth), Double(p.size.height))
            rotation = D3(p.rotation.x, p.rotation.y, p.rotation.z)
            visible = p.visible
        }
        static func lerp(_ a: Pose, _ b: Pose, _ t: Double) -> Pose {
            Pose(position: a.position + (b.position - a.position) * t, size: a.size + (b.size - a.size) * t,
                 rotation: a.rotation + (b.rotation - a.rotation) * t, visible: a.visible || b.visible)
        }
    }

    struct Waypoint { var t: Double; var pose: Pose }

    var instanceId: UUID
    var duration: Double
    var easing: Easing
    var elapsed = 0.0
    var pivots: [UUID: P3?]
    var waypoints: [UUID: [Waypoint]]
    /// Pose shown last frame; the start of the next animation if this one is interrupted.
    var current: [UUID: Pose]

    var finished: Bool { elapsed >= duration }

    /// Builds the animation from the poses at both ends and the track keyframes. A keyframe field that is nil
    /// is interpolated linearly between start and end at that time.
    static func make(instanceId: UUID, def: FurnitureDefinition, track: AnimationTrack,
                     start: [UUID: Pose], end: [UUID: Pose]) -> StateAnimation {
        var waypoints: [UUID: [Waypoint]] = [:]
        var pivots: [UUID: P3?] = [:]
        for c in def.components {
            guard let s = start[c.id], let e = end[c.id] else { continue }
            pivots[c.id] = c.pivot
            var list = [Waypoint(t: 0, pose: s)]
            for k in track.keyframes.sorted(by: { $0.t < $1.t }) where k.t > 0 && k.t < 1 {
                let lin = Pose.lerp(s, e, k.t)
                var p = lin
                if let o = k.poses[c.id] {
                    if let v = o.position { p.position = D3(Double(v.x), Double(v.y), Double(v.z)) }
                    if let v = o.size { p.size = D3(Double(v.width), Double(v.depth), Double(v.height)) }
                    if let v = o.rotation { p.rotation = D3(v.x, v.y, v.z) }
                }
                p.visible = s.visible || e.visible
                list.append(Waypoint(t: k.t, pose: p))
            }
            list.append(Waypoint(t: 1, pose: e))
            waypoints[c.id] = list
        }
        return StateAnimation(instanceId: instanceId, duration: max(Double(track.durationMs) / 1000, 0.001), easing: track.easing,
                              pivots: pivots, waypoints: waypoints, current: start)
    }

    static func ease(_ t: Double, _ e: Easing) -> Double {
        let x = min(max(t, 0), 1)
        switch e {
        case .linear: return x
        case .easeIn: return x * x * x
        case .easeOut: return 1 - pow(1 - x, 3)
        case .easeInOut: return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
        }
    }

    func pose(of id: UUID, progress: Double) -> Pose? {
        guard let list = waypoints[id], list.count >= 2 else { return nil }
        let p = Self.ease(progress, easing)
        var i = 0
        while i < list.count - 2 && list[i + 1].t < p { i += 1 }
        let a = list[i], b = list[i + 1]
        let span = max(b.t - a.t, 1e-9)
        return Pose.lerp(a.pose, b.pose, min(max((p - a.t) / span, 0), 1))
    }

    /// Local matrix (unit primitive to definition space) in double precision; mirrors `FurnitureResolver.componentMatrix`.
    static func matrix(_ p: Pose, pivot: P3?) -> simd_double4x4 {
        let scale = Transform.scale(p.size.x, p.size.y, p.size.z)
        let pos = Transform.translation(p.position.x, p.position.y, p.position.z)
        let rot = R3(p.rotation.x, p.rotation.y, p.rotation.z)
        if rot.isZero { return pos * scale }
        let pv = pivot.map { D3(Double($0.x), Double($0.y), Double($0.z)) } ?? p.position
        return Transform.translation(pv.x, pv.y, pv.z) * Transform.rotation(rot) * Transform.translation(-pv.x, -pv.y, -pv.z) * pos * scale
    }

    /// Advances time; returns the component poses to display this frame.
    mutating func advance(_ dt: Double) -> [(UUID, Pose, P3?)] {
        elapsed += dt
        let progress = min(elapsed / duration, 1)
        var out: [(UUID, Pose, P3?)] = []
        for id in waypoints.keys {
            if let p = pose(of: id, progress: progress) {
                current[id] = p
                out.append((id, p, pivots[id] ?? nil))
            }
        }
        return out
    }
}
