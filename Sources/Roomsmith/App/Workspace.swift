import AppKit
import Foundation
import Observation
import RoomsmithCore

/// What a pane of the compare split shows.
enum PaneContent: String, CaseIterable, Identifiable {
    case plan, scene
    var id: String { rawValue }
    var title: String { self == .plan ? "Plan" : "3D" }
    var symbol: String { self == .plan ? "map" : "cube" }
}

enum CompareSide { case left, right }

/// Two projects shown next to each other. The left pane is the active tab; each pane has its own project, camera and
/// plan / 3D choice. The sidebar, inspector, status bar and menus follow the focused pane.
struct CompareState: Equatable {
    var rightId: UUID
    var axis: SplitAxis = .sideBySide
    var leftContent: PaneContent = .plan
    var rightContent: PaneContent = .plan
    var focus: CompareSide = .left
}

/// A drag of furniture from one open project to another: `roomsmith-transfer:<source model id>:<id>,<id>…`.
/// Only the token travels on the pasteboard; the workspace resolves it inside the process.
struct TransferToken: Equatable {
    static let prefix = "roomsmith-transfer:"
    var sourceId: UUID
    var ids: [UUID]

    var payload: String { Self.prefix + sourceId.uuidString + ":" + ids.map(\.uuidString).joined(separator: ",") }

    init(sourceId: UUID, ids: [UUID]) { self.sourceId = sourceId; self.ids = ids }

    init?(payload: String) {
        guard payload.hasPrefix(Self.prefix) else { return nil }
        let parts = payload.dropFirst(Self.prefix.count).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let source = UUID(uuidString: String(parts[0])) else { return nil }
        let ids = parts[1].split(separator: ",").compactMap { UUID(uuidString: String($0)) }
        guard !ids.isEmpty else { return nil }
        self.sourceId = source; self.ids = ids
    }
}

/// The open projects of the window (tabs), the compare split and everything between projects (transfer, clipboard).
/// Each project is its own `AppModel` with its own store, undo history, selection and camera; the window-wide view
/// settings live in one shared `WindowPrefs`.
@MainActor @Observable
final class Workspace {
    let prefs = WindowPrefs()
    private(set) var tabs: [AppModel] = []
    private(set) var activeId = UUID()
    var compare: CompareState?
    /// The comparison figures sheet (Projects > Compare Figures…) is showing.
    var showComparisonSheet = false

    /// Furniture copied with ⌘C, and the token that was put on the pasteboard with it.
    @ObservationIgnored private(set) var clipboard: FurnitureTransfer?
    @ObservationIgnored private var clipboardToken: String?
    @ObservationIgnored private var pasteCount = 0
    @ObservationIgnored var agentHost: AgentHost?

    /// The "Open Recent" list (file paths, newest first). Kept in the support folder unless a check run owns the process.
    private(set) var recent = AppDefaults.persistsSession ? RecentProjects.load() : RecentProjects()
    /// False until the last session has been restored, so the empty start-up state never overwrites the stored one.
    @ObservationIgnored private(set) var sessionTracking = false
    @ObservationIgnored private var lastSavedSession: SessionState?

    init() {
        let first = makeModel(project: AppModel.starterProject(), url: nil)
        activeId = first.id
    }

    // MARK: Tabs

    var active: AppModel { tabs.first { $0.id == activeId } ?? tabs[0] }
    /// The project the sidebar, inspector, status bar and menus act on.
    var focused: AppModel {
        if let c = compare, c.focus == .right, let m = model(c.rightId) { return m }
        return active
    }
    var rightModel: AppModel? { compare.flatMap { model($0.rightId) } }
    var showsTabBar: Bool { tabs.count > 1 || compare != nil }

    func model(_ id: UUID) -> AppModel? { tabs.first { $0.id == id } }
    /// A tab by tab id or project id.
    func model(matching id: UUID) -> AppModel? { model(id) ?? tabs.first { $0.project.id == id } }

    private func makeModel(project: Project, url: URL?) -> AppModel {
        let m = AppModel(project: project, prefs: prefs)
        m.fileURL = url
        m.workspace = self
        let a = Autosave(model: m)
        m.autosave = a
        a.start()
        tabs.append(m)
        return m
    }

