import AppKit
import Foundation
import Synchronization
import Observation
import RoomsmithCore
import RoomsmithIPC

/// Runs the local agent socket server for the open projects and keeps the activity shown in the Agents panel.
/// Every open project has its own `ToolRegistry` (created on first use; a registry is bound to one store). A request
/// runs on the project that is active when it arrives; `app.subscribe_changes` stays with that project.
@MainActor @Observable
final class AgentHost {
    struct ClientInfo: Identifiable, Equatable {
        let id: String
        var lastSeen: Date
        var calls: Int
    }

    struct CallRecord: Identifiable, Equatable {
        let id: Int
        let time: Date
        let clientId: String
        let tool: String
        let ok: Bool
        let code: String?
    }

    static let maxRecentCalls = 200
    /// Clients remembered for the connection list; the least recently seen ones go first (clients can pick any id).
    static let maxClients = 64
    /// A client counts as connected while it has called within this many seconds.
    static let connectedWindow: TimeInterval = 60

    /// Clients that called since the app started, most recently seen first.
    var clients: [ClientInfo] { clientMap.values.sorted { $0.lastSeen > $1.lastSeen } }
    /// The last calls, newest first.
    private(set) var recentCalls: [CallRecord] = []
    private(set) var isRunning = false
    let socketPath: String

    private var clientMap: [String: ClientInfo] = [:]
    private var callCounter = 0
    @ObservationIgnored private let workspace: Workspace
    @ObservationIgnored private var server: AgentSocketServer?
    @ObservationIgnored private var registries: [UUID: ToolRegistry] = [:]
    @ObservationIgnored private var auditLog: AuditLog?

    init(workspace: Workspace) {
        self.workspace = workspace
        socketPath = AgentPaths.socketURL.path
        workspace.agentHost = self
    }

    /// The registry of one project, created on first use. One audit log serves all of them.
    private func registry(for model: AppModel) -> ToolRegistry? {
        if let r = registries[model.id] { return r }
        guard let auditLog else { return nil }
        model.agentViewBridge = AppViewBridge(model: model)
        let r = ToolRegistry(store: model.store, context: model, auditLog: auditLog)
        registries[model.id] = r
        return r
    }

    /// A closed project drops its registry (and its view bridge).
    func forget(_ model: AppModel) {
        registries[model.id] = nil
        model.agentViewBridge = nil
    }

    func start() throws {
        guard !isRunning else { return }
        let token = try AgentToken.loadOrCreate(at: AgentPaths.tokenURL)
        let auditLog = AuditLog(url: AgentPaths.auditLogURL)
        self.auditLog = auditLog
        // Wrong token: audit entry with client and tool only (the callback never receives the token).
        // Texts are clipped and entries throttled per client, so a flood cannot fill the log.
        let throttle = Mutex(AuthFailureThrottle())
        let onAuthFailure: @Sendable (String, String) -> Void = { clientId, tool in
            guard let suppressed = throttle.withLock({ $0.admit(clientId: clientId) }) else { return }
            auditLog.record(clientId: AuthFailureThrottle.clip(clientId), tool: AuthFailureThrottle.clip(tool),
                            arguments: suppressed > 0 ? .object(["suppressed": .int(Int64(suppressed))]) : .object([:]),
                            ok: false, errorCode: AgentError.unauthorized, revision: 0, durationMs: 0)
        }
        let server = AgentSocketServer(socketPath: socketPath, token: token, onAuthFailure: onAuthFailure) { [weak self] request in
            await Self.handle(request, host: self)
        }
        try server.start()
        self.server = server
        isRunning = true
    }

    func stop() {
        server?.stop()
        server = nil
        registries = [:]
        isRunning = false
    }

    /// True when a client has called within the last minute.
    func isConnected(at date: Date = Date()) -> Bool {
        clientMap.values.contains { date.timeIntervalSince($0.lastSeen) < Self.connectedWindow }
    }

    // MARK: Calls

