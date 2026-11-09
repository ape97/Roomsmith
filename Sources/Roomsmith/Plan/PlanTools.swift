import AppKit
import simd
import RoomsmithCore

// Drawing tools: wall, room, door/window/opening, dimension, measure, calibrate.

extension PlanNSView {
    // MARK: Dispatch

    /// Pointer moved (or a modifier changed) while a drawing tool is active.
    func toolMoved(_ e: NSEvent, _ pt: CGPoint) {
        guard let m = mouseModel else { return }
        switch model.tool {
        case .wall:
            snapResult = snapped(m, anchor: wallPoints.last)
        case .room:
            snapResult = roomSnap(m)
        case .door, .window, .opening:
            updateProposal()
        case .dimension, .measure, .calibrate:
            snapResult = snapped(m)
            if model.tool == .dimension, let a = dimA, let b = dimB {
                let ax = Geo.axis(a, b)
                let off = simd_dot(m - a.v, ax.normal)
                dimOffset = MM(SnapEngine.snapDelta(off, grid: 10, enabled: snapOn))
            }
        case .select, .hand: break
        }
    }

    // MARK: Wall tool

    /// Current end point of the wall segment being drawn: typed length along the pointer direction, else the snapped pointer.
    func wallCandidate() -> P2? {
        guard let last = wallPoints.last else { return snapResult?.point }
        if !wallInput.isEmpty {
            guard let len = LengthUnit.parse(wallInput, defaultUnit: project.settings.displayUnit), len > 0 else { return nil }
            var dir = V2(1, 0)
            if let m = snapResult?.point, m != last {
                dir = simd_normalize(m.v - last.v)
            } else if let m = mouseModel, simd_length(m - last.v) > 1 {
                dir = simd_normalize(m - last.v)
            }
            return P2(origin: last, direction: dir, length: Double(len))
        }
        return snapResult?.point
    }

    func wallDown(_ e: NSEvent, _ pt: CGPoint) {
        guard let m = mouseModel else { return }
        snapResult = snapped(m, anchor: wallPoints.last)
        if e.clickCount >= 2, wallPoints.count >= 2 { finishWall(closed: false); return }
        guard let p = wallInput.isEmpty ? snapResult?.point : wallCandidate() else { return }
        if wallPoints.count >= 3, let first = wallPoints.first {
            let s = vp.screen(first)
            if hypot(Double(s.x - pt.x), Double(s.y - pt.y)) <= 10 { finishWall(closed: true); return }
        }
        if p == wallPoints.last { return }
        wallPoints.append(p)
        wallInput = ""
    }

    func finishWall(closed: Bool) {
        let pts = wallPoints
        wallPoints = []; wallInput = ""
        guard pts.count >= 2 else { needsDisplay = true; return }
        var ids: [UUID] = []
        let level = levelId
        let s = project.settings
        if model.perform(closed ? "Draw Walls (closed)" : "Draw Walls", { p in
            ids = try p.addWalls(levelId: level, points: pts, closed: closed,
                                 thickness: s.defaultWallThickness, height: s.defaultWallHeight)
        }) {
            model.selection = Set(ids)
        }
        needsDisplay = true
    }

    /// Keyboard in the wall tool. Returns true when handled.
    func wallKey(_ e: NSEvent) -> Bool {
        switch e.keyCode {
        case 36, 76: // Return / Enter
            if !wallInput.isEmpty {
                if let p = wallCandidate(), p != wallPoints.last {
                    if wallPoints.isEmpty { wallInput = ""; return true }
                    wallPoints.append(p)
                } else {
                    model.lastError = "Type a length (\(project.settings.displayUnit.bareNumberHint))"
                }
                wallInput = ""
            } else if wallPoints.count >= 2 {
                finishWall(closed: false)
            } else {
                wallPoints = []
            }
            needsDisplay = true
            return true
        case 51: // Backspace
            if !wallInput.isEmpty { wallInput.removeLast() }
            else if !wallPoints.isEmpty { wallPoints.removeLast() }
            needsDisplay = true
            return true
        default: break
        }
        let flags = e.modifierFlags.intersection([.command, .control, .option])
        guard flags.isEmpty, !wallPoints.isEmpty, let chars = e.characters else { return false }
        let allowed = Set("0123456789.,-mcMC ")
        var took = false
        for ch in chars where allowed.contains(ch) && !(ch == " " && wallInput.isEmpty) {
            wallInput.append(ch); took = true
        }
        if took { needsDisplay = true }
        return took
    }

    // MARK: Room tool

    func roomSnap(_ m: V2) -> SnapResult {
        let tol = vp.mm(10)
        var best: (V2, Double)?
        for c in baseScene.corners {
            let d = simd_length(c - m)
            if d <= tol, best == nil || d < best!.1 { best = (c, d) }
        }
        if let b = best, snapOn { return SnapResult(point: P2(rounding: b.0), kind: .wallEndpoint) }
        return snapped(m, anchor: roomPoints.last)
    }

