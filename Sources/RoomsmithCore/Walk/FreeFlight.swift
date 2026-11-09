import Foundation
import simd

/// Speed step of the free camera: Option = slow, Shift = fast.
public enum FlightSpeedStep: Sendable, Equatable {
    case slow, normal, fast
    public var factor: Double {
        switch self {
        case .slow: 0.3
        case .normal: 1
        case .fast: 3
        }
    }
}

/// Free-camera input for one frame. `forward` (W/S), `strafe` (D/A) and `vertical` (E/Q) are -1...1.
public struct FreeFlightInput: Sendable, Equatable {
    public var forward: Double
    public var strafe: Double
    public var vertical: Double
    public var step: FlightSpeedStep
    public init(forward: Double = 0, strafe: Double = 0, vertical: Double = 0, step: FlightSpeedStep = .normal) {
        self.forward = forward; self.strafe = strafe; self.vertical = vertical; self.step = step
    }
}

/// Flying physics of the free camera: no collision, no floor, the eye moves along the view direction. The velocity eases
/// towards the wished velocity with an exponential response, so the result does not depend on the frame rate. The
/// displacement is transient `Double` maths; the app adds it to the camera target, which is stored as millimetres.
public struct FreeFlight: Sendable, Equatable {
    /// Cruise speed in mm/s at the normal speed step.
    public static let baseSpeedMmPerSecond = 2500.0
    /// Time constant of the velocity response in seconds.
    public static let responseSeconds = 0.12
    /// Below this speed (mm/s) without input the camera stops dead.
    static let stopSpeed = 1.0

    /// Velocity in mm/s (document axes, Z up).
    public private(set) var velocity = SIMD3<Double>.zero

    public init() {}

    /// True while the camera still glides (the app keeps ticking until this is false).
    public var isMoving: Bool { velocity != .zero }

    /// Unit-or-shorter wish direction. Forward follows the view (including pitch), strafe the horizontal `right`,
    /// vertical is world up. Combined input is normalised when longer than 1.
    public static func direction(for input: FreeFlightInput, yawDeg: Double, pitchDeg: Double) -> SIMD3<Double> {
        let y = yawDeg * .pi / 180, p = pitchDeg * .pi / 180
        let forward = SIMD3(-sin(y) * cos(p), cos(y) * cos(p), sin(p))
        let right = SIMD3(cos(y), sin(y), 0)
        var d = forward * input.forward + right * input.strafe + SIMD3(0, 0, 1) * input.vertical
        let len = simd_length(d)
        if len > 1 { d /= len }
        return d
    }

    /// Advances by `dt` seconds with constant `input` and returns the displacement in mm. A negative or non-finite `dt`
    /// does nothing.
    @discardableResult
    public mutating func advance(dt: Double, input: FreeFlightInput, yawDeg: Double, pitchDeg: Double) -> SIMD3<Double> {
        guard dt.isFinite, dt > 0 else { return .zero }
        let dir = Self.direction(for: input, yawDeg: yawDeg, pitchDeg: pitchDeg)
        let wish = dir * (Self.baseSpeedMmPerSecond * input.step.factor)
        let old = velocity
        var v = old + (wish - old) * (1 - exp(-dt / Self.responseSeconds))
        if dir == .zero, simd_length(v) < Self.stopSpeed { v = .zero }
        velocity = v
        return (old + v) * (dt / 2)
    }

    /// Drops all speed (mode switch, focus loss).
    public mutating func stop() { velocity = .zero }
}
