import AppKit
import Foundation
import RoomsmithCore
import simd

/// Sensitivities of mouse, trackpad and keyboard in the 3D view. Everything that can feel too fast or too slow
/// lives here, so tuning never means touching the input code. Rotations are degrees per point of finger or mouse
/// travel (independent of the camera distance, like orbiting in Apple's apps); zooms are logarithmic, so the same
/// pinch always changes the distance by the same percentage.
enum TrackpadTuning {
    /// Click-drag (mouse, or three-finger drag) orbit.
    static let mouseOrbitDegPerPoint = 0.3
    /// Two-finger scroll in Orbit mode: slightly slower than a drag, because scrolling covers more distance.
    static let scrollOrbitDegPerPoint = 0.25
    /// Two-finger scroll in First person: look around.
    static let scrollLookDegPerPoint = 0.2
    /// Pinch: 1 means a 2x spread halves the distance exactly.
    static let pinchGain = 1.0
    /// Mouse wheel without precise deltas: logarithmic zoom per wheel line (0.15 = about 16 % closer per notch).
    static let wheelDollyPerLine = 0.15
    /// Command + two-finger scroll: logarithmic zoom per point of finger travel (100 points = 55 %).
    static let commandScrollDollyPerPoint = 0.008
    /// Two-finger rotate: 1 means the view turns exactly with the fingers.
    static let rotateGain = 1.0
    /// First person: millimetres walked per unit of dolly amount (pinch or wheel).
    static let walkMmPerUnit = 4000.0
    /// Free: millimetres flown per unit of dolly amount when nothing is under the cursor (no distance known).
    static let flyMmPerUnit = 4000.0
    /// Free: the fly step is proportional to the distance to the point under the cursor (like the orbit zoom), but
    /// never smaller than this many millimetres per unit, so the eye can still pass close surfaces.
    static let flyMinMmPerUnit = 1500.0
    /// Free: one forward step covers at most this share of the distance to the point under the cursor (unless the
    /// minimum step is larger), so a fast pinch slows down before the surface instead of jumping through it.
    static let flyMaxShare = 0.8
    /// Free: distances beyond this (a flat look towards the horizon hits the floor kilometres away) count as this
    /// much, so one pinch never throws the eye out of the scene.
    static let flyMaxDistance = 60_000.0
    /// Debounce before a camera change is stored in the document, seconds.
    static let persistDelay = 0.4
}

/// Further camera constants that are not input gains.
enum CameraTuning {
    /// Free: depth in mm at which a pan of one point moves the eye by one screen point's worth of the view.
    static let freePanDepth = 3000.0
}

/// What a scroll event does to the camera.
enum ScrollAction: Equatable {
    case orbit, pan, dolly, look
}

/// Pure mapping of input to camera actions (no AppKit objects, so it can be checked without events).
enum TrackpadMapping {
    /// Two-finger scroll or wheel. `precise` is `hasPreciseScrollingDeltas` (trackpad, Magic Mouse).
    /// - Orbit: scroll orbits, shift pans. Top: pan. First person and free: look (shift is walking speed there, so it never changes the turn).
    /// - Command + scroll and every wheel without precise deltas zoom.
    static func scrollAction(mode: CameraMode, precise: Bool, shift: Bool, command: Bool) -> ScrollAction {
        if !precise || command { return .dolly }
        switch mode {
        case .orbit: return shift ? .pan : .orbit
        case .top: return .pan
        case .firstPerson, .free: return .look
        }
    }

    /// Free: millimetres to fly for a dolly `amount` (positive = forward). `distance` is the distance from the eye to
    /// the point under the cursor (nil if nothing is there). Far away the step grows with the distance, so a scene
    /// seen from 40 m comes closer as fast as one seen from 4 m.
    static func flyStep(amount: Double, distance: Double?) -> Double {
        guard amount.isFinite else { return 0 }
        guard let d0 = distance, d0.isFinite, d0 > 0 else { return amount * TrackpadTuning.flyMmPerUnit }
        let d = min(d0, TrackpadTuning.flyMaxDistance)
        var step = amount * max(d, TrackpadTuning.flyMinMmPerUnit)
        if amount > 0 { step = min(step, max(d * TrackpadTuning.flyMaxShare, amount * TrackpadTuning.flyMinMmPerUnit)) }
        return step
    }

    /// Logarithmic dolly amount of a zooming scroll event.
    static func dollyAmount(scrollingDeltaY: Double, precise: Bool) -> Double {
        precise ? scrollingDeltaY * TrackpadTuning.commandScrollDollyPerPoint : scrollingDeltaY * TrackpadTuning.wheelDollyPerLine
    }
}

