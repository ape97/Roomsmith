import Foundation

/// All stored linear measures are integer millimetres. Never store a length as Float/Double.
public typealias MM = Int64

/// Valid coordinate range: ±100 km. Keeps every product/sum of two coordinates far away from Int64 overflow.
public let coordinateLimit: MM = 100_000_000
/// Valid size range for walls, furniture and openings: 1 mm … 100 m.
public let sizeLimit: ClosedRange<MM> = 1...100_000

/// A point in the floor plane. World axes: X east (right in the plan), Y north (up in the plan), Z up (height).
public struct P2: Codable, Hashable, Sendable {
    public var x: MM
    public var y: MM
    public init(_ x: MM, _ y: MM) { self.x = x; self.y = y }
    public static let zero = P2(0, 0)
    // Operands are API-checked to ±coordinateLimit, so these cannot overflow; wrapping (`&`) keeps a stray
    // out-of-range value from trapping the app, and `isInRange` / the validator reject the result.
    public static func + (a: P2, b: P2) -> P2 { P2(a.x &+ b.x, a.y &+ b.y) }
    public static func - (a: P2, b: P2) -> P2 { P2(a.x &- b.x, a.y &- b.y) }
    public var isInRange: Bool { x.magnitude <= coordinateLimit.magnitude && y.magnitude <= coordinateLimit.magnitude }
}

/// A point in world space (mm). `z` is the height above the level's floor.
public struct P3: Codable, Hashable, Sendable {
    public var x: MM
    public var y: MM
    public var z: MM
    public init(_ x: MM, _ y: MM, _ z: MM) { self.x = x; self.y = y; self.z = z }
    public static let zero = P3(0, 0, 0)
    public var xy: P2 { P2(x, y) }
    public static func + (a: P3, b: P3) -> P3 { P3(a.x &+ b.x, a.y &+ b.y, a.z &+ b.z) }
    public static func - (a: P3, b: P3) -> P3 { P3(a.x &- b.x, a.y &- b.y, a.z &- b.z) }
    public static prefix func - (a: P3) -> P3 { P3(0 &- a.x, 0 &- a.y, 0 &- a.z) }
    public var isInRange: Bool {
        x.magnitude <= coordinateLimit.magnitude && y.magnitude <= coordinateLimit.magnitude && z.magnitude <= coordinateLimit.magnitude
    }
}

/// Size of a box in mm: width along local X, depth along local Y, height along Z.
public struct Size3: Codable, Hashable, Sendable {
    public var width: MM
    public var depth: MM
    public var height: MM
    public init(_ width: MM, _ depth: MM, _ height: MM) { self.width = width; self.depth = depth; self.height = height }
    public var isValid: Bool { sizeLimit.contains(width) && sizeLimit.contains(depth) && sizeLimit.contains(height) }
}

/// Euler rotation in degrees, applied X, then Y, then Z (intrinsic Z-Y-X is not used anywhere).
public struct R3: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double
    public init(_ x: Double = 0, _ y: Double = 0, _ z: Double = 0) { self.x = x; self.y = y; self.z = z }
    public static let zero = R3()
    public var isZero: Bool { x == 0 && y == 0 && z == 0 }
}

public enum Angle {
    /// Normalises to [0, 360) and rounds to 1/1000 degree so stored values stay stable across save/load.
    public static func normalized(_ deg: Double) -> Double {
        guard deg.isFinite else { return 0 }
        var d = deg.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        d = (d * 1000).rounded() / 1000
        return d >= 360 ? 0 : d
    }
}

/// Parsing and formatting of lengths for UI and agent input.
public enum LengthUnit: String, Codable, Sendable, CaseIterable {
    case mm, cm, m

    public var factor: Double {
        switch self { case .mm: 1; case .cm: 10; case .m: 1000 }
    }

    /// Typing hint naming the effective unit of bare numbers, e.g. "cm unless you add mm or m".
    public var bareNumberHint: String {
        let others = LengthUnit.allCases.filter { $0 != self }.map(\.rawValue)
        return "\(rawValue) unless you add \(others[0]) or \(others[1])"
    }

    /// Formats an exact mm value. cm/m use as many decimals as needed so the value is never rounded.
    public func format(_ value: MM, withUnit: Bool = true) -> String {
        let text: String
        switch self {
        case .mm: text = "\(value)"
        case .cm: text = Self.decimal(value, places: 1)
        case .m: text = Self.decimal(value, places: 3)
        }
        return withUnit ? "\(text) \(rawValue)" : text
    }

    private static func decimal(_ value: MM, places: Int) -> String {
        let divisor: MM = places == 1 ? 10 : 1000
        let negative = value < 0
        let magnitude = value.magnitude
        let whole = magnitude / UInt64(divisor)
        var frac = String(magnitude % UInt64(divisor))
        while frac.count < places { frac = "0" + frac }
        while frac.hasSuffix("0") { frac.removeLast() }
        let body = frac.isEmpty ? "\(whole)" : "\(whole).\(frac)"
        return negative ? "-" + body : body
    }

    /// Parses "4250", "4250 mm", "425 cm", "4.25 m", "4,25m". Bare numbers use `defaultUnit`.
    /// Returns nil for garbage, non-finite numbers, or values that are not a whole number of millimetres.
    public static func parse(_ input: String, defaultUnit: LengthUnit = .mm) -> MM? {
        // Strict full match: optional sign, digits with at most one decimal separator (. or ,), optional unit.
        let s = input.lowercased()
        guard let m = s.wholeMatch(of: /\s*([+-]?)\s*([0-9]{1,15}[.,]?[0-9]{0,6}|[.,][0-9]{1,6})\s*(mm|cm|m)?\s*/) else { return nil }
        let unit = m.3.flatMap { LengthUnit(rawValue: String($0)) } ?? defaultUnit
        let number = String(m.2).replacingOccurrences(of: ",", with: ".")
        guard var decimal = Decimal(string: number, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        if m.1 == "-" { decimal = -decimal }
        let mm = decimal * Decimal(unit.factor)
        var rounded = Decimal()
        var copy = mm
        NSDecimalRound(&rounded, &copy, 0, .plain)
        guard rounded == mm else { return nil }
        let value = NSDecimalNumber(decimal: rounded)
        guard abs(value.doubleValue) <= Double(coordinateLimit) else { return nil }
        return value.int64Value
    }
}
