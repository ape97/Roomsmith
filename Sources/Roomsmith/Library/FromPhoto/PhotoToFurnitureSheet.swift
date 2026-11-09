import SwiftUI
import UniformTypeIdentifiers
import RoomsmithCore

/// What the furniture builder starts from when it is opened from a photo proposal.
public struct PhotoBuilderDraft: Identifiable, Sendable {
    public let id = UUID()
    var proposal: PhotoProposal
    var name: String
    var hint: String
    var images: [PhotoImage]
}

/// Furniture from photos: pick photos (drop or file dialog), give at least one real dimension and an optional hint, look at
/// the proposal, then save it to the AI section or continue in the furniture builder. With `improveEntryId` the photos
/// improve an existing AI entry instead (values you keep stay).
struct PhotoToFurnitureSheet: View {
    let improveEntryId: UUID?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var images: [PhotoImage] = []
    @State private var previews: [NSImage] = []
    @State private var widthText = ""
    @State private var depthText = ""
    @State private var heightText = ""
    @State private var hint = ""
    @State private var name = ""
    @State private var keep: Set<ParamField> = []
    @State private var proposal: PhotoProposal?
    @State private var busy = false
    @State private var problem: String?
    @State private var importing = false
    @State private var dropTargeted = false

    private let library = LibraryModel.shared
    private let provider = VisionFurnitureProvider()

