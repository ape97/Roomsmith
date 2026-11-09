import AppKit
import Foundation
import RoomsmithCore

/// Connects the agent view and render tools to the running window: layout and panel state (the same
/// `AppDefaults.store` keys the views bind to), plan viewport requests, the 3D camera and the scene renderer.
@MainActor
final class AppViewBridge: AgentViewBridge {
    private unowned let model: AppModel
    private let defaults = AppDefaults.store

    init(model: AppModel) { self.model = model }

    // MARK: State

    private var axis: SplitAxis { SplitAxis(rawValue: defaults.string(forKey: EditorLayoutKey.axis) ?? "") ?? .sideBySide }

    private func fractionKey(_ axis: SplitAxis) -> String {
        axis == .sideBySide ? EditorLayoutKey.fractionSideBySide : EditorLayoutKey.fractionStacked
    }

    private func flag(_ key: String) -> Bool { defaults.object(forKey: key) as? Bool ?? true }

    /// Whether the 3D view is detached, counting a change the agent asked for that the window has not applied yet
    /// (the window opens or closes on the next UI pass; `SceneWindowView` clears `pendingDetach` once it has).
    private var detachedNow: Bool {
        model.pendingDetach ?? (defaults.object(forKey: EditorLayoutKey.detached) as? Bool ?? false)
    }

    func viewState() -> AgentViewState {
        let a = axis
        let fraction = defaults.object(forKey: fractionKey(a)) as? Double ?? 0.5
        return AgentViewState(
            layout: AgentLayoutMode(rawValue: model.layout.rawValue) ?? .split,
            arrangement: AgentArrangement(rawValue: a.rawValue) ?? .sideBySide,
            splitFraction: fraction,
            sidebarTab: AgentSidebarTab(rawValue: model.sidebarTab.rawValue) ?? .objects,
            sidebar: flag(ViewKey.showSidebar), inspector: flag(ViewKey.showInspector), statusBar: flag(ViewKey.showStatusBar),
            sceneControls: model.showSceneControls,
            showCeilings: model.showCeilings, showLamps: model.showLamps, onlyActiveLevel: model.onlyActiveLevel,
            wallOpacity: model.wallOpacity,
            detach3D: detachedNow,
            planViewport: model.layout == .scene ? nil : model.planViewport)
    }

    func applyView(_ c: AgentViewChange) -> AgentViewState {
        let wasDetached = detachedNow
        if let v = c.layout, let l = ViewLayout(rawValue: v.rawValue) { model.layout = l }
        if let v = c.arrangement { defaults.set(v.rawValue, forKey: EditorLayoutKey.axis) }
        if let f = c.splitFraction { defaults.set(f, forKey: fractionKey(axis)) }
        if let v = c.sidebarTab, let t = SidebarTab(rawValue: v.rawValue) { model.sidebarTab = t }
        if let v = c.sidebar { defaults.set(v, forKey: ViewKey.showSidebar) }
        if let v = c.inspector { defaults.set(v, forKey: ViewKey.showInspector) }
        if let v = c.statusBar { defaults.set(v, forKey: ViewKey.showStatusBar) }
        if let v = c.sceneControls { model.showSceneControls = v }
        if let v = c.showCeilings { model.showCeilings = v }
        if let v = c.showLamps { model.showLamps = v }
        if let v = c.onlyActiveLevel { model.onlyActiveLevel = v }
        if let v = c.wallOpacity { model.wallOpacity = v }
        if c.planViewport != nil || c.planFit != nil {
            model.planViewRequest = PlanViewRequest(serial: (model.planViewRequest?.serial ?? 0) + 1,
                                                    viewport: c.planViewport, fit: c.planFit)
            if let v = c.planViewport { model.planViewport = v }
        }
        // Window changes happen on the next UI pass (see `SceneWindowView` and `ContentView`). Record the outcome as
        // pending, so this answer and any `view.get` before that pass already report the resulting state.
        if let want = c.detach3D, want != wasDetached {
            model.sceneWindowRequest = SceneWindowRequest(serial: (model.sceneWindowRequest?.serial ?? 0) + 1, detach: want)
            model.pendingDetach = want
            if want {
                model.layout = .plan  // what the window does when it appears
            } else if c.layout == .plan {
                model.keepPlanOnDock = true  // docking normally returns to plan + 3D; an explicit plan wins
            } else if c.layout == nil, model.layout == .plan {
                model.layout = .split  // what the window does when it closes from plan-only
            }
        } else if wasDetached, c.detach3D == nil, let l = c.layout, l != .plan {
            model.pendingDetach = false  // showing 3D in the main window docks the detached window
        }
        return viewState()
    }

