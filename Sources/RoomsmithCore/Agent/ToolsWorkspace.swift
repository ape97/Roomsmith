import Foundation

// MARK: - workspace.* and scene.transfer_objects

/// One open project (tab) of the workspace as the agent sees it.
public struct AgentWorkspaceTab: Sendable, Equatable {
    /// Id of the tab; stable while the tab is open. Tools accept this or the project's own id.
    public var id: UUID
    public var projectId: UUID
    public var name: String
    public var path: String?
    public var dirty: Bool
    /// The project that agent requests currently act on.
    public var active: Bool
    /// Shown in the compare split.
    public var inCompare: Bool
    public init(id: UUID, projectId: UUID, name: String, path: String?, dirty: Bool, active: Bool, inCompare: Bool) {
        self.id = id; self.projectId = projectId; self.name = name; self.path = path
        self.dirty = dirty; self.active = active; self.inCompare = inCompare
    }
}

/// What a transfer between two projects did.
public struct AgentTransferOutcome: Sendable, Equatable {
    public var targetName: String
    public var newIds: [UUID]
    public var moved: Bool
    /// Move only: the copy was made but the originals could not be deleted.
    public var deleteError: String?
    public init(targetName: String, newIds: [UUID], moved: Bool, deleteError: String?) {
        self.targetName = targetName; self.newIds = newIds; self.moved = moved; self.deleteError = deleteError
    }
}

/// The multi-project workspace of the app: tabs, compare split and transfers. Implemented by the app; nil in contexts
/// without a window, where the workspace tools answer UNSUPPORTED.
@MainActor
public protocol AgentWorkspaceBridge: AnyObject {
    func workspaceTabs() -> [AgentWorkspaceTab]
    /// Makes the tab the target of agent requests and of the editor.
    func workspaceActivate(_ id: UUID) throws
    /// Opens the package at `url` in a tab (an empty unchanged tab is reused; an already open file is activated).
    /// nil opens a new untitled project. Returns the tab id. Shows no dialog.
    func workspaceOpen(_ url: URL?) throws -> UUID
    /// Closes a tab. Unsaved changes throw CONFLICT unless `discard`.
    func workspaceClose(_ id: UUID, discard: Bool) throws
    /// Copy of the project in a tab.
    func workspaceProject(_ id: UUID) -> Project?
    /// Shows two projects side by side or stacked in the compare split.
    func workspaceShowCompare(left: UUID, right: UUID, arrangement: AgentArrangement?) throws
    /// Copies or moves furniture of `source` (the document the tool ran on) into the tab `target`.
    func workspaceTransfer(ids: [UUID], from source: DocumentStore, to target: UUID, move: Bool, clientId: String) throws -> AgentTransferOutcome
}

extension AgentAppContext {
    public var workspaceBridge: AgentWorkspaceBridge? { nil }
}

/// Figures shown side by side in the compare sheet.
public struct ProjectFigures: Sendable, Equatable {
    public struct RoomFigure: Sendable, Equatable {
        public var name: String
        public var level: String
        public var twiceAreaMM2: Int64
        public var areaM2: String { ReportFormat.squareMetres(twiceAreaMM2: twiceAreaMM2) }
    }
    public var name: String
    public var twiceTotalAreaMM2: Int64
    public var rooms: [RoomFigure]
    public var furnitureCount: Int
    public var wallLengthMM: Double
    public var totalAreaM2: String { ReportFormat.squareMetres(twiceAreaMM2: twiceTotalAreaMM2) }

    public init(_ p: Project) {
        name = p.name
        let report = RoomReport.make(p)
        var out: [RoomFigure] = []
        for l in report.levels { for r in l.rooms { out.append(RoomFigure(name: r.name, level: l.name, twiceAreaMM2: r.twiceFloorAreaMM2)) } }
        rooms = out
        twiceTotalAreaMM2 = report.twiceFloorAreaMM2
        furnitureCount = p.instances.count
        wallLengthMM = p.walls.reduce(0) { sum, w in
            let dx = Double(w.end.x - w.start.x), dy = Double(w.end.y - w.start.y)
            return sum + (dx * dx + dy * dy).squareRoot()
        }
    }

