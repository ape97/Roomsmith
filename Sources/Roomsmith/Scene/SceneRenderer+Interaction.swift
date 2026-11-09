import AppKit
import Foundation
import RealityKit
import RoomsmithCore
import simd

// Input handling of the 3D view. `SceneARView` forwards raw events here; everything below works on view points with
// the origin at the bottom left, so it can be exercised without an NSView.

/// A mouse press that may still turn out to be a click (it becomes a camera drag after a few points of travel).
struct PendingClick {
    var point: SIMD2<Double>
    var shift: Bool
    /// Set when the press is on an already selected piece of furniture: dragging moves it over the floor.
    var furnitureId: UUID?
    /// The press happened with the Hand tool or Space held: releasing Space before the mouse must not select.
    var handPress = false
    /// The press happened with the Measure tool: a click (no drag) sets a measuring point; a drag still orbits.
    var measurePress = false
}

/// State of a running gizmo drag. The entities show a live preview; the document is only touched on release.
struct GizmoDrag {
    var handle: GizmoHandle
    var origin: D3
    /// Objects the command acts on (groups are expanded by the command itself).
    var ids: [UUID]
    /// Objects whose entities move in the preview (groups expanded).
    var expanded: [UUID]
    var bases: [(entity: Entity, matrix: simd_float4x4)]
    var startParam = 0.0
    var startAngle = 0.0
    /// Absolute rotation of a single piece of furniture or group, so its angle can snap to the step.
    var startRotation: Double?
    var pivot: P2
    /// Current snapped value: mm along the axis, or degrees.
    var delta = 0.0
    /// X/Y axis drag of furniture and groups: what the move stops at (see `GizmoContact`). Nil otherwise.
    var contact: GizmoContact?
    /// Z axis drag of furniture and groups: the heights it is drawn to (see `GizmoVertical`). Nil otherwise.
    var vertical: GizmoVertical?
}

/// Footprints and obstacles of an axis drag, built once when the drag starts.
struct GizmoContact {
    var bodies: [ContactBody]
    var obstacles: [ContactObstacle]
    var depth: Double
}

struct GizmoVertical {
    var contact: VerticalContact
    var depth: Double
}

enum DragState {
    case camera
    case gizmo(GizmoDrag)
    case furnitureMove(FurnitureMoveDrag)
}

/// What the gizmo would act on.
struct GizmoTargets {
    var ids: [UUID]
    var handles: Set<GizmoHandle>
    var origin: D3
    var startRotation: Double?
}

extension SceneRenderer {
    /// Movement in points before a press stops being a click.
    static let clickSlop = 3.0

    // MARK: Geometry helpers

    func ray(at p: SIMD2<Double>) -> (origin: D3, dir: D3) {
        let size = camera.viewSize
        guard size.width > 0, size.height > 0 else { return (camera.rig.eye, camera.rig.forward) }
        let ndc = SIMD2(2 * p.x / Double(size.width) - 1, 2 * p.y / Double(size.height) - 1)
        return camera.rig.ray(ndc: ndc, aspect: Double(size.width / size.height))
    }

    /// Nearest pickable object along a ray: shown levels and shown pieces only (lamps are skipped while "Lamps" is off).
    func pickNearest(origin: D3, dir: D3) -> PickIndex.Hit? {
        let p = model.project
        let lamps = options.showLamps ? [] : p.lampDefinitionIds
        return pickIndex.pick(origin: origin, dir: dir, project: p, levelShown: { levelShown($0) },
                              instanceShown: { !lamps.contains($0.definitionId) })
    }

    func pickHit(at p: SIMD2<Double>) -> PickIndex.Hit? {
        let r = ray(at: p)
        return pickNearest(origin: r.origin, dir: r.dir)
    }

    /// The point under the cursor that zoom keeps in place: the picked surface, else the ground plane at target height.
    func focus(at p: SIMD2<Double>) -> (point: D3?, dir: D3) {
        let r = ray(at: p)
        if let hit = pickNearest(origin: r.origin, dir: r.dir) {
            return (r.origin + r.dir * hit.t, r.dir)
        }
        if abs(r.dir.z) > 1e-6 {
            let t = (camera.rig.target.z - r.origin.z) / r.dir.z
            if t > 0 { return (r.origin + r.dir * t, r.dir) }
        }
        return (nil, r.dir)
    }

