import Foundation
import RealityKit
import RoomsmithCore
import simd

typealias D3 = SIMD3<Double>

/// Axis-aligned box in document mm.
struct Bounds3: Equatable {
    var lo: D3
    var hi: D3
    var center: D3 { (lo + hi) / 2 }
    var radius: Double { simd_length(hi - lo) / 2 }
    mutating func extend(_ p: D3) { lo = simd_min(lo, p); hi = simd_max(hi, p) }
    mutating func extend(_ b: Bounds3) { extend(b.lo); extend(b.hi) }
    static func around(_ p: D3) -> Bounds3 { Bounds3(lo: p, hi: p) }
    /// Grows the box symmetrically so its half-diagonal is at least `r` (tiny or empty content still frames sensibly).
    func padded(toRadius r: Double) -> Bounds3 {
        let cur = radius
        guard cur < r else { return self }
        let grow = cur > 1 ? r / cur : 0
        if grow == 0 { let e = D3(repeating: r / 3.0.squareRoot()); return Bounds3(lo: center - e, hi: center + e) }
        let h = (hi - lo) / 2 * grow
        return Bounds3(lo: center - h, hi: center + h)
    }
}

extension CameraMode {
    /// Gizmo, selection tint and hover tint belong to the editing views. First person is only for walking and looking.
    var allowsSelectionEditing: Bool { self != .firstPerson }
}

/// Camera pose in document space (mm, Z up). All maths in Double; only the final matrix is Float.
///
/// Yaw is counter-clockwise from north (+Y): forward = (-sin y cos p, cos y cos p, sin p). `right` is always
/// (cos y, sin y, 0), which stays well defined when looking straight down.
struct CameraRig: Equatable {
    var mode: CameraMode
    /// Orbit and top: the point looked at. First person and free: the eye.
    var target: D3
    var distance: Double
    var yaw: Double
    var pitch: Double
    var fov: Double

    /// Eye height used when no walk settings are wired in (tests); the live view takes it from `WalkSettings`.
    static let eyeHeight = 1600.0
    /// Top view is a narrow-FOV perspective camera, so picking and drawing share one projection and the view is
    /// orthographic-like (no visible perspective distortion).
    static let topFov = 10.0
    static let orbitPitchRange: ClosedRange<Double> = -89 ... -2
    static let distanceRange: ClosedRange<Double> = 300 ... 200_000

    init(mode: CameraMode, target: D3, distance: Double, yaw: Double, pitch: Double, fov: Double) {
        self.mode = mode; self.target = target; self.distance = distance; self.yaw = yaw; self.pitch = pitch; self.fov = fov
    }

    init(_ s: CameraState) {
        self.init(mode: s.mode, target: D3(Double(s.target.x), Double(s.target.y), Double(s.target.z)),
                  distance: Double(s.distance), yaw: s.yawDeg, pitch: s.pitchDeg, fov: s.fovDeg)
        sanitize()
    }

    var state: CameraState {
        func mm(_ v: Double) -> MM { MM(v.rounded()) }
        var y = yaw.truncatingRemainder(dividingBy: 360)
        if y > 180 { y -= 360 } else if y <= -180 { y += 360 }
        return CameraState(mode: mode, target: P3(mm(target.x), mm(target.y), mm(target.z)), distance: mm(distance),
                           yawDeg: (y * 100).rounded() / 100, pitchDeg: (pitch * 100).rounded() / 100, fovDeg: fov)
    }

    mutating func sanitize() {
        if !fov.isFinite || fov < 10 || fov > 120 { fov = 60 }
        if !yaw.isFinite { yaw = 30 }
        if !pitch.isFinite { pitch = -35 }
        if !distance.isFinite { distance = 9000 }
        distance = min(max(distance, Self.distanceRange.lowerBound), Self.distanceRange.upperBound)
        clampPitch()
    }

