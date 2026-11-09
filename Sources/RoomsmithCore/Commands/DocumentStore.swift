import Foundation
import Observation

/// Options for one document command.
public struct CommandOptions: Sendable {
    public var origin: ChangeOrigin
    /// Optimistic concurrency: the command fails with CONFLICT if the project revision differs.
    public var expectedRevision: Int64?
    /// Optimistic concurrency per object: CONFLICT if any listed object has a different revision.
    public var expectedObjectRevisions: [UUID: Int64]
    /// Validate and compute the change set without committing.
    public var dryRun: Bool
    /// false for transient changes such as camera orbiting.
    public var recordUndo: Bool

    public init(origin: ChangeOrigin = .user, expectedRevision: Int64? = nil, expectedObjectRevisions: [UUID: Int64] = [:],
                dryRun: Bool = false, recordUndo: Bool = true) {
        self.origin = origin; self.expectedRevision = expectedRevision
        self.expectedObjectRevisions = expectedObjectRevisions; self.dryRun = dryRun; self.recordUndo = recordUndo
    }
    public static let user = CommandOptions()
    public static func agent(_ clientId: String) -> CommandOptions { CommandOptions(origin: .agent(clientId)) }
}

public struct CommandResult<R> {
    public var value: R
    public var changes: ChangeSet
    /// Project revision after the command (unchanged on dry run or no-op).
    public var revision: Int64
    public var committed: Bool
}

public enum ChangeEventKind: String, Codable, Sendable { case command, undo, redo, reset }

/// One committed change, delivered to observers and agent subscribers.
public struct ChangeEvent: Codable, Sendable, Equatable {
    public var seq: Int64
    public var revision: Int64
    public var origin: ChangeOrigin
    public var name: String
    public var changes: ChangeSet
    public var kind: ChangeEventKind
}

/// The single source of truth of the open project. Every change – from the UI, an agent or the system – goes
/// through `apply`, which validates, stamps revisions, records undo and emits a change event.
@MainActor @Observable
public final class DocumentStore {
    public private(set) var project: Project
    /// Agents may only change the document while this is on (read tools always work).
    public var agentWriteEnabled = true
    /// Objects the user is currently dragging or editing; agent writes to them fail with BUSY.
    public private(set) var busy: [UUID: String] = [:]
    public private(set) var savedRevision: Int64
    public var isDirty: Bool { project.revision != savedRevision }
    /// Revision of the last change to document content. View-only changes (the live camera) raise `revision` for
    /// subscribers but not this, so looking around never marks a clean document as edited and never turns an
    /// agent's `expectedRevision` into a conflict.
    public private(set) var contentRevision: Int64

    private struct HistoryEntry { var name: String; var before: Project; var after: Project; var origin: ChangeOrigin }
    @ObservationIgnored private var undoStack: [HistoryEntry] = []
    @ObservationIgnored private var redoStack: [HistoryEntry] = []
    public private(set) var undoName: String?
    public private(set) var redoName: String?
    public let historyLimit = 200

    @ObservationIgnored private var events: [ChangeEvent] = []
    @ObservationIgnored private let eventLimit = 2000
    @ObservationIgnored public private(set) var lastSeq: Int64 = 0
    @ObservationIgnored private var waiters: [UUID: (after: Int64, cont: CheckedContinuation<[ChangeEvent], Never>)] = [:]
    @ObservationIgnored private var observers: [UUID: @MainActor (ChangeEvent) -> Void] = [:]

    public init(project: Project) {
        self.project = project
        self.savedRevision = project.revision
        self.contentRevision = project.revision
    }

    // MARK: Observers and events

    @discardableResult
    public func addObserver(_ body: @escaping @MainActor (ChangeEvent) -> Void) -> UUID {
        let token = UUID(); observers[token] = body; return token
    }
    public func removeObserver(_ token: UUID) { observers[token] = nil }

    /// Events with seq > `after` still in the ring buffer. `truncated` is true if older events were dropped.
    public func events(after: Int64) -> (events: [ChangeEvent], truncated: Bool) {
        let list = events.filter { $0.seq > after }
        let truncated = (events.first.map { $0.seq > after + 1 } ?? (lastSeq > after))
        return (list, truncated)
    }