    public var json: JSONValue {
        .object([
            "name": .string(name),
            "totalAreaM2": .string(totalAreaM2),
            "rooms": .array(rooms.map { .object(["name": .string($0.name), "level": .string($0.level), "areaM2": .string($0.areaM2)]) }),
            "furnitureCount": .int(Int64(furnitureCount)),
            "wallLengthMm": J.mm(wallLengthMM),
        ])
    }
}

@MainActor
enum WorkspaceTools {
    static func bridge(_ env: ToolEnv) throws -> AgentWorkspaceBridge {
        guard let b = env.context.workspaceBridge else {
            throw AgentError.unsupportedFeature("The workspace tools need the Roomsmith window; this app context has none.")
        }
        return b
    }

    static func tabJSON(_ t: AgentWorkspaceTab) -> JSONValue {
        .object(["id": J.id(t.id), "projectId": J.id(t.projectId), "name": .string(t.name),
                 "path": t.path.map { .string($0) } ?? .null, "dirty": .bool(t.dirty), "active": .bool(t.active),
                 "inCompare": .bool(t.inCompare)])
    }

    static func tabsJSON(_ b: AgentWorkspaceBridge) -> JSONValue {
        .object(["projects": .array(b.workspaceTabs().map(tabJSON))])
    }

    /// A tab by its tab id or its project id.
    static func resolve(_ id: UUID, in b: AgentWorkspaceBridge, field: String) throws -> AgentWorkspaceTab {
        let tabs = b.workspaceTabs()
        guard let t = tabs.first(where: { $0.id == id }) ?? tabs.first(where: { $0.projectId == id }) else {
            throw ToolError.notFound("Open project", id)
        }
        return t
    }