    private var improved: LibraryEntry? { improveEntryId.flatMap { library.entry($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(improved.map { "Improve \"\($0.name)\" with new photos" } ?? "Furniture from photos").font(.title3.weight(.semibold))
            if improveEntryId != nil, improved == nil {
                Text("This entry no longer exists.").foregroundStyle(.secondary)
            } else {
                photoArea
                dimensionFields
                TextField("What is it? (e.g. three-seat sofa)", text: $hint)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("photoHint")
                if improveEntryId != nil { keepFields }
                Button(proposal == nil ? "Analyse" : "Analyse Again") { Task { await analyse() } }
                    .disabled(images.isEmpty || busy)
                    .help("Reads the photos on this Mac (nothing is sent anywhere) and proposes a design")
                    .accessibilityIdentifier("photoAnalyse")
                if busy { ProgressView().controlSize(.small) }
                if let problem { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout) }
                if let proposal { proposalView(proposal) }
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(16).frame(width: 520, height: 640)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { add(urls) }
        }
    }

    // MARK: Parts

    private var photoArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Photos (\(images.count) of \(FurnitureFromPhoto.maxPhotos))").font(.callout.weight(.medium))
                Spacer()
                Button("Choose…") { importing = true }.disabled(images.count >= FurnitureFromPhoto.maxPhotos || busy)
                    .accessibilityIdentifier("photoChoose")
            }
            ZStack {
                RoundedRectangle(cornerRadius: 8).strokeBorder(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                if previews.isEmpty {
                    Text("Drop photos here. The first one should show the front of the furniture.").font(.callout).foregroundStyle(.secondary).padding(8)
                } else {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(previews.indices, id: \.self) { i in
                                Image(nsImage: previews[i]).resizable().scaledToFill().frame(width: 84, height: 84)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                                    .overlay(alignment: .topTrailing) {
                                        Button { remove(i) } label: { Image(systemName: "xmark.circle.fill") }
                                            .buttonStyle(.borderless).disabled(busy).padding(2).help("Remove this photo").accessibilityLabel("Remove photo")
                                    }
                            }
                        }.padding(8)
                    }
                }
            }
            .frame(height: 110)
            .dropDestination(for: URL.self) { urls, _ in add(urls); return true } isTargeted: { dropTargeted = $0 }
        }
    }

    private var dimensionFields: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                dimField("Width", $widthText)
                dimField("Depth", $depthText)
                dimField("Height", $heightText)
            }
            Text("Give at least one real size (mm, or with cm / m). A photo cannot tell the size; missing sizes are estimated from its proportions.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func dimField(_ title: String, _ text: Binding<String>) -> some View {
        TextField(title, text: text).textFieldStyle(.roundedBorder).accessibilityLabel("\(title) in millimetres")
    }

    private var keepFields: some View {
        DisclosureGroup("Keep these values from the saved design") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading) {
                ForEach(ParamField.allCases, id: \.self) { f in
                    Toggle(Self.title(f), isOn: Binding(get: { keep.contains(f) }, set: { if $0 { keep.insert(f) } else { keep.remove(f) } }))
                        .toggleStyle(.checkbox)
                }
            }
        }
    }

    private func proposalView(_ p: PhotoProposal) -> some View {
        let s = p.spec.params.size
        let u = model.project.settings.displayUnit
        return GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                Text("Proposal: \(p.template.title)").font(.headline)
                Text("\(u.format(s.width, withUnit: false)) × \(u.format(s.depth, withUnit: false)) × \(u.format(s.height, withUnit: false)) \(u.rawValue)"
                     + (p.materialName.map { " · \($0)" } ?? ""))
                    .font(.callout)
                ForEach(p.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if improveEntryId == nil {
                    TextField("Name", text: $name, prompt: Text(FurnitureFromPhoto.defaultName(hint: hint, template: p.template)))
                        .textFieldStyle(.roundedBorder).accessibilityIdentifier("photoName")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Spacer()
            if improveEntryId != nil {
                Button("Apply to Entry") { applyImprovement() }.disabled(proposal == nil || busy)
                    .keyboardShortcut(.defaultAction).accessibilityIdentifier("photoApply")
            } else {
                Button("Continue in Builder…") { continueInBuilder() }.disabled(proposal == nil || busy)
                    .help("Open the furniture builder with this proposal to adjust it")
                    .accessibilityIdentifier("photoContinue")
                Button("Save to Library") { saveToLibrary() }.disabled(proposal == nil || busy)
                    .keyboardShortcut(.defaultAction).help("Keep it in the AI section of the library, with the photos")
                    .accessibilityIdentifier("photoSave")
            }
        }
    }

    // MARK: Actions

    private func add(_ urls: [URL]) {
        problem = nil
        for url in urls {
            guard images.count < FurnitureFromPhoto.maxPhotos else { problem = "At most \(FurnitureFromPhoto.maxPhotos) photos per furniture item"; break }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= FurnitureFromPhoto.maxPhotoBytes,
                  let data = try? Data(contentsOf: url) else { problem = "\(url.lastPathComponent) could not be read or is too large"; continue }
            guard let ext = PhotoImage.sniffExtension(data), let preview = ImageThumbnail.make(data: data, maxPixel: 200) else {
                problem = "\(url.lastPathComponent) is not a supported image (JPEG, PNG, HEIC, TIFF, GIF, WebP, BMP)"; continue
            }
            images.append(PhotoImage(data: data, fileExtension: ext))
            previews.append(preview)
            proposal = nil
        }
    }

    private func remove(_ i: Int) {
        guard images.indices.contains(i) else { return }
        images.remove(at: i); previews.remove(at: i); proposal = nil
    }

    /// Typed sizes; empty fields are not given. Nil with a message when a field is not a valid length.
    private func dimensions() -> PhotoDimensions? {
        func read(_ t: String, _ label: String) -> (MM?, Bool) {
            let s = t.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { return (nil, true) }
            guard let v = PendingInput.length(s, unit: .mm, range: sizeLimit, emptyIsZero: false) else {
                problem = "\(label) is not a valid length (1 mm to 100 m)"; return (nil, false)
            }
            return (v, true)
        }
        let w = read(widthText, "Width"), d = read(depthText, "Depth"), h = read(heightText, "Height")
        guard w.1, d.1, h.1 else { return nil }
        return PhotoDimensions(width: w.0, depth: d.0, height: h.0)
    }

    private func analyse() async {
        problem = nil
        guard let dims = dimensions() else { return }
        busy = true
        defer { busy = false }
        do {
            proposal = try await FurnitureFromPhoto.propose(provider: provider, images: images, hint: hint, dimensions: dims)
        } catch let e as PhotoAnalysisError { proposal = nil; problem = e.message } catch { proposal = nil; problem = userMessage(for: error) }
    }

    private func saveToLibrary() {
        guard let proposal else { return }
        do {
            let e = try FurnitureFromPhoto.save(proposal: proposal, name: name, hint: hint, images: images, in: library.store)
            model.statusMessage = "Saved \"\(e.name)\" to the AI library"
            dismiss()
        } catch { problem = userMessage(for: error) }
    }

    private func continueInBuilder() {
        guard let proposal else { return }
        let n = name.trimmingCharacters(in: .whitespaces)
        let draft = PhotoBuilderDraft(proposal: proposal, name: n.isEmpty ? FurnitureFromPhoto.defaultName(hint: hint, template: proposal.template) : n,
                                      hint: hint, images: images)
        dismiss()
        // The next sheet can only come up after this one is gone.
        Task { @MainActor in model.sheet = .photoBuilder(draft) }
    }

    private func applyImprovement() {
        guard let proposal, let id = improveEntryId, let dims = dimensions() else { return }
        do {
            let r = try FurnitureFromPhoto.improve(entryId: id, proposal: proposal, dimensions: dims, keep: keep, images: images, in: library.store)
            var msg = "Improved \"\(r.entry.name)\""
            if let t = r.merge.suggestedTemplate { msg += " (the photos may rather show a \(t.rawValue); name it in the hint to switch)" }
            model.statusMessage = msg
            dismiss()
        } catch { problem = userMessage(for: error) }
    }

    static func title(_ f: ParamField) -> String {
        switch f {
        case .width: "Width"; case .depth: "Depth"; case .height: "Height"; case .shelves: "Shelves"; case .doors: "Doors"
        case .plinth: "Plinth"; case .legInset: "Leg inset"; case .topThickness: "Top thickness"; case .boards: "Boards"
        case .armWidth: "Arm width"; case .seatHeight: "Seat height"; case .material: "Material"
        }
    }
}
