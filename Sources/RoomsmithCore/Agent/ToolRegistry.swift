import Foundation

/// What the tool layer needs from the running app besides the document.
@MainActor
public protocol AgentAppContext: AnyObject {
    var selection: Set<UUID> { get set }
    /// Sets the selection on the agent's behalf (`scene.select_objects`). Unlike a user selection it does not count as
    /// "seen" for the "New" badges of agent additions.
    func setSelectionByAgent(_ ids: Set<UUID>)
    var activeLevelId: UUID { get set }
    /// File of the open project; nil while it is untitled.
    var fileURL: URL? { get }
    var appVersion: String { get }
    /// Saves the open project to its own path (never shows a panel). Returns the path.
    func saveForAgent() throws -> String
    /// App-side view state (layout, panels, 3D options, plan viewport, camera presets, scene rendering). Nil in
    /// contexts without a window; the view and render tools then answer UNSUPPORTED.
    var viewBridge: AgentViewBridge? { get }
    /// Walk mode of the live 3D view (settings, doors). Nil without a window; `walk.*` then answer UNSUPPORTED.
    var walkBridge: AgentWalkBridge? { get }
    /// Tabs, compare split and transfers between open projects (see `AgentWorkspaceBridge`). Nil without a window.
    var workspaceBridge: AgentWorkspaceBridge? { get }
    /// Replaces the open project by a new empty one. Never shows a panel or alert; the tool has checked unsaved changes.
    func newProjectForAgent() throws
    /// Loads the `.roomsmith` package at `url` into the open document (no panel or alert). Returns load warnings.
    func openProjectForAgent(_ url: URL) throws -> [String]
    /// Writes the open project to a new package at `url` and makes it the project's file (no panel or alert).
    func saveProjectAsForAgent(_ url: URL) throws
    /// Loads a USD/USDZ model and returns its size in mm (width = X, depth = Z, height = Y of the model), as the import menu command measures it.
    /// Throws an `AgentError` when the file cannot be read or has no usable geometry. Does not touch the project.
    func measureModelForAgent(_ url: URL) async throws -> Size3
    /// Folder of the global furniture library (see `LibraryStore`). Tests point it at a temporary folder.
    var libraryRoot: URL { get }
    /// Renders library thumbnails. Nil without a window; `library.thumbnail` then answers UNSUPPORTED unless it is cached.
    var libraryBridge: AgentLibraryBridge? { get }
    /// Analyses reference photos for `library.create_from_photo` (Vision on device). Nil without the app; the tool then answers UNSUPPORTED.
    var photoProvider: (any FurnitureFromPhotoProvider)? { get }
}

extension AgentAppContext {
    public func setSelectionByAgent(_ ids: Set<UUID>) { selection = ids }
    public var viewBridge: AgentViewBridge? { nil }
    public var libraryRoot: URL { LibraryStore.defaultRoot }
    public var libraryBridge: AgentLibraryBridge? { nil }
    public var photoProvider: (any FurnitureFromPhotoProvider)? { nil }
    public func newProjectForAgent() throws { throw AgentError.unsupportedFeature("This app context cannot create projects.") }
    public func openProjectForAgent(_ url: URL) throws -> [String] { throw AgentError.unsupportedFeature("This app context cannot open projects.") }
    public func saveProjectAsForAgent(_ url: URL) throws { throw AgentError.unsupportedFeature("This app context cannot save projects under a new path.") }
    public func measureModelForAgent(_ url: URL) async throws -> Size3 { throw AgentError.unsupportedFeature("This app context cannot import 3D models.") }
}

extension AgentError {
    static func unsupportedFeature(_ message: String) -> AgentError { AgentError(code: ExportTools.unsupported, message: message) }
}

/// Dispatches agent requests to the tools. All document access happens on the main actor.
@MainActor
public final class ToolRegistry {
    public static let apiVersion = 1
    static let maxListedChanges = 200
    static let maxBatchSteps = 100

    let store: DocumentStore
    let context: AgentAppContext
    let auditLog: AuditLog?
    private var specs: [String: ToolSpec] = [:]
    private var order: [String] = []