    var activeElevation: Double {
        Double(model.project.level(model.activeLevelId)?.elevation ?? 0)
    }

    // MARK: Bounds

    func bounds(of id: UUID) -> Bounds3? {
        let p = model.project
        if let i = p.instance(id) {
            guard i.visible, levelShown(i.levelId), instanceShown(i) else { return nil }
            return pickIndex.entry(for: i, project: p)?.bounds
        }
        if let g = p.group(id) {
            var out: Bounds3?
            for m in g.memberIds { if let b = bounds(of: m) { if out == nil { out = b } else { out!.extend(b) } } }
            return out
        }
        if let w = p.wall(id), let level = p.level(w.levelId), levelShown(level.id) {
            let half = Double(w.thickness) / 2
            let z0 = Double(level.elevation), z1 = z0 + Double(w.height)
            var b = Bounds3.around(D3(Double(w.start.x), Double(w.start.y), z0))
            b.extend(D3(Double(w.end.x), Double(w.end.y), z1))
            b.lo -= D3(half, half, 0)
            b.hi += D3(half, half, 0)
            return b
        }
        if let r = p.room(id), let level = p.level(r.levelId), levelShown(level.id), !r.points.isEmpty {
            let z = Double(level.elevation)
            var b = Bounds3.around(D3(Double(r.points[0].x), Double(r.points[0].y), z))
            for pt in r.points { b.extend(D3(Double(pt.x), Double(pt.y), z)) }
            return b
        }
        return nil
    }

    func selectionBounds() -> Bounds3? {
        var out: Bounds3?
        for id in model.selection {
            if let b = bounds(of: id) { if out == nil { out = b } else { out!.extend(b) } }
        }
        return out
    }

    /// Everything that is shown (respects "Only active level").
    func contentBounds() -> Bounds3? {
        let p = model.project
        var out: Bounds3?
        func add(_ b: Bounds3?) { if let b { if out == nil { out = b } else { out!.extend(b) } } }
        for w in p.walls { add(bounds(of: w.id)) }
        for r in p.rooms { add(bounds(of: r.id)) }
        for i in p.instances { add(bounds(of: i.id)) }
        return out
    }

    // MARK: View modes and framing

    private var cameraIsAerial: Bool {
        camera.rig.mode == .orbit && abs(camera.rig.pitch - SceneCameraController.aerialPitch) < 0.5
    }

    /// Distance from the eye to the first surface in the middle of the view along `forward`, nil when nothing is hit.
    /// Not `focus(at:)`: its ground fallback is meaningless when the eye is the target (free camera).
    func centerSurfaceDistance() -> Double? {
        let r = camera.rig
        return pickNearest(origin: r.eye, dir: r.forward)?.t
    }

    /// Makes the 3D view the key receiver (so W A S D reach it right after the mode button), unless a text field is
    /// being edited.
    func focusView() {
        guard let v = arView, let w = v.window, !(w.firstResponder is NSText) else { return }
        w.makeFirstResponder(v)
    }

    func setViewMode(_ mode: SceneViewMode) {
        scroll.cancelMomentum()
        pressedKeys.removeAll()
        flight.stop()
        if mode != .firstPerson { walk.releasePointerLock() }
        let elevation = activeElevation
        // Leaving free: the orbit target lands on the surface in the middle of the view (else 3 m ahead).
        let hint = camera.rig.mode == .free ? centerSurfaceDistance() : nil
        switch mode {
        case .aerial:
            camera.aerial(contentBounds())
        case .orbit:
            if cameraIsAerial {
                var r = camera.rig
                r.pitch = -35
                camera.set(r)
            } else {
                camera.setMode(.orbit, levelElevation: elevation, viewDistanceHint: hint)
            }
        case .free:
            camera.setMode(.free, levelElevation: elevation)
            focusView()
        case .top:
            let fromFree = camera.rig.mode == .free
            camera.setMode(.top, levelElevation: elevation, viewDistanceHint: hint)
            // From free the top view is fitted to the content instead of reusing the short orbit distance.
            if fromFree { camera.frame(contentBounds() ?? Bounds3(lo: D3(-4000, -3000, 0), hi: D3(4000, 3000, 2500)), levelElevation: elevation) }
        case .firstPerson:
            camera.setMode(.firstPerson, levelElevation: elevation, viewDistanceHint: hint)
        }
        updateViewMode()
        flushCameraPersistence()
    }

