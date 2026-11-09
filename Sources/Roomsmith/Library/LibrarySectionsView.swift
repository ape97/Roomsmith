import SwiftUI
import RoomsmithCore

/// What the preview sheet shows.
enum LibraryPreviewTarget: Identifiable, Equatable {
    case entry(UUID)
    case catalog(String)
    var id: String {
        switch self {
        case .entry(let i): "e-\(i)"
        case .catalog(let k): "c-\(k)"
        }
    }
}

/// "My furniture": the global library as collapsible categories of tiles, plus "Unsorted".
/// Entries are dragged into plan or 3D, between categories, or onto a category header.
struct LibrarySectionsView: View {
    let query: String
    let section: LibrarySection?
    @Binding var details: UUID?
    @Binding var preview: LibraryPreviewTarget?
    @Environment(AppModel.self) private var model
    @Environment(Workspace.self) private var workspace
    private let library = LibraryModel.shared

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty || section != nil }

    var body: some View {
        let hits = LibrarySearch.filter(library.entries, query: query, section: section,
                                        categories: library.categories, category: .any)
        CollapsibleSection("My furniture", count: library.entries.count, key: "library.open.mine", forceOpen: searching) {
            VStack(alignment: .leading, spacing: 10) {
                if library.entries.isEmpty && library.categories.isEmpty {
                    Text("Nothing saved yet. Select furniture and choose Edit > Save Selection to My Furniture, or drag it here.")
                        .font(.caption).foregroundStyle(Color(nsColor: .secondaryLabelColor)).padding(.horizontal, 8)
                } else if searching && hits.isEmpty {
                    Text("No matches").font(.caption).foregroundStyle(Color(nsColor: .secondaryLabelColor)).padding(.horizontal, 8)
                }
                ForEach(library.categories) { c in
                    let items = library.entries(in: c.id, matching: hits)
                    if !(searching && items.isEmpty) {
                        categoryBlock(title: c.name, id: c.id, items: items)
                    }
                }
                let loose = library.entries(in: nil, matching: hits)
                if !loose.isEmpty { categoryBlock(title: "Unsorted", id: nil, items: loose) }
                Button { model.sheet = .photoToFurniture(improve: nil) } label: { Label("Furniture from photos…", systemImage: "photo.badge.plus") }
                    .buttonStyle(.borderless).font(.caption).padding(.horizontal, 8)
                    .help("Build furniture from photos and your measurements, on this Mac")
                    .accessibilityIdentifier("libraryFromPhotos")
            }
        }
        if let w = library.warning { Text(w).font(.caption).foregroundStyle(.orange).padding(.horizontal, 8) }
        if let w = library.actionError { Text(w).font(.caption).foregroundStyle(.red).padding(.horizontal, 8) }
    }

    @ViewBuilder
    private func categoryBlock(title: String, id: UUID?, items: [LibraryEntry]) -> some View {
        CollapsibleSection(title, count: items.count, key: "library.open.cat.\(id?.uuidString ?? "unsorted")", forceOpen: searching) {
            if items.isEmpty {
                Text("Empty. Drop furniture on this heading.").font(.caption)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor)).padding(.horizontal, 8)
            } else {
                LibraryGridView {
                    ForEach(items) { e in tile(e) }
                }
            }
        } menu: {
            if let id { categoryMenu(id) }
        }
        .dropDestination(for: String.self) { texts, _ in drop(texts, into: id) }
    }

    @ViewBuilder
    private func categoryMenu(_ id: UUID) -> some View {
        let idx = library.categories.firstIndex { $0.id == id }
        Button("Rename…") { library.dialog = .renameCategory(id) }
        Button("Move Up") { library.moveCategory(id, by: -1) }.disabled(idx == 0)
        Button("Move Down") { library.moveCategory(id, by: 1) }.disabled(idx == library.categories.count - 1)
        Divider()
        Button("Delete…", role: .destructive) { library.dialog = .deleteCategory(id) }
    }

    private func tile(_ e: LibraryEntry) -> some View {
        let level = model.activeLevel?.name ?? "level"
        return LibraryTileView(title: e.name, subtitle: subtitle(e), image: library.picture(for: e),
                               dragPayload: LibraryDragToken(entryId: e.id).payload,
                               actions: LibraryTileActions(edit: { details = e.id }, preview: { preview = .entry(e.id) }, place: { place(e) }),
                               placeLabel: "Place on \(level)",
                               isNew: library.newEntries.contains(e.id), onSeen: { library.markSeen(e.id) })
            .contextMenu {
                Button("Edit…") { details = e.id }
                Button("Preview") { preview = .entry(e.id) }
                Button("Place on \(level)") { place(e) }
                Divider()
                Button("Rename…") { library.dialog = .renameEntry(e.id) }
                Menu("Change Category") {
                    Button("Unsorted") { library.move(e.id, toCategory: nil) }
                    ForEach(library.categories) { c in Button(c.name) { library.move(e.id, toCategory: c.id) } }
                }
                Button("Duplicate") { library.duplicate(e.id) }
                Divider()
                Button("Delete…", role: .destructive) { library.dialog = .deleteEntry(e.id) }
            }
    }

    private func subtitle(_ e: LibraryEntry) -> String {
        let u = model.project.settings.displayUnit
        let size = "\(u.format(e.size.width, withUnit: false)) × \(u.format(e.size.depth, withUnit: false)) × \(u.format(e.size.height, withUnit: false))"
        return e.status.map { "\(size) · \($0.rawValue)" } ?? size
    }

    private func place(_ e: LibraryEntry) { library.markSeen(e.id); _ = model.dropLibrary(e.id, at: model.placementPoint()) }

    /// A library tile moves into the category; a scene object becomes a new entry there.
    private func drop(_ texts: [String], into category: UUID?) -> Bool {
        var done = false
        for text in texts {
            if let id = AppModel.libraryEntryId(text) {
                done = library.move(id, toCategory: category) || done
            } else if let (source, token) = workspace.resolve(payload: text) {
                done = source.saveObjectsToLibrary(token.ids, category: category) || done
            }
        }
        return done
    }
}

