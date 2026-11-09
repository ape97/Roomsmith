import SwiftUI
import RoomsmithCore

/// Details of one library entry: picture, text, size, materials, status, tags, reference photos. Edits are applied with "Save".
struct LibraryDetailView: View {
    let entryId: UUID
    /// Opens the furniture builder on this entry (the sidebar presents it once this popover is gone).
    var onEditDesign: ((UUID) -> Void)?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private let library = LibraryModel.shared

    @State private var name = ""
    @State private var text = ""
    @State private var tags = ""
    @State private var status: PurchaseStatus?
    @State private var section: LibrarySection = .own
    @State private var loaded = false
    @State private var confirmDelete = false
    /// Reference photos as small thumbnails, decoded once off the main thread (never in `body`).
    @State private var photoThumbs: [String: NSImage] = [:]

    var body: some View {
        if let e = library.entry(entryId) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    LibraryPicture(image: library.picture(for: e), side: 96)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                        Text(dimensions(e.size)).font(.caption).foregroundStyle(.secondary)
                        Text(e.materialNames.isEmpty ? "No materials" : e.materialNames.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Text("Description").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $text).font(.body).frame(height: 64)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                TextField("Tags, separated by commas", text: $tags).textFieldStyle(.roundedBorder)
                HStack {
                    Picker("Section", selection: $section) {
                        ForEach(LibrarySection.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Status", selection: $status) {
                        Text("None").tag(PurchaseStatus?.none)
                        ForEach(PurchaseStatus.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(PurchaseStatus?.some($0)) }
                    }
                }
                if !e.photoAssetNames.isEmpty {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(e.photoAssetNames, id: \.self) { n in
                                if let img = photoThumbs[n] {
                                    Image(nsImage: img).resizable().scaledToFill().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 4))
                                        .accessibilityLabel("Reference photo")
                                }
                            }
                        }
                    }
                    .frame(height: 60)
                    .task(id: e.photoAssetNames) {
                        let urls = e.photoAssetNames.compactMap { n in library.store.assetURL(n).map { (n, $0) } }
                        let made = await Task.detached(priority: .utility) {
                            var out: [String: NSImage] = [:]
                            for (n, url) in urls { if let t = ImageThumbnail.make(url: url, maxPixel: 112) { out[n] = t } }
                            return out
                        }.value
                        guard !Task.isCancelled else { return }
                        photoThumbs = made
                    }
                }
                Button("Edit design…") { let id = entryId; dismiss(); onEditDesign?(id) }
                    .disabled(onEditDesign == nil || !LibraryDesignEditor.canEdit(e))
                    .help(LibraryDesignEditor.canEdit(e) ? "Change the parts of this furniture in the furniture builder"
                                                         : "Only single furniture items can be edited in the builder")
                    .accessibilityIdentifier("libraryEditDesign")
                Button("Update from selection") { updateFurniture(e) }
                    .disabled(selectedPiece == nil)
                    .help("Replace the stored furniture with the furniture selected in the project (one furniture item or group)")
                Button("Improve with new photo…") { improveFromPhoto(e) }
                    .disabled(e.spec == nil)
                    .help(e.spec == nil ? "Only furniture built from a template (for example from photos) can be improved this way"
                                        : "Analyse more photos and update this design; values you keep stay as they are")
                    .accessibilityIdentifier("libraryImproveFromPhoto")
                HStack {
                    Button("Delete", role: .destructive) { confirmDelete = true }
                        .help("Delete this entry from the library (projects keep their copies)")
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Save") { save(e) }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .help("Save the changes to the library")
                }
            }
            .padding(14).frame(width: 340)
            .onAppear {
                guard !loaded else { return }
                loaded = true
                name = e.name; text = e.description; tags = e.tags.joined(separator: ", "); status = e.status; section = e.section
            }
            .confirmationDialog("Delete \"\(e.name)\" from the library?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) {
                    do { try library.store.remove(e.id); dismiss() } catch { model.lastError = userMessage(for: error) }
                }
            } message: { Text("This cannot be undone. Projects that used it keep their copies.") }
        } else {
            Text("This entry no longer exists.").padding(14)
        }
    }

    private var selectedPiece: UUID? {
        let ids = model.selectionIds.filter { model.project.instance($0) != nil || model.project.group($0) != nil }
        return ids.count == 1 ? ids.first : nil
    }

    private func improveFromPhoto(_ e: LibraryEntry) {
        let id = e.id
        dismiss()
        // The sheet can only come up after this popover is gone.
        Task { @MainActor in model.sheet = .photoToFurniture(improve: id) }
    }

    private func updateFurniture(_ e: LibraryEntry) {
        guard let id = selectedPiece else { return }
        do {
            let t = try LibraryContent.pack(project: model.project, ids: [id], packageURL: model.fileURL)
            _ = try library.store.replaceTransfer(e.id, with: t)
            model.statusMessage = "Updated \"\(e.name)\" in the library"
        } catch { model.lastError = userMessage(for: error) }
    }

    private func save(_ e: LibraryEntry) {
        let list = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        do {
            try library.store.update(e.id) {
                $0.name = name.trimmingCharacters(in: .whitespaces); $0.description = text; $0.tags = list
                $0.status = status; $0.section = section
            }
            dismiss()
        } catch { model.lastError = userMessage(for: error) }
    }

    private func dimensions(_ s: Size3) -> String {
        let u = model.project.settings.displayUnit
        return "\(u.format(s.width, withUnit: false)) × \(u.format(s.depth, withUnit: false)) × \(u.format(s.height, withUnit: false)) \(u.rawValue)"
    }
}

/// A rendered picture, or a placeholder while it is being rendered.
struct LibraryPicture: View {
    let image: NSImage?
    /// Fixed edge length, or nil to fill the width offered (square).
    let side: CGFloat?

    var body: some View {
        RoundedRectangle(cornerRadius: 5).fill(.quaternary.opacity(0.5))
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "chair.lounge").foregroundStyle(.tertiary)
                }
            }
            .frame(width: side, height: side)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .accessibilityHidden(true)
    }
}
