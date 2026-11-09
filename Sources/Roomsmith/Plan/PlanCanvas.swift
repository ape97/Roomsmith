import AppKit
import simd
import RoomsmithCore

/// Handles shown on a single selected object.
enum PlanHandle: Equatable {
    case wallStart(UUID), wallEnd(UUID)
    case roomVertex(UUID, Int)
    case dimA(UUID), dimB(UUID), dimOffset(UUID)
    case rotate(UUID)
}

/// Body drag of the selection (live preview, one command on mouse-up).
struct PlanMoveDrag {
    var ids: [UUID]
    var anchorId: UUID
    var startModel: V2
    var started = false
    /// Click on an already selected item of a multi-selection: narrows to it on mouse-up without a drag.
    var narrowTo: UUID?
    var delta = P2(0, 0)
    var guides: [SnapGuide] = []
    /// Contact stop of furniture and groups, built once when the drag starts (changes made meanwhile count from the
    /// next drag). Nil for walls, rooms, openings and mixed selections.
    var contact: PlanContact?
    /// Height a single dragged piece takes from the furniture under it, built once when the drag starts. Nil for groups
    /// and selections of several objects (they keep their height).
    var rest: RestingDrag?
    /// Height change of the piece against the start (mm), applied with the move.
    var dz: MM = 0
}

/// What a furniture drag in the plan stops at: the footprints that move and the obstacles they must not enter.
struct PlanContact {
    var bodies: [ContactBody]
    var obstacles: [ContactObstacle]
}

/// Drag of a handle (wall end, room vertex, dimension point/offset, rotation).
struct PlanHandleDrag {
    var handle: PlanHandle
    var startModel: V2
    var started = false
    var target = P2(0, 0)
    /// Rotation: pivot, angle of the mouse at drag start (for a trackpad gesture: the accumulated gesture angle),
    /// rotation at drag start, new delta in degrees.
    var pivot = V2(0, 0)
    var startAngle = 0.0
    var startRotation = 0.0
    var rotationDelta = 0.0
    /// Trackpad rotation gesture (no mouse button involved) and the objects frozen at its start.
    var gesture = false
    var ids: [UUID] = []
    var guides: [SnapGuide] = []
}

/// Proposed door/window/opening under the pointer.
struct PlanOpeningProposal {
    var wallId: UUID
    var opening: Opening
    var item: PlanOpeningItem
}

@MainActor
final class PlanNSView: NSView {
    let model: AppModel

    // Viewport and scene
    var vp = PlanViewport() {
        didSet {
            guard vp != oldValue else { return }
            publishViewport()
            if remembersViewport { model.savedPlanViewport = (model.project.id, vp) }
        }
    }
    /// Only the on-screen view keeps its viewport in the model (the presenter's offscreen view must not).
    private var remembersViewport = false
    var lastViewRequest = 0
    var cached: PlanScene?
    var preview: PlanScene?
    var didInitialFit = false
    /// Viewport right after the last whole-plan fit. While the user has not panned or zoomed since (the viewport still
    /// equals it), a resize fits again, so a growing window does not leave the plan tiny in a corner.
    private var fittedView: (center: V2, scale: Double)?
    var fittedProjectId: UUID?
    var lastFrameRequest = 0
    var lastTool: EditorTool = .select
    var lastRevision: Int64 = 0
    var lastLevelId: UUID?

    // Pointer
    var mouse: CGPoint?
    var mouseModel: V2?
    var spaceDown = false
    var panning = false
    var lastPanPoint = CGPoint.zero

    // Select tool
    var moveDrag: PlanMoveDrag?
    var handleDrag: PlanHandleDrag?
    var marquee: (start: CGPoint, current: CGPoint, additive: Bool)?
    var hoverHandle: PlanHandle?
    var resignObserver: NSObjectProtocol?
    var dragBaseColliding: Set<UUID> = []
    /// Library item dragged over the plan (drop preview).
    var dropState: PlanDropState?
    /// Outline of a library entry being dragged over the plan (centre and size in mm).
    var libraryDrop: (center: P2, size: Size3)?