    /// Runs on a socket thread; hops to the main actor for the registry (the document lives there).
    private nonisolated static func handle(_ request: AgentRequest, host: AgentHost?) async -> AgentResponse {
        let registry: ToolRegistry? = await MainActor.run {
            host?.noteStart(request.clientId)
            guard let host else { return nil }
            return host.registry(for: host.workspace.active)
        }
        guard let registry else {
            return AgentResponse.failure(id: request.id, AgentError(code: AgentError.notRunning, message: "Roomsmith is shutting down"))
        }
        let response = await registry.call(request)
        await MainActor.run {
            host?.noteFinished(request, response)
        }
        return response
    }

    private func noteStart(_ clientId: String) {
        var info = clientMap[clientId] ?? ClientInfo(id: clientId, lastSeen: Date(), calls: 0)
        info.lastSeen = Date()
        clientMap[clientId] = info
        trimClients()
    }

    private func trimClients() {
        guard clientMap.count > Self.maxClients else { return }
        let drop = clientMap.values.sorted { $0.lastSeen < $1.lastSeen }.prefix(clientMap.count - Self.maxClients)
        for c in drop { clientMap[c.id] = nil }
    }

    private func noteFinished(_ request: AgentRequest, _ response: AgentResponse) {
        var info = clientMap[request.clientId] ?? ClientInfo(id: request.clientId, lastSeen: Date(), calls: 0)
        info.lastSeen = Date()
        info.calls += 1
        clientMap[request.clientId] = info
        trimClients()
        callCounter += 1
        recentCalls.insert(CallRecord(id: callCounter, time: Date(), clientId: request.clientId, tool: request.tool,
                                      ok: response.ok, code: response.error?.code), at: 0)
        if recentCalls.count > Self.maxRecentCalls { recentCalls.removeLast(recentCalls.count - Self.maxRecentCalls) }
        // Agent edits may have deleted selected objects or the active level.
        for m in workspace.tabs { m.pruneSelection() }
    }
}

// MARK: - Context for the tools

extension AppModel: AgentAppContext {
    public var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// Saves to the project's own file; never shows a panel.
    public func saveForAgent() throws -> String {
        guard let url = fileURL else {
            throw AgentError(code: "NO_FILE",
                             message: "The project has not been saved yet. Ask the user to save it once in Roomsmith (File > Save); agents cannot choose a path.")
        }
        guard write(to: url) else {
            throw AgentError(code: AgentError.internal, message: lastError ?? "Could not save the project")
        }
        return url.path
    }

    public var viewBridge: AgentViewBridge? { agentViewBridge }
    public var walkBridge: AgentWalkBridge? { AppWalkBridge.bridge(for: self) }
    public var workspaceBridge: AgentWorkspaceBridge? { workspace }
    public var libraryRoot: URL { LibraryModel.shared.store.root }
    public var libraryBridge: AgentLibraryBridge? { LibraryThumbnailBridge.shared }
    public var photoProvider: (any FurnitureFromPhotoProvider)? { VisionFurnitureProvider() }

    // The tools check unsaved changes and paths first (see ProjectTools); these never show a dialog.

    public func newProjectForAgent() throws {
        if store.isDirty { autosave?.discard() }
        load(AppModel.starterProject(), url: nil)
        statusMessage = "New project"
    }

    public func openProjectForAgent(_ url: URL) throws -> [String] {
        let loaded: (Project, [String])
        do { loaded = try ProjectPackage.load(from: url) } catch {
            throw AgentError(code: AgentError.invalidArgument, message: "Could not open \(url.lastPathComponent): \(error)")
        }
        if store.isDirty { autosave?.discard() }
        load(loaded.0, url: url)
        noteRecent(url)
        statusMessage = "Opened \(url.lastPathComponent)"
        return loaded.1
    }

    public func saveProjectAsForAgent(_ url: URL) throws {
        guard write(to: url) else {
            throw AgentError(code: AgentError.internal, message: lastError ?? "Could not save the project")
        }
    }

    /// Same measuring as File > Import 3D Model… (RealityKit bounds, mapped to Roomsmith axes).
    public func measureModelForAgent(_ url: URL) async throws -> Size3 {
        do { return try await USDZImport.measure(url) } catch {
            throw AgentError(code: AgentError.invalidArgument, message: "Could not import \(url.lastPathComponent): \(error)")
        }
    }
}
