import AppKit
import simd
import RoomsmithCore

/// A library item being dragged over the plan.
struct PlanDropState {
    var source: FurnitureDragSource
    var definition: FurnitureDefinition
    var position: P2
    var guides: [SnapGuide]
}

/// Drop target of the plan: furniture dragged from the library is placed at the pointer (one command, one undo step).
extension PlanNSView {
    static let dropTypes: [NSPasteboard.PasteboardType] = [.string]

    func dropSource(_ info: NSDraggingInfo) -> FurnitureDragSource? {
        guard let text = info.draggingPasteboard.string(forType: .string) else { return nil }
        return FurnitureDragSource(payload: text)
    }

    /// Snapped footprint centre for a pointer position (mm). Option disables snapping, like when moving.
    func dropPosition(_ def: FurnitureDefinition, at m: V2, snap: Bool) -> (P2, [SnapGuide]) {
        let settings = project.settings.snap
        let on = settings.enabled && snap
        let proposed = P2(rounding: m)
        var inst = FurnitureInstance(definitionId: def.id, levelId: levelId, name: def.name, position: P3(proposed.x, proposed.y, 0))
        inst.stateId = def.defaultStateId
        if on, settings.toWalls {
            var ctx = baseScene.snapContext
            ctx.anchor = nil
            let r = SnapEngine.snapFurniture(inst, definition: def, proposed: proposed, context: ctx,
                                             tolerance: snapTolerance, alignRotation: false)
            if r.kind != .none { return (r.position, r.guides) }
        }
        return (P2(SnapEngine.snapDelta(Double(proposed.x), grid: settings.grid, enabled: on && settings.toGrid),
                   SnapEngine.snapDelta(Double(proposed.y), grid: settings.grid, enabled: on && settings.toGrid)), [])
    }