    // Drawing tools
    var wallPoints: [P2] = []
    var wallInput = ""
    var roomPoints: [P2] = []
    var snapResult: SnapResult?
    var proposal: PlanOpeningProposal?
    var flipHinge = false
    var dimA: P2?
    var dimB: P2?
    var dimOffset: MM = 300
    var measureA: P2?
    var measureB: P2?
    var calA: P2?
    var calB: P2?

    // Misc
    var hint: String?
    var images: [UUID: NSImage?] = [:]
    var imagesFor: URL?
    var textCache: [String: NSAttributedString] = [:]
    /// Screen boxes of the dimension texts drawn in the current pass (see `PlanLabelFit`); cleared per pass.
    var dimLabelBoxes: [PlanLabelFit.Box] = []

    init(model: AppModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        layer?.drawsAsynchronously = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Floor plan")
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        registerForDraggedTypes(Self.dropTypes)
    }

    /// Takes over the viewport this project had when its tab was last shown, then starts remembering changes.
    func restoreViewport() {
        if let saved = model.savedPlanViewport, saved.projectId == model.project.id {
            vp = saved.viewport
            didInitialFit = true
            fittedProjectId = model.project.id
        }
        remembersViewport = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Project access

    var project: Project { model.project }
    var levelId: UUID { model.activeLevel?.id ?? model.activeLevelId }

    /// Scene of the document; rebuilt only when the revision, project or level changes.
    var baseScene: PlanScene {
        let p = model.project
        let key = PlanSceneKey(projectId: p.id, revision: model.store.contentRevision, levelId: levelId)
        if let c = cached, c.key == key { return c }
        let s = PlanScene.build(p, revision: key.revision, levelId: key.levelId, full: true)
        cached = s
        return s
    }

    /// What is drawn: the live preview during a drag, otherwise the document scene.
    var displayScene: PlanScene { preview ?? baseScene }

    // MARK: SwiftUI sync

    func sync(projectId: UUID, revision: Int64, levelId: UUID, tool: EditorTool, frameRequest: Int, viewRequest: PlanViewRequest? = nil) {
        if fittedProjectId != projectId {
            fittedProjectId = projectId
            cancelInteraction(clearSelection: false)
            didInitialFit = false
            images.removeAll()
        }
        if tool != lastTool {
            cancelInteraction(clearSelection: false)
            lastTool = tool
            hint = nil
            window?.invalidateCursorRects(for: self)
        }
        if revision != lastRevision || levelId != lastLevelId {
            if (moveDrag?.started ?? false) || (handleDrag?.started ?? false), revision != lastRevision {
                cancelDrags()
            }
            if levelId != lastLevelId, lastLevelId != nil { cancelInteraction(clearSelection: false) }
            lastRevision = revision
            lastLevelId = levelId
            proposal = nil
            pruneBackgroundImages()
        }
        if let h = handleDrag, h.gesture, Set(h.ids) != model.selection { cancelDrags() }
        if frameRequest != lastFrameRequest {
            lastFrameRequest = frameRequest
            fit(selectionOnly: true)
        }
        if let r = viewRequest, r.serial != lastViewRequest {
            lastViewRequest = r.serial
            applyViewRequest(r)
        }
        if !didInitialFit, vp.size.width > 10 { fit(selectionOnly: false) }
        needsDisplay = true
    }

    /// Tells the model where the plan is looking (read by the agent `view.get`).
    private func publishViewport() {
        model.planViewport = AgentPlanViewport(centerX: Int64(vp.center.x.rounded()), centerY: Int64(vp.center.y.rounded()),
                                               mmPerPoint: 1 / vp.scale)
    }

    private func applyViewRequest(_ r: PlanViewRequest) {
        guard vp.size.width > 10, vp.size.height > 10 else { return }
        if let v = r.viewport {
            vp.center = V2(Double(v.centerX), Double(v.centerY))
            vp.scale = min(max(1 / v.mmPerPoint, PlanViewport.minScale), PlanViewport.maxScale)
            didInitialFit = true
            needsDisplay = true
        } else if let f = r.fit {
            fit(selectionOnly: f == .selection)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        vp.size = newSize
        let untouched = fittedView.map { $0.center == vp.center && $0.scale == vp.scale } ?? false
        if !didInitialFit || untouched, newSize.width > 10, newSize.height > 10 { fit(selectionOnly: false) }
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let o = resignObserver { NotificationCenter.default.removeObserver(o); resignObserver = nil }
        if let w = window {
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelDrags() }
            }
            lastFrameRequest = model.frameSelectionRequest
            lastViewRequest = model.planViewRequest?.serial ?? 0
            publishViewport()
            lastTool = model.tool
            lastRevision = model.store.contentRevision
            lastLevelId = levelId
            fittedProjectId = model.project.id
            if vp.size.width > 10, !didInitialFit { fit(selectionOnly: false) }
        } else {
            model.planViewport = nil
        }
    }

