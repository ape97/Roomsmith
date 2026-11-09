import Foundation
import simd

/// The scene's sun and sky derived from `LightingSettings`. Pure data: the renderer only translates it into RealityKit.
public struct SunSkyLook: Equatable, Sendable {
    /// Unit vector the sunlight travels along (model space, Z up). Meaningless when `sunIntensity` is 0.
    public var sunTravel: SIMD3<Double>
    /// Sun height above the horizon in degrees.
    public var sunElevationDeg: Double
    /// Linear sun colour 0...1.
    public var sunColor: SIMD3<Double>
    /// 0...1 share of the full sun strength that reaches the scene (0 at night and below the horizon).
    public var sunIntensity: Double
    /// Whether the sun casts shadows (needs sun, the user's switch, and no overcast sky).
    public var sunShadows: Bool
    /// Strength of the sky/ambient light, 1 = the daylight baseline.
    public var ambient: Double
    /// Sky colours (sRGB 0...1), used for the environment image and the background.
    public var zenith: SIMD3<Double>
    public var horizon: SIMD3<Double>
    public var ground: SIMD3<Double>
    /// Exposure offset in EV stops (the mood's own bias plus the user's exposure).
    public var exposureEV: Double

    public init(_ s: LightingSettings) {
        let pos = SunPosition.compute(s)
        sunElevationDeg = pos.elevationDeg
        sunTravel = -pos.directionToSun(northDeg: s.northDeg)
        // Sun fades out between -2 and +6 degrees so dusk and dawn are not a hard switch.
        let fade = min(max((pos.elevationDeg + 2) / 8, 0), 1)
        let strength = min(max(pos.elevationDeg / 30, 0.25), 1)   // low sun is weaker per area
        switch s.mood {
        case .daylight:
            sunIntensity = fade * strength
            sunColor = Kelvin.rgb(pos.elevationDeg < 15 ? 4500 : 6000)
            ambient = 1
            zenith = SIMD3(0.36, 0.55, 0.85); horizon = SIMD3(0.80, 0.86, 0.93); ground = SIMD3(0.42, 0.41, 0.40)
            exposureEV = 0
        case .evening:
            sunIntensity = fade * strength * 0.8
            sunColor = Kelvin.rgb(3000)
            ambient = 0.7
            zenith = SIMD3(0.22, 0.26, 0.45); horizon = SIMD3(0.95, 0.60, 0.38); ground = SIMD3(0.30, 0.24, 0.22)
            exposureEV = 0.8
        case .night:
            sunIntensity = 0
            sunColor = Kelvin.rgb(9000)
            ambient = 0.2
            zenith = SIMD3(0.02, 0.03, 0.09); horizon = SIMD3(0.06, 0.08, 0.16); ground = SIMD3(0.04, 0.04, 0.05)
            exposureEV = 1.2
        case .overcast:
            sunIntensity = fade * strength * 0.15
            sunColor = Kelvin.rgb(7000)
            ambient = 0.9
            zenith = SIMD3(0.62, 0.65, 0.70); horizon = SIMD3(0.78, 0.80, 0.83); ground = SIMD3(0.40, 0.40, 0.40)
            exposureEV = 0
        }
        sunShadows = s.shadows && s.mood != .overcast && sunIntensity > 0.05
        exposureEV += s.exposure
    }
}

/// One lamp that actually shines, in world millimetres (Z up).
public struct ActiveLight: Equatable, Sendable {
    public var instanceId: UUID
    public var emitterId: UUID
    public var kind: LightKind
    public var position: SIMD3<Double>
    /// Unit direction a spot points along; (0, 0, -1) for point lights.
    public var direction: SIMD3<Double>
    public var coneDeg: Double
    public var lumens: Int
    /// Linear-ish RGB 0...1.
    public var color: SIMD3<Double>
    public var rangeMm: Double
}

/// Picks the lamps to render. RealityKit lights are expensive, so only the strongest `maxActive` shine; the rest are counted as skipped.
public enum LightRig {
    /// Cap on simultaneously rendered lamps (each is a RealityKit light entity with its own shading cost).
    public static let maxActive = 8

    /// All lamps of switched-on, visible pieces on visible levels, strongest first (then by id so the choice is stable).
    /// `levelVisible` decides which levels count (e.g. only the active level).
    public static func collect(_ p: Project, levelVisible: (UUID) -> Bool = { _ in true }) -> (active: [ActiveLight], skipped: Int) {
        var all = [ActiveLight]()
        let defs = Dictionary(uniqueKeysWithValues: p.definitions.map { ($0.id, $0) })
        for inst in p.instances where inst.lightOn && inst.visible {
            guard let def = defs[inst.definitionId], !def.lights.isEmpty, let level = p.level(inst.levelId),
                  level.visible, levelVisible(inst.levelId) else { continue }
            let m = FurnitureResolver.instanceMatrix(inst, definition: def, levelElevation: level.elevation)
            let yaw = inst.rotationDeg * .pi / 180
            for e in def.lights {
                let w = m * SIMD4(Double(e.position.x), Double(e.position.y), Double(e.position.z), 1)
                let ey = e.yawDeg * .pi / 180, ep = e.pitchDeg * .pi / 180
                let local = SIMD3(cos(ep) * cos(ey), cos(ep) * sin(ey), sin(ep))
                let dir = SIMD3(cos(yaw) * local.x - sin(yaw) * local.y, sin(yaw) * local.x + cos(yaw) * local.y, local.z)
                all.append(ActiveLight(instanceId: inst.id, emitterId: e.id, kind: e.kind, position: SIMD3(w.x, w.y, w.z),
                                       direction: e.kind == .spot ? dir : SIMD3(0, 0, -1), coneDeg: e.coneDeg, lumens: e.lumens,
                                       color: e.rgb, rangeMm: Double(e.rangeMm)))
            }
        }
        all.sort { a, b in
            a.lumens != b.lumens ? a.lumens > b.lumens
                : (a.instanceId.uuidString, a.emitterId.uuidString) < (b.instanceId.uuidString, b.emitterId.uuidString)
        }
        return (Array(all.prefix(maxActive)), max(0, all.count - maxActive))
    }
}

/// Reuse plan for the renderer's lamp entities: which existing entity can stay and which must be created fresh.
public enum LampSlotPlan {
    public enum Action: Equatable, Sendable { case keep, create }

    /// One action per wanted lamp, by index: `keep` when the entity at that index has the same kind, otherwise `create`
    /// (the old entity at that index, if any, is replaced). Entities beyond `wanted.count` are dropped.
    public static func plan(current: [LightKind], wanted: [LightKind]) -> [Action] {
        wanted.enumerated().map { i, k in i < current.count && current[i] == k ? .keep : .create }
    }
}