    @MainActor
    static func specs() -> [ToolSpec] {
        [
            .action("workspace.list",
                    "Lists the projects open in the Roomsmith window (tabs): tab id, project id, name, file path, unsaved changes, which one is active (all other tools act on it) and which are shown in the compare split.",
                    readOnly: true) { env, _ in tabsJSON(try bridge(env)) },
            .action("workspace.activate",
                    "Makes an open project the active one: from the next call on, all tools act on it, and the editor shows its tab. Calls that are already waiting keep their project. app.subscribe_changes stays bound to the project that was active when it was called.",
                    ["projectId": S.uuid("Tab id or project id from workspace.list.")], required: ["projectId"]) { env, a in
                let b = try bridge(env)
                let t = try resolve(try a.requireUUID("projectId"), in: b, field: "projectId")
                try b.workspaceActivate(t.id)
                return tabsJSON(b)
            },
            .action("workspace.open",
                    "Opens a `.roomsmith` package in a new tab (an empty unchanged tab is reused; a file that is already open is just activated) and makes it active. Without `path` a new untitled project opens. Needs write access. No dialog is shown.",
                    ["path": S.str("Absolute path of an existing .roomsmith package folder. Omit for a new untitled project.")]) { env, a in
                try env.requireWriteAccess("workspace.open adds a project")
                let b = try bridge(env)
                let url = try a.string("path").map { try ProjectTools.existingPackage($0) }
                let id = try b.workspaceOpen(url)
                var json = tabsJSON(b)
                if case .object(var o) = json { o["opened"] = J.id(id); json = .object(o) }
                return json
            },
            .action("workspace.close",
                    "Closes an open project (tab). Fails with CONFLICT while it has unsaved changes unless `discard` is true. Closing the last tab leaves a new untitled project. Needs write access.",
                    ["projectId": S.uuid("Tab id or project id from workspace.list."),
                     "discard": S.bool("Drop unsaved changes (default false).")], required: ["projectId"]) { env, a in
                try env.requireWriteAccess("workspace.close closes a project")
                let b = try bridge(env)
                let t = try resolve(try a.requireUUID("projectId"), in: b, field: "projectId")
                try b.workspaceClose(t.id, discard: try a.bool("discard") ?? false)
                return tabsJSON(b)
            },
            .action("workspace.compare",
                    "Compares two open projects: total floor area, rooms with area, furniture count and wall length of each, plus the differences. With `show` the compare split opens in the window (needs write access; without `show` it only reads).",
                    ["projectA": S.uuid("Tab id or project id; default the active project."),
                     "projectB": S.uuid("Tab id or project id; default the only other open project."),
                     "show": S.bool("Also show both in the compare split (default false)."),
                     "arrangement": S.str("Split direction when shown: sideBySide or stacked.", values: AgentArrangement.allCases.map(\.rawValue))],
                    readOnly: true) { env, a in
                // The comparison only reads; `show` changes the window layout, so it needs write access like the other view changes.
                let show = try a.bool("show") ?? false
                if show { try env.requireWriteAccess("workspace.compare with show changes the window layout") }
                let b = try bridge(env)
                let tabs = b.workspaceTabs()
                let first: AgentWorkspaceTab
                if let id = try a.uuid("projectA") { first = try resolve(id, in: b, field: "projectA") }
                else if let active = tabs.first(where: \.active) { first = active }
                else { throw ToolError.invalid("projectA", "no project is active") }
                let second: AgentWorkspaceTab
                if let id = try a.uuid("projectB") { second = try resolve(id, in: b, field: "projectB") }
                else {
                    let others = tabs.filter { $0.id != first.id }
                    guard others.count == 1, let only = others.first else {
                        throw ToolError.invalid("projectB", "is required unless exactly one other project is open")
                    }
                    second = only
                }
                guard first.id != second.id else { throw ToolError.invalid("projectB", "must differ from projectA") }
                guard let pa = b.workspaceProject(first.id), let pb = b.workspaceProject(second.id) else {
                    throw ToolError.invalid(nil, "A project is no longer open")
                }
                let fa = ProjectFigures(pa), fb = ProjectFigures(pb)
                if show {
                    try b.workspaceShowCompare(left: first.id, right: second.id, arrangement: try a.enumValue("arrangement", AgentArrangement.self))
                }
                let diffMm2 = fb.twiceTotalAreaMM2 - fa.twiceTotalAreaMM2
                return .object([
                    "a": fa.json, "b": fb.json,
                    "difference": .object([
                        "totalAreaM2": .string(ReportFormat.squareMetres(twiceAreaMM2: diffMm2)),
                        "furnitureCount": .int(Int64(fb.furnitureCount - fa.furnitureCount)),
                        "wallLengthMm": J.mm(fb.wallLengthMM - fa.wallLengthMM),
                    ]),
                    "note": "difference = b minus a",
                ])
            },
            .action("scene.transfer_objects",
                    "Copies (or with `move` moves) furniture and groups of the active project into another open project, with its designs, materials, textures, models and product data; every id is new in the target. Rooms, walls and groups themselves are not transferred. Each side gets one undo step; a move first copies, then deletes, and if the delete fails the copy stays and `deleteError` says why. The target needs a saved file when models, textures or product files travel. Needs write access.",
                    ["targetProjectId": S.uuid("Tab id or project id of the target from workspace.list."),
                     "ids": S.uuids("Furniture instance ids (or group ids) of the active project."),
                     "move": S.bool("Delete the originals after the copy (default false).")],
                    required: ["targetProjectId", "ids"]) { env, a in
                try env.requireWriteAccess("scene.transfer_objects changes two projects")
                let b = try bridge(env)
                let target = try resolve(try a.requireUUID("targetProjectId"), in: b, field: "targetProjectId")
                let ids = try a.requireUUIDList("ids")
                try env.project.requireAll(ids)
                let move = try a.bool("move") ?? false
                do {
                    let out = try b.workspaceTransfer(ids: ids, from: env.store, to: target.id, move: move, clientId: env.clientId)
                    var o: [String: JSONValue] = [
                        "target": .string(out.targetName), "targetProjectId": J.id(target.id),
                        "newIds": J.ids(out.newIds), "moved": .bool(out.moved),
                    ]
                    if let e = out.deleteError { o["deleteError"] = .string(e) }
                    return .object(o)
                } catch let e as CommandError {
                    throw AgentError(e)
                }
            },
        ]
    }
}