    func frameSelection() {
        camera.frame(selectionBounds() ?? contentBounds() ?? Bounds3(lo: D3(-4000, -3000, 0), hi: D3(4000, 3000, 2500)),
                     levelElevation: activeElevation)
        flushCameraPersistence()
    }

    func resetView() {
        if cameraIsAerial {
            camera.aerial(contentBounds())
        } else {
            camera.reset(contentBounds(), levelElevation: activeElevation)
        }
        flushCameraPersistence()
    }

    /// First opening of a project without a stored camera: frame everything, but do not write it to the document.
    func autoFrame() {
        camera.reset(contentBounds(), levelElevation: activeElevation)
        adoptProjectCamera()
        refitOnLayout = true
    }

    // MARK: Mouse

    func mouseDown(point: SIMD2<Double>, shift: Bool, option: Bool, clickCount: Int = 1) {
        scroll.cancelMomentum()
        lastMousePoint = point
        pendingClick = nil
        if camera.rig.mode == .firstPerson {
            // Walk mode: a double click works the door in view; a click captures the mouse (Esc frees it).
            if clickCount >= 2, walk.toggleNearestOpening(tilt: option) { return }
            if walk.pointerLocked { return }
            walk.engagePointerLock()
            if walk.pointerLocked { return }
            // No gizmo here; the press may still turn into a look-around drag.
            pendingClick = PendingClick(point: point, shift: shift)
            return
        }
        if handActive {
            // Hand tool / Space: no gizmo, no furniture move. The press only becomes a camera drag; a click does nothing.
            pendingClick = PendingClick(point: point, shift: shift, handPress: true)
            return
        }
        if measureActive {
            // Measure tool: no gizmo, no selection, no furniture move. A click sets a point, a drag orbits.
            pendingClick = PendingClick(point: point, shift: shift, handPress: true, measurePress: true)
            return
        }
        if let origin = gizmoOrigin,
           let h = gizmo.hit(point: point, origin: origin, rig: camera.rig, viewSize: camera.viewSize, mmPerUnit: gizmoUnit(at: origin)),
           beginGizmoDrag(h, at: point) {
            return
        }
        pendingClick = PendingClick(point: point, shift: shift, furnitureId: shift ? nil : furnitureMoveCandidate(at: point))
    }

    func mouseDragged(point: SIMD2<Double>, dx: Double, dy: Double, shift: Bool, option: Bool) {
        lastMousePoint = point
        if walk.pointerLocked { walk.look(dx: dx, dy: dy); return }
        switch drag {
        case .gizmo:
            updateGizmoDrag(at: point, option: option)
        case .furnitureMove:
            updateFurnitureMove(at: point, option: option)
        case .camera:
            cameraDrag(dx: dx, dy: dy, shift: shift)
        case nil:
            guard let pc = pendingClick, simd_length(point - pc.point) > Self.clickSlop else { return }
            pendingClick = nil
            if allowsEditing, !pc.handPress, beginFurnitureMoveIfNeeded(pc, current: point) {
                updateFurnitureMove(at: point, option: option)
                return
            }
            drag = .camera
            // The first few points are not lost: replay the travel since the press.
            let d = point - pc.point
            cameraDrag(dx: d.x, dy: -d.y, shift: shift)
        }
    }

    func mouseUp(point: SIMD2<Double>, shift: Bool) {
        lastMousePoint = point
        switch drag {
        case .gizmo:
            endGizmoDrag(commit: true)
        case .furnitureMove:
            endFurnitureMove(commit: true)
        case .camera:
            drag = nil
            flushCameraPersistence()
        case nil:
            guard let pc = pendingClick else { return }
            pendingClick = nil
            // First person only walks and looks, the Hand tool only looks: a click selects nothing.
            if pc.measurePress { measureClick(at: point) } else if allowsEditing, !pc.handPress { click(at: point, shift: shift) }
        }
    }

