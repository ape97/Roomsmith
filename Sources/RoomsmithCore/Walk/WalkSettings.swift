import Foundation

/// How the walk camera chooses its vertical field of view.
public enum WalkFOVMode: Codable, Sendable, Equatable {
    /// A fixed vertical field of view in degrees.
    case standard(fovDeg: Double)
    /// The view subtends the same angle as the physical window does at the viewing distance (1:1 on screen).
    case calibrated

    private enum CodingKeys: String, CodingKey { case mode, fovDeg }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .mode) {
        case "calibrated": self = .calibrated
        default: self = .standard(fovDeg: try c.decodeIfPresent(Double.self, forKey: .fovDeg) ?? 60)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .calibrated: try c.encode("calibrated", forKey: .mode)
        case .standard(let deg): try c.encode("standard", forKey: .mode); try c.encode(deg, forKey: .fovDeg)
        }
    }
}

/// The three walking speeds (Alt, none, Shift).
public enum WalkSpeedStep: String, Codable, Sendable, CaseIterable { case slow, normal, fast }

/// Settings of the first-person walk mode. View state of the user (remembered per user, never part of the document).
/// Lengths are millimetres, speeds metres per second.
public struct WalkSettings: Codable, Sendable, Equatable {
    public static let eyeToBodyRatio = 0.936

    public var bodyHeightMm: Double = 1750
    public var eyeHeightOverrideMm: Double?
    public var fovMode: WalkFOVMode = .standard(fovDeg: 60)
    /// Physical height of the screen's picture; nil = read from the display.
    public var screenHeightMm: Double?
    public var viewingDistanceMm: Double = 600
    public var speedSlowMps: Double = 0.8
    public var speedNormalMps: Double = 1.4
    public var speedFastMps: Double = 2.5
    public var accelerationMps2: Double = 3.0
    public var crouchEyeFactor: Double = 0.6
    public var headBob: Bool = false
    public var collision: Bool = true
    /// Degrees of turn per point of mouse movement.
    public var mouseSensitivity: Double = 0.15
    public var invertY: Bool = false
    public var controllerDeadzone: Double = 0.15
    /// Degrees per second at full stick deflection.
    public var controllerSensitivity: Double = 120
    public var bodyRadiusMm: Double = 220
    /// Shows a 1 m measuring stick in front of the camera.
    public var showScale: Bool = false

    public init() {}

    public var eyeHeightMm: Double { eyeHeightOverrideMm ?? (bodyHeightMm * Self.eyeToBodyRatio).rounded() }

    public func speedMps(_ step: WalkSpeedStep) -> Double {
        switch step {
        case .slow: speedSlowMps
        case .normal: speedNormalMps
        case .fast: speedFastMps
        }
    }

    public static let bodyHeightRange: ClosedRange<Double> = 1000...2300
    public static let eyeHeightRange: ClosedRange<Double> = 600...2200
    public static let fovRange: ClosedRange<Double> = 10...120

    /// A copy with every value brought into its valid range (NaN and infinities fall back to the default).
    public func sanitized() -> WalkSettings {
        var s = self
        let d = WalkSettings()
        func fix(_ v: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            v.isFinite ? min(max(v, range.lowerBound), range.upperBound) : fallback
        }
        s.bodyHeightMm = fix(bodyHeightMm, Self.bodyHeightRange, d.bodyHeightMm)
        s.eyeHeightOverrideMm = eyeHeightOverrideMm.map { fix($0, Self.eyeHeightRange, d.eyeHeightMm) }
        if case .standard(let deg) = fovMode { s.fovMode = .standard(fovDeg: fix(deg, Self.fovRange, 60)) }
        s.screenHeightMm = screenHeightMm.flatMap { $0.isFinite && $0 > 0 ? min(max($0, 50), 3000) : nil }
        s.viewingDistanceMm = fix(viewingDistanceMm, 200...3000, d.viewingDistanceMm)
        s.speedSlowMps = fix(speedSlowMps, 0.1...10, d.speedSlowMps)
        s.speedNormalMps = fix(speedNormalMps, 0.1...10, d.speedNormalMps)
        s.speedFastMps = fix(speedFastMps, 0.1...15, d.speedFastMps)
        s.accelerationMps2 = fix(accelerationMps2, 0.2...30, d.accelerationMps2)
        s.crouchEyeFactor = fix(crouchEyeFactor, 0.3...1, d.crouchEyeFactor)
        s.mouseSensitivity = fix(mouseSensitivity, 0.02...1, d.mouseSensitivity)
        s.controllerDeadzone = fix(controllerDeadzone, 0...0.9, d.controllerDeadzone)
        s.controllerSensitivity = fix(controllerSensitivity, 10...400, d.controllerSensitivity)
        s.bodyRadiusMm = fix(bodyRadiusMm, 50...600, d.bodyRadiusMm)
        return s
    }