    func activate(_ id: UUID) {
        guard model(id) != nil, id != activeId else {
            if compare != nil, id == activeId { compare?.focus = .left }
            return
        }
        if var c = compare, c.rightId == id {
            c.rightId = activeId  // the other pane's project moves to the left; the two swap sides
            swap(&c.leftContent, &c.rightContent)
            compare = c
        }
        activeId = id
        compare?.focus = .left
    }

    static func notOpen(_ id: UUID) -> AgentError {
        AgentError(code: AgentError.notFound, message: "No open project has the id \(id.uuidString.lowercased())")
    }

    /// A project nobody touched: untitled, no change, no undo step. New and Open reuse it instead of adding a tab.
    func isPristine(_ m: AppModel) -> Bool {
        m.fileURL == nil && !m.store.isDirty && m.store.undoDepth == 0
    }

    /// File > New: a new untitled tab (the active one when it is still empty).
    @discardableResult
    func newProject() -> AppModel {
        if isPristine(active) { return active }
        let m = makeModel(project: AppModel.starterProject(), url: nil)
        activate(m.id)
        return m
    }

    /// Opens a project file in a tab: an already open file is activated, an empty tab is reused, else a new tab.
    @discardableResult
    func openTab(_ url: URL, noteRecent: Bool = true) throws -> AppModel {
        if let open = tabs.first(where: { $0.fileURL?.standardizedFileURL == url.standardizedFileURL }) {
            activate(open.id)
            return open
        }
        let loaded: (Project, [String])
        do { loaded = try ProjectPackage.load(from: url) } catch {
            throw AgentError(code: AgentError.invalidArgument, message: "Could not open \(url.lastPathComponent): \(error)")
        }
        let target: AppModel
        if isPristine(active) { target = active } else {
            target = makeModel(project: AppModel.starterProject(), url: nil)
            activate(target.id)
        }
        target.load(loaded.0, url: url)
        if noteRecent { noteRecentProject(url) }
        let w = loaded.1
        target.statusMessage = w.isEmpty ? "Opened \(url.lastPathComponent)" : "Opened with \(w.count) warning(s): \(w.joined(separator: "; "))"
        return target
    }

    /// Menu and Finder variant of `openTab`: errors go to the status bar.
    func open(_ url: URL) {
        do { try openTab(url) } catch { active.lastError = userMessage(for: error) }
    }

