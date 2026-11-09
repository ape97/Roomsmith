import AppKit
import RoomsmithCore

// Right-click menu of the plan: dimension chains for the selected walls.

extension PlanNSView {
    /// Walls of the active level that are selected, in document order.
    private var selectedWallIds: [UUID] {
        let level = levelId
        return project.walls.filter { $0.levelId == level && model.selection.contains($0.id) }.map(\.id)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard model.tool == .select, handleDrag == nil, moveDrag == nil else { return nil }
        // Like a left click: a wall outside the selection becomes the selection first.
        if let hit = hitObject(at: point(event)), project.wall(hit) != nil || project.instance(hit) != nil || project.group(hit) != nil,
           !model.selection.contains(hit) {
            model.selection = [hit]
        }
        let n = selectedWallIds.count
        let furniture = model.selectionIds.filter { project.instance($0) != nil || project.group($0) != nil }
        guard n > 0 || !furniture.isEmpty else { return nil }
        let menu = NSMenu()
        if n > 0 {
            let title = n == 1 ? "Add Dimension Chain" : "Add Dimension Chains (\(n) Walls)"
            let item = NSMenuItem(title: title, action: #selector(addDimensionChainsForSelection(_:)), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if !furniture.isEmpty {
            if n > 0 { menu.addItem(.separator()) }
            menu.addSaveToLibrary(model: model, ids: furniture)
        }
        return menu
    }

    /// One chain per selected wall on its outer face (left face when the outside is unclear), 500 mm from the wall,
    /// split at openings, with a total. One undo step for all walls.
    @objc func addDimensionChainsForSelection(_ sender: Any?) {
        let walls = selectedWallIds
        guard !walls.isEmpty else { return }
        let level = levelId
        var made: [UUID] = []
        let name = walls.count == 1 ? "Add Dimension Chain" : "Add \(walls.count) Dimension Chains"
        let ok = model.perform(name) { p in
            for w in walls {
                let chain = try DimensionChains.wallChain(p, wallId: w, side: .auto, offset: 500)
                made += try p.addDimensionChain(levelId: level, points: chain.points, offset: chain.offset, includeTotal: true)
            }
        }
        if ok { model.selection = Set(made) }
        needsDisplay = true
    }
}
