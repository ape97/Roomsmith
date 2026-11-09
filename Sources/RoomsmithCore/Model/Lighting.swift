import Foundation

/// Atmosphere preset of the 3D scene. The sun position comes from date, time and north; the mood decides how much of
/// that sun reaches the scene and what colour the sky has.
public enum LightMood: String, Codable, Sendable, CaseIterable {
    /// Clear day: full sun, blue sky.
    case daylight
    /// Warm low light: orange sun and sky.
    case evening
    /// No sun, dark blue sky; lamps do the work.
    case night
    /// Cloudy: weak sun without hard shadows, grey sky.
    case overcast

    /// Time of day (minutes after midnight) that fits the mood; `LightingSettings.applying(mood:)` uses it.
    public var suggestedTimeMinutes: Int {
        switch self {
        case .daylight: 13 * 60
        case .evening: 19 * 60 + 30
        case .night: 23 * 60 + 30
        case .overcast: 12 * 60
        }
    }
}

/// Light of the whole scene: sun and sky. Document state, so every change is a command with undo.
public struct LightingSettings: Codable, Hashable, Sendable {
    /// Where geographic north lies in the plan: degrees counter-clockwise (seen from above, like `rotationDeg`) from the plan's
    /// +Y axis. 0 = north is +Y and east is +X; 90 = north is -X.
    public var northDeg: Double = 0
    /// Day of the year 1...366 (21 June = 172), for the sun's height.
    public var dayOfYear: Int = 172
    /// Local solar time in minutes after midnight, 0...1439 (noon = 720; no time zone or equation of time).
    public var timeMinutes: Int = 13 * 60
    /// Latitude in degrees, -66...66 (positive = north).
    public var latitudeDeg: Double = 50
    public var mood: LightMood = .daylight
    /// Sun (and later spot) shadows. RealityKit point lights never cast shadows.
    public var shadows: Bool = true
    /// Exposure in EV stops, -3...3.
    public var exposure: Double = 0
    public init() {}
    public init(mood: LightMood) { self.mood = mood; timeMinutes = mood.suggestedTimeMinutes }

    public static let northRange = -360.0...360.0
    public static let dayRange = 1...366
    public static let timeRange = 0...1439
    public static let latitudeRange = -66.0...66.0
    public static let exposureRange = -3.0...3.0

    /// The settings with `mood` and its suggested time of day.
    public func applying(mood: LightMood) -> LightingSettings {
        var s = self
        s.mood = mood
        s.timeMinutes = mood.suggestedTimeMinutes
        return s
    }

    public var isValid: Bool {
        northDeg.isFinite && Self.northRange.contains(northDeg) && Self.dayRange.contains(dayOfYear)
            && Self.timeRange.contains(timeMinutes) && latitudeDeg.isFinite && Self.latitudeRange.contains(latitudeDeg)
            && exposure.isFinite && Self.exposureRange.contains(exposure)
    }

    /// "13:00".
    public var timeText: String { String(format: "%02d:%02d", timeMinutes / 60, timeMinutes % 60) }
}

public enum LightKind: String, Codable, Sendable, CaseIterable {
    /// Shines in all directions.
    case point
    /// Cone along the emitter's aim.
    case spot
}