    func roomDown(_ e: NSEvent, _ pt: CGPoint) {
        guard let m = mouseModel else { return }
        let r = roomSnap(m)
        snapResult = r
        if e.clickCount >= 2 {
            if roomPoints.count <= 1 {
                roomPoints = []
                detectRoom(at: m)
            } else if roomPoints.count >= 3 {
                finishRoom()
            }
            return
        }
        if roomPoints.count >= 3, let first = roomPoints.first {
            let s = vp.screen(first)
            if hypot(Double(s.x - pt.x), Double(s.y - pt.y)) <= 10 { finishRoom(); return }
        }
        if r.point != roomPoints.last { roomPoints.append(r.point) }
    }

    func finishRoom() {
        var pts: [P2] = []
        for p in roomPoints where p != pts.last { pts.append(p) }
        if pts.count > 1, pts.first == pts.last { pts.removeLast() }
        roomPoints = []
        guard pts.count >= 3 else { model.lastError = "A room needs at least 3 corners"; needsDisplay = true; return }
        addRoom(points: pts)
    }

    func addRoom(points: [P2]) {
        guard Geo.isSimplePolygon(points), Geo.area(points) > 1 else {
            model.lastError = "The room outline crosses itself or is empty"
            needsDisplay = true
            return
        }
        let level = levelId
        let name = "Room \(project.rooms.filter { $0.levelId == level }.count + 1)"
        var id: UUID?
        if model.perform("Add Room", { p in id = try p.addRoom(levelId: level, name: name, points: points) }), let id {
            model.selection = [id]
        }
        needsDisplay = true
    }

    /// Detects the closed wall loop around `m` (walls must meet at their end points) and adds a room inside it.
    func detectRoom(at m: V2) {
        let walls = project.walls.filter { $0.levelId == levelId && $0.start != $0.end }
        guard !walls.isEmpty else { model.lastError = "Draw walls first, or click the room corners one by one"; return }
        guard let poly = RoomFinder.face(containing: m, walls: walls) else {
            model.lastError = "No closed wall loop around this point. Click the corners instead."
            return
        }
        addRoom(points: poly)
    }

    // MARK: Door / window / opening

    var openingDefaults: (kind: OpeningKind, width: MM, height: MM, sill: MM?) {
        switch model.tool {
        case .window: (.window, 1200, 1250, nil)
        case .opening: (.opening, 900, 2100, 0)
        default: (.door, 900, 2100, 0)
        }
    }

    func updateProposal() {
        proposal = nil
        hint = nil
        guard let m = mouseModel else { return }
        let sc = baseScene
        let reach = vp.mm(14)
        var best: (idx: Int, dist: Double, t: Double)?
        for i in sc.query(lo: m - V2(reach + 500, reach + 500), hi: m + V2(reach + 500, reach + 500)) {
            let r = sc.refs[i]
            guard r.kind == .wall else { continue }
            let w = sc.walls[r.index].wall
            let hit = Geo.pointSegment(m, w.start.v, w.end.v)
            let d = max(0, hit.distance - Double(w.thickness) / 2)
            guard d <= reach else { continue }
            if best == nil || d < best!.dist { best = (r.index, d, hit.t) }
        }
        guard let b = best else { return }
        let item = sc.walls[b.idx]
        let w = item.wall
        let ax = Geo.axis(w.start, w.end)
        let d = openingDefaults
        guard ax.length >= Double(d.width) else { hint = "Wall is too short for a \(d.width) mm \(d.kind.rawValue)"; return }
        hint = nil
        let raw = b.t * ax.length
        var off = (raw / 10).rounded() * 10
        off = min(max(off, Double(d.width) / 2), ax.length - Double(d.width) / 2)
        let axisPoint = w.start.v + ax.dir * raw
        let inward = simd_dot(m - axisPoint, ax.normal) >= 0
        var o = Opening(wallId: w.id, kind: d.kind, offset: MM(off.rounded()), width: d.width, height: d.height,
                        sill: d.sill ?? (d.kind == .window ? 900 : 0))
        o.inward = inward
        o.flipped = flipHinge != NSEvent.modifierFlags.contains(.shift)
        let it = PlanScene.makeOpeningItem(o, wall: w, outline: item.outline, wallIndex: b.idx)
        proposal = PlanOpeningProposal(wallId: w.id, opening: o, item: it)
    }

    func openingDown(_ e: NSEvent, _ pt: CGPoint) {
        updateProposal()
        guard let pr = proposal else { return }
        let o = pr.opening
        var id: UUID?
        if model.perform("Add \(o.kind.rawValue.capitalized)", { p in
            let new = try p.addOpening(wallId: o.wallId, kind: o.kind, offset: o.offset, width: o.width, height: o.height, sill: o.sill)
            try p.updateOpening(new, flipped: o.flipped, inward: o.inward)
            id = new
        }), let id {
            model.selection = [id]
        }
        updateProposal()
    }

    // MARK: Dimension tool

