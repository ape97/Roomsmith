import Foundation

// MARK: - App bridge

/// What `walk.*` reports about the walk mode of the live 3D view.
public struct AgentWalkState: Sendable, Equatable {
    public var settings: WalkSettings
    /// True while the 3D camera is in first person.
    public var active: Bool
    /// Current eye height above the floor in mm (settings, crouching, head bob).
    public var eyeHeightMm: Double
    public var speedMps: Double
    /// Vertical field of view in use, degrees.
    public var fovDeg: Double
    /// Screen height read from the display; nil when the display does not report one.
    public var autoScreenHeightMm: Double?
    /// Doors currently open in the view (view state, not in the document).
    public var openDoors: [UUID]
    /// Windows and balcony doors currently turned or tilted open in the view, with their mode.
    public var openOpenings: [OpenOpening]
    public struct OpenOpening: Sendable, Equatable {
        public var id: UUID
        public var mode: OpeningMode
        public init(id: UUID, mode: OpeningMode) { self.id = id; self.mode = mode }
    }
    public init(settings: WalkSettings, active: Bool, eyeHeightMm: Double, speedMps: Double, fovDeg: Double,
                autoScreenHeightMm: Double?, openDoors: [UUID], openOpenings: [OpenOpening] = []) {
        self.settings = settings; self.active = active; self.eyeHeightMm = eyeHeightMm; self.speedMps = speedMps
        self.fovDeg = fovDeg; self.autoScreenHeightMm = autoScreenHeightMm; self.openDoors = openDoors
        self.openOpenings = openOpenings
    }
}

/// Walk mode of the running app. Implemented by the app; the tools live in the core and are tested against a fake.
@MainActor
public protocol AgentWalkBridge: AnyObject {
    func walkState() -> AgentWalkState
    /// Stores validated settings and applies them to the live view.
    func applyWalkSettings(_ settings: WalkSettings) -> AgentWalkState
    /// Opens (`open` true), closes (false) or toggles (nil) a door in the view. Returns whether it is open now.
    /// Throws UNSUPPORTED when there is no live 3D view.
    func setDoor(_ openingId: UUID, open: Bool?) throws -> Bool
    /// Like `setDoor` for any movable opening in `mode` (turn or tilt). Returns the mode it is heading to (`.closed` when shut).
    func setOpening(_ openingId: UUID, open: Bool?, mode: OpeningMode) throws -> OpeningMode
}

extension AgentWalkBridge {
    /// Default for bridges that only know doors: turning forwards to `setDoor`, tilting is refused.
    public func setOpening(_ openingId: UUID, open: Bool?, mode: OpeningMode) throws -> OpeningMode {
        guard mode == .turn else { throw AgentError(code: "INVALID_ARGUMENT", message: "This view cannot tilt openings.") }
        return try setDoor(openingId, open: open) ? .turn : .closed
    }
}

extension AgentAppContext {
    public var walkBridge: AgentWalkBridge? { nil }
}

extension ToolEnv {
    func requireWalkBridge(_ what: String) throws -> AgentWalkBridge {
        guard let b = context.walkBridge else {
            throw AgentError.unsupportedFeature("\(what) needs the Roomsmith window; this app context has none.")
        }
        return b
    }
}

// MARK: - walk.*

@MainActor
enum WalkTools {
    static func json(_ st: AgentWalkState) -> JSONValue {
        var o: [String: JSONValue] = [:]
        if let data = try? JSONEncoder().encode(st.settings), let v = try? JSONDecoder().decode(JSONValue.self, from: data),
           case .object(let d) = v { o = d }
        o["eyeHeightMm"] = .number(st.eyeHeightMm)
        o["baseEyeHeightMm"] = .number(st.settings.eyeHeightMm)
        o["active"] = .bool(st.active)
        o["speedMps"] = .number(st.speedMps)
        o["fovDeg"] = .number(st.fovDeg)
        o["autoScreenHeightMm"] = st.autoScreenHeightMm.map { .number($0) } ?? .null
        o["openDoors"] = .array(st.openDoors.map { .string($0.uuidString) })
        o["openOpenings"] = .array(st.openOpenings.map { .object(["id": .string($0.id.uuidString), "mode": .string($0.mode.rawValue)]) })
        return .object(o)
    }