    /// Right and middle button drag, and the pan modifier of other tools: always pans.
    func panDrag(dx: Double, dy: Double) {
        scroll.cancelMomentum()
        camera.pan(dx: dx, dy: dy)
    }

    func panDragEnded() { flushCameraPersistence() }

    private func cameraDrag(dx: Double, dy: Double, shift: Bool) {
        switch camera.rig.mode {
        case .top:
            if shift { camera.orbit(dx: dx, dy: dy) } else { camera.pan(dx: dx, dy: dy) }
        case .orbit, .free, .firstPerson:
            if shift { camera.pan(dx: dx, dy: dy) } else { camera.orbit(dx: dx, dy: dy) }
        }
    }

    private func click(at point: SIMD2<Double>, shift: Bool) {
        if let hit = pickHit(at: point) {
            if shift {
                if model.selection.contains(hit.id) { model.selection.remove(hit.id) } else { model.selection.insert(hit.id) }
            } else {
                model.selection = [hit.id]
                if model.activeLevelId != hit.levelId { model.activeLevelId = hit.levelId }
            }
        } else if !shift {
            if !model.selection.isEmpty { model.selection = [] }
        }
        flushCameraPersistence()
    }

    /// Raw mouse movement (view points); only used while the walk mode holds the mouse.
    func mouseDelta(dx: Double, dy: Double) { walk.look(dx: dx, dy: dy) }

    func mouseMoved(point: SIMD2<Double>) {
        lastMousePoint = point
        if walk.pointerLocked { return }
        guard drag == nil, pendingClick == nil else { return }
        if measureActive, !handActive { measureHover(at: point); return }
        guard allowsEditing else { return }
        if let origin = gizmoOrigin,
           let h = gizmo.hit(point: point, origin: origin, rig: camera.rig, viewSize: camera.viewSize, mmPerUnit: gizmoUnit(at: origin)) {
            gizmo.highlight(h)
            setHover(nil)
            return
        }
        gizmo.highlight(nil)
        setHover(pickHit(at: point)?.id)
    }

    func mouseExited() {
        lastMousePoint = nil
        if drag == nil { gizmo.highlight(nil) }
        setHover(nil)
    }

    private func setHover(_ id: UUID?) {
        if model.hoveredId != id { model.hoveredId = id }
    }

    // MARK: Trackpad and wheel

    /// Two-finger scroll, mouse wheel, ⌘-scroll. See `TrackpadMapping` for the mapping and `docs/DEVELOPMENT.md`.
    func scrollWheel(point: SIMD2<Double>, dx: Double, dy: Double, precise: Bool, shift: Bool, command: Bool,
                     phase: NSEvent.Phase, momentum: NSEvent.Phase, directionInverted: Bool) {
        lastMousePoint = point
        let proposed = TrackpadMapping.scrollAction(mode: camera.rig.mode, precise: precise, shift: shift, command: command)
        guard let step = scroll.event(phase: phase, momentum: momentum, proposed: proposed) else { return }
        // With natural scrolling the content follows the fingers; without it the deltas are mirrored.
        let sx = directionInverted ? dx : -dx
        let sy = directionInverted ? dy : -dy
        switch step.action {
        case .orbit:
            camera.orbit(dx: sx, dy: sy, degPerPoint: TrackpadTuning.scrollOrbitDegPerPoint)
        case .look:
            camera.orbit(dx: sx, dy: sy, degPerPoint: TrackpadTuning.scrollLookDegPerPoint)
        case .pan:
            camera.pan(dx: sx, dy: sy)
        case .dolly:
            guard dy != 0 else { return }
            let f = focus(at: point)
            camera.dolly(TrackpadMapping.dollyAmount(scrollingDeltaY: dy, precise: precise), focus: f.point, rayDir: f.dir)
        }
    }

    /// Pinch: zooms toward the cursor (walks forward in first person).
    func magnify(point: SIMD2<Double>, magnification: Double, phase: NSEvent.Phase) {
        lastMousePoint = point
        scroll.cancelMomentum()
        let f = focus(at: point)
        camera.pinch(magnification, focus: f.point, rayDir: f.dir)
        if phase.contains(.ended) || phase.contains(.cancelled) { flushCameraPersistence() }
    }

