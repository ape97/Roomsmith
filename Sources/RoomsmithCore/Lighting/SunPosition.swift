import Foundation

/// Where the sun is, from date, solar time, latitude and the plan's north. Pure maths, no rendering.
public struct SunPosition: Equatable, Sendable {
    /// Compass bearing clockwise from true north (0 = north, 90 = east, 180 = south), 0..<360.
    public var azimuthDeg: Double
    /// Height above the horizon in degrees; negative = below it.
    public var elevationDeg: Double

    public init(azimuthDeg: Double, elevationDeg: Double) { self.azimuthDeg = azimuthDeg; self.elevationDeg = elevationDeg }

    /// Standard solar-position formulas with the declination approximated by 23.44 degrees times a sine over the year (accurate to about a degree).
    public static func compute(dayOfYear: Int, timeMinutes: Int, latitudeDeg: Double) -> SunPosition {
        let rad = Double.pi / 180
        let declination = 23.44 * sin(2 * .pi * (284 + Double(dayOfYear)) / 365) * rad
        let hour = (Double(timeMinutes) - 720) / 4 * rad   // 15 degrees per hour, afternoon positive
        let lat = latitudeDeg * rad
        let sinEl = sin(lat) * sin(declination) + cos(lat) * cos(declination) * cos(hour)
        let el = asin(min(max(sinEl, -1), 1))
        // Azimuth from south, positive towards west; +180 turns it into a bearing from north.
        let fromSouth = atan2(sin(hour), cos(hour) * sin(lat) - tan(declination) * cos(lat))
        var az = fromSouth / rad + 180
        az = az.truncatingRemainder(dividingBy: 360)
        if az < 0 { az += 360 }
        return SunPosition(azimuthDeg: az, elevationDeg: el / rad)
    }

    public static func compute(_ s: LightingSettings) -> SunPosition {
        compute(dayOfYear: s.dayOfYear, timeMinutes: s.timeMinutes, latitudeDeg: s.latitudeDeg)
    }

    /// Unit vector in model space (X east for northDeg 0, Y north, Z up) that points from the scene towards the sun.
    public func directionToSun(northDeg: Double) -> SIMD3<Double> {
        let rad = Double.pi / 180
        // Direction angle counter-clockwise from +X: north sits at 90 + northDeg, bearings run clockwise.
        let phi = (90 + northDeg - azimuthDeg) * rad
        let el = elevationDeg * rad
        return SIMD3(cos(el) * cos(phi), cos(el) * sin(phi), sin(el))
    }
}
