import Foundation
import Observation

/// View settings that belong to the window, not to one project: layout, sidebar tab and the 3D display options.
/// The workspace owns one instance and hands it to every open project, so all tabs and both compare panes stay in
/// sync. Remembered between launches (see `AppDefaults`); older versions kept the 3D options under `scene.*`.
@MainActor @Observable
public final class WindowPrefs {
    /// Which editors are shown.
    public var layout: ViewLayout = ViewLayout(rawValue: AppDefaults.store.string(forKey: ViewKey.layout) ?? "") ?? .split {
        didSet { if layout != oldValue { AppDefaults.store.set(layout.rawValue, forKey: ViewKey.layout) } }
    }
    /// The floating camera and display controls of the 3D view.
    public var showSceneControls: Bool = AppDefaults.store.object(forKey: ViewKey.sceneControls) as? Bool ?? true {
        didSet { if showSceneControls != oldValue { AppDefaults.store.set(showSceneControls, forKey: ViewKey.sceneControls) } }
    }
    public var showCeilings: Bool = AppDefaults.migrated(ViewKey.showCeilings, legacy: "scene.showCeilings", fallback: false) {
        didSet { if showCeilings != oldValue { AppDefaults.store.set(showCeilings, forKey: ViewKey.showCeilings) } }
    }
    /// Furniture with lamps is drawn; off hides the pieces only, their light stays on.
    public var showLamps: Bool = AppDefaults.store.object(forKey: ViewKey.showLamps) as? Bool ?? true {
        didSet { if showLamps != oldValue { AppDefaults.store.set(showLamps, forKey: ViewKey.showLamps) } }
    }
    public var onlyActiveLevel: Bool = AppDefaults.migrated(ViewKey.onlyActiveLevel, legacy: "scene.onlyActiveLevel", fallback: false) {
        didSet { if onlyActiveLevel != oldValue { AppDefaults.store.set(onlyActiveLevel, forKey: ViewKey.onlyActiveLevel) } }
    }
    public var wallOpacity: Double = AppDefaults.migrated(ViewKey.wallOpacity, legacy: "scene.wallOpacity", fallback: 1.0) {
        didSet { if wallOpacity != oldValue { AppDefaults.store.set(wallOpacity, forKey: ViewKey.wallOpacity) } }
    }
    /// Selected tab of the sidebar.
    var sidebarTab: SidebarTab = SidebarTab(rawValue: AppDefaults.store.string(forKey: ViewKey.sidebarTab) ?? "") ?? .objects {
        didSet { if sidebarTab != oldValue { AppDefaults.store.set(sidebarTab.rawValue, forKey: ViewKey.sidebarTab) } }
    }

    public init() {}
}