    public init(store: DocumentStore, context: AgentAppContext, auditLog: AuditLog? = nil) {
        self.store = store
        self.context = context
        self.auditLog = auditLog
        let all = AppTools.specs() + ProjectTools.specs() + SceneTools.specs() + GeometryTools.specs()
            + CatalogTools.specs() + FurnitureTools.specs() + CameraTools.specs() + HistoryTools.specs() + ExportTools.specs()
            + ReportTools.specs() + BackgroundTools.specs() + ViewTools.specs() + RenderTools.specs()
            + MaterialTools.specs() + FurnitureDesignTools.specs() + DimensionTools.specs() + WalkTools.specs()
            + WorkspaceTools.specs() + LightTools.specs() + LibraryTools.specs() + LibraryPhotoTools.specs()
        for s in all {
            precondition(specs[s.name] == nil, "duplicate tool \(s.name)")
            specs[s.name] = s
            order.append(s.name)
        }
    }

    public var descriptors: [ToolDescriptor] { order.compactMap { specs[$0]?.descriptor } }

    func spec(_ name: String) -> ToolSpec? { specs[name] }

    // MARK: Entry point

    public func call(_ request: AgentRequest) async -> AgentResponse {
        let started = ContinuousClock.now
        let response: AgentResponse
        do {
            response = .success(id: request.id, try await execute(request))
        } catch {
            response = .failure(id: request.id, Self.agentError(error))
        }
        let elapsed = started.duration(to: .now)
        let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        auditLog?.record(clientId: request.clientId, tool: request.tool, arguments: request.arguments, ok: response.ok,
                         errorCode: response.error?.code, revision: store.project.revision, durationMs: ms)
        return response
    }

    static func agentError(_ error: Error) -> AgentError {
        if let a = error as? AgentError { return a }
        if let c = error as? CommandError { return AgentError(c) }
        return AgentError(code: AgentError.internal, message: "\(error)")
    }

    private func env(_ clientId: String) -> ToolEnv {
        ToolEnv(store: store, context: context, clientId: clientId, registry: self)
    }

    private func execute(_ request: AgentRequest) async throws -> JSONValue {
        guard let spec = specs[request.tool] else {
            throw AgentError(code: AgentError.unknownTool,
                             message: "Unknown tool '\(request.tool)'. Call app.list_tools for the available tools.",
                             details: .object(["tool": .string(request.tool)]))
        }
        let args = try prepareArgs(spec, request.arguments, extraKeys: spec.isWrite ? ToolSpec.commonKeys : [])
        let env = env(request.clientId)
        switch spec.handler {
        case .read(let h), .action(let h): return try h(env, args)
        case .asyncRead(let h): return try await h(env, args)
        case .write(let h): return try runWrite(spec, h, args, env)
        }
    }

    // MARK: Arguments

    func prepareArgs(_ spec: ToolSpec, _ json: JSONValue, extraKeys: Set<String>) throws -> Args {
        let args = try Args(json)
        if !spec.openArguments {
            let allowed = Set(spec.properties.keys).union(extraKeys)
            if let bad = args.values.keys.sorted().first(where: { !allowed.contains($0) }) {
                throw ToolError.invalid(bad, "unknown argument. Allowed: \(allowed.sorted().joined(separator: ", "))")
            }
        }
        for r in spec.required where !args.has(r) { throw ToolError.missing(r) }
        return args
    }

    // MARK: Mutating tools

    private func runWrite(_ spec: ToolSpec, _ handler: ToolSpec.WriteHandler, _ args: Args, _ env: ToolEnv) throws -> JSONValue {
        let dry = try args.bool("dryRun") ?? false
        let expectedRevision = try args.int("expectedRevision")
        var objectRevisions = try args.revisionMap("expectedObjectRevisions")
        var label = "Agent: " + String(spec.name.drop(while: { $0 != "." }).dropFirst()).replacingOccurrences(of: "_", with: " ")
        if spec.name == "app.batch" {
            let steps = try args.requireArray("steps")
            label = "Agent: batch (\(steps.count) steps)"
            for (i, step) in steps.enumerated() {
                do {
                    let stepArgs = try Args(step["arguments"] ?? .object([:]))
                    objectRevisions.merge(try stepArgs.revisionMap("expectedObjectRevisions")) { _, new in new }
                } catch let e as AgentError {
                    throw Self.stepError(e, index: i, tool: step["tool"]?.stringValue)
                }
            }
        }
        let options = CommandOptions(origin: .agent(env.clientId), expectedRevision: expectedRevision,
                                     expectedObjectRevisions: objectRevisions, dryRun: dry, recordUndo: spec.recordUndo)
        var extra: JSONValue = .null
        var env = env
        env.dryRun = dry
        let result = try store.apply(label, options: options) { p in
            extra = try handler(&p, env, args)
        }
        return Self.mutationJSON(committed: result.committed, revision: result.revision, changes: result.changes,
                                 extra: extra, dryRun: dry, project: store.project)
    }

