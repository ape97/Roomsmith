import AppKit
import simd
import RoomsmithCore

// Mouse, scroll and keyboard handling plus the select tool (move, handles, rotation, marquee).

extension PlanNSView {
    // MARK: Helpers

    func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    func syncModifiers(_ e: NSEvent) {
        let alt = e.modifierFlags.contains(.option)
        if model.snapSuspended != alt { model.snapSuspended = alt }
    }

    var snapOn: Bool { project.settings.snap.enabled && !model.snapSuspended }
    /// Pixel-based reach (9 pt, clamped to 20...300 mm), capped by the "Tolerance" setting.
    var snapTolerance: Double { min(min(max(vp.mm(9), 20), 300), Double(project.settings.snap.tolerance)) }

    /// Snaps a model point with the level's snap context. `exclude` objects are ignored.
    func snapped(_ m: V2, anchor: P2? = nil, exclude: Set<UUID> = []) -> SnapResult {
        var ctx = baseScene.snapContext
        ctx.anchor = anchor
        ctx.excludeIds = exclude
        var s = project.settings.snap
        if model.snapSuspended { s.enabled = false }
        return SnapEngine.snapPoint(m, context: ctx, settings: s, tolerance: snapTolerance)
    }

    // MARK: Mouse

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        syncModifiers(e)
        if handleDrag?.gesture == true { cancelDrags() }
        let pt = point(e)
        mouse = pt; mouseModel = vp.model(pt); publishCursor()
        if spaceDown || model.tool == .hand { beginPan(pt); return } // Hand tool and Space only navigate
        switch model.tool {
        case .hand: break
        case .select: selectDown(e, pt)
        case .wall: wallDown(e, pt)
        case .room: roomDown(e, pt)
        case .door, .window, .opening: openingDown(e, pt)
        case .dimension: dimensionDown(e, pt)
        case .measure: measureDown(e, pt)
        case .calibrate: calibrateDown(e, pt)
        }
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        syncModifiers(e)
        let pt = point(e)
        mouse = pt; mouseModel = vp.model(pt); publishCursor()
        if panning { continuePan(pt); return }
        if model.tool == .select { selectDragged(e, pt) } else { toolMoved(e, pt) }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        syncModifiers(e)
        let pt = point(e)
        mouse = pt; mouseModel = vp.model(pt)
        if panning { endPan(); return }
        if model.tool == .select { selectUp(e, pt) }
        needsDisplay = true
    }

    override func mouseMoved(with e: NSEvent) {
        syncModifiers(e)
        let pt = point(e)
        mouse = pt; mouseModel = vp.model(pt); publishCursor()
        if model.tool == .select {
            hoverHandle = handleHit(at: pt)
            setHover(hoverHandle == nil ? hitObject(at: pt) : nil)
        } else {
            setHover(nil)
            toolMoved(e, pt)
        }
        needsDisplay = true
    }

    override func mouseExited(with e: NSEvent) {
        mouse = nil; mouseModel = nil
        if model.cursorPoint != nil { model.cursorPoint = nil }
        setHover(nil)
        hoverHandle = nil
        proposal = nil
        snapResult = nil
        needsDisplay = true
    }

    override func otherMouseDown(with e: NSEvent) {
        if e.buttonNumber == 2 { beginPan(point(e)) }
    }
    override func otherMouseDragged(with e: NSEvent) {
        if panning { continuePan(point(e)) }
    }
    override func otherMouseUp(with e: NSEvent) {
        if panning { endPan() }
    }

    func beginPan(_ pt: CGPoint) {
        panning = true
        lastPanPoint = pt
        NSCursor.closedHand.set()
    }

    /// The pan ended: back to the cursor the tool shows when idle (open hand in the Hand tool or while Space is held).
    func endPan() {
        panning = false
        (model.tool == .hand || spaceDown ? NSCursor.openHand : NSCursor.arrow).set()
    }

    func continuePan(_ pt: CGPoint) {
        vp.pan(dx: Double(pt.x - lastPanPoint.x), dy: Double(pt.y - lastPanPoint.y))
        lastPanPoint = pt
        refreshPointer()
        needsDisplay = true
    }

    // MARK: Scroll and gestures

    /// A mouse button is down (drag, handle drag, marquee) or the middle-button pan runs: gestures are ignored then.
    var mouseBusy: Bool { panning || NSEvent.pressedMouseButtons != 0 || moveDrag != nil || marquee != nil }

    override func scrollWheel(with e: NSEvent) {
        if e.phase == .mayBegin { return }
        let pt = point(e)
        mouse = pt
        let precise = e.hasPreciseScrollingDeltas
        if e.modifierFlags.contains(.command) || !precise {
            if !precise, e.modifierFlags.contains(.shift) {
                // Shift + wheel: horizontal pan.
                let dx = PlanGesture.shiftWheelPan(deltaX: Double(e.scrollingDeltaX), deltaY: Double(e.scrollingDeltaY))
                guard dx != 0 else { return }
                vp.pan(dx: dx, dy: 0)
                refreshPointer()
                needsDisplay = true
                return
            }
            // Momentum of a cmd-scroll would keep zooming after the fingers left: drop it.
            if precise, !e.momentumPhase.isEmpty { return }
            let factor = PlanGesture.scrollZoomFactor(deltaY: Double(e.scrollingDeltaY), precise: precise)
            guard factor != 1 else { return }
            zoom(by: factor, around: pt)
        } else {
            let dx = Double(e.scrollingDeltaX), dy = Double(e.scrollingDeltaY)
            guard dx != 0 || dy != 0 else { return }
            vp.pan(dx: dx, dy: dy)
            refreshPointer()
            needsDisplay = true
        }
    }

    override func magnify(with e: NSEvent) {
        guard !mouseBusy else { return }
        zoom(by: PlanGesture.pinchFactor(magnification: Double(e.magnification)), around: point(e))
    }

    override func smartMagnify(with e: NSEvent) {
        guard !mouseBusy else { return }
        fit(selectionOnly: !model.selection.isEmpty)
    }

    /// Objects touched by a handle drag. A rotation gesture uses the ids frozen at its start, so busy flags are
    /// always released for exactly the objects they were set on.
    func handleIds(_ h: PlanHandleDrag) -> [UUID] {
        h.ids.isEmpty ? handleBusyIds(h.handle) : expandedIds(h.ids)
    }

    /// Two-finger rotation turns the selection around its centre. Live preview through the handle-drag machinery
    /// (so the degree tag is shown), one undo step at the end, cancelled gesture restores. Without selection: no-op.
    /// The decisions live in `PlanGesture.rotationAction` (tested); a pressed mouse button cancels the gesture.
    override func rotate(with e: NSEvent) {
        syncModifiers(e)
        mouse = point(e)
        let phase: PlanGesture.RotationPhase
        switch e.phase {
        case .began: phase = .began
        case .changed: phase = .changed
        case .ended: phase = .ended
        case .cancelled: phase = .cancelled
        default: return
        }
        let current = handleDrag.flatMap { $0.gesture ? $0 : nil }
        let action = PlanGesture.rotationAction(
            phase: phase, active: current != nil, mouseDown: panning || NSEvent.pressedMouseButtons != 0 || moveDrag != nil || marquee != nil,
            selectionChanged: current.map { Set($0.ids) != model.selection } ?? false)
        switch action {
        case .none: return
        case .cancel: cancelDrags()
        case .discardAndBegin:
            cancelDrags()
            beginRotationGesture(e)
            changeRotationGesture(e)
        case .begin:
            beginRotationGesture(e)
            changeRotationGesture(e)
        case .update: changeRotationGesture(e)
        case .commit:
            guard let h = current else { return }
            handleDrag = nil
            let ids = handleIds(h)
            if commitNeeded(h) { model.perform(handleName(h.handle)) { p in try self.applyHandle(&p, h) } }
            model.store.endInteraction(ids)
            preview = nil
            needsDisplay = true
        }
    }

    func beginRotationGesture(_ e: NSEvent) {
        guard handleDrag == nil, model.tool == .select else { return }
        let ids = Array(model.selection)
        guard let first = ids.first else { return }
        var trial = project
        guard (try? trial.rotateObjects(ids, by: 1)) != nil else { return }
        var d = PlanHandleDrag(handle: .rotate(first), startModel: vp.model(point(e)))
        if ids.count == 1, let r = rotationPivot(of: first) { d.pivot = r.pivot; d.startRotation = r.rotation }
        d.started = true
        d.gesture = true
        d.ids = ids
        handleDrag = d
        model.store.beginInteraction(handleIds(d), reason: "Rotating in plan")
        prepareDragCollisions(handleIds(d))
    }

    func changeRotationGesture(_ e: NSEvent) {
        guard var h = handleDrag, h.gesture else { return }
        h.startAngle += Double(e.rotation) // accumulated gesture angle (counter-clockwise = positive)
        h.rotationDelta = PlanGesture.rotationDelta(accumulated: h.startAngle, startRotation: h.startRotation,
                                                    step: project.settings.snap.angleStep, snap: snapOn)
        handleDrag = h
        updatePreview()
    }

    // MARK: Select tool

    func selectDown(_ e: NSEvent, _ pt: CGPoint) {
        let m = vp.model(pt)
        if let h = handleHit(at: pt), let id = model.selection.first {
            var d = PlanHandleDrag(handle: h, startModel: m)
            if case .rotate = h, let r = rotationPivot(of: id) {
                d.pivot = r.pivot
                d.startRotation = r.rotation
                d.startAngle = atan2(m.y - r.pivot.y, m.x - r.pivot.x) * 180 / .pi
            }
            handleDrag = d
            return
        }
        if e.clickCount >= 2 { return } // double-click on room/wall: selection from the first click stays
        let shift = e.modifierFlags.contains(.shift)
        if let hit = hitObject(at: pt) {
            if shift {
                if model.selection.contains(hit) { model.selection.remove(hit) } else { model.selection.insert(hit) }
                return
            }
            let was = model.selection.contains(hit)
            if !was { model.selection = [hit] }
            moveDrag = PlanMoveDrag(ids: Array(model.selection), anchorId: hit, startModel: m,
                                    narrowTo: was && model.selection.count > 1 ? hit : nil)
        } else {
            if !shift, !model.selection.isEmpty { model.selection = [] }
            marquee = (pt, pt, shift)
        }
    }

    func selectDragged(_ e: NSEvent, _ pt: CGPoint) {
        let m = vp.model(pt)
        if var d = moveDrag {
            if !d.started {
                let s = vp.screen(d.startModel)
                guard hypot(Double(pt.x - s.x), Double(pt.y - s.y)) > 3 else { return }
                d.started = true
                let exp = expandedIds(d.ids)
                model.store.beginInteraction(exp, reason: "Moving in plan")
                prepareDragCollisions(exp)
                d.contact = contactSetup(for: d.ids)
                d.rest = RestingDrag(project: project, levelId: levelId, ids: Set(d.ids))
            }
            let r = moveDelta(d, current: m)
            d.delta = r.0; d.guides = r.1; d.dz = r.2
            moveDrag = d
            updatePreview()
            // Compare split: pulling the selection out of this pane hands it to the other project (drop = copy, ⌘ = move).
            if model.workspace?.compare != nil, !bounds.contains(pt) { beginTransferDrag(d, e, at: pt) }
        } else if var h = handleDrag {
            if !h.started {
                let s = vp.screen(h.startModel)
                guard hypot(Double(pt.x - s.x), Double(pt.y - s.y)) > 3 else { return }
                h.started = true
                let ids = handleIds(h)
                model.store.beginInteraction(ids, reason: "Editing in plan")
                prepareDragCollisions(ids)
            }
            updateHandleTarget(&h, current: m)
            handleDrag = h
            updatePreview()
        } else if var mq = marquee {
            mq.current = pt
            marquee = mq
        }
    }

    func selectUp(_ e: NSEvent, _ pt: CGPoint) {
        if let d = moveDrag {
            moveDrag = nil
            if d.started {
                let exp = expandedIds(d.ids)
                if d.delta.x != 0 || d.delta.y != 0 || d.dz != 0 {
                    let delta = d.delta, ids = d.ids, dz = d.dz
                    model.perform(ids.count == 1 ? "Move \(project.displayName(of: ids[0]))" : "Move \(ids.count) Objects") { p in
                        try p.moveObjects(ids, by: P3(delta.x, delta.y, dz))
                    }
                }
                model.store.endInteraction(exp)
                preview = nil
            } else if let n = d.narrowTo {
                model.selection = [n]
            }
        } else if let h = handleDrag {
            handleDrag = nil
            if h.started {
                let ids = handleIds(h)
                let changed = commitNeeded(h)
                if changed {
                    model.perform(handleName(h.handle)) { p in try self.applyHandle(&p, h) }
                }
                model.store.endInteraction(ids)
                preview = nil
            }
        } else if let mq = marquee {
            marquee = nil
            let a = vp.model(mq.start), b = vp.model(mq.current)
            if hypot(Double(mq.current.x - mq.start.x), Double(mq.current.y - mq.start.y)) > 3 {
                let found = objects(inLo: simd_min(a, b), hi: simd_max(a, b))
                if mq.additive { model.selection.formUnion(found) } else { model.selection = Set(found) }
            }
        }
    }

    func commitNeeded(_ h: PlanHandleDrag) -> Bool {
        if case .rotate = h.handle { return abs(h.rotationDelta) > 1e-9 }
        return h.target != currentHandleValue(h.handle)
    }

    func currentHandleValue(_ h: PlanHandle) -> P2 {
        let p = project
        switch h {
        case .wallStart(let id): return p.wall(id)?.start ?? P2(0, 0)
        case .wallEnd(let id): return p.wall(id)?.end ?? P2(0, 0)
        case .roomVertex(let id, let i): return p.room(id).flatMap { i < $0.points.count ? $0.points[i] : nil } ?? P2(0, 0)
        case .dimA(let id): return p.dimension(id)?.a ?? P2(0, 0)
        case .dimB(let id): return p.dimension(id)?.b ?? P2(0, 0)
        case .dimOffset(let id): return P2(p.dimension(id)?.offset ?? 0, 0)
        case .rotate: return P2(0, 0)
        }
    }

    func handleName(_ h: PlanHandle) -> String {
        switch h {
        case .wallStart, .wallEnd: "Move Wall End"
        case .roomVertex: "Move Room Corner"
        case .dimA, .dimB: "Move Dimension Point"
        case .dimOffset: "Move Dimension Line"
        case .rotate: "Rotate"
        }
    }

    // MARK: Drag computation

    /// Snapped move delta (mm) and snap guides for the current pointer position. Furniture and groups additionally stop
    /// flush at walls and other furniture (and slide along them); Option / the snap toggle switches that off too.
    /// The third value is the height change: a single piece dragged over a table (or shelf) climbs onto it and falls back
    /// to the floor when it leaves again (`RestingDrag`); holding Option switches that off as well.
    func moveDelta(_ d: PlanMoveDrag, current m: V2) -> (P2, [SnapGuide], MM) {
        let snapped = snappedMoveDelta(d, current: m)
        var out = snapped
        if snapOn, let c = d.contact {
            let res: ContactResult
            if let rest = model.snapSuspended ? nil : d.rest {
                res = rest.resolve(moving: c.bodies, raw: snapped.0.v, obstacles: c.obstacles, tolerance: snapTolerance, slide: true).result
            } else {
                res = MoveContact.resolve(moving: c.bodies, raw: snapped.0.v, obstacles: c.obstacles,
                                          tolerance: snapTolerance, slide: true)
            }
            if res.contact { out = (P2(rounding: res.delta), res.guides) }
        }
        guard !model.snapSuspended, let rest = d.rest else { return (out.0, out.1, 0) }
        return (out.0, out.1, rest.z(at: out.0.v) - rest.startZ)
    }

    /// Contact data for a drag of furniture and groups only, or nil.
    func contactSetup(for ids: [UUID]) -> PlanContact? {
        let p = project
        guard !ids.isEmpty, ids.allSatisfy({ p.instance($0) != nil || p.group($0) != nil }) else { return nil }
        let settings = p.settings.snap
        guard settings.toWalls || settings.toObjects else { return nil }
        let bodies = MoveContact.bodies(project: p, levelId: levelId, ids: Set(ids))
        guard !bodies.isEmpty else { return nil }
        let obstacles = MoveContact.obstacles(project: p, levelId: levelId, excluding: Set(ids),
                                              toWalls: settings.toWalls, toObjects: settings.toObjects)
        return PlanContact(bodies: bodies, obstacles: obstacles)
    }

    private func snappedMoveDelta(_ d: PlanMoveDrag, current m: V2) -> (P2, [SnapGuide]) {
        let p = project
        let raw = m - d.startModel
        let on = snapOn
        let settings = p.settings.snap
        let expanded = Set(expandedIds(d.ids))
        var ctx = baseScene.snapContext
        ctx.excludeIds = expanded
        ctx.anchor = nil
        var s = settings
        if !on { s.enabled = false }

        if d.ids.count == 1, p.opening(d.ids[0]) != nil {
            let dx = SnapEngine.snapDelta(raw.x, grid: settings.grid, enabled: on && settings.toGrid)
            let dy = SnapEngine.snapDelta(raw.y, grid: settings.grid, enabled: on && settings.toGrid)
            return (P2(dx, dy), [])
        }
        if d.ids.count == 1, let inst = p.instance(d.ids[0]), let def = p.definition(inst.definitionId) {
            let start = inst.position.xy
            let proposed = P2(rounding: start.v + raw)
            if on, settings.toWalls {
                let r = SnapEngine.snapFurniture(inst, definition: def, proposed: proposed, context: ctx,
                                                 tolerance: snapTolerance, alignRotation: false)
                if r.kind != .none { return (r.position - start, r.guides) }
            }
            let x = SnapEngine.snapDelta(Double(proposed.x), grid: settings.grid, enabled: on && settings.toGrid)
            let y = SnapEngine.snapDelta(Double(proposed.y), grid: settings.grid, enabled: on && settings.toGrid)
            return (P2(x, y) - start, [])
        }
        guard let ref = referencePoint(of: d.anchorId) else { return (P2(rounding: raw), []) }
        let r = SnapEngine.snapPoint(ref.v + raw, context: ctx, settings: s, tolerance: snapTolerance)
        return (r.point - ref, r.guides)
    }

    func referencePoint(of id: UUID) -> P2? {
        let p = project
        if let g = p.group(id) { return g.origin.xy }
        return p.referencePoints(id).first
    }

    func updateHandleTarget(_ h: inout PlanHandleDrag, current m: V2) {
        let p = project
        switch h.handle {
        case .wallStart(let id), .wallEnd(let id):
            guard let w = p.wall(id) else { return }
            var isStart = false
            if case .wallStart = h.handle { isStart = true }
            let other = isStart ? w.end : w.start
            let moving = isStart ? w.start : w.end
            var exclude: Set<UUID> = [id]
            for o in p.walls where o.id != id && o.levelId == w.levelId && (o.start == moving || o.end == moving) { exclude.insert(o.id) }
            let r = snapped(m, anchor: other, exclude: exclude)
            h.target = r.point; h.guides = r.guides
        case .roomVertex(let id, _):
            let r = snapped(m, exclude: [id])
            h.target = r.point; h.guides = r.guides
        case .dimA, .dimB:
            let r = snapped(m)
            h.target = r.point; h.guides = r.guides
        case .dimOffset(let id):
            guard let d = p.dimension(id) else { return }
            let ax = Geo.axis(d.a, d.b)
            let off = simd_dot(m - d.a.v, ax.normal)
            h.target = P2(SnapEngine.snapDelta(off, grid: 10, enabled: snapOn), 0)
        case .rotate:
            let angle = atan2(m.y - h.pivot.y, m.x - h.pivot.x) * 180 / .pi
            let wanted = h.startRotation + (angle - h.startAngle)
            let snap = project.settings.snap
            let target = SnapEngine.snapAngle(wanted, step: snap.angleStep, enabled: snapOn)
            var delta = (target - h.startRotation).truncatingRemainder(dividingBy: 360)
            if delta > 180 { delta -= 360 } else if delta <= -180 { delta += 360 }
            h.rotationDelta = delta
        }
    }

    func applyHandle(_ p: inout Project, _ h: PlanHandleDrag) throws {
        switch h.handle {
        case .wallStart(let id): try p.updateWall(id, start: h.target, moveJoined: true)
        case .wallEnd(let id): try p.updateWall(id, end: h.target, moveJoined: true)
        case .roomVertex(let id, let i):
            guard var pts = p.room(id)?.points, i < pts.count else { return }
            pts[i] = h.target
            try p.updateRoom(id, points: pts)
        case .dimA(let id): try p.updateDimension(id, a: h.target)
        case .dimB(let id): try p.updateDimension(id, b: h.target)
        case .dimOffset(let id): try p.updateDimension(id, offset: h.target.x)
        case .rotate(let id): try p.rotateObjects(h.gesture ? h.ids : [id], by: h.rotationDelta)
        }
    }

    // MARK: Preview

    /// Collisions of everything not touched by the drag stay as they are.
    func prepareDragCollisions(_ ids: [UUID]) {
        let base = baseScene
        let exp = Set(ids)
        guard project.settings.collisionWarnings else { dragBaseColliding = []; return }
        let partners = CollisionChecker.check(project, levelId: levelId, only: exp).compactMap(\.b)
        dragBaseColliding = base.colliding.subtracting(exp).subtracting(partners)
    }

    func updatePreview() {
        var p = project
        var involved: [UUID] = []
        if let d = moveDrag, d.started {
            try? p.moveObjects(d.ids, by: P3(d.delta.x, d.delta.y, d.dz))
            involved = expandedIds(d.ids)
        } else if let h = handleDrag, h.started {
            try? applyHandle(&p, h)
            involved = handleIds(h)
        } else {
            preview = nil
            needsDisplay = true
            return
        }
        var sc = PlanScene.build(p, revision: model.store.contentRevision, levelId: levelId, full: false)
        if p.settings.collisionWarnings {
            let exp = Set(involved)
            let onlyFurniture = exp.allSatisfy { p.instance($0) != nil }
            if onlyFurniture {
                sc.colliding = dragBaseColliding.union(PlanScene.collidingIds(p, levelId: levelId, only: exp))
            } else {
                sc.colliding = PlanScene.collidingIds(p, levelId: levelId, only: nil)
            }
        }
        sc.snapContext = baseScene.snapContext
        preview = sc
        needsDisplay = true
    }

    // MARK: Keyboard

    override func keyDown(with e: NSEvent) {
        syncModifiers(e)
        if e.keyCode == 49, model.tool != .wall || wallInput.isEmpty { // space
            if !spaceDown { spaceDown = true; NSCursor.openHand.set() }
            return
        }
        if e.keyCode == 53 { escape(); return }
        let flags = e.modifierFlags.intersection([.command, .shift, .option, .control])
        if !panning, !toolHasState, let tool = HandMode.shortcut(characters: e.charactersIgnoringModifiers, command: flags.contains(.command),
                                                   control: flags.contains(.control), option: flags.contains(.option)) {
            model.tool = tool == .hand ? .hand : .select
            return
        }
        switch model.tool {
        case .wall:
            if wallKey(e) { return }
        case .room:
            if e.keyCode == 36 || e.keyCode == 76 { finishRoom(); return }
            if e.keyCode == 51, !roomPoints.isEmpty { roomPoints.removeLast(); needsDisplay = true; return }
        case .select:
            if selectKey(e, flags) { return }
        case .door, .window, .opening:
            if e.charactersIgnoringModifiers?.lowercased() == "f" { flipHinge.toggle(); updateProposal(); needsDisplay = true; return }
        default: break
        }
        super.keyDown(with: e)
    }

    override func keyUp(with e: NSEvent) {
        if e.keyCode == 49, spaceDown {
            spaceDown = false
            if panning { panning = false }
            (model.tool == .hand ? NSCursor.openHand : NSCursor.arrow).set()
            window?.invalidateCursorRects(for: self)
        } else {
            super.keyUp(with: e)
        }
    }

    override func flagsChanged(with e: NSEvent) {
        syncModifiers(e)
        if model.tool != .select, model.tool != .hand { toolMoved(e, mouse ?? .zero) }
        needsDisplay = true
    }

    func selectKey(_ e: NSEvent, _ flags: NSEvent.ModifierFlags) -> Bool {
        let ids = model.selectionIds
        if let sk = e.specialKey {
            switch sk {
            case .leftArrow, .rightArrow, .upArrow, .downArrow:
                guard !ids.isEmpty else { return true }
                let step: MM = flags.contains(.command) ? 100 : flags.contains(.shift) ? 10 : 1
                var dx: MM = 0, dy: MM = 0
                switch sk {
                case .leftArrow: dx = -step
                case .rightArrow: dx = step
                case .upArrow: dy = step
                default: dy = -step
                }
                model.perform("Nudge") { p in try p.moveObjects(ids, by: P3(dx, dy, 0)) }
                return true
            case .delete, .deleteForward:
                model.deleteUnlocked(ids)
                return true
            default: break
            }
        }
        if e.keyCode == 51 || e.keyCode == 117 { model.deleteUnlocked(ids); return true }
        if flags.isDisjoint(with: [.command, .control, .option]), e.charactersIgnoringModifiers?.lowercased() == "r" {
            model.rotate(ids, by: flags.contains(.shift) ? -90 : 90)
            return true
        }
        return false
    }

    func escape() {
        if moveDrag?.started == true || handleDrag?.started == true || marquee != nil {
            cancelDrags()
            return
        }
        if moveDrag != nil || handleDrag != nil { cancelDrags(); return }
        if toolHasState {
            cancelInteraction(clearSelection: false)
            return
        }
        switch model.tool {
        case .select: if !model.selection.isEmpty { model.selection = [] }
        default: model.tool = .select // also leaves the Hand tool
        }
        needsDisplay = true
    }

    var toolHasState: Bool {
        !wallPoints.isEmpty || !wallInput.isEmpty || !roomPoints.isEmpty || dimA != nil || measureA != nil || calA != nil
    }
}
