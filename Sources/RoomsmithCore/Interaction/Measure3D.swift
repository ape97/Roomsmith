import Foundation

/// Distance text shared by the plan's measure tool and the 3D measure tool, so both always read the same.
public enum DistanceText {
    /// "4.25 m  (4250 mm)" in the project's display unit; just "4250 mm" when the unit is millimetres.
    public static func text(mm d: MM, unit: LengthUnit) -> String {
        let shown = unit.format(d)
        let mmText = "\(d) mm"
        return shown == mmText ? mmText : "\(shown)  (\(mmText))"
    }

    /// Straight-line length between two points, rounded to whole millimetres.
    public static func length(dx: MM, dy: MM, dz: MM = 0) -> MM {
        let x = Double(dx), y = Double(dy), z = Double(dz)
        return MM((x * x + y * y + z * z).squareRoot().rounded())
    }
}

/// A finished or previewed measurement between two world points of the 3D view (X east, Y north, Z up, mm).
public struct Measurement3D: Equatable, Sendable {
    public var a: P3
    public var b: P3

    public init(a: P3, b: P3) { self.a = a; self.b = b }

    public var dx: MM { b.x &- a.x }
    public var dy: MM { b.y &- a.y }
    public var dz: MM { b.z &- a.z }

    /// Straight distance in whole millimetres.
    public var distanceMm: MM { DistanceText.length(dx: dx, dy: dy, dz: dz) }

    /// Straight distance, formatted exactly like the plan's measure tool.
    public func distanceText(unit: LengthUnit) -> String { DistanceText.text(mm: distanceMm, unit: unit) }

    /// Signed components, e.g. "dx 1.2 m   dy -0.5 m   dz 0 m" (X east, Y north, Z up).
    public func componentsText(unit: LengthUnit) -> String {
        "dx \(unit.format(dx))   dy \(unit.format(dy))   dz \(unit.format(dz))"
    }

    /// The label lines shown next to the measuring line.
    public func labelLines(unit: LengthUnit) -> [String] {
        [distanceText(unit: unit), componentsText(unit: unit)]
    }
}

/// The two-click state machine of the 3D measure tool: first click sets A, second sets B, a third starts over.
public struct Measure3DState: Equatable, Sendable {
    public private(set) var a: P3?
    public private(set) var b: P3?

    public init() {}

    public var isEmpty: Bool { a == nil }
    /// A is set and waiting for B (a live preview line may follow the pointer).
    public var isPending: Bool { a != nil && b == nil }
    public var finished: Measurement3D? {
        guard let a, let b else { return nil }
        return Measurement3D(a: a, b: b)
    }

    /// Registers a click on `point`. A finished measurement is replaced; a second click on exactly A is ignored.
    public mutating func click(_ point: P3) {
        if a == nil || b != nil {
            a = point; b = nil
        } else if point != a {
            b = point
        }
    }

    public mutating func clear() { a = nil; b = nil }
}
