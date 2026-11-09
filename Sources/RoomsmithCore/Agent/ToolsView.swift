import Foundation

// MARK: - App bridge

/// Plan viewport as reported by or sent to the 2D editor. Millimetres, X east, Y north.
public struct AgentPlanViewport: Sendable, Equatable {
    public var centerX: Int64
    public var centerY: Int64
    /// Millimetres per view point (zoom). Smaller means closer.
    public var mmPerPoint: Double
    public init(centerX: Int64, centerY: Int64, mmPerPoint: Double) {
        self.centerX = centerX; self.centerY = centerY; self.mmPerPoint = mmPerPoint
    }
    /// Zoom range of the plan editor (0.002...4 points per millimetre).
    public static let mmPerPointRange: ClosedRange<Double> = 0.25...500
}

/// Which part of the plan `view.set` frames.
public enum AgentPlanFit: String, CaseIterable, Sendable {
    case all, selection
}

public enum AgentLayoutMode: String, CaseIterable, Sendable { case split, plan, scene }
public enum AgentArrangement: String, CaseIterable, Sendable { case sideBySide, stacked }
public enum AgentSidebarTab: String, CaseIterable, Sendable { case levels, objects, catalog }

/// Camera presets of the 3D view (the buttons of the view mode bar and Reset View / Frame Selection).
public enum AgentCameraPreset: String, CaseIterable, Sendable { case aerial, reset, top, frame }

/// Everything `view.get` reports besides the active level.
public struct AgentViewState: Sendable, Equatable {
    public var layout: AgentLayoutMode
    public var arrangement: AgentArrangement
    /// Divider position (share of the first editor) of the current arrangement.
    public var splitFraction: Double
    public var sidebarTab: AgentSidebarTab
    public var sidebar: Bool
    public var inspector: Bool
    public var statusBar: Bool
    public var sceneControls: Bool
    public var showCeilings: Bool
    /// 3D view shows furniture whose design has lamps. Their light stays on either way.
    public var showLamps: Bool
    public var onlyActiveLevel: Bool
    public var wallOpacity: Double
    /// The 3D view is in its own window (View > Open 3D in Separate Window). The main window then shows the plan only.
    public var detach3D: Bool
    /// Last viewport the plan editor reported; nil while no plan editor is shown.
    public var planViewport: AgentPlanViewport?

    public init(layout: AgentLayoutMode, arrangement: AgentArrangement, splitFraction: Double, sidebarTab: AgentSidebarTab,
                sidebar: Bool, inspector: Bool, statusBar: Bool, sceneControls: Bool, showCeilings: Bool,
                showLamps: Bool = true, onlyActiveLevel: Bool, wallOpacity: Double, detach3D: Bool = false, planViewport: AgentPlanViewport?) {
        self.layout = layout; self.arrangement = arrangement; self.splitFraction = splitFraction; self.sidebarTab = sidebarTab
        self.sidebar = sidebar; self.inspector = inspector; self.statusBar = statusBar; self.sceneControls = sceneControls
        self.showCeilings = showCeilings; self.showLamps = showLamps; self.onlyActiveLevel = onlyActiveLevel; self.wallOpacity = wallOpacity
        self.detach3D = detach3D
        self.planViewport = planViewport
    }
}

/// A validated partial change of the view state. Every field is optional; nil leaves it alone.
public struct AgentViewChange: Sendable, Equatable {
    public var layout: AgentLayoutMode?
    public var arrangement: AgentArrangement?
    public var splitFraction: Double?
    public var sidebarTab: AgentSidebarTab?
    public var sidebar: Bool?
    public var inspector: Bool?
    public var statusBar: Bool?
    public var sceneControls: Bool?
    public var showCeilings: Bool?
    public var showLamps: Bool?
    public var onlyActiveLevel: Bool?
    public var wallOpacity: Double?
    public var detach3D: Bool?
    public var planViewport: AgentPlanViewport?
    public var planFit: AgentPlanFit?
    public init() {}
}

