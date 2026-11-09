import AppKit
import RoomsmithCore

/// Drop target of the 3D view: furniture dragged from the library lands on the floor of the active level under the
/// pointer (same payload, command and undo step as the plan drop, `PlanDrop.swift`). Snaps to the grid like the plan
/// unless Option is held; wall snapping stays a plan feature.
extension SceneARView {
    func registerDropTypes() { registerForDraggedTypes([.string]) }

    private func dropSource(_ info: NSDraggingInfo) -> FurnitureDragSource? {
        guard let text = info.draggingPasteboard.string(forType: .string) else { return nil }
        return FurnitureDragSource(payload: text)
    }

    /// Floor point (mm, plan coordinates) under a window location, or nil when the ray misses the floor plane.
    /// `piece` is the size of what is dropped: a surface hit only counts when the piece fits on it and the surface
    /// qualifies as a carrier (`RestingField`); nil (several pieces, unknown size) always uses the floor.
    func floorPoint(_ windowLocation: NSPoint, snap: Bool, piece: Size3?) -> P2? {
        let p = convert(windowLocation, from: nil)
        let r = renderer.ray(at: SIMD2(Double(p.x), Double(p.y)))
        let settings = renderer.model.project.settings.snap
        // Over a table or shelf the pointer ray meets its top first: drop there (the height follows from the furniture
        // under the point). Option skips this and uses the floor.
        if !NSEvent.modifierFlags.contains(.option), let piece, let levelId = renderer.model.activeLevel?.id,
           let hit = RestingSurface.rayHit(origin: r.origin, direction: r.dir, elevation: renderer.activeElevation,
                                           field: restingField(levelId: levelId), piece: piece) {
            let p = DropPoint.snapped(hit.xy.x, hit.xy.y, settings: settings, modifierOff: !snap)
            if p.isInRange { return p }
        }
        return DropPoint.onFloor(origin: r.origin, direction: r.dir, elevation: renderer.activeElevation,
                                 settings: settings, modifierOff: !snap)
    }

    /// The carriers of the active level, built once per project revision and drag (`draggingUpdated` asks for every
    /// mouse move); dropped when the drag ends.
    private func restingField(levelId: UUID) -> RestingField {
        let rev = renderer.model.project.revision, lamps = renderer.options.showLamps
        if let c = dropFieldCache, c.revision == rev, c.levelId == levelId, c.showLamps == lamps { return c.field }
        let field = RestingField(project: renderer.model.project, levelId: levelId, excluding: [], group: nil, showLamps: lamps)
        dropFieldCache = (rev, levelId, lamps, field)
        return field
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dropFieldCache = nil }
    override func draggingEnded(_ sender: NSDraggingInfo) { dropFieldCache = nil }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { dropFieldCache = nil }

    private func dropTarget(_ info: NSDraggingInfo) -> (FurnitureDragSource, P2)? {
        guard renderer.model.activeLevel != nil, let source = dropSource(info),
              let def = renderer.model.project.dragDefinition(source),
              let at = floorPoint(info.draggingLocation, snap: !NSEvent.modifierFlags.contains(.option), piece: def.size) else { return nil }
        return (source, at)
    }

    /// Furniture dragged out of another open project, with the floor point under the pointer.
    private func transferTarget(_ info: NSDraggingInfo) -> ((source: AppModel, ids: [UUID]), P2)? {
        guard let t = renderer.model.transferDrop(info.draggingPasteboard.string(forType: .string)),
              renderer.model.activeLevel != nil,
              let at = floorPoint(info.draggingLocation, snap: !NSEvent.modifierFlags.contains(.option),
                                  piece: transferPieceSize(t)) else { return nil }
        return (t, at)
    }

    /// Size of a transferred piece; only a single piece is put onto furniture, so several give nil (floor).
    private func transferPieceSize(_ t: (source: AppModel, ids: [UUID])) -> Size3? {
        guard t.ids.count == 1, let inst = t.source.project.instance(t.ids[0]),
              let def = t.source.project.definition(inst.definitionId) else { return nil }
        return FurnitureResolver.size(of: inst, definition: def)
    }

    /// Library entry dragged from the sidebar, with the floor point under the pointer.
    private func libraryTarget(_ info: NSDraggingInfo) -> (UUID, P2)? {
        guard let id = AppModel.libraryEntryId(info.draggingPasteboard.string(forType: .string)), renderer.model.activeLevel != nil,
              let at = floorPoint(info.draggingLocation, snap: !NSEvent.modifierFlags.contains(.option),
                                  piece: LibraryModel.shared.entries.first { $0.id == id }?.size) else { return nil }
        return (id, at)
    }

    private func operation(_ info: NSDraggingInfo) -> NSDragOperation {
        if libraryTarget(info) != nil { return .copy }
        if let (t, _) = transferTarget(info) { return AppModel.transferOperation(info, from: t.source) }
        return dropTarget(info) == nil ? [] : .copy
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { operation(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { operation(sender) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let (id, at) = libraryTarget(sender) { return renderer.model.dropLibrary(id, at: at) }
        if let (t, at) = transferTarget(sender) {
            return renderer.model.dropTransfer(t, at: at, move: AppModel.transferOperation(sender, from: t.source) == .move)
        }
        guard let (source, at) = dropTarget(sender) else { return false }
        return renderer.model.placeDragged(source, at: at)
    }
}