    mutating func clampPitch() {
        switch mode {
        case .orbit: pitch = min(max(pitch, Self.orbitPitchRange.lowerBound), Self.orbitPitchRange.upperBound)
        case .firstPerson, .free: pitch = min(max(pitch, -89), 89)
        case .top: pitch = min(max(pitch, -89), 89)
        }
    }

    // MARK: basis

    var effectivePitch: Double { mode == .top ? -90 : pitch }
    var viewFov: Double { mode == .top ? Self.topFov : fov }
    var tanHalf: Double { tan(viewFov * .pi / 360) }

    var forward: D3 {
        let y = yaw * .pi / 180, p = effectivePitch * .pi / 180
        return D3(-sin(y) * cos(p), cos(y) * cos(p), sin(p))
    }
    var right: D3 {
        let y = yaw * .pi / 180
        return D3(cos(y), sin(y), 0)
    }
    var up: D3 { simd_cross(right, forward) }

    /// Orbit distance from `b.center` at which all eight corners of `b` lie inside the view, keeping `margin` of
    /// each half-extent free. Uses the real aspect ratio, so wide windows are filled and narrow ones never clip.
    func fitDistance(_ b: Bounds3, aspect: Double, margin: Double) -> Double {
        let tv = tan(fov * .pi / 360) * (1 - margin)
        let th = tv * min(max(aspect, 0.1), 10)
        let f = forward, r = right, u = up, c = b.center
        var d = 0.0
        for i in 0 ..< 8 {
            let p = D3(i & 1 == 0 ? b.lo.x : b.hi.x, i & 2 == 0 ? b.lo.y : b.hi.y, i & 4 == 0 ? b.lo.z : b.hi.z) - c
            let z = simd_dot(p, f)
            d = max(d, abs(simd_dot(p, r)) / th - z, abs(simd_dot(p, u)) / tv - z)
        }
        return d
    }

    /// Top-view `distance` (see `viewDistance`) that shows the footprint of `b` with `margin` free on each side.
    func topFitDistance(_ b: Bounds3, aspect: Double, margin: Double) -> Double {
        let r = right, u = up, c = b.center
        var halfW = 0.0, halfH = 0.0
        for i in 0 ..< 4 {
            let p = D3(i & 1 == 0 ? b.lo.x : b.hi.x, i & 2 == 0 ? b.lo.y : b.hi.y, c.z) - c
            halfW = max(halfW, abs(simd_dot(p, r))); halfH = max(halfH, abs(simd_dot(p, u)))
        }
        let half = max(halfH, halfW / min(max(aspect, 0.1), 10)) / (1 - margin)
        return 2 * half / 1.2
    }
    /// Horizontal forward (unit), used for panning and walking.
    var flatForward: D3 {
        let y = yaw * .pi / 180
        return D3(-sin(y), cos(y), 0)
    }

    /// Distance between eye and target.
    var viewDistance: Double {
        switch mode {
        case .orbit: return distance
        case .firstPerson, .free: return 0
        case .top: return distance * 1.2 / (2 * tan(Self.topFov * .pi / 360))
        }
    }
    /// First person and free: `target` is the eye itself.
    var eyeIsTarget: Bool { mode == .firstPerson || mode == .free }
    var eye: D3 { eyeIsTarget ? target : target - forward * viewDistance }

    /// Visible height at the target distance, in mm.
    var visibleHeightAtTarget: Double { 2 * max(viewDistance, 1) * tanHalf }

    var nearFar: (near: Float, far: Float) {
        switch mode {
        case .firstPerson, .free: return (0.05, 500)
        case .orbit: return (Float(max(0.05, viewDistance / 1000 * 0.02)), Float(max(200, viewDistance / 1000 * 8)))
        case .top: return (Float(max(0.5, viewDistance / 1000 * 0.4)), Float(viewDistance / 1000 * 2 + 200))
        }
    }

    /// Camera entity transform in RealityKit world space (metres).
    var entityMatrix: simd_float4x4 {
        let r = SceneCoords.worldDirection(right), u = SceneCoords.worldDirection(up), b = SceneCoords.worldDirection(-forward)
        let t = SceneCoords.world(eye)
        return simd_float4x4(SIMD4(r, 0), SIMD4(u, 0), SIMD4(b, 0), SIMD4(t, 1))
    }