    // MARK: Camera

    func cameraPreset(_ preset: AgentCameraPreset, ids: [UUID]) throws -> CameraState {
        let live = SceneSnapshot.liveView(for: model)?.renderer
        let renderer = live ?? offscreenRenderer(camera: nil)
        if live == nil { renderer.camera.viewSize = CGSize(width: 1280, height: 800) }
        apply(preset, ids: ids, on: renderer)
        let state = renderer.camera.rig.state
        if live == nil {
            renderer.teardown()
            do {
                try model.store.run("Camera", options: CommandOptions(origin: .system, recordUndo: false)) { $0.setCamera(state) }
            } catch {
                throw AgentError(code: AgentError.internal, message: "Could not store the camera: \(error)")
            }
        } else {
            renderer.flushCameraPersistence()
        }
        return state
    }

    /// Runs a view-button preset on `renderer`. `frame` frames exactly `ids` (the whole scene when empty), never
    /// the user's own selection, which is restored afterwards. `top` also frames the whole scene: the Top button
    /// alone only turns the camera down and keeps the orbit target and distance.
    private func apply(_ preset: AgentCameraPreset, ids: [UUID], on renderer: SceneRenderer) {
        let savedSelection = model.selection
        if preset == .frame || preset == .top { model.selection = Set(ids) }
        switch preset {
        case .aerial: renderer.setViewMode(.aerial)
        case .top: renderer.setViewMode(.top); renderer.frameSelection()
        case .reset: renderer.resetView()
        case .frame: renderer.frameSelection()
        }
        if model.selection != savedSelection { model.selection = savedSelection }
    }

    /// A throwaway renderer must see the same levels as the picture, or `onlyActiveLevel` fits to hidden levels.
    private func offscreenRenderer(camera: CameraState?) -> SceneRenderer {
        let r = SceneRenderer(model: model, interactive: false, camera: camera)
        r.setOptions(SceneOptions(showCeilings: model.showCeilings, onlyActiveLevel: model.onlyActiveLevel,
                                  wallOpacity: model.wallOpacity, showLamps: model.showLamps))
        return r
    }

    // MARK: Render

    func renderScene(width: Int, height: Int, dark: Bool, camera: CameraState?, preset: AgentCameraPreset?, ids: [UUID]) async throws -> Data {
        // Without an explicit camera the picture shows what the user sees in the 3D view.
        var cam = camera ?? SceneSnapshot.liveView(for: model)?.renderer.camera.rig.state
        if let preset {
            // A throwaway, non-interactive renderer fits the preset to the picture's aspect; it never stores a camera.
            let fitter = offscreenRenderer(camera: cam)
            fitter.camera.viewSize = CGSize(width: width, height: height)
            apply(preset, ids: ids, on: fitter)
            cam = fitter.camera.rig.state
            fitter.teardown()
        }
        let image = try await SceneSnapshot.render(model: model, camera: cam, size: CGSize(width: width, height: height), dark: dark,
                                                   openings: SceneSnapshot.liveView(for: model)?.renderer.walk.openings)
        guard let data = SceneSnapshot.png(from: image) else { throw SceneSnapshot.Failure.renderFailed("could not encode the PNG") }
        return data
    }
}
