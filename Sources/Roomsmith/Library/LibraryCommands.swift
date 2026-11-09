import AppKit
import SwiftUI
import RoomsmithCore

/// Edit > Save Selection to My Furniture, with a submenu to pick the category.
struct LibraryCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            SaveToLibraryMenu(title: "Save Selection to My Furniture", ids: model.selectionIds, model: model)
            Button("Remove Unused Furniture…") { model.confirmAndRemoveUnusedFurniture() }
                .disabled(model.removableDefinitionCount == 0)
        }
    }
}

/// "Save to My Furniture" as a submenu of the categories (or a plain button while there are none).
struct SaveToLibraryMenu: View {
    let title: String
    let ids: [UUID]
    let model: AppModel
    private let library = LibraryModel.shared

    var body: some View {
        let usable = ids.contains { model.project.instance($0) != nil || model.project.group($0) != nil }
        if library.categories.isEmpty {
            Button(title) { model.saveObjectsToLibrary(ids) }.disabled(!usable)
        } else {
            Menu(title) {
                Button("Unsorted") { model.saveObjectsToLibrary(ids) }
                Divider()
                ForEach(library.categories) { c in Button(c.name) { model.saveObjectsToLibrary(ids, category: c.id) } }
            }
            .disabled(!usable)
        }
    }
}

/// Target for the AppKit plan menu: runs one save from an `NSMenuItem`.
@MainActor
final class LibrarySaveAction: NSObject {
    private let model: AppModel
    private let ids: [UUID]
    private let category: UUID?
    init(model: AppModel, ids: [UUID], category: UUID?) { self.model = model; self.ids = ids; self.category = category }
    @objc func run(_ sender: Any?) { model.saveObjectsToLibrary(ids, category: category) }
}

extension NSMenu {
    /// Appends "Save to My Furniture" (with the categories as a submenu) for the given furniture or groups.
    @MainActor
    func addSaveToLibrary(model: AppModel, ids: [UUID]) {
        let cats = LibraryModel.shared.categories
        func item(_ title: String, category: UUID?) -> NSMenuItem {
            let action = LibrarySaveAction(model: model, ids: ids, category: category)
            let i = NSMenuItem(title: title, action: #selector(LibrarySaveAction.run(_:)), keyEquivalent: "")
            i.target = action
            i.representedObject = action   // keeps the target alive as long as the item
            return i
        }
        if cats.isEmpty {
            addItem(item("Save to My Furniture", category: nil))
            return
        }
        let parent = NSMenuItem(title: "Save to My Furniture", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.addItem(item("Unsorted", category: nil))
        sub.addItem(.separator())
        for c in cats { sub.addItem(item(c.name, category: c.id)) }
        parent.submenu = sub
        addItem(parent)
    }
}