    /// Open Recent: opens the entry; a file that is gone is reported and removed from the list.
    func openRecent(_ path: String) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            forgetRecent(path)
            active.statusMessage = "\(url.lastPathComponent) could not be found and was removed from the recent list"
            return
        }
        open(url)
    }

    func noteRecentProject(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)  // Dock menu
        recent.note(SessionState.path(for: url))
        saveRecent()
    }

    func forgetRecent(_ path: String) { recent.remove(path); saveRecent() }

    func clearRecent() {
        recent.clear()
        NSDocumentController.shared.clearRecentDocuments(nil)
        saveRecent()
    }

    private func saveRecent() {
        guard AppDefaults.persistsSession else { return }
        try? recent.save()
    }

    func openWithPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Choose one or more .roomsmith projects"
        if panel.runModal() == .OK { for url in panel.urls { open(url) } }
    }

    /// Puts recovered copies into tabs (an empty first tab is reused). They count as unsaved changes.
    func restore(_ items: [(project: Project, originalURL: URL?)]) {
        for item in items {
            let m: AppModel
            // A recovered copy of a file that the last session reopened replaces that tab instead of adding a second one.
            if let url = item.originalURL?.standardizedFileURL,
               let open = tabs.first(where: { $0.fileURL?.standardizedFileURL == url && !$0.store.isDirty }) {
                m = open
            } else if isPristine(active) { m = active } else {
                m = makeModel(project: AppModel.starterProject(), url: nil)
                activate(m.id)
            }
            m.store.replaceProject(item.project, markSaved: false)
            m.fileURL = item.originalURL
            m.selection = []
            m.activeLevelId = m.store.project.levels.first?.id ?? UUID()
            m.statusMessage = "Restored unsaved changes"
            m.autosave?.tick()  // the recovery copy was removed when it was loaded: write it again right away
        }
    }

    /// Closes a tab after asking about unsaved changes. The last tab is replaced by an empty project.
    @discardableResult
    func closeWithConfirmation(_ id: UUID) -> Bool {
        guard let m = model(id) else { return true }
        let wasActive = activeId
        if m.store.isDirty, id != wasActive { activate(id) }  // show what the question is about
        guard m.confirmDiscard() else { return false }
        remove(m)
        return true
    }

    /// Agent variant: no dialog; unsaved changes need `discard`.
    func closeForAgent(_ id: UUID, discard: Bool) throws {
        guard let m = model(id) else { return }
        if m.store.isDirty, !discard {
            throw AgentError(code: AgentError.conflict, message: "\(m.project.name) has unsaved changes. Save it first, or pass discard=true to close it without saving.")
        }
        remove(m)
    }

    private func remove(_ m: AppModel) {
        m.autosave?.discard()
        m.autosave?.stop()
        agentHost?.forget(m)
        m.presenter?.shutdown()
        m.presenter = nil
        let index = tabs.firstIndex { $0 === m } ?? 0
        if compare?.rightId == m.id || activeId == m.id { compare = nil }
        tabs.removeAll { $0 === m }
        if tabs.isEmpty {
            let fresh = makeModel(project: AppModel.starterProject(), url: nil)
            activeId = fresh.id
        } else if activeId == m.id {
            activeId = tabs[min(index, tabs.count - 1)].id
        }
    }

    /// Quit and window close: asks about every tab with unsaved changes. False when the user cancels.
    func confirmDiscardAll() -> Bool {
        for m in tabs where m.store.isDirty {
            if m.id != activeId { activate(m.id) }
            guard m.confirmDiscard() else { return false }
        }
        return true
    }

    func discardAllAutosaves() { for m in tabs { m.autosave?.discard() } }

    // MARK: Session

    /// What a restart should bring back: saved projects in tab order, the active one and the split.
    var sessionSnapshot: SessionState { sessionSnapshot(active: activeId, compare: compare) }

    /// The session with the given active tab and split, but the tabs' current files (quit takes the active tab and
    /// split from before its unsaved-changes questions and the paths from after them, so a tab saved there is kept).
    func sessionSnapshot(active: UUID, compare: CompareState?) -> SessionState {
        let activeIndex = tabs.firstIndex { $0.id == active } ?? 0
        var split: SessionState.Split?
        if let c = compare, let right = tabs.firstIndex(where: { $0.id == c.rightId }) {
            split = SessionState.Split(
                rightIndex: right, axis: SessionState.Axis(rawValue: c.axis.rawValue) ?? .sideBySide,
                leftContent: SessionState.Pane(rawValue: c.leftContent.rawValue) ?? .plan,
                rightContent: SessionState.Pane(rawValue: c.rightContent.rawValue) ?? .plan,
                focus: c.focus == .right ? .right : .left)
        }
        return SessionState.make(tabs: tabs.map { $0.fileURL.map(SessionState.path(for:)) }, active: activeIndex, split: split)
    }

    /// Writes the session when it changed (tab, open, close, Save As, split). No-op before `finishSessionRestore` has run.
    func persistSession(_ state: SessionState? = nil) {
        guard sessionTracking, AppDefaults.persistsSession else { return }
        let s = state ?? sessionSnapshot
        guard s != lastSavedSession else { return }
        lastSavedSession = s
        try? s.save()
    }

    struct SessionOpened {
        var ids: [Int: UUID] = [:]
        var missing = 0
        var broken = 0
    }

    /// First half of the restore: opens the stored tabs in order (the empty starter tab is reused for the first one).
    /// Files that are gone or unreadable are skipped and counted.
    func openSessionTabs(_ state: SessionState) -> SessionOpened {
        var result = SessionOpened()
        for (i, path) in state.tabs.enumerated() {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { result.missing += 1; continue }
            do { result.ids[i] = try openTab(url, noteRecent: false).id } catch { result.broken += 1 }
        }
        return result
    }

    /// Second half: active tab, split and the status message about skipped files. Starts the session tracking.
    func finishSessionRestore(_ state: SessionState, opened: SessionOpened) {
        let firstOpen = opened.ids.keys.min().flatMap { opened.ids[$0] }
        if let id = opened.ids[state.activeIndex] ?? firstOpen { activate(id) }
        if let sp = state.split, let left = opened.ids[state.activeIndex], let right = opened.ids[sp.rightIndex], left != right {
            activate(left)
            startCompare(with: right)
            compare?.axis = SplitAxis(rawValue: sp.axis.rawValue) ?? .sideBySide
            compare?.leftContent = PaneContent(rawValue: sp.leftContent.rawValue) ?? .plan
            compare?.rightContent = PaneContent(rawValue: sp.rightContent.rawValue) ?? .plan
            compare?.focus = sp.focus == .right ? .right : .left
        }
        let skipped = opened.missing + opened.broken
        if skipped > 0 {
            let n = skipped == 1 ? "1 project" : "\(skipped) projects"
            active.statusMessage = opened.broken == 0 ? "\(n) from the last session could not be found"
                                                       : "\(n) from the last session could not be opened"
        }
        sessionTracking = true
        persistSession()
    }

    // MARK: Compare

    var compareCandidates: [AppModel] { tabs.filter { $0.id != activeId } }

    /// Shows the active project and `other` next to each other.
    func startCompare(with other: UUID) {
        guard other != activeId, model(other) != nil else { return }
        let axis = compare?.axis ?? .sideBySide
        compare = CompareState(rightId: other, axis: axis)
    }

    func endCompare() { compare = nil }

    func setFocus(_ side: CompareSide) { if compare != nil, compare?.focus != side { compare?.focus = side } }

    // MARK: Transfer between projects

    /// Resolves a drag payload to the source project and token, nil when the project is gone.
    func resolve(payload: String) -> (source: AppModel, token: TransferToken)? {
        guard let t = TransferToken(payload: payload), let m = model(t.sourceId) else { return nil }
        return (m, t)
    }

    /// Copies or moves furniture into `target` (its active level). `point` puts the middle of the furniture there
    /// (drops); nil keeps the plan positions. Each side gets one undo step; a failed delete in a move leaves the copy.
    @discardableResult
    func transfer(ids: [UUID], from source: AppModel, to target: AppModel, move: Bool, at point: P2? = nil,
                  options: CommandOptions = .user) throws -> FurnitureTransferService.Outcome {
        guard source !== target else { throw CommandError.invalid("Choose a different project as the target") }
        guard let level = target.activeLevel else { throw CommandError.invalid("The target project has no level") }
        var offset = P2(0, 0)
        var prebuilt: FurnitureTransfer?
        if let point {
            let t = try FurnitureTransfer.make(from: source.project, ids: ids, packageURL: source.fileURL)
            if let c = t.center { offset = P2(point.x - c.x, point.y - c.y) }
            prebuilt = t
        }
        let outcome: FurnitureTransferService.Outcome
        if move {
            outcome = try FurnitureTransferService.move(ids: ids, from: source.store, sourcePackage: source.fileURL, to: target.store,
                                                        targetPackage: target.fileURL, levelId: level.id, offset: offset, options: options, prebuilt: prebuilt)
        } else {
            outcome = try FurnitureTransferService.copy(ids: ids, from: source.store, sourcePackage: source.fileURL, to: target.store,
                                                        targetPackage: target.fileURL, levelId: level.id, offset: offset, options: options, prebuilt: prebuilt)
        }
        target.selection = Set(outcome.newIds)
        target.lastError = nil
        let n = outcome.newIds.count
        let what = n == 1 ? "1 object" : "\(n) objects"
        if move, outcome.sourceRemoved {
            source.pruneSelection()
            source.lastError = nil
            source.statusMessage = "Moved \(what) to \(target.project.name)"
            target.statusMessage = "Moved \(what) from \(source.project.name)"
        } else if move {
            // The copy stands; the originals are still in the source.
            source.lastError = "Copied \(what) to \(target.project.name), but could not remove the originals: \(outcome.deleteError ?? "unknown error")"
            target.statusMessage = "Copied \(what) from \(source.project.name); the originals stay there"
        } else {
            source.statusMessage = "Copied \(what) to \(target.project.name)"
            target.statusMessage = "Copied \(what) from \(source.project.name)"
        }
        return outcome
    }

    /// GUI wrapper: failures go to the status bar of the source project.
    @discardableResult
    func transferReportingErrors(ids: [UUID], from source: AppModel, to target: AppModel, move: Bool, at point: P2? = nil) -> Bool {
        do { try transfer(ids: ids, from: source, to: target, move: move, at: point); return true } catch {
            source.lastError = userMessage(for: error)
            NSSound.beep()
            return false
        }
    }

    /// Furniture and groups among `ids` (what can travel).
    func transferable(_ ids: [UUID], in m: AppModel) -> [UUID] {
        ids.filter { id in m.project.instances.contains { $0.id == id } || m.project.groups.contains { $0.id == id } }
    }

    // MARK: Clipboard (⌘C / ⌘V)

    func copySelection(of m: AppModel) {
        let ids = transferable(m.selectionIds, in: m)
        guard !ids.isEmpty else { return }
        do {
            let t = try FurnitureTransfer.make(from: m.project, ids: ids, packageURL: m.fileURL)
            let token = TransferToken(sourceId: m.id, ids: ids).payload
            clipboard = t
            clipboardToken = token
            pasteCount = 0
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(token, forType: .string)
            m.statusMessage = "Copied \(t.instances.count) object(s)"
            m.lastError = nil
        } catch {
            m.lastError = userMessage(for: error)
            NSSound.beep()
        }
    }

    /// True while the workspace clipboard is what the pasteboard still points at.
    var canPaste: Bool {
        guard clipboard != nil, let token = clipboardToken else { return false }
        return NSPasteboard.general.string(forType: .string) == token
    }

    func paste(into m: AppModel) {
        guard canPaste, let t = clipboard, let level = m.activeLevel else { return }
        pasteCount += 1
        // Pasting into the project it came from would land exactly on the originals: step it aside.
        let sameProject = clipboardToken.flatMap(TransferToken.init(payload:)).map { $0.sourceId == m.id } ?? false
        let step = Int64(300 * pasteCount)
        do {
            let ids = try FurnitureTransferService.importTransfer(t, into: m.store, targetPackage: m.fileURL, levelId: level.id,
                                                                  offset: sameProject ? P2(step, step) : P2(0, 0))
            m.selection = Set(ids)
            m.lastError = nil
            m.statusMessage = "Pasted \(ids.count) object(s)"
        } catch {
            m.lastError = userMessage(for: error)
            NSSound.beep()
        }
    }
}