    // MARK: ray and projection

    /// Ray through a point of the view in normalised device coordinates (-1...1, y up).
    func ray(ndc: SIMD2<Double>, aspect: Double) -> (origin: D3, dir: D3) {
        let d = forward + right * (ndc.x * tanHalf * aspect) + up * (ndc.y * tanHalf)
        return (eye, simd_normalize(d))
    }

    /// Projects a point to NDC. nil when behind the camera.
    func project(_ p: D3, aspect: Double) -> SIMD2<Double>? {
        let d = p - eye
        let z = simd_dot(d, forward)
        guard z > 1e-6 else { return nil }
        return SIMD2(simd_dot(d, right) / (z * tanHalf * aspect), simd_dot(d, up) / (z * tanHalf))
    }

    /// mm per point at a given depth (view-space z along forward).
    func mmPerPoint(depth: Double, viewHeight: Double) -> Double {
        2 * max(depth, 1) * tanHalf / max(viewHeight, 1)
    }
}

/// Holds the current camera rig and applies mouse, trackpad and keyboard input to it. Knows nothing about AppKit.
@MainActor
final class SceneCameraController {
    private(set) var rig: CameraRig
    /// Called after every change of the rig.
    var onChange: (() -> Void)?
    var viewSize = CGSize(width: 800, height: 600)
    var aspect: Double { viewSize.height > 0 ? Double(viewSize.width / viewSize.height) : 4.0 / 3 }
    private var lastOrbit: CameraRig?
    /// Standing eye height above the level floor in mm (the walk settings, see `WalkController`).
    var eyeHeight: () -> Double = { CameraRig.eyeHeight }

    init(state: CameraState) { rig = CameraRig(state) }

    func set(_ new: CameraRig) {
        guard new != rig else { return }
        rig = new
        rig.sanitize()
        onChange?()
    }

    private func mutate(_ body: (inout CameraRig) -> Void) {
        var r = rig
        body(&r)
        r.sanitize()
        guard r != rig else { return }
        rig = r
        onChange?()
    }

    // MARK: input

    /// Orbit: drag right turns the scene with the cursor; drag down looks more from above.
    /// `degPerPoint` overrides the mouse sensitivity (the trackpad uses its own, see `TrackpadTuning`).
    func orbit(dx: Double, dy: Double, degPerPoint: Double? = nil) {
        mutate { r in
            switch r.mode {
            case .orbit:
                let k = degPerPoint ?? TrackpadTuning.mouseOrbitDegPerPoint
                r.yaw -= dx * k
                r.pitch -= dy * k
            case .firstPerson, .free:
                let k = (degPerPoint ?? TrackpadTuning.mouseOrbitDegPerPoint) * 0.67
                r.yaw -= dx * k
                r.pitch -= dy * k
            case .top:
                r.yaw -= dx * (degPerPoint ?? TrackpadTuning.mouseOrbitDegPerPoint)
            }
        }
    }

    /// Pan so the scene follows the cursor. dx right, dy down (screen points).
    func pan(dx: Double, dy: Double) {
        mutate { r in
            if r.mode == .free {
                // Free: slide the eye in the view plane, scaled to a fixed depth so the speed does not depend on the surroundings.
                let u = r.mmPerPoint(depth: CameraTuning.freePanDepth, viewHeight: Double(viewSize.height))
                r.target += r.up * (dy * u) - r.right * (dx * u)
                return
            }
            guard r.mode != .firstPerson else {
                // First person: sideways and forward shuffle.
                let u = 3.0
                r.target += r.right * (dx * u) * -1 + r.flatForward * (dy * u)
                return
            }
            let u = r.mmPerPoint(depth: r.viewDistance, viewHeight: Double(viewSize.height))
            r.target -= r.right * (dx * u)
            let k = 1 / max(abs(sin(r.effectivePitch * .pi / 180)), 0.25)
            r.target += r.flatForward * (dy * u * k)
        }
    }