    /// Runs one tool of a batch (or a re-dispatched tool) inside the surrounding edit.
    func runInner(_ tool: String, _ json: JSONValue, _ p: inout Project, _ env: ToolEnv, allowObjectRevisions: Bool) throws -> JSONValue {
        guard let spec = specs[tool] else {
            throw AgentError(code: AgentError.unknownTool, message: "Unknown tool '\(tool)'. Call app.list_tools for the available tools.",
                             details: .object(["tool": .string(tool)]))
        }
        guard spec.batchable, case .write(let h) = spec.handler else {
            throw ToolError.invalid("tool", "'\(tool)' cannot be used here; only mutating tools that record undo are allowed")
        }
        let args = try prepareArgs(spec, json, extraKeys: allowObjectRevisions ? ["expectedObjectRevisions"] : [])
        if spec.openArguments {
            // Open-argument tools skip the allowed-key check; dryRun/expectedRevision still make no sense per step.
            let shared = ToolSpec.commonKeys.subtracting(allowObjectRevisions ? ["expectedObjectRevisions"] : [])
            if let bad = args.values.keys.sorted().first(where: { shared.contains($0) }) {
                throw ToolError.invalid(bad, "is not allowed inside a batch step; pass it to the batch itself")
            }
        }
        return try h(&p, env, args)
    }

    static func stepError(_ e: AgentError, index: Int, tool: String?) -> AgentError {
        var d = e.details?.objectValue ?? [:]
        d["step"] = .int(Int64(index))
        if let tool { d["tool"] = .string(tool) }
        let label = tool.map { " (\($0))" } ?? ""
        return AgentError(code: e.code, message: "Step \(index) failed\(label): \(e.message). Nothing was changed.", details: .object(d))
    }

    // MARK: Result shapes

    static func changeRows(_ cs: ChangeSet, project: Project, withRev: Bool) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        let rows: [JSONValue] = cs.objects.prefix(maxListedChanges).map { c in
            var o: [String: JSONValue] = ["id": J.id(c.id), "kind": .string(c.kind.rawValue), "op": .string(c.op.rawValue)]
            if withRev, c.op != .removed, let r = project.rev(of: c.id) { o["rev"] = .int(r) }
            return .object(o)
        }
        out["changes"] = .array(rows)
        out["changeCount"] = .int(Int64(cs.objects.count))
        out["changesTruncated"] = .bool(cs.objects.count > maxListedChanges)
        if cs.settingsChanged { out["settingsChanged"] = true }
        if cs.cameraChanged { out["cameraChanged"] = true }
        if cs.metaChanged { out["metaChanged"] = true }
        return out
    }

    static func mutationJSON(committed: Bool, revision: Int64, changes: ChangeSet, extra: JSONValue, dryRun: Bool, project: Project) -> JSONValue {
        var o = extra.objectValue ?? [:]
        for (k, v) in changeRows(changes, project: project, withRev: committed) { o[k] = v }
        o["committed"] = .bool(committed)
        o["revision"] = .int(revision)
        if dryRun { o["dryRun"] = true }
        return .object(o)
    }

    static func eventJSON(_ e: ChangeEvent) -> JSONValue {
        let cs = e.changes
        func count(_ op: ChangeOp) -> Int64 { Int64(cs.objects.filter { $0.op == op }.count) }
        var summary: [String: JSONValue] = [
            "added": .int(count(.added)), "modified": .int(count(.modified)), "removed": .int(count(.removed)),
            "total": .int(Int64(cs.objects.count)),
            "objects": .array(cs.objects.prefix(50).map {
                .object(["id": J.id($0.id), "kind": .string($0.kind.rawValue), "op": .string($0.op.rawValue)])
            }),
        ]
        if cs.settingsChanged { summary["settingsChanged"] = true }
        if cs.cameraChanged { summary["cameraChanged"] = true }
        if cs.metaChanged { summary["metaChanged"] = true }
        return .object([
            "seq": .int(e.seq), "revision": .int(e.revision), "origin": .string(e.origin.description),
            "name": .string(e.name), "kind": .string(e.kind.rawValue), "changes": .object(summary),
        ])
    }
}

// MARK: - app.*

enum AppTools {
    static let errorCodes = ["UNKNOWN_TOOL", "INVALID_ARGUMENT", "NOT_FOUND", "OUT_OF_RANGE", "CONFLICT", "LOCKED", "WRITE_LOCKED",
                             "BUSY", "NO_FILE", "UNAUTHORIZED", "NOT_RUNNING", "UNSUPPORTED", "INTERNAL"]