/// A lamp that is part of a furniture design. It is switched per placed piece by `FurnitureInstance.lightOn`.
public struct LightEmitter: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: LightKind = .point
    /// Position in the design's space: origin at the footprint centre on the floor, mm. Scales with the instance size.
    public var position: P3
    /// Aim of a spot: yaw (counter-clockwise from +X, seen from above, turns with the piece) and pitch (-90 = straight down).
    public var yawDeg: Double = 0
    public var pitchDeg: Double = -90
    /// Full opening angle of a spot's cone, 10...150.
    public var coneDeg: Double = 80
    /// Light colour temperature in Kelvin, 1500...12000, unless `color` is set.
    public var kelvin: Int = 2700
    /// Explicit colour; overrides `kelvin`.
    public var color: RGBColor?
    /// Luminous flux, 1...100000 lm (a 60 W incandescent bulb is about 800).
    public var lumens: Int = 800
    /// Distance in mm at which the light fades out, 200...30000.
    public var rangeMm: MM = 5000

    public init(id: UUID = UUID(), name: String = "Lamp", kind: LightKind = .point, position: P3) {
        self.id = id; self.name = name; self.kind = kind; self.position = position
    }

    public static let lumensRange = 1...100_000
    public static let kelvinRange = 1500...12_000
    public static let coneRange = 10.0...150.0
    public static let rangeMmLimit: ClosedRange<MM> = 200...30_000
    public static let pitchRange = -90.0...90.0
    public static let maxPerDefinition = 8

    /// Linear RGB-ish colour 0...1 (sRGB values) of the emitted light.
    public var rgb: SIMD3<Double> {
        if let c = color { return SIMD3(Double(c.r), Double(c.g), Double(c.b)) / 255 }
        return Kelvin.rgb(kelvin)
    }

    public var isValid: Bool {
        Self.lumensRange.contains(lumens) && Self.kelvinRange.contains(kelvin) && Self.coneRange.contains(coneDeg)
            && Self.rangeMmLimit.contains(rangeMm) && yawDeg.isFinite && pitchDeg.isFinite && Self.pitchRange.contains(pitchDeg)
            && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// Colour temperature to sRGB (Tanner Helland's approximation of the black-body curve), 0...1 per channel.
public enum Kelvin {
    public static func rgb(_ kelvin: Int) -> SIMD3<Double> {
        let t = Double(min(max(kelvin, 1000), 40_000)) / 100
        let r: Double = t <= 66 ? 255 : 329.698727446 * pow(t - 60, -0.1332047592)
        let g: Double = t <= 66 ? 99.4708025861 * log(t) - 161.1195681661 : 288.1221695283 * pow(t - 60, -0.0755148492)
        let b: Double = t >= 66 ? 255 : (t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307)
        func c(_ v: Double) -> Double { min(max(v, 0), 255) / 255 }
        return SIMD3(c(r), c(g), c(b))
    }
}

// MARK: Sanitising (files and agents can carry anything; the renderer and validator expect ranges)

private func clampFinite(_ v: Double, _ r: ClosedRange<Double>, default d: Double) -> Double {
    v.isFinite ? min(max(v, r.lowerBound), r.upperBound) : d
}

public extension LightingSettings {
    /// Same settings with every value inside its range; non-finite numbers fall back to the default.
    func sanitized() -> LightingSettings {
        var s = self
        let d = LightingSettings()
        s.northDeg = clampFinite(northDeg, Self.northRange, default: d.northDeg)
        s.dayOfYear = min(max(dayOfYear, Self.dayRange.lowerBound), Self.dayRange.upperBound)
        s.timeMinutes = min(max(timeMinutes, Self.timeRange.lowerBound), Self.timeRange.upperBound)
        s.latitudeDeg = clampFinite(latitudeDeg, Self.latitudeRange, default: d.latitudeDeg)
        s.exposure = clampFinite(exposure, Self.exposureRange, default: d.exposure)
        return s
    }
}

public extension LightEmitter {
    /// Same lamp with every value inside its range; non-finite numbers fall back to the default.
    func sanitized() -> LightEmitter {
        var e = self
        let d = LightEmitter(position: position)
        e.yawDeg = yawDeg.isFinite ? yawDeg : d.yawDeg
        e.pitchDeg = clampFinite(pitchDeg, Self.pitchRange, default: d.pitchDeg)
        e.coneDeg = clampFinite(coneDeg, Self.coneRange, default: d.coneDeg)
        e.kelvin = min(max(kelvin, Self.kelvinRange.lowerBound), Self.kelvinRange.upperBound)
        e.lumens = min(max(lumens, Self.lumensRange.lowerBound), Self.lumensRange.upperBound)
        e.rangeMm = min(max(rangeMm, Self.rangeMmLimit.lowerBound), Self.rangeMmLimit.upperBound)
        if name.trimmingCharacters(in: .whitespaces).isEmpty { e.name = "Lamp" }
        return e
    }

    /// Clamps every lamp, gives repeated ids a fresh one and keeps at most `maxPerDefinition` lamps.
    static func sanitize(_ lamps: [LightEmitter]) -> [LightEmitter] {
        var seen = Set<UUID>()
        var out: [LightEmitter] = []
        for var e in lamps.prefix(maxPerDefinition) {
            e = e.sanitized()
            if !seen.insert(e.id).inserted { e.id = UUID(); seen.insert(e.id) }
            out.append(e)
        }
        return out
    }
}

// MARK: - Lamp furniture (3D view filter)

public extension FurnitureDefinition {
    /// A lamp design: it has a light, or it is lamp furniture without one (category "Lighting" like the built-in catalog, a tag
    /// "lamp"/"light", or "lamp"/"Lampe"/"Leuchte" in the name or a tag, e.g. "Tischlampe", "Deckenleuchte"; case-insensitive, whole-word "light" only in tags).
    /// The 3D view's "Lamps" switch hides the pieces of such designs.
    var isLamp: Bool {
        if !lights.isEmpty { return true }
        if category.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("Lighting") == .orderedSame { return true }
        func words(_ t: String) -> [String] { t.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init) }
        let tagWords = tags.flatMap(words)
        return (words(name) + tagWords).contains { $0.contains("lamp") || $0.contains("leuchte") } || tagWords.contains { $0 == "light" || $0 == "lights" }
    }
}

public extension Project {
    /// Ids of the designs with lamps; one pass, for loops over many pieces.
    var lampDefinitionIds: Set<UUID> { Set(definitions.filter(\.isLamp).map(\.id)) }

    /// Whether the 3D view draws, picks and collides with `instance`: false only for a lamp piece while `showLamps` is off.
    /// Its light is not affected (see `LightRig`); an unknown design counts as plain furniture.
    func isInstanceShown(_ instance: FurnitureInstance, showLamps: Bool) -> Bool {
        showLamps || definition(instance.definitionId)?.isLamp != true
    }
}