    /// Two-finger rotate: yaw about the target.
    func rotate(degrees: Double, phase: NSEvent.Phase) {
        scroll.cancelMomentum()
        camera.rotate(degrees: degrees)
        if phase.contains(.ended) || phase.contains(.cancelled) { flushCameraPersistence() }
    }

    /// Two-finger double tap: frame the selection, otherwise everything.
    func smartMagnify() {
        scroll.cancelMomentum()
        frameSelection()
    }

    // MARK: Keyboard

    /// Returns true when the key was used.
    func keyDown(code: UInt16, modifiers: NSEvent.ModifierFlags, isRepeat: Bool = false, characters: String? = nil) -> Bool {
        if code == KeyCode.escape, case .gizmo = drag {
            endGizmoDrag(commit: false)
            return true
        }
        if code == KeyCode.escape, case .furnitureMove = drag {
            endFurnitureMove(commit: false)
            return true
        }
        if code == KeyCode.escape, walk.pointerLocked {
            walk.releasePointerLock()
            return true
        }
        // Esc leaves the Hand tool for Select, as in the plan (Space alone ends by releasing it).
        if code == KeyCode.escape, drag == nil, pendingClick == nil, HandMode.escapeLeavesHand(toolIsHand: model.tool == .hand) {
            model.tool = .select
            return true
        }
        // Esc clears a measurement, then leaves the Measure tool for Select, as in the plan.
        if code == KeyCode.escape, measureActive, drag == nil, pendingClick == nil {
            if !measure.isEmpty { clearMeasurement() } else { model.tool = .select }
            return true
        }
        // Nothing running to cancel: Esc clears the selection, as in the plan. Not in first person (no selection there).
        if code == KeyCode.escape, camera.rig.mode != .firstPerson, drag == nil, pendingClick == nil, !model.selection.isEmpty {
            model.selection = []
            return true
        }
        // Delete/Backspace removes the selected furniture, as in the plan. Locked objects stay; not while a drag runs.
        if KeyCode.isDelete(code), allowsEditing, drag == nil, pendingClick == nil,
           modifiers.intersection([.command, .control, .option]).isEmpty, !model.selection.isEmpty {
            model.deleteUnlocked(model.selectionIds)
            return true
        }
        // Space held: temporary Hand tool. H selects the Hand tool, V the Select tool (nothing while a drag runs).
        if code == KeyCode.space, camera.rig.mode != .firstPerson, drag == nil, pendingClick == nil,
           modifiers.intersection([.command, .control, .option]).isEmpty {
            if !spaceHeld { spaceHeld = true; handModeDidChange() }
            return true
        }
        if drag == nil, pendingClick == nil,
           let tool = HandMode.shortcut(characters: characters ?? Self.letter(for: code), command: modifiers.contains(.command),
                                        control: modifiers.contains(.control), option: modifiers.contains(.option)) {
            model.tool = tool == .hand ? .hand : .select
            return true
        }
        if code == KeyCode.e, camera.rig.mode == .firstPerson, modifiers.intersection([.command, .control]).isEmpty {
            if !isRepeat { _ = walk.toggleNearestOpening(tilt: modifiers.contains(.shift)) }
            return true
        }
        if camera.rig.mode == .free, KeyCode.flying.contains(code), modifiers.intersection([.command, .control]).isEmpty {
            scroll.cancelMomentum()
            pressedKeys.insert(code)
            return true
        }
        // First person: Space held walks through walls and furniture (`WalkPassThrough`); not the temporary Hand there.
        if code == KeyCode.space, camera.rig.mode == .firstPerson, modifiers.intersection([.command, .control]).isEmpty {
            pressedKeys.insert(code)
            return true
        }
        guard camera.rig.mode == .firstPerson, KeyCode.walking.contains(code),
              modifiers.intersection([.command, .control]).isEmpty else { return false }
        scroll.cancelMomentum()
        pressedKeys.insert(code)
        return true
    }