// MARK: - Agent bridge

extension Workspace: AgentWorkspaceBridge {
    func workspaceTabs() -> [AgentWorkspaceTab] {
        tabs.map { m in
            AgentWorkspaceTab(id: m.id, projectId: m.project.id, name: m.project.name, path: m.fileURL?.path, dirty: m.store.isDirty,
                              active: m.id == activeId, inCompare: compare != nil && (m.id == activeId || m.id == compare?.rightId))
        }
    }

    func workspaceActivate(_ id: UUID) throws {
        guard model(matching: id) != nil else { throw Workspace.notOpen(id) }
        activate(model(matching: id)!.id)
    }

    func workspaceOpen(_ url: URL?) throws -> UUID {
        guard let url else { return newProject().id }
        return try openTab(url).id
    }

    func workspaceClose(_ id: UUID, discard: Bool) throws {
        guard let m = model(matching: id) else { throw Workspace.notOpen(id) }
        try closeForAgent(m.id, discard: discard)
    }

    func workspaceProject(_ id: UUID) -> Project? { model(matching: id)?.project }

    func workspaceShowCompare(left: UUID, right: UUID, arrangement: AgentArrangement?) throws {
        guard let l = model(matching: left) else { throw Workspace.notOpen(left) }
        guard let r = model(matching: right) else { throw Workspace.notOpen(right) }
        guard l !== r else { throw AgentError(code: AgentError.invalidArgument, message: "Compare needs two different projects") }
        activate(l.id)
        startCompare(with: r.id)
        if let arrangement { compare?.axis = arrangement == .stacked ? .stacked : .sideBySide }
    }

    func workspaceTransfer(ids: [UUID], from source: DocumentStore, to target: UUID, move: Bool, clientId: String) throws -> AgentTransferOutcome {
        guard let src = tabs.first(where: { $0.store === source }) else {
            throw AgentError(code: AgentError.internal, message: "The project the call ran on is no longer open")
        }
        guard let dst = model(matching: target) else { throw Workspace.notOpen(target) }
        let o = try transfer(ids: ids, from: src, to: dst, move: move, options: CommandOptions(origin: .agent(clientId)))
        return AgentTransferOutcome(targetName: dst.project.name, newIds: o.newIds, moved: o.sourceRemoved, deleteError: o.deleteError)
    }
}