/// Keeps one scroll gesture consistent: the action is decided when the fingers touch down and stays the same
/// through the momentum phase, so releasing a modifier or moving the cursor never changes a running coast.
/// Momentum events are dropped once something else took over (click, key, mode change, new touch).
struct ScrollTracker {
    private var locked: ScrollAction?
    private var momentumCancelled = false

    /// The action to apply for this event, or nil to ignore it. `isMomentum` is true for the coasting phase.
    mutating func event(phase: NSEvent.Phase, momentum: NSEvent.Phase, proposed: ScrollAction) -> (action: ScrollAction, isMomentum: Bool)? {
        if !momentum.isEmpty {
            guard let a = locked, !momentumCancelled else { return nil }
            if momentum.contains(.ended) || momentum.contains(.cancelled) { locked = nil }
            return (a, true)
        }
        if phase.contains(.mayBegin) {
            cancelMomentum()
            return nil
        }
        if phase.contains(.began) {
            locked = proposed
            momentumCancelled = false
            return (proposed, false)
        }
        if phase.contains(.changed) || phase.contains(.stationary) {
            let a = locked ?? proposed
            locked = a
            return (a, false)
        }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            // Keep the lock: momentum may follow.
            return (locked ?? proposed, false)
        }
        // A plain wheel has no phases: every event stands alone.
        locked = nil
        return (proposed, false)
    }

    /// Drops the coast of the last gesture (called by clicks, keys and mode switches).
    mutating func cancelMomentum() {
        momentumCancelled = true
        locked = nil
    }
}

// MARK: - Self test

/// Checks the camera maths behind the gestures without any input events. Run with `ROOMSMITH_SCENE_SELFTEST=1`;
/// every check prints one `SCENE_SELFTEST` line.
@MainActor
enum SceneSelfTest {
    private static var didRun = false

