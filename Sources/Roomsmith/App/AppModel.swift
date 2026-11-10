import AppKit
import Foundation
import Observation
import RoomsmithCore

/// Editor tools of the 2D plan.
public enum EditorTool: String, CaseIterable, Identifiable, Sendable {
    case select, hand, wall, room, door, window, opening, dimension, measure, calibrate
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .select: "Select (V)"; case .hand: "Hand (H)"; case .wall: "Wall"; case .room: "Room"; case .door: "Door"
        case .window: "Window"; case .opening: "Opening"; case .dimension: "Dimension"
        case .measure: "Measure"; case .calibrate: "Calibrate background"
        }
    }
    public var symbol: String {
        switch self {
        case .select: "cursorarrow"; case .hand: "hand.raised"; case .wall: "line.diagonal"; case .room: "square.dashed"
        case .door: "door.left.hand.open"; case .window: "window.vertical.closed"; case .opening: "rectangle.portrait"
        case .dimension: "ruler"; case .measure: "ruler.fill"; case .calibrate: "scope"
        }
    }

    /// Whether the tool does anything in the given layout. The 3D view only selects, looks (Hand) and measures;
    /// drawing and dimensioning tools work on the plan. Plan and split layouts offer every tool.
    public func isAvailable(in layout: ViewLayout) -> Bool {
        switch layout {
        case .plan, .split: true
        case .scene: self == .select || self == .hand || self == .measure
        }
    }

    /// Tooltip of the tool; says why it is greyed out when it is not available in the layout.
    public func help(in layout: ViewLayout) -> String {
        isAvailable(in: layout) ? title : "\(title) – available in the plan view"
    }

    /// The tools shown in the toolbar (calibrating the background scale starts from the inspector or the File menu).
    public static var pickerTools: [EditorTool] { allCases.filter { $0 != .calibrate } }
}

/// Which editors are visible in the main window.
public enum ViewLayout: String, CaseIterable, Identifiable, Sendable {
    case split, plan, scene
    public var id: String { rawValue }
    public var title: String { switch self { case .split: "Plan + 3D"; case .plan: "Plan"; case .scene: "3D" } }
    public var symbol: String { switch self { case .split: "rectangle.split.2x1"; case .plan: "map"; case .scene: "cube" } }
}

/// Sheets presented by the main window.
public enum AppSheet: Identifiable, Sendable {
    /// Parametric furniture builder; nil = new definition.
    case furnitureBuilder(UUID?)
    /// File > Export > Reports…
    case reports
    /// Furniture from photos; with an entry id the photos improve that library entry.
    case photoToFurniture(improve: UUID?)
    /// The furniture builder, prefilled from a photo proposal; it can save into the AI section of the library.
    case photoBuilder(PhotoBuilderDraft)
    public var id: String {
        switch self {
        case .furnitureBuilder(let d): "builder-\(d?.uuidString ?? "new")"
        case .reports: "reports"
        case .photoToFurniture(let e): "photo-\(e?.uuidString ?? "new")"
        case .photoBuilder(let d): "photo-builder-\(d.id.uuidString)"
        }
    }
}

/// A viewport change for the plan editor: either a fixed viewport or fit to everything / the selection.
struct PlanViewRequest: Equatable {
    var serial: Int
    var viewport: AgentPlanViewport?
    var fit: AgentPlanFit?
}

/// Agent request to move the 3D view into its own window or back (`view.set detach3D`). ContentView carries it out
/// with the same window actions as the View menu, because only a view can open and close scene windows.
struct SceneWindowRequest: Equatable {
    var serial: Int
    var detach: Bool
}