    @MainActor
    static func specs() -> [ToolSpec] {
        [
            .read("app.get_capabilities", "Version, limits, units, conventions and whether agents may currently change the project. Call this first.") { env, _ in
                .object([
                    "app": "Roomsmith",
                    "appVersion": .string(env.context.appVersion),
                    "apiVersion": .int(Int64(ToolRegistry.apiVersion)),
                    "writeEnabled": .bool(env.store.agentWriteEnabled),
                    "toolCount": .int(Int64(env.registry.descriptors.count)),
                    "units": ["length": "integer millimetres", "angle": "degrees (double), counter-clockwise; objects at 0: local X east, back north (front south); camera yawDeg 0 = north",
                              "area": "mm2 (rooms) in `area`, m2 in `areaM2`", "ids": "lowercase UUID strings",
                              "axes": "X east, Y north, Z up"],
                    "limits": ["pageDefault": 50, "pageMax": 500, "batchMaxSteps": 100, "subscribeMaxTimeoutMs": 30000,
                               "changesListed": 200, "sizeMm": "1...100000", "coordinateMm": "+-100000000"],
                    "concurrency": "Every object has `rev`. Pass expectedObjectRevisions {uuid: rev} to fail with CONFLICT instead of overwriting newer edits; expectedRevision does the same for the whole project (camera-only changes never make it stale).",
                    "errorCodes": .array(errorCodes.map { .string($0) }),
                    "revision": .int(env.project.revision),
                ])
            },
            .read("app.get_active_project", "Name, file path, revision, dirty flag, levels, active level, selection and undo state of the open project.") { env, _ in
                let p = env.project
                return .object([
                    "name": .string(p.name),
                    "id": J.id(p.id),
                    "path": env.context.fileURL.map { .string($0.path) } ?? .null,
                    "revision": .int(p.revision),
                    "dirty": .bool(env.store.isDirty),
                    "writeEnabled": .bool(env.store.agentWriteEnabled),
                    "activeLevelId": J.id(env.context.activeLevelId),
                    "levels": .array(p.levels.map { .object(["id": J.id($0.id), "name": .string($0.name), "rev": .int($0.rev)]) }),
                    "selection": J.ids(env.context.selection.sorted { $0.uuidString < $1.uuidString }),
                    "undoName": env.store.undoName.map { .string($0) } ?? .null,
                    "redoName": env.store.redoName.map { .string($0) } ?? .null,
                    "canUndo": .bool(env.store.canUndo),
                    "canRedo": .bool(env.store.canRedo),
                    "lastSeq": .int(env.store.lastSeq),
                ])
            },
            .read(agentListToolsName, "All tools with their JSON schema (array of descriptors).") { env, _ in
                try JSONValue(encoding: env.registry.descriptors)
            },
            .asyncRead("app.subscribe_changes",
                       "Long poll for document changes. Pass the `latestSeq` of the previous answer as afterSeq; the call returns as soon as events exist or after timeoutMs. Without afterSeq it returns immediately with the current latestSeq. `truncated` means events were dropped or the app restarted: re-read the scene.",
                       ["afterSeq": S.int("Return events with seq greater than this."),
                        "timeoutMs": S.int("Wait up to this long (0...30000, default 0) when nothing happened yet.")]) { env, a in
                let store = env.store
                @MainActor func answer(_ events: [ChangeEvent], truncated: Bool, hasMore: Bool = false) -> JSONValue {
                    .object(["events": .array(events.map { ToolRegistry.eventJSON($0) }),
                             "latestSeq": .int(events.last?.seq ?? store.lastSeq),
                             "truncated": .bool(truncated), "hasMore": .bool(hasMore),
                             "revision": .int(store.project.revision)])
                }
                guard let after = try a.int("afterSeq") else { return answer([], truncated: false) }
                guard after >= 0 else { throw ToolError.invalid("afterSeq", "must not be negative") }
                let timeout = try a.int("timeoutMs") ?? 0
                guard (0...30000).contains(timeout) else { throw ToolError.invalid("timeoutMs", "must be between 0 and 30000") }
                if after > store.lastSeq { return answer([], truncated: true) }
                let now = store.events(after: after)
                var events = now.events
                let truncated = now.truncated
                if events.isEmpty && timeout > 0 {
                    events = await store.waitForEvents(after: after, timeout: Double(timeout) / 1000)
                }
                let hasMore = events.count > 500
                return answer(Array(events.prefix(500)), truncated: truncated, hasMore: hasMore)
            },
            batchSpec(),
        ]
    }