    /// Runs once when the environment variable is set; prints the results to stdout.
    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment["ROOMSMITH_SCENE_SELFTEST"] == "1" else { return }
        didRun = true
        let lines = run()
        for l in lines { FileHandle.standardOutput.write(Data((l + "\n").utf8)) }
    }

    static func run() -> [String] {
        var out: [String] = []
        var passed = 0, failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { passed += 1 } else { failed += 1 }
            out.append("SCENE_SELFTEST \(ok ? "pass" : "FAIL") \(name)\(detail.isEmpty ? "" : " " + detail)")
        }
        func controller(_ mode: CameraMode, yaw: Double = 30, pitch: Double = -35, distance: Double = 8000) -> SceneCameraController {
            let c = SceneCameraController(state: CameraState(mode: mode, target: P3(3000, 2000, 0), distance: MM(distance),
                                                             yawDeg: yaw, pitchDeg: pitch, fovDeg: 60))
            c.viewSize = CGSize(width: 1000, height: 800)
            return c
        }
        func screen(_ r: CameraRig, _ p: D3, _ size: CGSize) -> SIMD2<Double>? {
            guard let n = r.project(p, aspect: Double(size.width / size.height)) else { return nil }
            return SIMD2((n.x + 1) / 2 * Double(size.width), (n.y + 1) / 2 * Double(size.height))
        }

        // 1. Pinch toward a point keeps that point under the cursor (orbit and top).
        for mode in [CameraMode.orbit, .top] {
            let c = controller(mode)
            let focus = D3(4200, 900, 0)
            let before = screen(c.rig, focus, c.viewSize)
            c.pinch(0.35, focus: focus)
            let after = screen(c.rig, focus, c.viewSize)
            let drift = (before != nil && after != nil) ? simd_length(before! - after!) : .infinity
            check("pinch-keeps-cursor-point-\(mode)", drift < 1e-6, "drift=\(drift)pt")
        }

        // 2. Pinch in then out by the inverse factor returns to the start.
        do {
            let c = controller(.orbit)
            let start = c.rig
            let focus = D3(5000, 1000, 0)
            c.pinch(0.5, focus: focus)
            let inDist = c.rig.distance
            c.pinch(1 / 1.5 - 1, focus: focus)
            let back = simd_length(c.rig.target - start.target) + abs(c.rig.distance - start.distance)
            check("pinch-in-out-roundtrip", inDist < start.distance && back < 1e-6, "back=\(back)mm")
        }

        // 3. The zoom is relative: the same pinch changes the distance by the same factor near and far.
        do {
            let near = controller(.orbit, distance: 1000), far = controller(.orbit, distance: 50_000)
            near.pinch(0.2); far.pinch(0.2)
            let a = near.rig.distance / 1000, b = far.rig.distance / 50_000
            check("pinch-distance-independent", abs(a - b) < 1e-9, "factor=\(a)/\(b)")
        }

        // 4. Zoom stops at the distance limits and never flips or becomes non-finite.
        do {
            let c = controller(.orbit)
            for _ in 0..<60 { c.pinch(2.0, focus: D3(0, 0, 0)) }
            let minOK = c.rig.distance >= CameraRig.distanceRange.lowerBound
            for _ in 0..<80 { c.pinch(-0.6, focus: D3(0, 0, 0)) }
            let maxOK = c.rig.distance <= CameraRig.distanceRange.upperBound && c.rig.target.x.isFinite
            check("pinch-clamped", minOK && maxOK, "distance=\(c.rig.distance)")
        }

        // 5. Two-finger rotate turns the yaw by the finger angle, the target stays.
        do {
            let c = controller(.orbit, yaw: 30)
            let t = c.rig.target
            c.rotate(degrees: 20)
            check("rotate-yaw", abs(c.rig.yaw - 10) < 1e-9 && c.rig.target == t, "yaw=\(c.rig.yaw)")
        }

        // 6. Pan in the top view follows the fingers 1:1 (a ground point moves exactly by the finger travel).
        do {
            let c = controller(.top, yaw: 0)
            let p = D3(3000, 2000, 0)
            let s0 = screen(c.rig, p, c.viewSize)!
            c.pan(dx: 120, dy: 45)
            let s1 = screen(c.rig, p, c.viewSize)!
            let err = simd_length((s1 - s0) - SIMD2(120, -45))
            check("pan-top-follows-fingers", err < 1e-6, "err=\(err)pt")
        }

        // 7. Orbit by scroll: a fixed finger travel gives a fixed angle at every distance.
        do {
            let a = controller(.orbit, distance: 800), b = controller(.orbit, distance: 90_000)
            a.orbit(dx: 100, dy: 40, degPerPoint: TrackpadTuning.scrollOrbitDegPerPoint)
            b.orbit(dx: 100, dy: 40, degPerPoint: TrackpadTuning.scrollOrbitDegPerPoint)
            check("orbit-angle-distance-independent", abs(a.rig.yaw - b.rig.yaw) < 1e-9 && abs(a.rig.pitch - b.rig.pitch) < 1e-9,
                  "dYaw=\(a.rig.yaw - 30)")
        }

        // 8. Orbit pitch is clamped (never upside down).
        do {
            let c = controller(.orbit)
            c.orbit(dx: 0, dy: -100_000, degPerPoint: 0.3)
            let lo = c.rig.pitch
            c.orbit(dx: 0, dy: 100_000, degPerPoint: 0.3)
            check("orbit-pitch-clamped", lo == CameraRig.orbitPitchRange.upperBound && c.rig.pitch == CameraRig.orbitPitchRange.lowerBound,
                  "pitch=\(lo)/\(c.rig.pitch)")
        }

        // 9. First person: pinch walks horizontally along the ray under the cursor, eye height stays.
        do {
            let c = controller(.firstPerson, yaw: 0, pitch: 0)
            let z = c.rig.target.z
            let dir = D3(1, 0, -0.3)
            c.pinch(0.5, rayDir: dir)
            let moved = c.rig.target - D3(3000, 2000, z)
            check("first-person-pinch-walks", moved.x > 100 && abs(moved.y) < 1e-9 && abs(moved.z) < 1e-9, "move=\(moved.x)mm")
        }

        // 10. Scroll mapping.
        check("scroll-orbit", TrackpadMapping.scrollAction(mode: .orbit, precise: true, shift: false, command: false) == .orbit)
        check("scroll-orbit-shift-pan", TrackpadMapping.scrollAction(mode: .orbit, precise: true, shift: true, command: false) == .pan)
        check("scroll-top-pan", TrackpadMapping.scrollAction(mode: .top, precise: true, shift: false, command: false) == .pan)
        check("scroll-command-zoom", TrackpadMapping.scrollAction(mode: .orbit, precise: true, shift: false, command: true) == .dolly)
        check("scroll-wheel-zoom", TrackpadMapping.scrollAction(mode: .top, precise: false, shift: false, command: false) == .dolly)
        check("scroll-first-person-look", TrackpadMapping.scrollAction(mode: .firstPerson, precise: true, shift: false, command: false) == .look)

        // 10b. Free: scroll looks (shift too), pinch flies along the ray / forward, the eye is the target.
        check("scroll-free-look", TrackpadMapping.scrollAction(mode: .free, precise: true, shift: false, command: false) == .look)
        check("scroll-free-shift-look", TrackpadMapping.scrollAction(mode: .free, precise: true, shift: true, command: false) == .look)
        check("scroll-first-person-shift-look", TrackpadMapping.scrollAction(mode: .firstPerson, precise: true, shift: true, command: false) == .look)
        do {
            let c = controller(.free, yaw: 0, pitch: 30)
            let eye0 = c.rig.eye
            c.pinch(0.5)
            let moved = c.rig.eye - eye0
            let f = c.rig.forward
            let along = simd_dot(moved, f), side = simd_length(moved - f * along)
            check("free-pinch-flies-forward", along > 100 && side < 1e-6 && abs(moved.z) > 1, "along=\(along)mm side=\(side)mm")
            let d = D3(0, 0, 1)
            let before = c.rig.eye
            c.pinch(0.5, rayDir: d)
            let up = c.rig.eye - before
            check("free-pinch-follows-ray", up.z > 100 && abs(up.x) < 1e-9 && abs(up.y) < 1e-9, "up=\(up.z)mm")
        }

        // 10b2. Free: the fly step scales with the distance to the point under the cursor.
        do {
            let far = TrackpadMapping.flyStep(amount: 0.15, distance: 40_000)
            let near = TrackpadMapping.flyStep(amount: 0.15, distance: 4000)
            check("free-fly-step-scales", abs(far / near - 10) < 1e-9, "far=\(far)mm near=\(near)mm")
            let close = TrackpadMapping.flyStep(amount: 0.15, distance: 200)
            check("free-fly-step-minimum", abs(close - 0.15 * TrackpadTuning.flyMinMmPerUnit) < 1e-9, "close=\(close)mm")
            let big = TrackpadMapping.flyStep(amount: 3, distance: 10_000)
            check("free-fly-step-no-overshoot", big <= 10_000 * TrackpadTuning.flyMaxShare + 1e-9, "big=\(big)mm")
            let back = TrackpadMapping.flyStep(amount: -0.15, distance: 40_000)
            check("free-fly-step-back", abs(back + far) < 1e-9, "back=\(back)mm")
            let none = TrackpadMapping.flyStep(amount: 0.15, distance: nil)
            check("free-fly-step-fallback", abs(none - 0.15 * TrackpadTuning.flyMmPerUnit) < 1e-9, "none=\(none)mm")
            let c = controller(.free, yaw: 0, pitch: -30)
            let eye0 = c.rig.eye
            c.pinch(0.2, focus: eye0 + c.rig.forward * 50_000)
            let moved = simd_length(c.rig.eye - eye0)
            check("free-pinch-far-focus-fast", moved > 5000, "moved=\(moved)mm")
            let huge = TrackpadMapping.flyStep(amount: 0.15, distance: 9_000_000)
            check("free-fly-step-capped", huge <= 0.15 * TrackpadTuning.flyMaxDistance + 1e-9, "huge=\(huge)mm")
        }
        // 10b3. Free without a picked point: high eye looking down uses the floor distance (fast); looking up keeps
        // the fixed fallback; a flat look is capped.
        do {
            func free(pitch: Double, z: Double) -> SceneCameraController {
                let c = SceneCameraController(state: CameraState(mode: .free, target: P3(3000, 2000, MM(z)), distance: 8000,
                                                                 yawDeg: 0, pitchDeg: pitch, fovDeg: 60))
                c.viewSize = CGSize(width: 1000, height: 800)
                return c
            }
            let down = free(pitch: -30, z: 20_000)
            let e0 = down.rig.eye
            down.pinch(0.2)
            let fast = simd_length(down.rig.eye - e0)
            check("free-pinch-floor-fast", fast > 5000, "moved=\(fast)mm")
            let up = free(pitch: 30, z: 20_000)
            let u0 = up.rig.eye
            up.pinch(0.2)
            let slow = simd_length(up.rig.eye - u0)
            check("free-pinch-up-fallback", abs(slow - log(1.2) * TrackpadTuning.flyMmPerUnit) < 1, "moved=\(slow)mm")
            let flat = free(pitch: -0.1, z: 20_000)
            let f0 = flat.rig.eye
            flat.pinch(0.2)
            let capped = simd_length(flat.rig.eye - f0)
            check("free-pinch-flat-capped", capped <= log(1.2) * TrackpadTuning.flyMaxDistance + 1, "moved=\(capped)mm")
        }

        // 10c. Mode changes: the eye survives Orbit -> Free -> Orbit; Free never lands in `lastOrbit`.
        do {
            let c = controller(.orbit, yaw: 40, pitch: -30, distance: 7000)
            let start = c.rig
            let eye0 = start.eye
            c.setMode(.free, levelElevation: 0)
            let inFree = c.rig
            check("mode-orbit-to-free-keeps-eye", inFree.mode == .free && simd_length(inFree.eye - eye0) < 1e-6
                  && abs(inFree.yaw - 40) < 1e-9 && abs(inFree.pitch + 30) < 1e-9 && inFree.fov == start.fov)
            c.setMode(.orbit, levelElevation: 0, viewDistanceHint: 7000)
            check("mode-free-to-orbit-roundtrip", c.rig.mode == .orbit && simd_length(c.rig.eye - eye0) < 1e-6
                  && abs(c.rig.distance - 7000) < 1e-6 && simd_length(c.rig.target - start.target) < 1e-6,
                  "eyeErr=\(simd_length(c.rig.eye - eye0))mm")
            c.setMode(.free, levelElevation: 0)
            c.setMode(.orbit, levelElevation: 0)
            check("mode-free-to-orbit-default-distance", c.rig.mode == .orbit && abs(c.rig.distance - 3000) < 1e-6
                  && simd_length(c.rig.eye - eye0) < 1e-6)
        }
        do {
            let c = controller(.orbit, yaw: 40, pitch: -30, distance: 7000)
            c.setMode(.free, levelElevation: 0)
            c.pan(dx: 200, dy: 0)
            let freeEye = c.rig.eye
            c.setMode(.firstPerson, levelElevation: 0)
            check("mode-free-to-first-person-keeps-xy", c.rig.mode == .firstPerson
                  && abs(c.rig.eye.x - freeEye.x) < 1 && abs(c.rig.eye.y - freeEye.y) < 1
                  && abs(c.rig.eye.z - c.eyeHeight()) < 1e-6, "eye=\(c.rig.eye) free=\(freeEye)")
            c.setMode(.orbit, levelElevation: 0)
            check("mode-first-person-to-orbit-no-free", c.rig.mode == .orbit && c.rig.distance == 3000
                  && simd_length(c.rig.eye - freeEye) < 1e-6, "mode=\(c.rig.mode)")
            // Orbit -> FP -> Free -> FP -> Orbit ends in an orbit pose, never in free.
            let d = controller(.orbit, yaw: 40, pitch: -30, distance: 7000)
            d.setMode(.firstPerson, levelElevation: 0)
            d.setMode(.free, levelElevation: 0)
            d.setMode(.firstPerson, levelElevation: 0)
            d.setMode(.orbit, levelElevation: 0)
            check("mode-last-orbit-never-free", d.rig.mode == .orbit && d.rig.distance == 3000)
        }
        // First person has no selection editing; every other mode keeps it.
        check("selection-editing-by-mode", CameraMode.firstPerson.allowsSelectionEditing == false
              && [CameraMode.orbit, .top, .free].allSatisfy(\.allowsSelectionEditing))

        // 11. Momentum: the action locked at touch-down survives the coast; a cancel stops it; no stray events.
        do {
            var t = ScrollTracker()
            let began = t.event(phase: .began, momentum: [], proposed: .orbit)
            let moving = t.event(phase: .changed, momentum: [], proposed: .pan)
            let ended = t.event(phase: .ended, momentum: [], proposed: .pan)
            let coast = t.event(phase: [], momentum: .changed, proposed: .pan)
            let coastEnd = t.event(phase: [], momentum: .ended, proposed: .pan)
            let after = t.event(phase: [], momentum: .changed, proposed: .pan)
            check("momentum-locks-action", began?.action == .orbit && moving?.action == .orbit && ended?.action == .orbit
                && coast?.action == .orbit && coast?.isMomentum == true && coastEnd != nil && after == nil)
            var u = ScrollTracker()
            _ = u.event(phase: .began, momentum: [], proposed: .orbit)
            _ = u.event(phase: .ended, momentum: [], proposed: .orbit)
            u.cancelMomentum()
            check("momentum-cancelled", u.event(phase: [], momentum: .changed, proposed: .orbit) == nil)
            var w = ScrollTracker()
            _ = w.event(phase: .began, momentum: [], proposed: .orbit)
            _ = w.event(phase: .ended, momentum: [], proposed: .orbit)
            _ = w.event(phase: .mayBegin, momentum: [], proposed: .orbit)
            check("momentum-stops-on-touch", w.event(phase: [], momentum: .changed, proposed: .orbit) == nil)
            var x = ScrollTracker()
            let wheel = x.event(phase: [], momentum: [], proposed: .dolly)
            check("wheel-without-phase", wheel?.action == .dolly && wheel?.isMomentum == false)
        }

        out.append("SCENE_SELFTEST summary passed=\(passed) failed=\(failed)")
        return out
    }
}
