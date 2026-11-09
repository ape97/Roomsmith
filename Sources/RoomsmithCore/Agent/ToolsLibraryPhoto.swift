import Foundation

// MARK: - library.create_from_photo

/// Furniture from reference photos. The photo analysis runs in the app (`AgentAppContext.photoProvider`, on device, no
/// network); everything else is shared with the "Furniture from photo" sheet through `FurnitureFromPhoto`.
enum LibraryPhotoTools {
    /// Largest photo read from disk, and largest inline Base64 text (which must fit one agent line of 16 MiB).
    static let maxFileBytes = 30_000_000
    static let maxBase64Chars = 14_000_000
    static let formats = "JPEG, PNG, HEIC, GIF, TIFF, WebP or BMP"

    @MainActor
    static func specs() -> [ToolSpec] { [createFromPhoto()] }

    private static func fail(_ e: Error) -> Error {
        switch e {
        case let e as PhotoAnalysisError: ToolError.invalid(nil, e.message)
        case let e as LibraryError:
            switch e {
            case .notFound(let id): ToolError.notFound("Library entry", id)
            case .invalid(let m): ToolError.invalid(nil, m)
            case .io(let m): AgentError(code: AgentError.internal, message: m)
            }
        case let e as CommandError: AgentError(e)
        default: e
        }
    }