    @MainActor
    private static func batchSpec() -> ToolSpec {
        .write("app.batch",
               "Runs several mutating tools atomically: one undo step, one revision. If any step fails nothing changes and the error names the step. Later steps may use ids that earlier steps created by passing `id` to the create tools. Not allowed as steps: app.batch, history.*, project.save, camera.set_state, read tools.",
               ["steps": S.arr("Steps in order.", items: S.obj("One step.", ["tool": S.str("Tool name, e.g. scene.move_objects."),
                                                                              "arguments": S.obj("Arguments of that tool.")], required: ["tool"]))],
               required: ["steps"]) { p, env, a in
            let steps = try a.requireArray("steps")
            guard !steps.isEmpty else { throw ToolError.invalid("steps", "must contain at least one step") }
            guard steps.count <= ToolRegistry.maxBatchSteps else {
                throw ToolError.invalid("steps", "at most \(ToolRegistry.maxBatchSteps) steps per batch")
            }
            var results: [JSONValue] = []
            for (i, step) in steps.enumerated() {
                let tool = step["tool"]?.stringValue
                do {
                    guard let tool else { throw ToolError.invalid("steps[\(i)].tool", "is required") }
                    let r = try env.registry.runInner(tool, step["arguments"] ?? .object([:]), &p, env, allowObjectRevisions: true)
                    results.append(.object(["index": .int(Int64(i)), "tool": .string(tool), "result": r]))
                } catch {
                    throw ToolRegistry.stepError(ToolRegistry.agentError(error), index: i, tool: tool)
                }
            }
            return .object(["steps": .array(results)])
        }
    }
}

// MARK: - history.*

enum HistoryTools {
    @MainActor
    static func specs() -> [ToolSpec] {
        [step("history.undo", "Undo the last change(s) of the project. This also undoes changes made by the user, not only by agents. Needs write access.", undo: true),
         step("history.redo", "Redo what was undone. Needs write access.", undo: false)]
    }

    @MainActor
    private static func step(_ name: String, _ description: String, undo: Bool) -> ToolSpec {
        .action(name, description, ["steps": S.int("How many steps (1...50, default 1).")]) { env, a in
            guard env.store.agentWriteEnabled else {
                throw AgentError(code: AgentError.writeLocked, message: "Agent write access is switched off in Roomsmith (Agents panel).")
            }
            let n = try a.int("steps") ?? 1
            guard (1...50).contains(n) else { throw ToolError.invalid("steps", "must be between 1 and 50") }
            let available = undo ? env.store.undoDepth : env.store.redoDepth
            guard n == 1 || n <= available else {  // a single step with nothing to do stays a harmless no-op
                throw AgentError(code: AgentError.invalidArgument,
                                 message: "Cannot \(undo ? "undo" : "redo") \(n) steps: only \(available) available. Nothing was changed.",
                                 details: .object(["field": .string("steps"), "available": .int(Int64(available))]))
            }
            if n > 1 && !env.store.busy.isEmpty {
                throw AgentError(code: AgentError.busy, message: "The user is currently editing objects; multi-step \(undo ? "undo" : "redo") was not started. Nothing was changed.",
                                 details: .object(["ids": J.ids(Array(env.store.busy.keys))]))
            }
            var names: [String] = []
            var merged: [UUID: ObjectChange] = [:]
            var order: [UUID] = []
            var flags = ChangeSet()
            for _ in 0..<n {
                let origin = ChangeOrigin.agent(env.clientId)
                guard let ev = try (undo ? env.store.undo(origin: origin) : env.store.redo(origin: origin)) else { break }
                names.append(ev.name)
                for c in ev.changes.objects {
                    if merged[c.id] == nil { order.append(c.id) }
                    merged[c.id] = c
                }
                flags.settingsChanged = flags.settingsChanged || ev.changes.settingsChanged
                flags.cameraChanged = flags.cameraChanged || ev.changes.cameraChanged
                flags.metaChanged = flags.metaChanged || ev.changes.metaChanged
            }
            flags.objects = order.compactMap { merged[$0] }
            var o = ToolRegistry.changeRows(flags, project: env.project, withRev: true)
            o["committed"] = .bool(!names.isEmpty)
            o["performed"] = .int(Int64(names.count))
            o["names"] = .array(names.map { .string($0) })
            o["revision"] = .int(env.project.revision)
            o["undoName"] = env.store.undoName.map { .string($0) } ?? .null
            o["redoName"] = env.store.redoName.map { .string($0) } ?? .null
            o["canUndo"] = .bool(env.store.canUndo)
            o["canRedo"] = .bool(env.store.canRedo)
            return .object(o)
        }
    }
}