    func updateDrop(_ info: NSDraggingInfo) -> NSDragOperation {
        // Furniture from the global library: outline of its overall size at the grid-snapped drop point.
        if let id = AppModel.libraryEntryId(info.draggingPasteboard.string(forType: .string)) {
            dropState = nil
            if let e = LibraryModel.shared.entry(id) {
                let at = DropPoint.snapped(P2(rounding: vp.model(convert(info.draggingLocation, from: nil))), settings: project.settings.snap,
                                           modifierOff: NSEvent.modifierFlags.contains(.option))
                libraryDrop = (at, e.size)
            }
            needsDisplay = true
            return .copy
        }
        libraryDrop = nil
        // Furniture dragged out of another open project: copy, or move with ⌘.
        if let t = model.transferDrop(info.draggingPasteboard.string(forType: .string)) {
            if dropState != nil { dropState = nil; needsDisplay = true }
            return AppModel.transferOperation(info, from: t.source)
        }
        guard let source = dropSource(info), let def = project.dragDefinition(source) else { return [] }
        let m = vp.model(convert(info.draggingLocation, from: nil))
        let (pos, guides) = dropPosition(def, at: m, snap: !NSEvent.modifierFlags.contains(.option))
        dropState = PlanDropState(source: source, definition: def, position: pos, guides: guides)
        needsDisplay = true
        return .copy
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrop(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrop(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropState = nil; libraryDrop = nil; needsDisplay = true }
    override func draggingEnded(_ sender: NSDraggingInfo) { dropState = nil; libraryDrop = nil; needsDisplay = true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { dropState = nil; libraryDrop = nil; needsDisplay = true }
        if let entry = AppModel.libraryEntryId(sender.draggingPasteboard.string(forType: .string)) {
            return model.dropLibrary(entry, at: P2(rounding: vp.model(convert(sender.draggingLocation, from: nil))))
        }
        if let t = model.transferDrop(sender.draggingPasteboard.string(forType: .string)) {
            let at = P2(rounding: vp.model(convert(sender.draggingLocation, from: nil)))
            return model.dropTransfer(t, at: at, move: AppModel.transferOperation(sender, from: t.source) == .move)
        }
        guard updateDrop(sender) != [], let d = dropState else { return false }
        return model.placeDragged(d.source, at: d.position)
    }

    /// Translucent top view at the drop position plus the snap guides.
    func drawDropPreview(_ ctx: CGContext) {
        if let l = libraryDrop {
            let hw = Double(l.size.width) / 2, hd = Double(l.size.depth) / 2, c = V2(Double(l.center.x), Double(l.center.y))
            let path = screenPath([c + V2(-hw, -hd), c + V2(hw, -hd), c + V2(hw, hd), c + V2(-hw, hd)])
            ctx.saveGState()
            ctx.setFillColor(PlanColors.accent.withAlphaComponent(0.18).cgColor)
            ctx.addPath(path); ctx.fillPath()
            ctx.setStrokeColor(PlanColors.accent.cgColor); ctx.setLineWidth(1.5)
            ctx.addPath(path); ctx.strokePath()
            ctx.restoreGState()
            return
        }
        guard let d = dropState else { return }
        var inst = FurnitureInstance(definitionId: d.definition.id, levelId: levelId, name: d.definition.name,
                                     position: P3(d.position.x, d.position.y, 0))
        inst.stateId = d.definition.defaultStateId
        var colors: [UUID: RoomsmithCore.RGBColor] = [:]
        for m in project.materials { colors[m.id] = m.color }
        for m in BuiltinCatalog.materials where colors[m.id] == nil { colors[m.id] = m.color }
        let top = FurnitureTopView.make(inst, definition: d.definition, colors: colors)
        let rect = FurnitureResolver.footprint(of: inst, definition: d.definition)
        ctx.saveGState()
        ctx.setAlpha(0.75)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        for shape in top.shapes {
            let c = topFill(shape.color)
            let path = screenPath(shape.points)
            ctx.setFillColor(c.fill); ctx.addPath(path); ctx.fillPath()
            ctx.setStrokeColor(c.line); ctx.setLineWidth(0.75); ctx.addPath(path); ctx.strokePath()
        }
        ctx.endTransparencyLayer()
        ctx.setStrokeColor(PlanColors.accent.cgColor)
        ctx.setLineWidth(1.5)
        ctx.addPath(screenPath(rect.corners)); ctx.strokePath()
        ctx.restoreGState()
        drawGuides(ctx, d.guides)
    }
}

extension AppModel {
    /// Places a dragged library item on the active level with its centre at `at` and selects it.
    @discardableResult
    func placeDragged(_ source: FurnitureDragSource, at: P2) -> Bool {
        guard let level = activeLevel else { return false }
        var newId: UUID?
        let ok = perform("Place \(project.dragName(source))") { p in
            // A piece dropped over a table or shelf stands on it; Option drops it to the floor.
            newId = try p.placeDragged(source, levelId: level.id, at: at,
                                       restOnFurniture: !NSEvent.modifierFlags.contains(.option))
        }
        if ok, let newId { selection = [newId] }
        return ok
    }
}

extension AppModel {
    /// A drag token (`roomsmith-transfer:…`) of furniture from another open project, resolved by the workspace.
    func transferDrop(_ text: String?) -> (source: AppModel, ids: [UUID])? {
        guard let text, text.hasPrefix(TransferToken.prefix), let workspace,
              let r = workspace.resolve(payload: text), r.source !== self else { return nil }
        let ids = workspace.transferable(r.token.ids, in: r.source)
        return ids.isEmpty ? nil : (r.source, ids)
    }

    /// Copy by default; ⌘ moves when the drag source allows it.
    static func transferOperation(_ info: NSDraggingInfo, from source: AppModel) -> NSDragOperation {
        let wantsMove = NSEvent.modifierFlags.contains(.command)
        return wantsMove && info.draggingSourceOperationMask.contains(.move) ? .move : .copy
    }

    /// Drops furniture of another project here (middle of the furniture at `at`).
    @discardableResult
    func dropTransfer(_ t: (source: AppModel, ids: [UUID]), at: P2, move: Bool) -> Bool {
        guard let workspace else { return false }
        return workspace.transferReportingErrors(ids: t.ids, from: t.source, to: self, move: move, at: at)
    }
}

// MARK: - Dragging out of the plan into another project

extension PlanNSView: NSDraggingSource {
    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Only inside Roomsmith: the payload is a token that other apps cannot resolve.
        context == .withinApplication ? [.copy, .move] : []
    }

    /// Replaces the move in progress by a drag session carrying the transfer token of the selection.
    func beginTransferDrag(_ d: PlanMoveDrag, _ e: NSEvent, at pt: CGPoint) {
        guard let workspace = model.workspace else { return }
        let ids = workspace.transferable(d.ids, in: model)
        guard !ids.isEmpty else { return }
        cancelDrags()
        let payload = TransferToken(sourceId: model.id, ids: ids).payload
        let item = NSDraggingItem(pasteboardWriter: Self.transferPasteboardItem(payload))
        let image = NSImage(systemSymbolName: "square.on.square", accessibilityDescription: nil) ?? NSImage()
        item.setDraggingFrame(NSRect(x: pt.x - 18, y: pt.y - 18, width: 36, height: 36), contents: image)
        beginDraggingSession(with: [item], event: e, source: self)
        model.statusMessage = "Drop in the other project to copy; hold ⌘ to move"
    }

    private static func transferPasteboardItem(_ payload: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(payload, forType: .string)
        return item
    }
}
