import SwiftUI
import RoomsmithCore

/// Small dialogs of the library sidebar: new or renamed category, renamed entry, and the delete confirmations.
struct LibraryDialogSheet: View {
    let dialog: LibraryDialog
    @Environment(\.dismiss) private var dismiss
    private let library = LibraryModel.shared
    @State private var text = ""
    @State private var target: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(heading).font(.headline)
            switch dialog {
            case .newCategory, .renameCategory, .renameEntry:
                TextField("Name", text: $text).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("libraryDialogName").onSubmit(commit)
            case .deleteCategory(let id):
                Text("The furniture in this category is kept.").font(.callout).foregroundStyle(.secondary)
                Picker("Move it to", selection: $target) {
                    Text("Unsorted").tag(UUID?.none)
                    ForEach(library.categories.filter { $0.id != id }) { Text($0.name).tag(UUID?.some($0.id)) }
                }
            case .deleteEntry(let id):
                Text("\"\(library.entry(id)?.name ?? "This entry")\" is deleted from My Furniture. Placed copies in projects stay.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let e = library.actionError { Text(e).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action: commit) { Text(confirm) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(needsText && text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18).frame(width: 340)
        .onAppear {
            library.actionError = nil
            switch dialog {
            case .renameCategory(let id): text = library.category(id)?.name ?? ""
            case .renameEntry(let id): text = library.entry(id)?.name ?? ""
            default: break
            }
        }
    }

    private var needsText: Bool {
        switch dialog { case .newCategory, .renameCategory, .renameEntry: true; default: false }
    }

    private var heading: String {
        switch dialog {
        case .newCategory: "New category"
        case .renameCategory: "Rename category"
        case .renameEntry: "Rename furniture"
        case .deleteCategory(let id): "Delete \"\(library.category(id)?.name ?? "category")\"?"
        case .deleteEntry: "Delete from My Furniture?"
        }
    }

    private var confirm: String {
        switch dialog {
        case .newCategory: "Create"
        case .renameCategory, .renameEntry: "Rename"
        case .deleteCategory, .deleteEntry: "Delete"
        }
    }

    private func commit() {
        if needsText && text.trimmingCharacters(in: .whitespaces).isEmpty { return }
        let ok: Bool
        switch dialog {
        case .newCategory: ok = library.createCategory(text)
        case .renameCategory(let id): ok = library.renameCategory(id, to: text)
        case .renameEntry(let id): ok = library.rename(id, to: text)
        case .deleteCategory(let id): ok = library.deleteCategory(id, moveTo: target)
        case .deleteEntry(let id): ok = library.delete(id)
        }
        if ok { dismiss() }
    }
}