    // Missing keys keep their defaults, so older stored settings still load after fields were added.
    private enum CodingKeys: String, CodingKey {
        case bodyHeightMm, eyeHeightOverrideMm, fovMode, screenHeightMm, viewingDistanceMm, speedSlowMps, speedNormalMps, speedFastMps
        case accelerationMps2, crouchEyeFactor, headBob, collision, mouseSensitivity, invertY, controllerDeadzone
        case controllerSensitivity, bodyRadiusMm, showScale
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ k: CodingKeys, _ d: T) throws -> T { try c.decodeIfPresent(T.self, forKey: k) ?? d }
        let d = WalkSettings()
        bodyHeightMm = try get(.bodyHeightMm, d.bodyHeightMm)
        eyeHeightOverrideMm = try c.decodeIfPresent(Double.self, forKey: .eyeHeightOverrideMm)
        fovMode = try get(.fovMode, d.fovMode)
        screenHeightMm = try c.decodeIfPresent(Double.self, forKey: .screenHeightMm)
        viewingDistanceMm = try get(.viewingDistanceMm, d.viewingDistanceMm)
        speedSlowMps = try get(.speedSlowMps, d.speedSlowMps)
        speedNormalMps = try get(.speedNormalMps, d.speedNormalMps)
        speedFastMps = try get(.speedFastMps, d.speedFastMps)
        accelerationMps2 = try get(.accelerationMps2, d.accelerationMps2)
        crouchEyeFactor = try get(.crouchEyeFactor, d.crouchEyeFactor)
        headBob = try get(.headBob, d.headBob)
        collision = try get(.collision, d.collision)
        mouseSensitivity = try get(.mouseSensitivity, d.mouseSensitivity)
        invertY = try get(.invertY, d.invertY)
        controllerDeadzone = try get(.controllerDeadzone, d.controllerDeadzone)
        controllerSensitivity = try get(.controllerSensitivity, d.controllerSensitivity)
        bodyRadiusMm = try get(.bodyRadiusMm, d.bodyRadiusMm)
        showScale = try get(.showScale, d.showScale)
    }
}

public enum WalkFOV {
    /// Vertical angle subtended by a picture `viewHeightMm` tall seen from `distanceMm`: 2 atan(h / 2 / d), in degrees.
    public static func calibratedVerticalDeg(viewHeightMm: Double, distanceMm: Double) -> Double {
        guard viewHeightMm > 0, distanceMm > 0 else { return 60 }
        return 2 * atan(viewHeightMm / 2 / distanceMm) * 180 / .pi
    }

    /// Vertical field of view for the settings. For `.calibrated` the 3D view covers `viewHeightPoints` of a screen
    /// `screenHeightPoints` tall whose picture is `screenHeightMm` tall (`autoScreenHeightMm` when the settings leave
    /// it open), so the physical height of the view is the matching share. Result clamped to 10...120 degrees.
    public static func verticalDeg(_ s: WalkSettings, autoScreenHeightMm: Double?, viewHeightPoints: Double, screenHeightPoints: Double) -> Double {
        switch s.fovMode {
        case .standard(let deg):
            return min(max(deg, WalkSettings.fovRange.lowerBound), WalkSettings.fovRange.upperBound)
        case .calibrated:
            let screenMm = s.screenHeightMm ?? autoScreenHeightMm ?? 190
            let share = screenHeightPoints > 0 ? min(max(viewHeightPoints / screenHeightPoints, 0.05), 1) : 1
            let deg = calibratedVerticalDeg(viewHeightMm: screenMm * share, distanceMm: s.viewingDistanceMm)
            return min(max(deg, WalkSettings.fovRange.lowerBound), WalkSettings.fovRange.upperBound)
        }
    }
}
