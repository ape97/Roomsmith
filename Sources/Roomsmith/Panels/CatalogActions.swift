import SwiftUI
import RoomsmithCore

extension AppModel {
    /// Catalog context menu: deletes a material, design or product when nothing uses it (one undo step). A used entry
    /// is refused with a message that names the number of users; the entry and its references stay untouched.
    @discardableResult
    func deleteCatalogEntry(_ id: UUID) -> Bool {
        let name = project.displayName(of: id)
        let ok = perform("Delete \(name)") { try $0.deleteUnusedCatalogEntry(id) }
        if ok { statusMessage = "Deleted \(name)" }
        return ok
    }

    /// Own designs that "Remove Unused Furniture" would delete: nothing placed from them and no product link.
    var removableDefinitionCount: Int { project.prunableDefinitions().count }

    /// Asks first (count, undo hint), then removes. The ask is skipped in test mode, like `confirmDiscard`.
    func confirmAndRemoveUnusedFurniture() {
        let n = removableDefinitionCount
        guard n > 0 else { statusMessage = "No unused furniture to remove"; return }
        if !AppDefaults.isTestMode {
            let a = NSAlert()
            a.messageText = "Remove \(n) unused furniture design\(n == 1 ? "" : "s")?"
            a.informativeText = "Furniture placed in the plan is not touched. Designs linked to a product stay. You can undo this."
            a.addButton(withTitle: "Remove"); a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        removeUnusedFurniture()
    }

    /// Deletes every design `removableDefinitionCount` counts, as one undo step. Returns how many went.
    @discardableResult
    func removeUnusedFurniture() -> Int {
        var removed = 0
        let ok = perform("Remove Unused Furniture") { removed = try $0.removeUnusedDefinitions().count }
        guard ok else { return 0 }
        statusMessage = removed == 0 ? "No unused furniture to remove" : "Removed \(removed) unused furniture design\(removed == 1 ? "" : "s")"
        return removed
    }
}
