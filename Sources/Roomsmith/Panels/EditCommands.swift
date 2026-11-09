import SwiftUI
import AppKit
import RoomsmithCore

/// The Arrange menu. Items act on the current selection and are disabled when they do not apply.
struct EditCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Arrange") {
            let ids = model.selectionIds
            let lockable = model.lockableIds(ids)
            let hideable = model.hideableIds(ids)
            let allLocked = !lockable.isEmpty && lockable.allSatisfy { model.isLockedForMenu($0) }
            let allHidden = !hideable.isEmpty && hideable.allSatisfy { model.isHidden($0) }

            Button("Delete") {
                if model.textEditingActive { NSApp.sendAction(#selector(NSText.deleteBackward(_:)), to: nil, from: nil) }
                else { model.deleteObjects(model.selectionIds) }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(ids.isEmpty && !model.textEditingActive)

            Button("Duplicate") { model.duplicateObjects(model.selectionIds) }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(ids.isEmpty)

            Divider()
            Button("Group") { model.groupObjects(model.selectionIds) }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(model.groupableIds(ids).isEmpty)
            Button("Ungroup") { model.ungroupObjects(model.selectionIds) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(model.groupIds(for: ids).isEmpty)

            Divider()
            Button(allLocked ? "Unlock" : "Lock") { model.toggleLock(model.selectionIds) }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(lockable.isEmpty)
            Button(allHidden ? "Show" : "Hide") { model.toggleVisible(model.selectionIds) }
                .disabled(hideable.isEmpty)

            Divider()
            Button("Rotate 90° Left") { model.rotate(model.selectionIds, by: 90) }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(ids.isEmpty)
            Button("Rotate 90° Right") { model.rotate(model.selectionIds, by: -90) }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(ids.isEmpty)

            Divider()
            Button("Select All on Level") {
                if model.textEditingActive { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
                else { model.selectAllOnLevel() }
            }
            .keyboardShortcut("a", modifiers: .command)
            Button("Deselect All") { model.selection = [] }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(ids.isEmpty)
            Button("Frame Selection") { model.frame(model.selectionIds) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(ids.isEmpty)
        }
    }
}
