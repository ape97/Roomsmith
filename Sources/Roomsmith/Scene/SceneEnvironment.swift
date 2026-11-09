import AppKit
import CoreGraphics
import Foundation
import RealityKit
import RoomsmithCore

/// Colours and image-based light of the 3D view. Neutral, so the room colours stay readable; light and dark aware.
@MainActor
enum SceneEnvironment {
    /// Daylight keeps the neutral light/dark palette of the app; the other moods bring their own sky.
    private static func moodLook(_ mood: LightMood) -> SunSkyLook? {
        mood == .daylight ? nil : SunSkyLook(LightingSettings(mood: mood))
    }

    private static func ns(_ c: SIMD3<Double>) -> NSColor { NSColor(srgbRed: c.x, green: c.y, blue: c.z, alpha: 1) }

    static func backgroundColor(dark: Bool, mood: LightMood) -> NSColor {
        moodLook(mood).map { ns($0.horizon) } ?? backgroundColor(dark: dark)
    }

    static func groundColor(dark: Bool, mood: LightMood) -> NSColor {
        moodLook(mood).map { ns($0.ground) } ?? groundColor(dark: dark)
    }

    static func backgroundColor(dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 0.24, green: 0.25, blue: 0.27, alpha: 1) : NSColor(srgbRed: 0.93, green: 0.94, blue: 0.95, alpha: 1)
    }

    static func groundColor(dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 0.32, green: 0.33, blue: 0.35, alpha: 1) : NSColor(srgbRed: 0.85, green: 0.86, blue: 0.87, alpha: 1)
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private static var cache: [LightMood: EnvironmentResource] = [:]

    /// Soft sky light (bright above, neutral below) built from a small generated equirectangular image.
    /// The light of the scene does not depend on the system appearance (only background and ground do),
    /// so a room looks equally bright in light and dark mode.
    static func resource(mood: LightMood = .daylight) async -> EnvironmentResource? {
        if let r = cache[mood] { return r }
        guard let image = skyImage(mood: mood) else { return nil }
        do {
            let r = try await EnvironmentResource(equirectangular: image, withName: "roomsmith-sky-\(mood.rawValue)")
            cache[mood] = r
            return r
        } catch {
            return nil
        }
    }

    /// 256 x 128 gradient: zenith, horizon, ground.
    static func skyImage(mood: LightMood = .daylight) -> CGImage? {
        let w = 256, h = 128
        var zenith: SIMD3<Double> = SIMD3(0.70, 0.80, 1.0)
        var horizon: SIMD3<Double> = SIMD3(1.0, 0.99, 0.96)
        var floor: SIMD3<Double> = SIMD3(0.55, 0.55, 0.56)
        if let look = moodLook(mood) { zenith = look.zenith; horizon = look.horizon; floor = look.ground }
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            let v = (Double(y) + 0.5) / Double(h)   // 0 = zenith, 1 = nadir
            let c: SIMD3<Double>
            if v < 0.5 {
                let t = pow(v / 0.5, 0.7)
                c = zenith + (horizon - zenith) * t
            } else {
                let t = min((v - 0.5) / 0.12, 1)
                c = horizon + (floor - horizon) * t
            }
            for x in 0..<w {
                let i = (y * w + x) * 4
                pixels[i] = UInt8(min(max(c.x, 0), 1) * 255)
                pixels[i + 1] = UInt8(min(max(c.y, 0), 1) * 255)
                pixels[i + 2] = UInt8(min(max(c.z, 0), 1) * 255)
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