/// App-wide UI state around the single open document. All document changes go through `store`.
@MainActor @Observable
public final class AppModel: Identifiable {
    /// Identifies the open project (tab) for the life of this model; the document id changes with every new file.
    public nonisolated let id = UUID()
    public let store: DocumentStore
    public var fileURL: URL?
    public var selection: Set<UUID> = [] {
        didSet { if !selectingForAgent && !newItems.isEmpty && !selection.isEmpty { newItems.markSeen(selection) } }
    }
    /// True while the agent sets the selection (`scene.select_objects`): that is not the user looking at the objects.
    private var selectingForAgent = false
    public func setSelectionByAgent(_ ids: Set<UUID>) {
        selectingForAgent = true
        defer { selectingForAgent = false }
        selection = ids
    }
    /// Objects an AI agent added while this project was open; their rows show a "New" badge until selected. Runtime only.
    var newItems = NewItemTracker()
    public var activeLevelId: UUID
    public var tool: EditorTool = .select
    /// Window-wide view settings, shared by every open project (owned by the workspace). The properties below
    /// forward to it, so a change in one tab shows in all of them.
    public let prefs: WindowPrefs
    /// Which editors are shown. Remembered between launches.
    public var layout: ViewLayout { get { prefs.layout } set { prefs.layout = newValue } }
    /// The floating camera and display controls of the 3D view. SceneView reads this flag (see docs/DEVELOPMENT.md).
    public var showSceneControls: Bool { get { prefs.showSceneControls } set { prefs.showSceneControls = newValue } }
    /// 3D display options (View settings of the scene, not part of the document). Remembered between launches.
    public var showCeilings: Bool { get { prefs.showCeilings } set { prefs.showCeilings = newValue } }
    public var showLamps: Bool { get { prefs.showLamps } set { prefs.showLamps = newValue } }
    public var onlyActiveLevel: Bool { get { prefs.onlyActiveLevel } set { prefs.onlyActiveLevel = newValue } }
    public var wallOpacity: Double { get { prefs.wallOpacity } set { prefs.wallOpacity = newValue } }
    /// Selected tab of the sidebar. Remembered between launches.
    var sidebarTab: SidebarTab { get { prefs.sidebarTab } set { prefs.sidebarTab = newValue } }
    /// Live lighting while a Light slider is dragged: shown by the 3D views, never saved and not undoable. The slider
    /// commits one undoable command on release and clears it.
    var lightPreview: LightingSettings?
    func previewLight(_ value: Double?, _ apply: (inout LightingSettings, Double) -> Void) {
        guard let value else { lightPreview = nil; return }
        var s = lightPreview ?? project.settings.lighting
        apply(&s, value)
        if s != lightPreview { lightPreview = s }
    }
    /// Pending request for the plan editor to move its viewport (agent `view.set`). The editor applies a request once
    /// (by serial) and ignores requests that were made while it was not shown.
    var planViewRequest: PlanViewRequest?
    /// Pending request to open or close the separate 3D window (agent `view.set`); handled once by ContentView.
    var sceneWindowRequest: SceneWindowRequest?
    /// Detach state requested by an agent and not yet applied by the 3D window (nil when none is pending).
    @ObservationIgnored var pendingDetach: Bool?
    /// Set by an agent that docks the 3D view and asks for the plan only: the closing window keeps that layout.
    @ObservationIgnored var keepPlanOnDock = false
    /// Last viewport the plan editor reported. Not observed: nothing redraws because of it.
    @ObservationIgnored var planViewport: AgentPlanViewport?
    /// Window and 3D bridge for the agent view and render tools (see AppViewBridge).
    @ObservationIgnored var agentViewBridge: AppViewBridge?
    /// Agent panel sheet (not remembered: a sheet that reopens by itself at launch would be in the way).
    public var showAgentPanel = false
    /// Presenter sheet (toolbar button, View > Present…).
    public var showPresenter = false
    /// Presenter (AirPlay / HLS); created when the main window appears. Nothing listens until the user presses Start.
    var presenter: PresenterEngine?
    /// Last error shown in the status bar (cleared on the next successful command).
    public var lastError: String?
    /// Short status line (e.g. "Saved").
    public var statusMessage: String?
    /// Snap toggles that are UI-only (temporarily off while ⌥ is held).
    public var snapSuspended = false
    /// Agent bridge, created by the app on launch (see AgentHost).
    /// Forwards to the workspace: one host serves every open project.
    @ObservationIgnored public var agentHost: AnyObject? {
        get { workspace?.agentHost ?? ownAgentHost }
        set { if let h = newValue as? AgentHost, let workspace { workspace.agentHost = h } else { ownAgentHost = newValue } }
    }
    @ObservationIgnored private var ownAgentHost: AnyObject?
    /// Plan view of this project (kept when its tab is hidden and shown again).
    @ObservationIgnored var savedPlanViewport: (projectId: UUID, viewport: PlanViewport)?
    /// Recovery copies while there are unsaved changes (see Autosave).
    @ObservationIgnored var autosave: Autosave?
    /// Object under the pointer in plan or 3D (for hover highlight in both views).
    public var hoveredId: UUID?
    /// Pointer position in plan coordinates (mm), shown in the status bar.
    public var cursorPoint: P2?
    /// Incremented to ask plan and 3D to frame the current selection.
    public var frameSelectionRequest = 0
    /// Modal sheet of the main window.
    public var sheet: AppSheet?

