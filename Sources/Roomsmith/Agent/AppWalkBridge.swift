import Foundation
import RoomsmithCore

/// Connects the `walk.*` agent tools to the running window: the shared walk settings and the live 3D view.
///
/// Settings are stored whether or not a 3D view is open; door state and the live readout need a view of this model.
@MainActor
final class AppWalkBridge: AgentWalkBridge {
    private weak var model: AppModel?
    private static var bridges: [ObjectIdentifier: AppWalkBridge] = [:]

    private init(model: AppModel) { self.model = model }

    /// One bridge per model, created on first use (the model class keeps no slot for it).
    static func bridge(for model: AppModel) -> AppWalkBridge {
        bridges = bridges.filter { $0.value.model != nil }  // drop bridges of closed windows
        let key = ObjectIdentifier(model)
        if let b = bridges[key] { return b }
        let b = AppWalkBridge(model: model)
        bridges[key] = b
        return b
    }

    private var renderer: SceneRenderer? {
        guard let model, let r = SceneSnapshot.liveView(for: model)?.renderer, r.model === model else { return nil }
        return r
    }

    func walkState() -> AgentWalkState {
        let s = WalkSettingsStore.shared.settings
        guard let r = renderer else {
            return AgentWalkState(settings: s, active: false, eyeHeightMm: s.eyeHeightMm, speedMps: 0,
                                  fovDeg: WalkFOV.verticalDeg(s, autoScreenHeightMm: nil, viewHeightPoints: 1, screenHeightPoints: 1),
                                  autoScreenHeightMm: nil, openDoors: [], openOpenings: [])
        }
        let w = r.walk
        let active = r.camera.rig.mode == .firstPerson
        return AgentWalkState(settings: s, active: active, eyeHeightMm: active ? w.currentEyeHeightMm : s.eyeHeightMm,
                              speedMps: active ? w.speedMps : 0, fovDeg: active ? r.camera.rig.fov : w.fovDeg(s),
                              autoScreenHeightMm: w.autoScreenHeightMm, openDoors: w.openDoorIds,
                              openOpenings: w.openWindowList.map { .init(id: $0.id, mode: $0.mode) })
    }

    func applyWalkSettings(_ settings: WalkSettings) -> AgentWalkState {
        WalkSettingsStore.shared.settings = settings
        return walkState()
    }

    func setDoor(_ openingId: UUID, open: Bool?) throws -> Bool {
        guard let r = renderer else {
            throw AgentError(code: "UNSUPPORTED", message: "Doors open and close in the 3D view; open the 3D view first.")
        }
        return r.walk.setDoor(openingId, open: open)
    }

    func setOpening(_ openingId: UUID, open: Bool?, mode: OpeningMode) throws -> OpeningMode {
        guard let r = renderer else {
            throw AgentError(code: "UNSUPPORTED", message: "Openings open and close in the 3D view; open the 3D view first.")
        }
        return r.walk.setOpening(openingId, mode: mode, open: open)
    }
}