    func keyUp(code: UInt16) -> Bool {
        // The key leaves `pressedKeys` in every case: Space may be held both as Hand shortcut and as walk key.
        let wasDown = pressedKeys.remove(code) != nil
        var handled = wasDown
        if code == KeyCode.space, spaceHeld {
            spaceHeld = false
            handModeDidChange()
            handled = true
        }
        if wasDown, pressedKeys.isEmpty { flushCameraPersistence() }
        return handled
    }

    /// Focus lost: nothing may keep walking, and an unfinished gizmo drag is cancelled.
    func releaseInput() {
        let walked = !pressedKeys.isEmpty
        if spaceHeld { spaceHeld = false; handModeDidChange() }
        pressedKeys.removeAll()
        flight.stop()
        walk.releasePointerLock()
        if case .gizmo = drag { endGizmoDrag(commit: false) }
        if case .furnitureMove = drag { endFurnitureMove(commit: false) }
        drag = nil
        pendingClick = nil
        if walked { flushCameraPersistence() }
    }

    func viewResized(size: CGSize) {
        guard size.width > 0, size.height > 0, size != camera.viewSize else { return }
        camera.viewSize = size
        // Untouched means: the document camera is the default and no move is waiting for the persist debounce.
        if refitOnLayout, model.project.camera == CameraState.default, camera.rig.state == lastPersisted {
            refitOnLayout = false
            camera.reset(contentBounds(), levelElevation: activeElevation)
            adoptProjectCamera()
        }
        placeGizmo()
    }

    // MARK: Hand tool

    /// The Hand tool or Space is on: the view only looks. See `HandMode`.
    var handActive: Bool { HandMode.isActive(toolIsHand: model.tool == .hand, spaceHeld: spaceHeld) }

    /// Selecting, gizmo, furniture move and the editing keys work (not in the Hand tool, not in first person).
    var allowsEditing: Bool {
        HandMode.allowsEditing(toolIsHand: model.tool == .hand, spaceHeld: spaceHeld,
                               cameraAllowsEditing: camera.rig.mode.allowsSelectionEditing && !measureActive)
    }

    /// Hand cursor in the view: only where the mode can show it (first person captures the mouse instead).
    var showsHandCursor: Bool { handActive && camera.rig.mode.allowsSelectionEditing }

    /// Crosshair while the Measure tool takes the clicks (the Hand wins while Space is held).
    var showsMeasureCursor: Bool { measureActive && !handActive }

    /// The Hand tool or Space turned on or off: hide hover and gizmo, show the matching cursor.
    func handModeDidChange() {
        lastHandActive = handActive
        guard interactive, !stopped else { return }
        if handActive {
            gizmo.highlight(nil)
            if model.hoveredId != nil { model.hoveredId = nil }
        }
        updateGizmo()
        if let v = arView { v.window?.invalidateCursorRects(for: v) }
    }

    /// Fallback letter for the two tool shortcuts when the event carries no characters (ANSI key codes 9 and 4).
    static func letter(for code: UInt16) -> String? {
        switch code {
        case KeyCode.v: "v"
        case KeyCode.h: "h"
        default: nil
        }
    }

    // MARK: Gizmo placement

    func gizmoUnit(at origin: D3) -> Double {
        let r = camera.rig
        let depth = max(simd_dot(origin - r.eye, r.forward), 100)
        return r.mmPerPoint(depth: depth, viewHeight: Double(camera.viewSize.height)) * Gizmo.screenLength
    }

    func placeGizmo() {
        guard interactive, let o = gizmoOrigin, gizmo.root.isEnabled else { return }
        gizmo.place(origin: o, mmPerUnit: gizmoUnit(at: o))
    }

    /// Shows, moves or hides the gizmo to match the selection. Not during a gizmo drag.
    func updateGizmo() {
        guard interactive, !stopped else { return }
        if case .gizmo = drag { return }
        guard let t = gizmoTargets() else {
            gizmoOrigin = nil
            gizmo.configure(handles: [])
            return
        }
        gizmoOrigin = t.origin
        gizmo.configure(handles: t.handles)
        placeGizmo()
    }

