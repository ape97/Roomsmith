import Foundation

/// What the photo analysis and the user's dimensions turn into: a template with parameters, ready to be built and saved.
public struct PhotoProposal: Sendable, Equatable {
    public var spec: ParametricSpec
    public var choice: TemplateChoice
    /// Dimensions that were estimated (not given by the user).
    public var derived: [String]
    public var materialName: String?
    /// Plain-language remarks for the user (fallback, ambiguity, estimates).
    public var notes: [String]
    public var template: BuilderTemplate { spec.template }
}

/// Photo to furniture: proposal, library entry and improvement of an existing entry.
public enum FurnitureFromPhoto {
    public static let maxPhotos = 6
    /// Largest photo file accepted (bytes).
    public static let maxPhotoBytes = LibraryPhotoTools.maxFileBytes

    // MARK: Proposal

    public static func propose(analysis: PhotoAnalysis, hint: String, dimensions: PhotoDimensions) throws -> PhotoProposal {
        let choice = TemplateChooser.choose(analysis: analysis, hint: hint)
        let dims = try PhotoDimensioning.derive(template: choice.template, analysis: analysis, user: dimensions)
        let material = PhotoDimensioning.material(for: analysis.dominantColors)
        let params = PhotoDimensioning.params(template: choice.template, size: dims.size, materialId: material?.id ?? BuilderParams().materialId)
        var notes: [String] = []
        if choice.fallback { notes.append("The photo and hint did not point to a known kind of furniture, so a plain box is proposed. Name the kind in the hint (for example \"sofa\" or \"Schrank\").") }
        else if choice.ambiguous { notes.append("Could also be a \(choice.ranking[1].template.rawValue); name the kind in the hint to settle it.") }
        if !dims.derived.isEmpty { notes.append("Estimated from the photo's proportions: \(dims.derived.joined(separator: ", ")). Check them against the real piece.") }
        if analysis.aspectWH == nil { notes.append("No proportions could be read from the photo; the missing sizes follow the template's usual proportions.") }
        return PhotoProposal(spec: ParametricSpec(template: choice.template, params: params), choice: choice, derived: dims.derived,
                             materialName: material?.name, notes: notes)
    }

    /// Analyses the photos with `provider` and proposes a design.
    public static func propose(provider: any FurnitureFromPhotoProvider, images: [PhotoImage], hint: String,
                               dimensions: PhotoDimensions) async throws -> PhotoProposal {
        try validate(images: images, dimensions: dimensions)
        let analysis = try await provider.analyze(images: images, hint: hint, dimensions: dimensions)
        return try propose(analysis: analysis, hint: hint, dimensions: dimensions)
    }

    public static func validate(images: [PhotoImage], dimensions: PhotoDimensions) throws {
        guard !images.isEmpty else { throw PhotoAnalysisError("Give at least one photo") }
        guard images.count <= maxPhotos else { throw PhotoAnalysisError("At most \(maxPhotos) photos per piece") }
        guard !dimensions.isEmpty else { throw PhotoAnalysisError("Give at least one dimension (width, depth or height in mm); sizes cannot be read from a photo alone") }
    }

    // MARK: Building and saving

    public static func defaultName(hint: String, template: BuilderTemplate) -> String {
        let h = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !h.isEmpty, h.count <= 40, !h.contains("\n") { return h }
        return "\(template.title) from photo"
    }

    /// The furniture of a spec as a transfer (one design, placed once in a scratch project).
    public static func transfer(for spec: ParametricSpec, name: String) throws -> FurnitureTransfer {
        try transfer(for: spec.generate(name: name))
    }

    /// One design as a transfer (placed once in a scratch project).
    public static func transfer(for definition: FurnitureDefinition) throws -> FurnitureTransfer {
        var p = Project.empty(name: definition.name)
        let id = p.addDefinition(definition)
        return try LibraryContent.pack(project: p, definitionId: id, packageURL: nil)
    }