/// What the view and render tools need from the running app (window state, live 3D view, offscreen renderer).
/// Implemented by the app; the tools themselves live in the core and are tested against a fake.
@MainActor
public protocol AgentViewBridge: AnyObject {
    func viewState() -> AgentViewState
    /// Applies an already validated change and returns the new state. Plan viewport changes are applied by the plan
    /// editor on its next redraw; `planViewport` of the answer then shows the requested values.
    func applyView(_ change: AgentViewChange) -> AgentViewState
    /// Moves the 3D camera to a preset and stores it in the document (no undo step). `ids` select what `frame` frames.
    func cameraPreset(_ preset: AgentCameraPreset, ids: [UUID]) throws -> CameraState
    /// PNG of the 3D scene. `camera` nil means the camera the user sees (live view) or else the document camera.
    /// A `preset` (never together with `camera`) is fitted to the picture's own size, starting from that camera: `aerial`
    /// and `top` keep its heading; `frame` keeps it too, except in first person, where it turns towards the content;
    /// `reset` uses the reset heading of the camera mode (orbit 30°, top and first person 0°), but while the camera is
    /// at the aerial tilt it re-fits the aerial view and keeps the heading. It changes neither the live view nor the document; `ids` select what `frame` frames (`top` always fits the whole content).
    func renderScene(width: Int, height: Int, dark: Bool, camera: CameraState?, preset: AgentCameraPreset?, ids: [UUID]) async throws -> Data
}

extension ToolEnv {
    /// The app bridge or UNSUPPORTED.
    func requireBridge(_ what: String) throws -> AgentViewBridge {
        guard let b = context.viewBridge else {
            throw AgentError.unsupportedFeature("\(what) needs the Roomsmith window; this app context has none.")
        }
        return b
    }

    func requireWriteAccess(_ why: String) throws {
        guard store.agentWriteEnabled else {
            throw AgentError(code: AgentError.writeLocked, message: "Agent write access is switched off in Roomsmith (Agents panel); \(why).")
        }
    }
}

// MARK: - view.*

enum ViewTools {
    static func json(_ s: AgentViewState, activeLevelId: UUID) -> JSONValue {
        var o: [String: JSONValue] = [
            "layout": .string(s.layout.rawValue), "arrangement": .string(s.arrangement.rawValue),
            "splitFraction": .number(s.splitFraction), "sidebarTab": .string(s.sidebarTab.rawValue),
            "sidebar": .bool(s.sidebar), "inspector": .bool(s.inspector), "statusBar": .bool(s.statusBar),
            "sceneControls": .bool(s.sceneControls), "showCeilings": .bool(s.showCeilings),
            "showLamps": .bool(s.showLamps),
            "onlyActiveLevel": .bool(s.onlyActiveLevel), "wallOpacity": .number(s.wallOpacity), "detach3D": .bool(s.detach3D),
            "activeLevelId": J.id(activeLevelId),
        ]
        o["planViewport"] = s.planViewport.map {
            .object(["center": .object(["x": .int($0.centerX), "y": .int($0.centerY)]), "mmPerPoint": .number($0.mmPerPoint)])
        } ?? .null
        return .object(o)
    }

    static let setKeys = ["layout", "arrangement", "splitFraction", "activeLevelId", "planViewport", "planFit", "sidebarTab",
                          "sidebar", "inspector", "statusBar", "sceneControls", "wallOpacity", "onlyActiveLevel", "showCeilings", "showLamps", "detach3D"]