    /// Long poll: returns as soon as events after `after` exist, or an empty list after `timeout` seconds.
    public func waitForEvents(after: Int64, timeout: Double) async -> [ChangeEvent] {
        let now = events(after: after).events
        if !now.isEmpty || timeout <= 0 { return now }
        let key = UUID()
        return await withCheckedContinuation { (cont: CheckedContinuation<[ChangeEvent], Never>) in
            waiters[key] = (after, cont)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let w = self?.waiters.removeValue(forKey: key) { w.cont.resume(returning: []) }
            }
        }
    }

    private func emit(_ name: String, _ origin: ChangeOrigin, _ changes: ChangeSet, _ kind: ChangeEventKind) {
        lastSeq += 1
        let ev = ChangeEvent(seq: lastSeq, revision: project.revision, origin: origin, name: name, changes: changes, kind: kind)
        events.append(ev)
        if events.count > eventLimit { events.removeFirst(events.count - eventLimit) }
        for o in observers.values { o(ev) }
        let ready = waiters.filter { $0.value.after < ev.seq }
        for (k, w) in ready {
            waiters[k] = nil
            w.cont.resume(returning: events.filter { $0.seq > w.after })
        }
    }

    // MARK: Interaction (busy objects)

    public func beginInteraction(_ ids: [UUID], reason: String) { for id in ids { busy[id] = reason } }
    public func endInteraction(_ ids: [UUID]? = nil) {
        if let ids { for id in ids { busy[id] = nil } } else { busy.removeAll() }
    }

    // MARK: Commands

    @discardableResult
    public func apply<R>(_ name: String, options: CommandOptions = .user, _ edit: (inout Project) throws -> R) throws -> CommandResult<R> {
        if options.origin.isAgent && !agentWriteEnabled && !options.dryRun {
            throw CommandError(.writeLocked, "Agent write access is turned off in Roomsmith")
        }
        if let exp = options.expectedRevision, exp != project.revision, !(exp >= contentRevision && exp <= project.revision) {
            throw CommandError(.conflict, "Project changed (expected revision \(exp), current \(project.revision))",
                               details: ["revision": String(project.revision)])
        }
        if !options.expectedObjectRevisions.isEmpty {
            var details: [String: String] = [:]
            var ids: [UUID] = []
            for (id, exp) in options.expectedObjectRevisions {
                let cur = project.rev(of: id)
                if cur != exp { details[id.uuidString.lowercased()] = cur.map(String.init) ?? "deleted"; ids.append(id) }
            }
            if !ids.isEmpty {
                details["revision"] = String(project.revision)
                throw CommandError(.conflict, "Objects changed since they were read", ids: ids, details: details)
            }
        }

        let before = project
        var draft = project
        let value = try edit(&draft)
        let stamp = before.revision + 1
        let cs = ChangeSet.diff(from: before, to: &draft, stamp: stamp)
        if cs.isEmpty {
            return CommandResult(value: value, changes: cs, revision: before.revision, committed: false)
        }
        if options.origin.isAgent && !busy.isEmpty {
            let hit = cs.objects.map(\.id).filter { busy[$0] != nil }
            if !hit.isEmpty {
                throw CommandError(.busy, "The user is currently editing \(hit.count == 1 ? "this object" : "these objects")", ids: hit)
            }
        }
        try Validator.validate(draft, changes: cs)
        if options.dryRun {
            return CommandResult(value: value, changes: cs, revision: before.revision, committed: false)
        }
        let viewOnly = cs.objects.isEmpty && !cs.settingsChanged && !cs.metaChanged
        let wasClean = !isDirty
        draft.revision = stamp
        project = draft
        if viewOnly {
            if wasClean { savedRevision = stamp }
        } else {
            contentRevision = stamp
        }
        if options.recordUndo {
            undoStack.append(HistoryEntry(name: name, before: before, after: draft, origin: options.origin))
            if undoStack.count > historyLimit { undoStack.removeFirst(undoStack.count - historyLimit) }
            redoStack.removeAll()
        } else if !undoStack.isEmpty {
            // Keep undo coherent: transient changes become part of the latest entry's result.
            undoStack[undoStack.count - 1].after = draft
        }
        updateNames()
        emit(name, options.origin, cs, .command)
        return CommandResult(value: value, changes: cs, revision: stamp, committed: true)
    }

    /// Convenience for commands without a return value.
    @discardableResult
    public func run(_ name: String, options: CommandOptions = .user, _ edit: (inout Project) throws -> Void) throws -> ChangeSet {
        try apply(name, options: options, edit).changes
    }

    public var undoDepth: Int { undoStack.count }
    public var redoDepth: Int { redoStack.count }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    @discardableResult
    public func undo(origin: ChangeOrigin = .user) throws -> ChangeEvent? {
        guard let entry = undoStack.last else { return nil }
        try checkHistoryAllowed(origin, entry.before)
        undoStack.removeLast()
        let ev = restore(entry.before, name: entry.name, origin: origin, kind: .undo)
        redoStack.append(entry)
        updateNames()
        return ev
    }

    @discardableResult
    public func redo(origin: ChangeOrigin = .user) throws -> ChangeEvent? {
        guard let entry = redoStack.last else { return nil }
        try checkHistoryAllowed(origin, entry.after)
        redoStack.removeLast()
        let ev = restore(entry.after, name: entry.name, origin: origin, kind: .redo)
        undoStack.append(entry)
        updateNames()
        return ev
    }

    private func checkHistoryAllowed(_ origin: ChangeOrigin, _ target: Project) throws {
        guard origin.isAgent else { return }
        if !agentWriteEnabled { throw CommandError(.writeLocked, "Agent write access is turned off in Roomsmith") }
        if !busy.isEmpty {
            var t = target
            let cs = ChangeSet.diff(from: project, to: &t, stamp: project.revision + 1)
            let hit = cs.objects.map(\.id).filter { busy[$0] != nil }
            if !hit.isEmpty { throw CommandError(.busy, "The user is currently editing objects this undo would change", ids: hit) }
        }
    }

    private func restore(_ target: Project, name: String, origin: ChangeOrigin, kind: ChangeEventKind) -> ChangeEvent? {
        var t = target
        // Keep the live camera and revision counter; history covers document content.
        t.camera = project.camera
        let stamp = project.revision + 1
        let cs = ChangeSet.diff(from: project, to: &t, stamp: stamp)
        t.revision = stamp
        project = t
        contentRevision = stamp
        emit(name, origin, cs, kind)
        return events.last
    }

    private func updateNames() {
        undoName = undoStack.last?.name
        redoName = redoStack.last?.name
    }

    /// Replaces the whole document (open file, new project). Clears history.
    public func replaceProject(_ p: Project, markSaved: Bool = true) {
        let old = project
        var np = p
        // Revisions must stay monotonic for subscribers across documents.
        np.revision = max(p.revision, old.revision + 1)
        project = np
        undoStack.removeAll(); redoStack.removeAll(); updateNames()
        busy.removeAll()
        contentRevision = np.revision
        if markSaved { savedRevision = np.revision }
        var cs = ChangeSet(); cs.metaChanged = true
        emit("Open project", .system, cs, .reset)
    }

    public func markSaved() { savedRevision = project.revision }
}