    static func storePhotos(_ images: [PhotoImage], in store: LibraryStore) throws -> [String] {
        var names: [String] = []
        for img in images {
            let n = try store.storeAsset(img.data, ext: img.fileExtension)
            if !names.contains(n) { names.append(n) }
        }
        return names
    }

    /// Saves the proposal as a new entry of the AI section; the photos are kept as assets of the entry.
    public static func save(proposal: PhotoProposal, name: String?, hint: String, images: [PhotoImage], in store: LibraryStore) throws -> LibraryEntry {
        let n = cleanName(name) ?? defaultName(hint: hint, template: proposal.template)
        return try save(definition: proposal.spec.generate(name: n), spec: proposal.spec, proposal: proposal, name: n, hint: hint, images: images, in: store)
    }

    /// Saves a design that was edited in the builder. `spec` is the recipe it still follows; pass nil when components
    /// were changed by hand, so a later "improve" cannot overwrite those edits.
    public static func save(definition: FurnitureDefinition, spec: ParametricSpec?, proposal: PhotoProposal, name: String, hint: String,
                            images: [PhotoImage], in store: LibraryStore) throws -> LibraryEntry {
        var d = definition
        d.name = name
        let t = try transfer(for: d)
        var entry = LibraryContent.makeEntry(from: t, section: .ai, name: name, description: description(proposal, hint: hint),
                                             tags: ["photo", proposal.template.rawValue], spec: spec)
        entry.photoAssetNames = try storePhotos(images, in: store)
        return try store.add(entry, transfer: t)
    }

    /// True when `definition` still has exactly the components the recipe generates (so the recipe describes it fully).
    public static func follows(_ definition: FurnitureDefinition, recipe spec: ParametricSpec) -> Bool {
        func plain(_ d: FurnitureDefinition) -> [Component] {
            d.components.map { var c = $0; c.id = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)); return c }
        }
        let generated = spec.generate(name: definition.name)
        return plain(generated) == plain(definition) && generated.states.map(\.name) == definition.states.map(\.name)
    }

    static func cleanName(_ name: String?) -> String? {
        let n = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return n.isEmpty ? nil : n
    }

    static func description(_ p: PhotoProposal, hint: String) -> String {
        let s = p.spec.params.size
        var d = "Built from a photo as a \(p.template.rawValue), \(s.width) x \(s.depth) x \(s.height) mm"
        if !p.derived.isEmpty { d += " (\(p.derived.joined(separator: ", ")) estimated)" }
        d += "."
        let h = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        return h.isEmpty ? d : d + " " + h
    }

    // MARK: Improve

    public struct ImproveResult: Sendable {
        public var entry: LibraryEntry
        public var merge: ParamMergeResult
    }

    /// Improves a stored design with a new proposal: fields in `keep` stay, the rest follow the proposal; new photos are
    /// added to the entry. Dimensions the user gave in this request are never kept.
    public static func improve(entryId: UUID, proposal: PhotoProposal, dimensions: PhotoDimensions, keep: Set<ParamField>,
                               images: [PhotoImage], in store: LibraryStore) throws -> ImproveResult {
        guard let entry = store.entry(entryId) else { throw LibraryError.notFound(entryId) }
        guard let current = entry.spec else {
            throw LibraryError.invalid("\"\(entry.name)\" has no builder recipe (it was saved from placed furniture), so it cannot be improved from a photo")
        }
        let merge = ParamMerge.merge(current: current, proposed: proposal.spec,
                                     currentTemplateScore: proposal.choice.score(of: current.template),
                                     proposedTemplateScore: proposal.choice.score, keep: keep.subtracting(ParamMerge.fields(of: dimensions)))
        let t = try transfer(for: merge.spec, name: entry.name)
        let photos = try storePhotos(images, in: store)
        _ = try store.replaceTransfer(entryId, with: t)
        let saved = try store.update(entryId) { e in
            e.spec = merge.spec
            for n in photos where !e.photoAssetNames.contains(n) { e.photoAssetNames.append(n) }
        }
        return ImproveResult(entry: saved, merge: merge)
    }
}