    /// Movable, visible, unlocked selection, or nil when there is nothing the gizmo may move.
    func gizmoTargets() -> GizmoTargets? {
        // First person is for walking and looking, the Hand tool for looking: no gizmo, whatever is selected.
        guard allowsEditing else { return nil }
        let p = model.project
        var ids: [UUID] = []
        var allFurniture = true
        var bounds: Bounds3?
        var furnitureOrigin: P3?
        var rotation: Double?
        for id in model.selection.sorted(by: { $0.uuidString < $1.uuidString }) {
            var locked = false
            var origin: P3?
            var rot: Double?
            if let i = p.instance(id) {
                guard i.visible, levelShown(i.levelId), instanceShown(i) else { continue }
                locked = i.locked || (i.groupId.flatMap { p.group($0)?.locked } ?? false) || p.level(i.levelId)?.locked == true
                origin = i.position
                rot = i.rotationDeg
            } else if let g = p.group(id) {
                guard levelShown(g.levelId) else { continue }
                let members = g.memberIds.compactMap { p.instance($0) }
                locked = g.locked || p.level(g.levelId)?.locked == true || members.contains { $0.locked }
                origin = g.origin
                rot = g.rotationDeg
            } else if let w = p.wall(id) {
                guard levelShown(w.levelId) else { continue }
                locked = w.locked || p.level(w.levelId)?.locked == true
                allFurniture = false
            } else if let r = p.room(id) {
                guard levelShown(r.levelId) else { continue }
                locked = p.level(r.levelId)?.locked == true
                allFurniture = false
            } else {
                continue
            }
            if locked { return nil }
            guard let b = self.bounds(of: id) else { continue }
            ids.append(id)
            if bounds == nil { bounds = b } else { bounds!.extend(b) }
            furnitureOrigin = origin
            rotation = rot
        }
        guard let b = bounds, !ids.isEmpty else { return nil }
        var handles: Set<GizmoHandle> = [.axisX, .axisY, .ring]
        if allFurniture { handles.insert(.axisZ) }
        let origin: D3
        if ids.count == 1, let o = furnitureOrigin {
            origin = D3(Double(o.x), Double(o.y), b.hi.z)
        } else {
            origin = D3(b.center.x.rounded(), b.center.y.rounded(), b.hi.z)
        }
        return GizmoTargets(ids: ids, handles: handles, origin: origin, startRotation: ids.count == 1 ? rotation : nil)
    }

    // MARK: Gizmo drag

    private func beginGizmoDrag(_ handle: GizmoHandle, at point: SIMD2<Double>) -> Bool {
        guard let t = gizmoTargets(), t.handles.contains(handle) else { return false }
        let r = ray(at: point)
        var startParam = 0.0, startAngle = 0.0
        if let axis = handle.axis {
            guard let s = Gizmo.axisParameter(rayOrigin: r.origin, rayDir: r.dir, origin: t.origin, axis: axis) else { return false }
            startParam = s
        } else {
            guard let a = Gizmo.ringAngle(rayOrigin: r.origin, rayDir: r.dir, pivot: t.origin, z: t.origin.z) else { return false }
            startAngle = a
        }
        let expanded = Array(expand(Set(t.ids)))
        var bases: [(entity: Entity, matrix: simd_float4x4)] = []
        for id in expanded {
            if let n = instNodes[id] { bases.append((n.root, n.root.transform.matrix)) }
            else if let n = wallNodes[id] { bases.append((n.entity, n.entity.transform.matrix)) }
            else if let n = roomNodes[id] {
                if let f = n.floor { bases.append((f, f.transform.matrix)) }
                if let c = n.ceiling { bases.append((c, c.transform.matrix)) }
            }
        }
        model.store.beginInteraction(expanded, reason: "Moving in 3D")
        gizmo.highlight(handle)
        var g = GizmoDrag(handle: handle, origin: t.origin, ids: t.ids, expanded: expanded, bases: bases,
                          pivot: P2(MM(t.origin.x.rounded()), MM(t.origin.y.rounded())))
        g.startParam = startParam
        g.startAngle = startAngle
        g.startRotation = t.startRotation
        g.contact = gizmoContact(handle: handle, ids: t.ids, expanded: expanded, origin: t.origin)
        g.vertical = gizmoVertical(handle: handle, ids: t.ids, expanded: expanded, origin: t.origin)
        drag = .gizmo(g)
        return true
    }