    /// The workspace this project is open in (nil for a standalone model, e.g. in tests).
    @ObservationIgnored weak var workspace: Workspace?

    public init(project: Project = AppModel.starterProject(), prefs: WindowPrefs? = nil) {
        self.prefs = prefs ?? WindowPrefs()
        store = DocumentStore(project: project)
        activeLevelId = project.levels.first?.id ?? UUID()
        store.addObserver { [weak self] event in self?.newItems.apply(event) }
    }

    public var project: Project { store.project }
    public var activeLevel: Level? { project.level(activeLevelId) ?? project.levels.first }

    /// Runs a user command and turns errors into a status message. Returns false on failure.
    @discardableResult
    public func perform(_ name: String, options: CommandOptions = .user, _ edit: (inout Project) throws -> Void) -> Bool {
        do {
            try store.run(name, options: options, edit)
            lastError = nil
            pruneSelection()
            return true
        } catch {
            lastError = userMessage(for: error)
            NSSound.beep()
            return false
        }
    }

    public func pruneSelection() {
        let ids = Set(project.allIds)
        selection = selection.filter { ids.contains($0) }
        if project.level(activeLevelId) == nil, let f = project.levels.first { activeLevelId = f.id }
    }

    public func undo() { do { try store.undo(); pruneSelection() } catch { lastError = userMessage(for: error) } }
    public func redo() { do { try store.redo(); pruneSelection() } catch { lastError = userMessage(for: error) } }

    // MARK: Files

    public var windowTitle: String {
        (fileURL?.deletingPathExtension().lastPathComponent ?? project.name) + (store.isDirty ? " — Edited" : "")
    }

    /// File > New: a new tab in the workspace (a standalone model replaces its own project after asking).
    public func newProject() {
        if let workspace { workspace.newProject(); return }
        guard confirmDiscard() else { return }
        load(AppModel.starterProject(), url: nil)
    }

    public func load(_ p: Project, url: URL?) {
        store.replaceProject(p)
        fileURL = url
        selection = []
        activeLevelId = store.project.levels.first?.id ?? UUID()
    }

    /// Dock menu and the workspace's own Open Recent list.
    func noteRecent(_ url: URL) {
        if let workspace { workspace.noteRecentProject(url) } else { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
    }

    public func open(_ url: URL) {
        if let workspace { workspace.open(url); return }
        do {
            let (p, warnings) = try ProjectPackage.load(from: url)
            load(p, url: url)
            noteRecent(url)
            statusMessage = warnings.isEmpty ? "Opened \(url.lastPathComponent)" : "Opened with \(warnings.count) warning(s): \(warnings.joined(separator: "; "))"
        } catch {
            lastError = "Could not open \(url.lastPathComponent): \(userMessage(for: error))"
        }
    }

    public func openWithPanel() {
        if let workspace { workspace.openWithPanel(); return }
        guard confirmDiscard() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Choose a .roomsmith project"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    @discardableResult
    public func save() -> Bool {
        guard let url = fileURL else { return saveAs() }
        return write(to: url)
    }

    @discardableResult
    public func saveAs() -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (fileURL?.deletingPathExtension().lastPathComponent ?? project.name) + ".\(ProjectPackage.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, var url = panel.url else { return false }
        if url.pathExtension != ProjectPackage.fileExtension { url.appendPathExtension(ProjectPackage.fileExtension) }
        return write(to: url)
    }

    @discardableResult
    public func write(to url: URL) -> Bool {
        do {
            try ProjectPackage.save(project, to: url, copyingAssetsFrom: fileURL)
            fileURL = url
            store.markSaved()
            autosave?.discard()
            noteRecent(url)
            statusMessage = "Saved \(url.lastPathComponent)"
            return true
        } catch {
            lastError = "Could not save: \(userMessage(for: error))"
            return false
        }
    }

    /// Asks before throwing away unsaved changes. Returns true if it is fine to continue.
    public func confirmDiscard() -> Bool {
        guard store.isDirty, !AppDefaults.isTestMode else { return true }
        let a = NSAlert()
        a.messageText = "Save changes to “\(windowTitle.replacingOccurrences(of: " — Edited", with: ""))”?"
        a.informativeText = "Your changes will be lost if you don't save them."
        a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel"); a.addButton(withTitle: "Don't Save")
        switch a.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: autosave?.discard(); return true
        default: return false
        }
    }

    /// A new project: one level, default materials, and the built-in furniture definitions available on demand.
    public static func starterProject() -> Project {
        var p = Project.empty(name: "Untitled")
        p.materials = BuiltinCatalog.materials
        return p
    }
}
