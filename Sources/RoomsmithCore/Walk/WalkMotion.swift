import Foundation
import simd

/// Walk input for one frame. `forward` and `strafe` are -1...1 (stick or keys), `yawDeg` is the heading (counter-clockwise
/// from north, like the camera rig).
public struct WalkInput: Sendable, Equatable {
    public var forward: Double
    public var strafe: Double
    public var yawDeg: Double
    public var step: WalkSpeedStep
    public var crouch: Bool
    public init(forward: Double = 0, strafe: Double = 0, yawDeg: Double = 0, step: WalkSpeedStep = .normal, crouch: Bool = false) {
        self.forward = forward; self.strafe = strafe; self.yawDeg = yawDeg; self.step = step; self.crouch = crouch
    }
}

/// Walking physics on a fixed time step, so the result does not depend on the frame rate: frames add their time to an
/// accumulator and the simulation advances in 1/120 s steps; the left-over is extrapolated for display.
public struct WalkMotion: Sendable, Equatable {
    public static let step = 1.0 / 120
    static let maxStepsPerAdvance = 24
    /// Share of the walking speed while crouching.
    public static let crouchSpeedFactor = 0.5
    static let bobStrideMm = 1400.0
    static let bobAmplitudeMm = 22.0
    static let crouchBlendPerSecond = 7.0

    /// Position of the feet in mm (document plane).
    public private(set) var position: V2
    /// Velocity in mm/s.
    public private(set) var velocity = V2.zero
    /// 0 standing ... 1 fully crouched.
    public private(set) var crouchBlend = 0.0
    public private(set) var bobPhase = 0.0
    private var accumulator = 0.0
    private var lastInput = WalkInput()

    public init(position: V2) { self.position = position }

    /// Teleports (mode switch, level change). Keeps no speed.
    public mutating func place(_ p: V2) { position = p; velocity = .zero; accumulator = 0 }

    public var speedMmPerSecond: Double { simd_length(velocity) }

    /// Advances by `dt` seconds with constant `input`. A collider keeps the body out of walls and furniture.
    public mutating func advance(dt: Double, input: WalkInput, settings: WalkSettings, collider: WalkCollider?) {
        guard dt.isFinite, dt > 0 else { return }
        lastInput = input
        accumulator += dt
        let h = Self.step
        var n = 0
        while accumulator >= h - 1e-12, n < Self.maxStepsPerAdvance {
            accumulator -= h
            n += 1
            stepOnce(h, input, settings, collider)
        }
        if n == Self.maxStepsPerAdvance { accumulator = 0 }
        if accumulator < 0 { accumulator = 0 }
    }

    private mutating func stepOnce(_ h: Double, _ input: WalkInput, _ s: WalkSettings, _ collider: WalkCollider?) {
        let yaw = input.yawDeg * .pi / 180
        let fwd = V2(-sin(yaw), cos(yaw)), right = V2(cos(yaw), sin(yaw))
        var wish = fwd * input.forward + right * input.strafe
        let len = simd_length(wish)
        if len > 1 { wish /= len }
        let crouchTarget = input.crouch ? 1.0 : 0.0
        let crouchStep = Self.crouchBlendPerSecond * h
        crouchBlend += min(max(crouchTarget - crouchBlend, -crouchStep), crouchStep)
        let speed = s.speedMps(input.step) * 1000 * (1 - crouchBlend * (1 - Self.crouchSpeedFactor))
        let target = wish * speed
        let delta = target - velocity
        let maxDv = s.accelerationMps2 * 1000 * h
        let dl = simd_length(delta)
        velocity = dl <= maxDv ? target : velocity + delta / dl * maxDv

        if s.collision, let collider { position = collider.resolve(position) }  // push-out never feeds the velocity
        let before = position
        let wanted = position + velocity * h
        if s.collision, let collider {
            let moved = collider.move(from: position, to: wanted)
            position = moved
            if simd_length(moved - wanted) > 1e-6 {
                // Sliding: keep only the part of the speed along the achieved path; never faster than before.
                let speedBefore = simd_length(velocity)
                velocity = (moved - before) / h
                let v = simd_length(velocity)
                if v > speedBefore, v > 0 { velocity *= speedBefore / v }
            }
        } else {
            position = wanted
        }
        bobPhase += simd_length(position - before) / Self.bobStrideMm
        if bobPhase > 1e6 { bobPhase.formTruncatingRemainder(dividingBy: 1) }
    }

    /// Feet position for drawing: the simulated one plus the not yet simulated share of the last frame.
    public func renderedPosition(collider: WalkCollider?, settings: WalkSettings) -> V2 {
        let p = position + velocity * accumulator
        guard settings.collision, let collider else { return p }
        return collider.resolve(p)
    }

    /// Vertical head-bob offset in mm (0 unless enabled; fades with speed).
    public func bobOffsetMm(settings: WalkSettings) -> Double {
        guard settings.headBob else { return 0 }
        let k = min(1, simd_length(velocity) / max(settings.speedNormalMps * 1000, 1))
        return Self.bobAmplitudeMm * k * sin(2 * .pi * bobPhase * 2)
    }

    /// Eye height above the level floor in mm, with crouching and head bob.
    public func eyeHeightMm(settings: WalkSettings) -> Double {
        settings.eyeHeightMm * (1 - crouchBlend * (1 - settings.crouchEyeFactor)) + bobOffsetMm(settings: settings)
    }
}