    static func image(fromFile raw: String, field: String) throws -> PhotoImage {
        guard raw.hasPrefix("/"), !raw.contains("\0") else { throw ToolError.invalid(field, "must be an absolute path") }
        // Resolve links first so the size and type checks see the file that is actually read.
        let url = URL(fileURLWithPath: raw).standardizedFileURL.resolvingSymlinksInPath()
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            throw ToolError.notFoundText("No file at \(url.path)")
        }
        guard (attrs[.type] as? FileAttributeType) == .typeRegular else { throw ToolError.invalid(field, "is not a regular file: \(url.path)") }
        let tooLarge = ToolError.invalid(field, "the file is larger than \(maxFileBytes / 1_000_000) MB")
        guard ((attrs[.size] as? Int) ?? 0) <= maxFileBytes else { throw tooLarge }
        // Bounded read: the file may grow between the check and the read.
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw ToolError.invalid(field, "the file cannot be read: \(url.path)") }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxFileBytes + 1) else { throw ToolError.invalid(field, "the file cannot be read: \(url.path)") }
        guard data.count <= maxFileBytes else { throw tooLarge }
        return try checked(data, field: field)
    }

    static func image(fromBase64 text: String, field: String) throws -> PhotoImage {
        var s = text
        if s.hasPrefix("data:"), let comma = s.firstIndex(of: ",") { s = String(s[s.index(after: comma)...]) }
        guard s.count <= maxBase64Chars else {
            throw ToolError.invalid(field, "is too large (at most about \(maxBase64Chars / 1_400_000) MB of image data); pass imagePath instead")
        }
        guard let data = Data(base64Encoded: s, options: .ignoreUnknownCharacters), !data.isEmpty else {
            throw ToolError.invalid(field, "is not valid Base64")
        }
        return try checked(data, field: field)
    }

    private static func checked(_ data: Data, field: String) throws -> PhotoImage {
        guard let ext = PhotoImage.sniffExtension(data) else { throw ToolError.invalid(field, "is not a supported image (\(formats))") }
        return PhotoImage(data: data, fileExtension: ext)
    }

    @MainActor
    private static func createFromPhoto() -> ToolSpec {
        let dims = S.obj("Known real dimensions in mm; at least one is required (sizes cannot be read from a photo alone). The others are estimated from the photo's proportions.",
                         ["width": S.int("Left to right, mm."), "depth": S.int("Front to back, mm."), "height": S.int("Floor to top, mm.")])
        var spec = ToolSpec.asyncRead("library.create_from_photo",
            "Creates parametric furniture from a photo (analysed on this Mac, nothing leaves it): picks the closest builder template (cabinet, table, shelf, sofa or box) from what the photo shows and the hint, derives missing sizes from the photo's proportions, maps the dominant colour to the nearest built-in material and saves the result as an entry of the AI section of the library with the photo attached. It is a starting point built from simple parts, not a copy of the photo. Returns the entry and the suggestion (template, spec, estimated sizes, notes); refine it with library.get / furniture design tools or run again with improveEntryId and another photo. Give the photo as imagePath (absolute file) or imageBase64 (up to about 10 MB). Needs write access and the Roomsmith app.",
            ["imagePath": S.str("Absolute path of a photo (\(formats))."),
             "imagePaths": S.arr("Several photos of the same piece (the first is the front view); at most \(FurnitureFromPhoto.maxPhotos) together with imagePath.", items: ["type": "string"]),
             "imageBase64": S.str("The photo itself as Base64 (a data: URL is accepted); alternative to imagePath."),
             "dimensions": dims,
             "hint": S.str("What it is, in German or English, for example \"three-seat sofa with arm rests\" or \"Schrank mit zwei Türen\". Settles the kind of furniture when the photo is ambiguous."),
             "name": S.str("Entry name (default: the hint, or the template name)."),
             "improveEntryId": S.uuid("Improve this library entry (made from a photo or with the furniture builder) instead of creating a new one: sizes and material follow the new photo and dimensions, the template changes only when the new evidence is clearly better."),
             "keepFields": S.arr("With improveEntryId: parameters that stay as they are (width, depth, height, shelves, doors, plinth, legInset, topThickness, boards, armWidth, seatHeight, material). Dimensions given in this call are applied anyway.", items: ["type": "string"])],
            required: ["dimensions"]) { env, a in
            try env.requireWriteAccess("library.create_from_photo changes the global library")
            let single = try a.nonEmptyString("imagePath"), list = try a.stringList("imagePaths") ?? [], b64 = try a.nonEmptyString("imageBase64")
            // Count before reading anything, so a long list cannot pull many large files into memory.
            guard (single == nil ? 0 : 1) + list.count + (b64 == nil ? 0 : 1) <= FurnitureFromPhoto.maxPhotos else {
                throw ToolError.invalid("imagePaths", "at most \(FurnitureFromPhoto.maxPhotos) photos")
            }
            var images: [PhotoImage] = []
            if let p = single { images.append(try image(fromFile: p, field: "imagePath")) }
            for (i, p) in list.enumerated() { images.append(try image(fromFile: p, field: "imagePaths[\(i)]")) }
            if let b = b64 { images.append(try image(fromBase64: b, field: "imageBase64")) }
            guard !images.isEmpty else { throw ToolError.invalid("imagePath", "give imagePath, imagePaths or imageBase64") }
            guard images.count <= FurnitureFromPhoto.maxPhotos else { throw ToolError.invalid("imagePaths", "at most \(FurnitureFromPhoto.maxPhotos) photos") }

            guard let d = try a.object("dimensions") else { throw ToolError.missing("dimensions") }
            let dimensions = PhotoDimensions(width: try d.int("width"), depth: try d.int("depth"), height: try d.int("height"))
            guard !dimensions.isEmpty else { throw ToolError.invalid("dimensions", "give at least one of width, depth, height (mm); sizes cannot be read from a photo alone") }
            for (n, v) in [("width", dimensions.width), ("depth", dimensions.depth), ("height", dimensions.height)] {
                if let v, !sizeLimit.contains(v) { throw ToolError.invalid("dimensions.\(n)", "must be between \(sizeLimit.lowerBound) and \(sizeLimit.upperBound) mm") }
            }
            let hint = try a.string("hint") ?? ""
            let name = try a.nonEmptyString("name")
            let improveId = try a.uuid("improveEntryId")
            var keep = Set<ParamField>()
            for f in try a.stringList("keepFields") ?? [] {
                guard let field = ParamField(rawValue: f) else {
                    throw ToolError.invalid("keepFields", "unknown field '\(f)'; use \(ParamField.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                keep.insert(field)
            }
            guard let provider = env.context.photoProvider else {
                throw AgentError.unsupportedFeature("Photo analysis needs the Roomsmith app (it uses the on-device Vision framework).")
            }
            let store = LibraryStore(root: env.context.libraryRoot)
            if let improveId, store.entry(improveId) == nil { throw ToolError.notFound("Library entry", improveId) }

            let proposal: PhotoProposal
            do { proposal = try await FurnitureFromPhoto.propose(provider: provider, images: images, hint: hint, dimensions: dimensions) }
            catch let e as PhotoAnalysisError { throw ToolError.invalid(nil, e.message) }
            catch let e as AgentError { throw e }
            catch { throw AgentError(code: AgentError.internal, message: "The photo could not be analysed: \(error.localizedDescription)") }

            var out: [String: JSONValue] = [:]
            var notes = proposal.notes
            var shown = proposal.spec
            do {
                if let improveId {
                    let r = try FurnitureFromPhoto.improve(entryId: improveId, proposal: proposal, dimensions: dimensions, keep: keep,
                                                           images: images, in: store)
                    out["entry"] = .object(LibraryTools.row(r.entry))
                    out["improved"] = true
                    out["templateChanged"] = .bool(r.merge.templateChanged)
                    out["changedFields"] = .array(r.merge.changed.map { .string($0.rawValue) })
                    out["keptFields"] = .array(r.merge.kept.map { .string($0.rawValue) })
                    if let s = r.merge.suggestedTemplate {
                        notes.append("The new photo looks more like a \(s.rawValue), but not clearly enough to change the template; add a hint or create a new entry.")
                    }
                    shown = r.merge.spec
                } else {
                    let e = try FurnitureFromPhoto.save(proposal: proposal, name: name, hint: hint, images: images, in: store)
                    out["entry"] = .object(LibraryTools.row(e))
                    out["improved"] = false
                }
            } catch { throw fail(error) }

            out["suggestion"] = .object([
                "template": .string(shown.template.rawValue),
                "spec": J.encode(shown),
                "size": J.size(shown.params.size),
                "estimated": .array(proposal.derived.map { .string($0) }),
                "material": proposal.materialName.map { .string($0) } ?? .null,
                "recognised": .bool(!proposal.choice.fallback),
                "ambiguous": .bool(proposal.choice.ambiguous),
                "alternatives": .array(proposal.choice.ranking.dropFirst().filter { $0.score > 0 }.map { .string($0.template.rawValue) }),
                "notes": .array(notes.map { .string($0) }),
            ])
            return .object(out)
        }
        spec.readOnly = false  // changes the library (async because the photo analysis is)
        return spec
    }
}