    static let clearable: Set<String> = ["eyeHeightOverrideMm", "screenHeightMm"]
    static let settingKeys = ["bodyHeightMm", "eyeHeightOverrideMm", "fovMode", "screenHeightMm", "viewingDistanceMm", "speedSlowMps",
                              "speedNormalMps", "speedFastMps", "accelerationMps2", "crouchEyeFactor", "headBob", "collision",
                              "mouseSensitivity", "invertY", "controllerDeadzone", "controllerSensitivity", "bodyRadiusMm", "showScale"]

    static func specs() -> [ToolSpec] {
        [
            .action("walk.get",
                    "Walk mode (first-person camera) settings and state: body and eye height, field of view mode, speeds, acceleration, head bob, collision, controller, plus the live values (current eye height, speed, FOV in use, open doors). View state of the user, not in the project file; no revision.",
                    readOnly: true) { env, _ in
                json(try env.requireWalkBridge("walk.get").walkState())
            },
            .action("walk.set",
                    "Changes walk mode settings (partial update, validated as a whole). Not an undo step and no revision. Needs write access. Lengths in mm, speeds in m/s. Returns the state like walk.get. Send eyeHeightOverrideMm or screenHeightMm as null to go back to automatic.",
                    ["bodyHeightMm": S.num("Body height (1000...2300); the eye is at 93.6% unless overridden."),
                     "eyeHeightOverrideMm": S.num("Eye height above the floor (600...2200); null = from body height."),
                     "fovMode": S.obj("Field of view: {mode: 'standard', fovDeg: 10...120} or {mode: 'calibrated'} (view subtends the same angle as the physical screen at viewingDistanceMm).",
                                      ["mode": S.str("Mode.", values: ["standard", "calibrated"]), "fovDeg": S.num("Vertical FOV for standard.")],
                                      required: ["mode"]),
                     "screenHeightMm": S.num("Physical picture height of the screen (50...3000); null = read from the display."),
                     "viewingDistanceMm": S.num("Eye-to-screen distance for calibrated FOV (200...3000)."),
                     "speedSlowMps": S.num("Slow step (Alt), 0.1...10."), "speedNormalMps": S.num("Normal speed, 0.1...10."),
                     "speedFastMps": S.num("Fast step (Shift), 0.1...15."),
                     "accelerationMps2": S.num("Acceleration and braking, 0.2...30."),
                     "crouchEyeFactor": S.num("Eye height share while crouching (0.3...1)."),
                     "headBob": S.bool("Walking bobs the view."), "collision": S.bool("Walls, closed doors, windows and furniture block."),
                     "mouseSensitivity": S.num("Degrees per mouse point (0.02...1)."), "invertY": S.bool("Invert vertical look."),
                     "controllerDeadzone": S.num("Stick deadzone (0...0.9)."),
                     "controllerSensitivity": S.num("Stick look speed in degrees per second (10...400)."),
                     "bodyRadiusMm": S.num("Collision radius (50...600)."), "showScale": S.bool("Show the 1 m scale stick.")]) { env, a in
                guard settingKeys.contains(where: a.present) else {
                    throw ToolError.invalid(nil, "Give at least one setting: \(settingKeys.joined(separator: ", "))")
                }
                let bridge = try env.requireWalkBridge("walk.set")
                try env.requireWriteAccess("walk.set changes what the user sees")
                var merged: [String: JSONValue] = [:]
                let current = try JSONEncoder().encode(bridge.walkState().settings)
                if case .object(let d) = try JSONDecoder().decode(JSONValue.self, from: current) { merged = d }
                for k in settingKeys where a.present(k) {
                    if a.isNull(k) {
                        guard clearable.contains(k) else { throw ToolError.invalid(k, "null is only allowed for eyeHeightOverrideMm and screenHeightMm") }
                        merged[k] = nil
                    } else { merged[k] = a.raw(k) }
                }
                let data = try JSONEncoder().encode(JSONValue.object(merged))
                let decoded: WalkSettings
                do { decoded = try JSONDecoder().decode(WalkSettings.self, from: data) }
                catch { throw ToolError.invalid(nil, "Walk settings have a wrong type or shape: \(error.localizedDescription)") }
                if decoded != decoded.sanitized() {
                    throw ViewTools.rangeError(settingKeys.first(where: a.present) ?? "settings",
                                               "a value is outside its range (see the tool description); nothing was changed")
                }
                return json(bridge.applyWalkSettings(decoded))
            },
            .action("walk.toggle_door",
                    "Opens or closes a door, window or balcony door in the 3D view (animated; view state only, the project is untouched). Toggles unless `open` is given. `mode` turn (default) swings the sash or leaf open; tilt (windows and balcony doors with a handle only) tips it in at the top. Open doors can be walked through; closed ones block. Windows that are fixed, plain openings and windows too small to open are refused. Needs write access and the live 3D view.",
                    ["openingId": S.uuid("Door, window or balcony door."), "open": S.bool("true opens, false closes; omit to toggle."),
                     "mode": S.str("turn (default) or tilt.", values: ["turn", "tilt"])],
                    required: ["openingId"]) { env, a in
                let id = try a.requireUUID("openingId")
                guard let o = env.project.openings.first(where: { $0.id == id }) else { throw ToolError.notFound("Opening", id) }
                let mode: OpeningMode = try a.string("mode").map {
                    guard let m = OpeningMode(rawValue: $0), m != .closed else { throw ToolError.invalid("mode", "Must be turn or tilt") }
                    return m
                } ?? .turn
                guard o.kind != .opening else { throw ToolError.invalid("openingId", "A plain opening has nothing to open") }
                if o.kind == .door {
                    guard mode == .turn else { throw ToolError.invalid("mode", "Doors only turn") }
                } else {
                    guard let wall = env.project.wall(o.wallId), Meshes.windowMotion(o, wall: wall)?.movable == true else {
                        throw ToolError.invalid("openingId", "This window is fixed or too small to open")
                    }
                }
                let bridge = try env.requireWalkBridge("walk.toggle_door")
                try env.requireWriteAccess("walk.toggle_door changes what the user sees")
                let now = try bridge.setOpening(id, open: try a.bool("open"), mode: mode)
                return .object(["openingId": .string(id.uuidString), "open": .bool(now != .closed), "mode": .string(now.rawValue)])
            },
            .action("walk.measure",
                    "Measures from the walker's point of view, in mm. kind: eye_above_surface (ids: [furniture]; eye height minus the top of the piece, e.g. a worktop), window_sill (ids: [window]; parapet height), door_clear (ids: [door or opening]; clear width and height inside the frame), gap (ids: [furniture, furniture]; shortest distance between the two footprints, e.g. sofa to coffee table). Read only.",
                    ["kind": S.str("What to measure.", values: WalkMeasure.kinds),
                     "ids": S.uuids("Ids the kind needs (one, or two for gap).")],
                    required: ["kind", "ids"], readOnly: true) { env, a in
                guard let kind = try a.string("kind"), WalkMeasure.kinds.contains(kind) else {
                    throw ToolError.invalid("kind", "Must be one of \(WalkMeasure.kinds.joined(separator: ", "))")
                }
                let ids = try a.requireUUIDList("ids")
                let want = kind == "gap" ? 2 : 1
                guard ids.count == want else { throw ToolError.invalid("ids", "\(kind) needs exactly \(want) id(s)") }
                let p = env.project
                func out(_ m: WalkMeasurement, extra: [String: JSONValue] = [:]) -> JSONValue {
                    var o: [String: JSONValue] = ["kind": .string(m.kind), "valueMm": .number(m.valueMm), "detail": .string(m.detail)]
                    for (k, v) in extra { o[k] = v }
                    return .object(o)
                }
                do {
                    switch kind {
                    case "eye_above_surface":
                        let eye = env.context.walkBridge?.walkState().settings.eyeHeightMm ?? WalkSettings().eyeHeightMm
                        return out(try WalkMeasure.eyeAboveSurface(eyeHeightMm: eye, project: p, furnitureId: ids[0]))
                    case "window_sill":
                        return out(try WalkMeasure.windowSill(project: p, openingId: ids[0]))
                    case "door_clear":
                        let r = try WalkMeasure.doorClear(project: p, openingId: ids[0])
                        return out(r.width, extra: ["clearWidthMm": .number(r.width.valueMm), "clearHeightMm": .number(r.height)])
                    default:
                        return out(try WalkMeasure.gap(project: p, a: ids[0], b: ids[1]))
                    }
                } catch let e as WalkMeasureError {
                    switch e {
                    case .notFound(let m): throw ToolError.notFoundText(m)
                    case .invalid(let m): throw ToolError.invalid("ids", m)
                    }
                }
            },
        ]
    }
}