    @MainActor
    static func specs() -> [ToolSpec] {
        [
            .action("view.get",
                    "Window and view state the user sees: layout (split/plan/scene), arrangement, divider, sidebar tab and panel visibility, 3D display options, active level and the plan viewport (center in mm, mmPerPoint; null while the plan is not shown). Not part of the project file; no revision.",
                    readOnly: true) { env, _ in
                let bridge = try env.requireBridge("view.get")
                return json(bridge.viewState(), activeLevelId: env.context.activeLevelId)
            },
            .action("view.set",
                    "Changes the window and view state (partial update, validated as a whole before anything changes). Not an undo step and no revision; the project file is untouched. Needs write access. The plan viewport is applied by the plan editor on its next redraw and only while it is shown; `planViewport` and `planFit` exclude each other. Returns the new state like view.get.",
                    ["layout": S.str("Which editors are shown.", values: AgentLayoutMode.allCases.map(\.rawValue)),
                     "arrangement": S.str("Plan and 3D side by side or stacked.", values: AgentArrangement.allCases.map(\.rawValue)),
                     "splitFraction": S.num("Divider position, share of the first editor (0.1...0.9) in the current arrangement."),
                     "activeLevelId": S.uuid("Level to show (must exist)."),
                     "planViewport": S.obj("Plan view: model point in the middle and zoom.",
                                           ["center": S.p2("Centre of the view."),
                                            "mmPerPoint": S.num("Millimetres per view point (0.25...500); smaller is closer.")],
                                           required: ["center", "mmPerPoint"]),
                     "planFit": S.str("Fit the whole level or the selection into the plan view.", values: AgentPlanFit.allCases.map(\.rawValue)),
                     "sidebarTab": S.str("Sidebar page.", values: AgentSidebarTab.allCases.map(\.rawValue)),
                     "sidebar": S.bool("Show the sidebar."), "inspector": S.bool("Show the inspector."),
                     "statusBar": S.bool("Show the status bar."), "sceneControls": S.bool("Show the floating 3D controls."),
                     "wallOpacity": S.num("Wall opacity in the 3D view (0...1)."),
                     "onlyActiveLevel": S.bool("3D view shows only the active level."),
                     "showCeilings": S.bool("3D view shows ceilings."),
                     "showLamps": S.bool("3D view shows lamp furniture: designs with lights, category Lighting, or lamp/light in name or tags (default true). false hides only the pieces; their light stays on and unchanged. Hidden pieces cannot be picked in 3D, do not block in walk mode and are no obstacle when dragging furniture in 3D."),
                     "detach3D": S.bool("true opens the 3D view in its own window (the main window then shows the plan only); false docks it back.")]) { env, a in
                guard setKeys.contains(where: a.has) else {
                    throw ToolError.invalid(nil, "Give at least one view key: \(setKeys.joined(separator: ", "))")
                }
                let bridge = try env.requireBridge("view.set")
                try env.requireWriteAccess("view.set changes what the user sees")
                var change = AgentViewChange()
                change.layout = try a.enumValue("layout", AgentLayoutMode.self)
                change.arrangement = try a.enumValue("arrangement", AgentArrangement.self)
                if let f = try a.double("splitFraction") {
                    guard (0.1...0.9).contains(f) else { throw rangeError("splitFraction", "must be between 0.1 and 0.9") }
                    change.splitFraction = f
                }
                var level: UUID?
                if let id = try a.uuid("activeLevelId") {
                    guard env.project.level(id) != nil else { throw ToolError.notFound("Level", id) }
                    level = id
                }
                if let v = a.raw("planViewport") {
                    guard case .object = v else { throw ToolError.invalid("planViewport", "must be {center: {x, y}, mmPerPoint}") }
                    let center = try Args.parseP2(v["center"] ?? .null, "planViewport.center")
                    guard let m = v["mmPerPoint"]?.doubleValue, m.isFinite else {
                        throw ToolError.invalid("planViewport.mmPerPoint", "must be a finite number")
                    }
                    guard AgentPlanViewport.mmPerPointRange.contains(m) else {
                        throw rangeError("planViewport.mmPerPoint", "must be between 0.25 and 500")
                    }
                    change.planViewport = AgentPlanViewport(centerX: center.x, centerY: center.y, mmPerPoint: m)
                }
                change.planFit = try a.enumValue("planFit", AgentPlanFit.self)
                if change.planViewport != nil && change.planFit != nil {
                    throw ToolError.invalid("planFit", "cannot be combined with planViewport")
                }
                change.sidebarTab = try a.enumValue("sidebarTab", AgentSidebarTab.self)
                change.sidebar = try a.bool("sidebar")
                change.inspector = try a.bool("inspector")
                change.statusBar = try a.bool("statusBar")
                change.sceneControls = try a.bool("sceneControls")
                if let o = try a.double("wallOpacity") {
                    guard (0.0...1.0).contains(o) else { throw rangeError("wallOpacity", "must be between 0 and 1") }
                    change.wallOpacity = o
                }
                change.onlyActiveLevel = try a.bool("onlyActiveLevel")
                change.showCeilings = try a.bool("showCeilings")
                change.showLamps = try a.bool("showLamps")
                change.detach3D = try a.bool("detach3D")
                if change.detach3D == true, let l = change.layout, l != .plan {
                    throw ToolError.invalid("detach3D", "a detached 3D window needs layout plan in the main window; cannot combine with layout \(l.rawValue)")
                }
                if let level { env.context.activeLevelId = level }
                let state = bridge.applyView(change)
                return json(state, activeLevelId: env.context.activeLevelId)
            },
        ]
    }

    static func rangeError(_ field: String, _ message: String) -> AgentError {
        AgentError(code: AgentError.outOfRange, message: "Argument '\(field)': \(message)",
                   details: .object(["field": .string(field)]))
    }
}