    override func resetCursorRects() {
        let cursor: NSCursor = switch model.tool {
        case .select: .arrow
        case .hand: panning ? .closedHand : .openHand
        default: .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }

    // MARK: View operations

    func fit(selectionOnly: Bool) {
        guard vp.size.width > 10, vp.size.height > 10 else { return }
        let sc = baseScene
        var lo: V2?, hi: V2?
        func add(_ l: V2, _ h: V2) {
            lo = lo.map { simd_min($0, l) } ?? l
            hi = hi.map { simd_max($0, h) } ?? h
        }
        if selectionOnly, !model.selection.isEmpty {
            for id in model.selection {
                if let r = sc.byId[id] { add(r.lo, r.hi) }
                else if let b = project.background(id), let ext = backgroundExtent(b) { add(ext.lo, ext.hi) }
            }
        }
        if lo == nil {
            if let b = sc.bounds { add(b.lo, b.hi) }
            for bg in project.backgrounds where bg.levelId == levelId && bg.visible {
                if let ext = backgroundExtent(bg) { add(ext.lo, ext.hi) }
            }
        }
        if let lo, let hi { vp.fit(lo: lo, hi: hi) } else { vp.fit(lo: V2(0, 0), hi: V2(8000, 6000)) }
        fittedView = selectionOnly && !model.selection.isEmpty ? nil : (vp.center, vp.scale)
        didInitialFit = true
        needsDisplay = true
    }

    func zoom(by factor: Double, around p: CGPoint) {
        vp.zoom(by: factor, around: p)
        refreshPointer()
        needsDisplay = true
    }

    /// Recomputes pointer-dependent values after the view moved under a stationary pointer.
    func refreshPointer() {
        guard let m = mouse else { return }
        mouseModel = vp.model(m)
        publishCursor()
    }

    func publishCursor() {
        let c = mouseModel.map { P2(rounding: $0) }
        if model.cursorPoint != c { model.cursorPoint = c }
    }

    func setHover(_ id: UUID?) {
        if model.hoveredId != id { model.hoveredId = id }
    }

    // MARK: Cancel

    func cancelDrags() {
        if let d = moveDrag, d.started { model.store.endInteraction(expandedIds(d.ids)) }
        if let h = handleDrag, h.started { model.store.endInteraction(handleIds(h)) }
        moveDrag = nil
        handleDrag = nil
        marquee = nil
        preview = nil
        panning = false
        needsDisplay = true
    }

    func cancelInteraction(clearSelection: Bool) {
        cancelDrags()
        wallPoints = []; wallInput = ""
        roomPoints = []
        dimA = nil; dimB = nil
        measureA = nil; measureB = nil
        calA = nil; calB = nil
        proposal = nil
        snapResult = nil
        hint = nil
        if clearSelection, !model.selection.isEmpty { model.selection = [] }
        needsDisplay = true
    }

    // MARK: Text helper

    func attributed(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, mono: Bool = false) -> NSAttributedString {
        let key = "\(text)|\(size)|\(weight.rawValue)|\(color.hashValue)|\(mono)"
        if let c = textCache[key] { return c }
        let font = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        if textCache.count > 600 { textCache.removeAll() }
        textCache[key] = s
        return s
    }
}