/// A few built-in pieces as examples (the full catalog is only for agent tools). They cannot be edited;
/// "Copy to My Furniture" makes an editable copy. The sofa example's context menu also places the modular sofa set.
struct ExamplesSection: View {
    let query: String
    @Binding var preview: LibraryPreviewTarget?
    @Environment(AppModel.self) private var model
    private let library = LibraryModel.shared

    var body: some View {
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let found = BuiltinCatalog.examples(matching: query)
        let level = model.activeLevel?.name ?? "level"
        if !(searching && found.isEmpty) {
            CollapsibleSection("Examples", count: found.count, key: "library.open.examples", defaultOpen: true, forceOpen: searching) {
                LibraryGridView {
                    ForEach(found, id: \.key) { e in
                        LibraryTileView(title: e.name, subtitle: e.tags.prefix(2).joined(separator: ", "), image: library.picture(catalogKey: e.key),
                                        dragPayload: FurnitureDragSource.catalog(e.key).payload,
                                        actions: LibraryTileActions(edit: nil, preview: { preview = .catalog(e.key) },
                                                                    place: { model.addCatalogEntry(key: e.key) }),
                                        placeLabel: "Place on \(level)")
                            .contextMenu {
                                Button("Preview") { preview = .catalog(e.key) }
                                Button("Place on \(level)") { model.addCatalogEntry(key: e.key) }
                                if e.key.hasPrefix("sofa.") {
                                    // The modular sofa set (grouped modules) has no tile of its own; it stays reachable here.
                                    Button("Place Modular Sofa Set on \(level)") { model.addModularSofa() }
                                }
                                Divider()
                                Menu("Copy to My Furniture") {
                                    Button("Unsorted") { library.copyStandard(key: e.key, category: nil) }
                                    ForEach(library.categories) { c in Button(c.name) { library.copyStandard(key: e.key, category: c.id) } }
                                }
                            }
                    }
                }
            }
        }
    }
}