    private func updateGizmoDrag(at point: SIMD2<Double>, option: Bool) {
        guard case .gizmo(var g) = drag else { return }
        let r = ray(at: point)
        let settings = model.project.settings
        let snapOn = settings.snap.enabled && !option && !model.snapSuspended
        var m = matrix_identity_float4x4
        if let axis = g.handle.axis {
            guard let s = Gizmo.axisParameter(rayOrigin: r.origin, rayDir: r.dir, origin: g.origin, axis: axis) else { return }
            var delta = Double(SnapEngine.snapDelta(s - g.startParam, grid: settings.snap.grid, enabled: snapOn))
            var touching = false
            if snapOn, let c = g.contact {
                // Furniture stops flush on its line (no sliding off the axis) and is pulled onto close faces.
                let a = V2(axis.x, axis.y)
                let res = MoveContact.resolve(moving: c.bodies, raw: a * delta, obstacles: c.obstacles,
                                              tolerance: contactTolerance(depth: c.depth), slide: false, constrainedTo: a)
                delta = simd_dot(res.delta, a)
            }
            if snapOn, let v = g.vertical,
               let stop = v.contact.stop(near: s - g.startParam, tolerance: contactTolerance(depth: v.depth)) {
                delta = Double(stop)
                touching = true
            }
            g.delta = delta
            m.columns.3 = SIMD4(Float(axis.x * delta), Float(axis.y * delta), Float(axis.z * delta), 1)
            gizmoOrigin = g.origin + axis * delta
            hudText = "Δ\(g.handle.label) \(Self.signed(delta)) mm" + (touching ? "  (touching)" : "")
        } else {
            guard let a = Gizmo.ringAngle(rayOrigin: r.origin, rayDir: r.dir, pivot: g.origin, z: g.origin.z) else { return }
            let raw = Gizmo.wrap(a - g.startAngle)
            let step = settings.snap.angleStep
            let delta: Double
            if let start = g.startRotation {
                // Single piece: the absolute angle lands on the step.
                let target = SnapEngine.snapAngle(start + raw, step: step, enabled: snapOn)
                delta = Gizmo.wrap(target - start)
            } else if snapOn, step > 0 {
                delta = (raw / step).rounded() * step
            } else {
                delta = (raw * 10).rounded() / 10
            }
            g.delta = delta
            let p = SIMD3(Float(g.pivot.x), Float(g.pivot.y), 0)
            var toPivot = matrix_identity_float4x4, fromPivot = matrix_identity_float4x4
            toPivot.columns.3 = SIMD4(p, 1)
            fromPivot.columns.3 = SIMD4(-p, 1)
            m = toPivot * simd_float4x4(simd_quatf(angle: Float(delta * .pi / 180), axis: SIMD3(0, 0, 1))) * fromPivot
            hudText = "Rotation \(Self.signed(delta, decimals: 1))°"
        }
        for b in g.bases { b.entity.transform.matrix = m * b.matrix }
        drag = .gizmo(g)
        placeGizmo()
    }

    /// Ends the drag. With `commit` the move or rotation becomes ONE command; without (Esc, focus lost) nothing changes.
    func endGizmoDrag(commit: Bool) {
        guard case .gizmo(let g) = drag else { return }
        drag = nil
        for b in g.bases { b.entity.transform.matrix = b.matrix }
        model.store.endInteraction(g.expanded)
        hudText = nil
        gizmo.highlight(nil)
        if commit, g.delta != 0 {
            if let axis = g.handle.axis {
                let d = P3(MM((axis.x * g.delta).rounded()), MM((axis.y * g.delta).rounded()), MM((axis.z * g.delta).rounded()))
                model.perform("Move") { try $0.moveObjects(g.ids, by: d) }
            } else {
                model.perform("Rotate") { try $0.rotateObjects(g.ids, by: g.delta, pivot: g.pivot) }
            }
        }
        updateGizmo()
    }

    static func signed(_ v: Double, decimals: Int = 0) -> String {
        let s = String(format: "%.\(decimals)f", abs(v))
        return v < 0 ? "-\(s)" : "+\(s)"
    }
}
