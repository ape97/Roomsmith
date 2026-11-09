import Foundation
import Observation
import RoomsmithCore

/// The walk settings of the user, remembered across launches (view state, never part of the document).
///
/// One JSON string under `walk.settings` in `AppDefaults.store` (so test mode uses its own suite). All 3D views
/// share this store; the settings popover, the agent (`walk.set`) and the frame update read and write it.
@MainActor
@Observable
final class WalkSettingsStore {
    static let shared = WalkSettingsStore()
    static let key = "walk.settings"

    var settings: WalkSettings {
        didSet {
            let clean = settings.sanitized()
            if clean != settings { settings = clean; return }
            if clean != oldValue { Self.save(clean) }
        }
    }

    init() { settings = Self.load() }

    private static func load() -> WalkSettings {
        guard let text = AppDefaults.store.string(forKey: key), let data = text.data(using: .utf8),
              let s = try? JSONDecoder().decode(WalkSettings.self, from: data) else { return WalkSettings() }
        return s.sanitized()
    }

    private static func save(_ s: WalkSettings) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(s), let text = String(data: data, encoding: .utf8) else { return }
        AppDefaults.store.set(text, forKey: key)
    }

    func reset() { settings = WalkSettings() }
}

/// What the walk HUD shows (one value per rendered change, so the overlay is not invalidated every frame).
struct WalkHUDInfo: Equatable {
    var eyeMm: Int
    var speedTenthsMps: Int
    var fovDeg: Int
    var calibrated: Bool
    var crouching: Bool
    var locked: Bool
    /// Length of the 1 m reference bar in view points and the distance it is drawn for (dm); nil when off.
    var scalePoints: Int?
    var scaleDepthDm: Int
}
