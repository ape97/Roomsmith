import AppKit
import Foundation

/// Where view state (panel visibility, layout, divider) is stored. Normal runs use the standard defaults. Under
/// `ROOMSMITH_TEST_MODE` a separate suite is used and cleared at launch, so checks never read or change the user's
/// real settings.
enum AppDefaults {
    static let isTestMode = ProcessInfo.processInfo.environment["ROOMSMITH_TEST_MODE"] == "1"
    /// Whether the last session and the recent list are read and written. A check run (`ROOMSMITH_TEST_MODE`) never
    /// touches them unless `ROOMSMITH_RESTORE_SESSION=1` asks for it, so it cannot disturb the user's own session.
    static let persistsSession = !isTestMode || ProcessInfo.processInfo.environment["ROOMSMITH_RESTORE_SESSION"] == "1"
    private static let testSuite = "app.roomsmith.testmode"

    nonisolated(unsafe) static let store: UserDefaults = {
        guard isTestMode, let suite = UserDefaults(suiteName: testSuite) else { return .standard }
        suite.removePersistentDomain(forName: testSuite)
        // `ROOMSMITH_HIDE` (see `TestHooks`) is seeded here as well, so these panels are hidden from the first frame:
        // toggled later, a hidden app (`open -j`) never finishes the collapse and keeps an empty column.
        let keys = ["sidebar": ViewKey.showSidebar, "inspector": ViewKey.showInspector, "statusbar": ViewKey.showStatusBar]
        for item in (ProcessInfo.processInfo.environment["ROOMSMITH_HIDE"] ?? "").split(separator: ",") {
            if let key = keys[item.trimmingCharacters(in: .whitespaces)] { suite.set(false, forKey: key) }
        }
        // `ROOMSMITH_SIDEBAR_TAB=levels|objects|catalog` opens the sidebar on that tab (screenshots).
        if let tab = ProcessInfo.processInfo.environment["ROOMSMITH_SIDEBAR_TAB"] { suite.set(tab, forKey: ViewKey.sidebarTab) }
        return suite
    }()

    /// A stored value, else the one an older version kept in the standard defaults (copied over once), else `fallback`.
    /// Test mode never reads the user's real settings.
    static func migrated<T>(_ key: String, legacy: String, fallback: T) -> T {
        if let v = store.object(forKey: key) as? T { return v }
        guard !isTestMode, let v = UserDefaults.standard.object(forKey: legacy) as? T else { return fallback }
        store.set(v, forKey: key)
        return v
    }

    /// Set once the application is quitting, so closing windows during quit is not mistaken for the user closing them.
    @MainActor static var isTerminating = false
}

/// `@AppStorage` keys for panel visibility (view state only, never part of the document).
enum ViewKey {
    static let showSidebar = "view.showSidebar"
    static let showInspector = "view.showInspector"
    static let showStatusBar = "view.showStatusBar"
    static let layout = "view.layout"
    static let sceneControls = "view.sceneControls"
    static let showCeilings = "view.showCeilings"
    static let showLamps = "view.showLamps"
    static let onlyActiveLevel = "view.onlyActiveLevel"
    static let wallOpacity = "view.wallOpacity"
    static let sidebarTab = "view.sidebarTab"
}