    func dimensionDown(_ e: NSEvent, _ pt: CGPoint) {
        guard let m = mouseModel else { return }
        let r = snapped(m)
        if dimA == nil { dimA = r.point; return }
        if dimB == nil {
            if r.point == dimA { return }
            dimB = r.point
            dimOffset = 300
            toolMoved(e, pt)
            return
        }
        guard let a = dimA, let b = dimB else { return }
        let off = dimOffset, level = levelId
        var id: UUID?
        if model.perform("Add Dimension", { p in id = try p.addDimension(levelId: level, a: a, b: b, offset: off) }), let id {
            model.selection = [id]
        }
        dimA = nil; dimB = nil
    }

    // MARK: Measure tool

    func measureDown(_ e: NSEvent, _ pt: CGPoint) {
        guard let m = mouseModel else { return }
        let r = snapped(m)
        if measureA == nil || measureB != nil {
            measureA = r.point; measureB = nil
        } else if r.point != measureA {
            measureB = r.point
        }
    }

    /// Text for the measure tool's distance.
    func distanceText(_ a: P2, _ b: P2) -> String {
        DistanceText.text(mm: MM(simd_length(b.v - a.v).rounded()), unit: project.settings.displayUnit)
    }

    // MARK: Calibrate tool

    func calibrationTarget() -> BackgroundImage? {
        let level = levelId
        let all = project.backgrounds.filter { $0.levelId == level }
        if let sel = all.first(where: { model.selection.contains($0.id) }) { return sel }
        let visible = all.filter(\.visible)
        return visible.count == 1 ? visible.first : nil
    }

    func calibrateDown(_ e: NSEvent, _ pt: CGPoint) {
        guard let m = mouseModel else { return }
        guard calibrationTarget() != nil else {
            model.lastError = project.backgrounds.contains { $0.levelId == levelId }
                ? "Select a background image first" : "This level has no background image"
            return
        }
        let r = snapped(m)
        if calA == nil || calB != nil {
            calA = r.point; calB = nil
            return
        }
        guard r.point != calA else { return }
        calB = r.point
        askCalibrationLength()
    }

    func askCalibrationLength() {
        guard let a = calA, let b = calB, let bg = calibrationTarget() else { return }
        let unit = project.settings.displayUnit
        let shown = MM(simd_length(b.v - a.v).rounded())
        let alert = NSAlert()
        alert.messageText = "Calibrate Background"
        alert.informativeText = "The two points are \(unit.format(shown)) apart on the image as it is now. Enter the real distance between them (\(unit.bareNumberHint))."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = unit.format(shown, withUnit: false)
        field.placeholderString = "Length in \(unit.rawValue)"
        alert.accessoryView = field
        alert.addButton(withTitle: "Calibrate")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            MainActor.assumeIsolated {
                guard let self else { return }
                defer { self.calA = nil; self.calB = nil; self.needsDisplay = true }
                guard resp == .alertFirstButtonReturn else { return }
                guard let real = LengthUnit.parse(field.stringValue, defaultUnit: unit), real > 0 else {
                    self.model.lastError = "That is not a valid length (\(unit.bareNumberHint))"
                    return
                }
                self.applyCalibration(bg.id, a: a, b: b, realLength: real)
            }
        }
        if let w = window { alert.beginSheetModal(for: w, completionHandler: finish) } else { finish(alert.runModal()) }
    }

    /// Rescales the image so that the picked world points are `realLength` apart; point A stays where it is.
    func applyCalibration(_ id: UUID, a: P2, b: P2, realLength: MM) {
        guard let bg = project.background(id) else { return }
        let mmpp = bg.mmPerPixel
        let pxA = V2((Double(a.x) - Double(bg.origin.x)) / mmpp, (Double(bg.origin.y) - Double(a.y)) / mmpp)
        let pxB = V2((Double(b.x) - Double(bg.origin.x)) / mmpp, (Double(bg.origin.y) - Double(b.y)) / mmpp)
        let dist = simd_length(pxB - pxA)
        guard dist > 0.5 else { model.lastError = "The two points are too close together"; return }
        let cA = P2(rounding: pxA), cB = P2(rounding: pxB)
        // The stored scale is calibrationLength / pixel distance of the rounded picks; derive the origin from
        // exactly that scale so that point A stays where it is.
        let pd = simd_length(cB.v - cA.v)
        guard pd > 0 else { model.lastError = "The two points are too close together"; return }
        let length = MM((Double(realLength) / dist * pd).rounded())
        let storedMmpp = Double(length) / pd
        let origin = P2(rounding: V2(Double(a.x) - pxA.x * storedMmpp, Double(a.y) + pxA.y * storedMmpp))
        if model.perform("Calibrate Background", { p in
            try p.updateBackground(id) { b in
                b.calibrationA = cA; b.calibrationB = cB; b.calibrationLength = length; b.origin = origin
            }
        }) {
            model.selection = [id]
            model.tool = .select
            fit(selectionOnly: false)
            if realLength < 2000 { model.statusMessage = "Calibrated. A reference of 2 m or more is more accurate." }
        }
    }
}
