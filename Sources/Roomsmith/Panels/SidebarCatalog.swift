import SwiftUI
import RoomsmithCore

/// Built-in catalog by category plus the project's own furniture designs.
struct SidebarCatalogView: View {
    @Environment(AppModel.self) private var model
    @Environment(MaterialEditorState.self) private var materialEditor
    @State private var search = ""
    @State private var sectionFilter: LibrarySection?
    @State private var details: UUID?
    @State private var preview: LibraryPreviewTarget?
    @State private var designEdit: UUID?
    @Bindable private var library = LibraryModel.shared

    var body: some View {
        // One row per design name (see `Project.listedOwnDefinitions`): the design with the most placed pieces, else the newest.
        let own = model.project.listedOwnDefinitions().filter { matchesSearch($0.definition) }
        let removable = model.removableDefinitionCount
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                HStack {
                    TextField("Search catalog", text: $search).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("catalogSearch")
                    Button { library.dialog = .newCategory } label: { Image(systemName: "folder.badge.plus") }
                        .accessibilityLabel("New category")
                        .help("New category in My Furniture")
                        .accessibilityIdentifier("libraryNewCategory")
                }
                HStack(spacing: 4) {
                    chip("All", nil)
                    ForEach(LibrarySection.allCases) { chip($0.title, $0) }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    LibrarySectionsView(query: search, section: sectionFilter, details: $details, preview: $preview)
                    if !own.isEmpty && sectionFilter == nil {
                        CollapsibleSection("In this project", count: own.count, key: "library.open.project", forceOpen: !search.isEmpty) {
                            LibraryGridView {
                                ForEach(own) { row in
                                    let def = row.definition
                                    LibraryTileView(title: def.name, subtitle: dims(def.size) + (row.copies > 1 ? " · \(row.copies) copies" : ""), image: nil,
                                                    dragPayload: FurnitureDragSource.definition(def.id).payload,
                                                    actions: LibraryTileActions(edit: { model.sheet = .furnitureBuilder(def.id) },
                                                                                preview: { model.sheet = .furnitureBuilder(def.id) },
                                                                                place: { model.addDefinitionInstance(def.id) }),
                                                    placeLabel: "Place on \(model.activeLevel?.name ?? "level")")
                                        .contextMenu {
                                            Button("Edit…") { model.sheet = .furnitureBuilder(def.id) }
                                            Button("Place on \(model.activeLevel?.name ?? "level")") { model.addDefinitionInstance(def.id) }
                                            Divider()
                                            Button("Save to My Furniture") { _ = model.saveDefinitionToLibrary(def.id) }
                                            Button("Save as planned item") { _ = model.saveDefinitionToLibrary(def.id, section: .planned) }
                                            Divider()
                                            Button("Delete", role: .destructive) { model.deleteCatalogEntry(def.id) }
                                            Button("Remove Unused Furniture…") { model.confirmAndRemoveUnusedFurniture() }.disabled(removable == 0)
                                        }
                                }
                            }
                        }
                    }
                    if sectionFilter == nil {
                        if !model.project.materials.isEmpty {
                            CollapsibleSection("Materials", count: model.project.materials.count, key: "library.open.materials") {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(model.project.materials) { m in
                                        HStack(spacing: 6) {
                                            Image(systemName: "circle.fill")
                                                .foregroundStyle(Color(.sRGB, red: Double(m.color.r) / 255, green: Double(m.color.g) / 255, blue: Double(m.color.b) / 255))
                                            Text(m.name).lineLimit(1).foregroundStyle(Color(nsColor: .labelColor))
                                            Spacer(minLength: 4)
                                        }
                                        .padding(.horizontal, 8)
                                        .contentShape(Rectangle())
                                        .onTapGesture(count: 2) { materialEditor.open(selecting: m.id) }
                                        .accessibilityElement(children: .combine)
                                        .accessibilityLabel("Material \(m.name)")
                                        .accessibilityAction(named: "Edit") { materialEditor.open(selecting: m.id) }
                                        .contextMenu {
                                            Button("Edit…") { materialEditor.open(selecting: m.id) }
                                            Button("Delete", role: .destructive) { model.deleteCatalogEntry(m.id) }
                                        }
                                    }
                                }
                            }
                        }
                        if !model.project.products.isEmpty {
                            CollapsibleSection("Products", count: model.project.products.count, key: "library.open.products") {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(model.project.products) { pr in
                                        VStack(alignment: .leading, spacing: 0) {
                                            Text(pr.name).lineLimit(1).foregroundStyle(Color(nsColor: .labelColor))
                                            if !pr.manufacturer.isEmpty { Text(pr.manufacturer).font(.caption).foregroundStyle(Color(nsColor: .secondaryLabelColor)).lineLimit(1) }
                                        }
                                        .padding(.horizontal, 8)
                                        .contextMenu { Button("Delete", role: .destructive) { model.deleteCatalogEntry(pr.id) } }
                                    }
                                }
                            }
                        }
                        ExamplesSection(query: search, preview: $preview)
                    }
                }
                .padding(.vertical, 6)
            }
            Divider()
            HStack {
                Button { model.sheet = .furnitureBuilder(nil) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New furniture")
                    .help("New furniture: build new furniture from primitives")
                Button { materialEditor.open() } label: { Image(systemName: "paintpalette") }
                    .accessibilityLabel("Materials")
                    .help("Materials: create and edit project materials")
                Button { model.confirmAndRemoveUnusedFurniture() } label: { Image(systemName: "trash.slash") }
                    .accessibilityLabel("Remove Unused Furniture")
                    .accessibilityIdentifier("removeUnusedFurniture")
                    .help("Remove Unused Furniture: delete designs of this project that no placed piece uses")
                    .disabled(removable == 0)
                Spacer()
            }
            .padding(8)
        }
        .sheet(item: $library.dialog) { LibraryDialogSheet(dialog: $0) }
        .popover(item: Binding(get: { details.map(DetailID.init) }, set: { details = $0?.id }), arrowEdge: .trailing) { d in
            LibraryDetailView(entryId: d.id, onEditDesign: { id in Task { @MainActor in designEdit = id } }).environment(model)
        }
        .sheet(item: Binding(get: { designEdit.map(DetailID.init) }, set: { designEdit = $0?.id })) { d in
            LibraryDesignEditor(entryId: d.id).environment(model)
        }
        .sheet(item: $preview) { LibraryPreviewSheet(target: $0).environment(model) }
    }

    private struct DetailID: Identifiable { let id: UUID }

    private func chip(_ title: String, _ s: LibrarySection?) -> some View {
        Button(title) { sectionFilter = s }
            .buttonStyle(.bordered).controlSize(.small)
            .tint(sectionFilter == s ? .accentColor : nil)
            .accessibilityAddTraits(sectionFilter == s ? .isSelected : [])
    }

    private func dims(_ s: Size3) -> String {
        let u = model.project.settings.displayUnit
        return "\(u.format(s.width, withUnit: false)) × \(u.format(s.depth, withUnit: false)) × \(u.format(s.height, withUnit: false)) \(u.rawValue)"
    }

    private func matchesSearch(_ d: FurnitureDefinition) -> Bool {
        let words = search.lowercased().split(whereSeparator: \.isWhitespace)
        let hay = ([d.name, d.category] + d.tags).joined(separator: " ").lowercased()
        return words.allSatisfy { hay.contains($0) }
    }
}