    /// Dolly with a logarithmic amount (positive = in; 0.1 is roughly 10 % closer).
    ///
    /// Orbit and top: the distance changes and the target moves along with it so that `focus` (the point under the
    /// cursor, document mm) stays at the same place on screen. First person: walks horizontally along `rayDir`
    /// (the ray under the cursor) or straight ahead. Free: flies along `rayDir` or `forward`, vertically too; the step grows with the distance to `focus`
    /// (see `TrackpadMapping.flyStep`).
    func dolly(_ amount: Double, focus: D3? = nil, rayDir: D3? = nil) {
        guard amount.isFinite else { return }
        mutate { r in
            if r.mode == .free {
                var d = rayDir ?? r.forward
                let len = simd_length(d)
                d = len > 1e-6 ? d / len : r.forward
                // Distance to what is under the cursor: the picked point, else the floor (z = 0) along the ray.
                var dist: Double? = focus.map { simd_length($0 - r.target) }
                if dist == nil, d.z < -1e-3, r.target.z > 0 { dist = r.target.z / -d.z }
                r.target += d * TrackpadMapping.flyStep(amount: amount, distance: dist)
            } else if r.mode == .firstPerson {
                var d = rayDir.map { D3($0.x, $0.y, 0) } ?? r.flatForward
                let len = simd_length(d)
                d = len > 1e-6 ? d / len : r.flatForward
                r.target += d * (amount * TrackpadTuning.walkMmPerUnit)
            } else {
                let old = r.distance
                let new = min(max(old * exp(-amount), CameraRig.distanceRange.lowerBound), CameraRig.distanceRange.upperBound)
                let k = new / old
                r.distance = new
                if let f = focus { r.target = f + (r.target - f) * k }
            }
        }
    }

    /// Pinch magnification (AppKit `magnification`, positive = spread = in).
    func pinch(_ magnification: Double, focus: D3? = nil, rayDir: D3? = nil) {
        dolly(log(max(1 + magnification * TrackpadTuning.pinchGain, 0.2)), focus: focus, rayDir: rayDir)
    }

    /// Field of view in degrees for orbit and first person (the top view keeps its own narrow lens).
    func setFieldOfView(_ degrees: Double) {
        mutate { $0.fov = min(max(degrees, 10), 120) }  // same range as `CameraRig.sanitize`
    }

    /// Two-finger rotation gesture (degrees, counter-clockwise on the trackpad): turns the view about the target.
    func rotate(degrees: Double) {
        mutate { $0.yaw -= degrees * TrackpadTuning.rotateGain }
    }

    // MARK: modes

    /// `viewDistanceHint`: distance from the eye to the surface in the middle of the view (nil when nothing is
    /// there). Only used when leaving free, to choose the orbit distance.
    func setMode(_ mode: CameraMode, levelElevation: Double, viewDistanceHint: Double? = nil) {
        guard mode != rig.mode else { return }
        var r = rig
        switch (r.mode, mode) {
        case (.orbit, .free), (.top, .free):
            // The eye stays where it is; fov and heading stay too. `lastOrbit` is left alone.
            r.target = r.eye
            r.pitch = r.effectivePitch
            r.mode = .free
        case (.firstPerson, .free):
            r.mode = .free
        case (.free, .firstPerson):
            // `lastOrbit` gets the orbit pose that matches the free eye (never a free pose); first person starts at the
            // free eye's position, at standing height.
            let eye = r.target
            lastOrbit = Self.orbitPose(fromFree: r, hint: viewDistanceHint)
            r.target.x = eye.x; r.target.y = eye.y
            r.target.z = levelElevation + eyeHeight()
            r.pitch = min(max(r.pitch, -20), 20)
            r.mode = .firstPerson
        case (.free, _):
            r = Self.orbitPose(fromFree: r, hint: viewDistanceHint)
            r.mode = mode
        case (.firstPerson, _):
            // Back to orbit/top: restore the last orbit view when there is one.
            if var o = lastOrbit {
                o.mode = mode
                o.yaw = r.yaw
                r = o
            } else {
                r.target = r.target + r.flatForward * 3000
                r.target.z = levelElevation
                r.distance = 6000
                r.pitch = -35
                r.mode = mode
            }
        case (_, .firstPerson):
            lastOrbit = r
            r.target.z = levelElevation + eyeHeight()
            r.pitch = max(min(r.pitch * 0.2, 20), -20)
            r.mode = .firstPerson
        default:
            r.mode = mode
        }
        r.sanitize()
        rig = r
        onChange?()
    }

    /// Orbit pose with the same eye as the free pose `f`: target `distance` ahead of the eye.
    static func orbitPose(fromFree f: CameraRig, hint: Double?) -> CameraRig {
        var o = f
        let eye = f.target
        let d = min(max(hint ?? 3000, CameraRig.distanceRange.lowerBound), CameraRig.distanceRange.upperBound)
        o.mode = .orbit
        o.pitch = min(max(o.pitch, CameraRig.orbitPitchRange.lowerBound), CameraRig.orbitPitchRange.upperBound)
        o.target = eye + o.forward * d
        o.distance = d
        return o
    }

    // MARK: framing

    func frame(_ b: Bounds3, levelElevation: Double) {
        mutate { r in
            let bb = b.padded(toRadius: 500)
            switch r.mode {
            case .orbit:
                r.target = bb.center
                r.distance = r.fitDistance(bb, aspect: aspect, margin: 0.1)
            case .top:
                r.target = bb.center
                r.distance = r.topFitDistance(bb, aspect: aspect, margin: 0.1)
            case .firstPerson, .free:
                let eye = r.target
                let d = b.center - eye
                let flat = simd_length(SIMD2(d.x, d.y))
                if flat > 1 { r.yaw = atan2(-d.x, d.y) * 180 / .pi }
                r.pitch = atan2(d.z, max(flat, 1)) * 180 / .pi
            }
        }
    }

    /// Aerial preset: orbit camera 55 degrees above the horizon, fitted to the whole box. Keeps the current heading.
    static let aerialPitch = -55.0

    func aerial(_ b: Bounds3?) {
        var r = rig
        if r.mode == .firstPerson, let o = lastOrbit { r = o }
        r.mode = .orbit
        let bb = b ?? Bounds3(lo: D3(-4000, -3000, 0), hi: D3(4000, 3000, 2500))
        let fit = bb.padded(toRadius: 1500)
        r.target = fit.center
        r.pitch = Self.aerialPitch
        r.distance = r.fitDistance(fit, aspect: aspect, margin: 0.05)
        r.sanitize()
        guard r != rig else { return }
        rig = r
        onChange?()
    }

    func reset(_ b: Bounds3?, levelElevation: Double) {
        mutate { r in
            let bb = b ?? Bounds3(lo: D3(-4000, -3000, 0), hi: D3(4000, 3000, 2500))
            let fit = bb.padded(toRadius: 1500)
            switch r.mode {
            case .orbit:
                r.target = fit.center
                r.yaw = 30
                r.pitch = -35
                r.distance = r.fitDistance(fit, aspect: aspect, margin: 0.08)
            case .top:
                r.target = fit.center
                r.yaw = 0
                r.distance = r.topFitDistance(fit, aspect: aspect, margin: 0.08)
            case .firstPerson:
                r.target = D3(bb.center.x, bb.center.y, levelElevation + eyeHeight())
                r.yaw = 0
                r.pitch = 0
            case .free:
                // Back off to the aerial-like spot of the orbit reset, looking at the middle of the scene.
                var o = r
                o.mode = .orbit
                o.target = fit.center
                o.yaw = 30
                o.pitch = -35
                o.distance = o.fitDistance(fit, aspect: aspect, margin: 0.08)
                r.target = o.eye
                r.yaw = o.yaw
                r.pitch = o.pitch
            }
        }
    }
}
