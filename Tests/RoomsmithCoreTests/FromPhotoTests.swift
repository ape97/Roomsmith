import Foundation
import Testing
@testable import RoomsmithCore

// MARK: - Fixtures

private struct FakeProvider: FurnitureFromPhotoProvider {
    var analysis: PhotoAnalysis
    var failure: String?
    func analyze(images: [PhotoImage], hint: String, dimensions: PhotoDimensions?) async throws -> PhotoAnalysis {
        if let failure { throw PhotoAnalysisError(failure) }
        return analysis
    }
}

private func sofaAnalysis() -> PhotoAnalysis {
    PhotoAnalysis(aspectWH: 2.4, aspectDH: nil, dominantColors: [PhotoColor(RGBColor(138, 141, 145), weight: 0.8)],
                  labels: [PhotoLabel("sofa", 0.9), PhotoLabel("armrest", 0.6)])
}

/// Bytes that start like a PNG (the tools only look at the leading bytes; the fake provider never decodes them).
private func pngBytes(_ salt: UInt8 = 0) -> Data {
    Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, salt, 1, 2, 3])
}

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("rs-photo-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@MainActor
private final class PhotoContext: AgentAppContext {
    var selection: Set<UUID> = []
    var activeLevelId: UUID
    var fileURL: URL?
    var appVersion = "test"
    let libraryRoot: URL
    var photoProvider: (any FurnitureFromPhotoProvider)?
    init(level: UUID, root: URL, provider: (any FurnitureFromPhotoProvider)?) { activeLevelId = level; libraryRoot = root; photoProvider = provider }
    func saveForAgent() throws -> String { "/tmp/test.roomsmith" }
}

@MainActor
private struct PhotoRig {
    let dir: URL
    let store: LibraryStore
    let registry: ToolRegistry
    let context: PhotoContext
    init(write: Bool = true, provider: (any FurnitureFromPhotoProvider)? = FakeProvider(analysis: sofaAnalysis())) throws {
        dir = try tempDir()
        store = LibraryStore(root: dir.appendingPathComponent("Library"))
        let doc = DocumentStore(project: Project.empty(name: "Photo"))
        doc.agentWriteEnabled = write
        context = PhotoContext(level: doc.project.levels[0].id, root: store.root, provider: provider)
        registry = ToolRegistry(store: doc, context: context)
    }
    func call(_ args: JSONValue) async -> AgentResponse {
        await registry.call(AgentRequest(id: 1, token: "t", clientId: "test", tool: "library.create_from_photo", arguments: args))
    }
    func ok(_ args: JSONValue) async -> JSONValue {
        let r = await call(args)
        #expect(r.ok, "failed: \(r.error?.code ?? "?") \(r.error?.message ?? "")")
        return r.result ?? .null
    }
    func writePhoto(_ name: String = "p.png", _ data: Data = pngBytes()) throws -> String {
        let u = dir.appendingPathComponent(name)
        try data.write(to: u)
        return u.path
    }
}

private func choose(_ labels: [(String, Double)] = [], hint: String = "") -> TemplateChoice {
    TemplateChooser.choose(analysis: PhotoAnalysis(labels: labels.map { PhotoLabel($0.0, $0.1) }), hint: hint)
}

// MARK: - Template choice

@Suite struct PhotoTemplateChoiceTests {
    @Test func sofaWithArmrestIsSofa() {
        let c = choose([("sofa", 0.8), ("armrest", 0.5), ("furniture", 0.9)])
        #expect(c.template == .sofa)
        #expect(!c.fallback)
    }

    @Test func tableWithLegsIsTable() {
        #expect(choose([("table", 0.7), ("legs", 0.4)]).template == .table)
    }

    @Test func unknownFallsBackToBox() {
        let c = choose([("banana", 0.9), ("outdoor", 0.8)])
        #expect(c.template == .box)
        #expect(c.fallback)
        #expect(!c.ambiguous)
        #expect(choose().template == .box)
    }

    @Test func germanAndEnglishWordsInTheHint() {
        let cases: [(String, BuilderTemplate)] = [
            ("Schrank mit zwei Türen", .cabinet), ("kitchen cabinet", .cabinet), ("Bücherregal", .shelf), ("open bookcase", .shelf),
            ("Esstisch", .table), ("writing desk", .table), ("Sofa", .sofa), ("Sessel", .sofa), ("Kiste", .box), ("wooden crate", .box),
            ("Kommode mit Schubladen", .cabinet), ("Sideboard", .cabinet), ("Lounge Couch", .sofa),
        ]
        for (hint, want) in cases { #expect(choose(hint: hint).template == want, "\(hint)") }
    }

    @Test func compoundsFollowTheirLastPart() {
        #expect(choose(hint: "Couchtisch").template == .table)
        #expect(choose(hint: "Nachttisch").template == .cabinet)   // explicit longer keyword
        #expect(choose(hint: "Sofatisch").template == .table)
        #expect(choose(hint: "Wandregal").template == .shelf)
    }

    @Test func shortWordsMatchWholeWordsOnly() {
        #expect(choose(hint: "legal advice about my cardboard").fallback)
        #expect(choose(hint: "table legs").template == .table)
    }

    @Test func shelvesOnACabinetStayACabinet() {
        #expect(choose(hint: "cabinet with shelves").template == .cabinet)
    }

    @Test func hintOutweighsLabel() {
        #expect(choose([("table", 0.9)], hint: "sofa").template == .sofa)
    }

    @Test func closeRunnerUpIsAmbiguous() {
        let c = choose([("bookcase", 1.0)], hint: "cabinet")
        #expect(c.template == .cabinet)
        #expect(c.ambiguous)
        #expect(c.ranking[1].template == .shelf)
        #expect(!choose([("sofa", 0.9), ("table", 0.1)]).ambiguous)
    }

    @Test func lowConfidenceCountsLess() {
        #expect(choose([("sofa", 0.1), ("table", 0.9)]).template == .table)
    }

    @Test func umlautsAndCaseAreFolded() {
        #expect(choose(hint: "BÜCHERREGAL").template == .shelf)
        #expect(choose(hint: "Wäschetruhe").template == .box)
    }
}

// MARK: - Dimensions, clamping, colour

@Suite struct PhotoDimensioningTests {
    @Test func missingSidesComeFromTheProportions() throws {
        let r = try PhotoDimensioning.derive(template: .sofa, analysis: PhotoAnalysis(aspectWH: 2.5), user: PhotoDimensions(width: 2000))
        #expect(r.size.width == 2000)
        #expect(r.size.height == 800)
        #expect(r.derived == ["depth", "height"])
        // Depth follows the template's proportions, scaled to the given width (sofa default 2000 x 900 x 850).
        #expect(r.size.depth == 900)
    }

    @Test func givenValuesAreNeverChanged() throws {
        let r = try PhotoDimensioning.derive(template: .table, analysis: PhotoAnalysis(aspectWH: 5), user: PhotoDimensions(width: 1200, depth: 700, height: 750))
        #expect(r.size == Size3(1200, 700, 750))
        #expect(r.derived.isEmpty)
    }

    @Test func sideViewGivesDepth() throws {
        let r = try PhotoDimensioning.derive(template: .cabinet, analysis: PhotoAnalysis(aspectWH: 1.0, aspectDH: 0.5), user: PhotoDimensions(height: 1000))
        #expect(r.size == Size3(1000, 500, 1000))
    }

    @Test func withoutProportionsTheTemplateScales() throws {
        let r = try PhotoDimensioning.derive(template: .shelf, analysis: PhotoAnalysis(), user: PhotoDimensions(height: 900))
        // Shelf default 800 x 300 x 1800, scale 0.5.
        #expect(r.size == Size3(400, 150, 900))
    }

    @Test func atLeastOneDimensionIsRequiredAndMustBeInRange() {
        #expect(throws: PhotoAnalysisError.self) { try PhotoDimensioning.derive(template: .box, analysis: PhotoAnalysis(), user: PhotoDimensions()) }
        #expect(throws: PhotoAnalysisError.self) { try PhotoDimensioning.derive(template: .box, analysis: PhotoAnalysis(), user: PhotoDimensions(width: 0)) }
        #expect(throws: PhotoAnalysisError.self) { try PhotoDimensioning.derive(template: .box, analysis: PhotoAnalysis(), user: PhotoDimensions(height: 100_001)) }
    }

    @Test func absurdProportionsStayInsideTheLimits() throws {
        let r = try PhotoDimensioning.derive(template: .box, analysis: PhotoAnalysis(aspectWH: 19.9), user: PhotoDimensions(width: 100_000))
        #expect(sizeLimit.contains(r.size.height) && sizeLimit.contains(r.size.depth))
        // Out-of-range proportions are ignored (template proportions instead).
        let s = try PhotoDimensioning.derive(template: .box, analysis: PhotoAnalysis(aspectWH: 0.001), user: PhotoDimensions(width: 500))
        #expect(s.size == Size3(500, 500, 500))
    }

    @Test func clampKeepsEveryParameterValid() {
        var p = BuilderParams()
        p.width = 500_000; p.depth = -5; p.height = 0
        p.shelves = 99; p.doors = -3; p.boards = 0; p.plinth = 9_999_999; p.legInset = -1; p.topThickness = 0; p.armWidth = 9_999_999; p.seatHeight = 0
        let q = PhotoDimensioning.clamp(p)
        #expect(q.width == sizeLimit.upperBound && q.depth == sizeLimit.lowerBound && q.height == sizeLimit.lowerBound)
        #expect((0...20).contains(q.shelves) && (0...6).contains(q.doors) && (2...20).contains(q.boards))
        #expect(q.armWidth <= q.width / 4 && q.plinth <= q.height / 4 && q.legInset >= 0 && q.topThickness >= 4 && q.seatHeight >= 1)
    }

    @Test func parametersFollowTheSize() {
        let sofa = PhotoDimensioning.params(template: .sofa, size: Size3(2000, 900, 850), materialId: nil)
        #expect(sofa.armWidth == 150 && sofa.seatHeight == 425)
        #expect(PhotoDimensioning.params(template: .cabinet, size: Size3(400, 400, 900), materialId: nil).doors == 1)
        #expect(PhotoDimensioning.params(template: .cabinet, size: Size3(1350, 400, 900), materialId: nil).doors == 3)
        #expect(PhotoDimensioning.params(template: .shelf, size: Size3(800, 300, 1800), materialId: nil).boards == 4)
    }

    @Test func colourMapsToTheNearestBuiltInMaterial() throws {
        let walnut = try #require(BuiltinCatalog.materials.first { $0.name == "Walnut" })
        #expect(PhotoDimensioning.nearestMaterial(to: walnut.color)?.name == "Walnut")
        let oak = try #require(BuiltinCatalog.materials.first { $0.name == "Oak" })
        #expect(PhotoDimensioning.nearestMaterial(to: RGBColor(oak.color.r &+ 3, oak.color.g, oak.color.b &- 3))?.name == "Oak")
        #expect(PhotoDimensioning.material(for: []) == nil)
    }

    @Test func largestColourShareWins() {
        let m = PhotoDimensioning.material(for: [PhotoColor(RGBColor(250, 250, 250), weight: 0.2), PhotoColor(RGBColor(20, 20, 20), weight: 0.8)])
        #expect(m?.name == "Black metal" || m?.name == "Black plastic")
    }

    @Test func neverPicksGlassOrNonFurnitureMaterials() {
        for r in stride(from: 0, through: 255, by: 51) { for g in stride(from: 0, through: 255, by: 51) { for b in stride(from: 0, through: 255, by: 51) {
            let m = PhotoDimensioning.nearestMaterial(to: RGBColor(UInt8(r), UInt8(g), UInt8(b)))
            #expect(m != nil && m!.opacity >= 1 && !["Soil", "Leaf green", "Screen black", "Lampshade"].contains(m!.name))
        } } }
    }
}

// MARK: - Analysis helpers

@Suite struct PhotoAnalysisTests {
    @Test func sniffsImageFormatsFromTheFirstBytes() {
        #expect(PhotoImage.sniffExtension(Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0])) == "jpg")
        #expect(PhotoImage.sniffExtension(pngBytes()) == "png")
        #expect(PhotoImage.sniffExtension(Data("GIF89a".utf8)) == "gif")
        var heic = Data([0, 0, 0, 24]); heic.append(Data("ftypheic".utf8)); heic.append(Data(repeating: 0, count: 8))
        #expect(PhotoImage.sniffExtension(heic) == "heic")
        var mp4 = Data([0, 0, 0, 24]); mp4.append(Data("ftypmp42".utf8)); mp4.append(Data(repeating: 0, count: 8))
        #expect(PhotoImage.sniffExtension(mp4) == nil)
        #expect(PhotoImage.sniffExtension(Data("hello world, not an image".utf8)) == nil)
        #expect(PhotoImage.sniffExtension(Data()) == nil)
    }

    @Test func combineKeepsFrontViewProportionsAndBestLabels() {
        let a = PhotoAnalysis(aspectWH: 2.0, dominantColors: [PhotoColor(RGBColor(10, 10, 10), weight: 1)], labels: [PhotoLabel("sofa", 0.4)])
        let b = PhotoAnalysis(aspectWH: 1.0, aspectDH: 0.5, dominantColors: [PhotoColor(RGBColor(10, 10, 10), weight: 1)],
                              labels: [PhotoLabel("sofa", 0.9), PhotoLabel("armrest", 0.3)])
        let c = PhotoAnalysis.combine([a, b])
        #expect(c.aspectWH == 2.0 && c.aspectDH == 0.5)
        #expect(c.labels.first == PhotoLabel("sofa", 0.9) && c.labels.count == 2)
        #expect(c.dominantColors.count == 1 && c.dominantColors[0].weight == 1)
        #expect(PhotoAnalysis.combine([]) == PhotoAnalysis())
    }
}

// MARK: - Merge

@Suite struct ParamMergeTests {
    private func spec(_ t: BuilderTemplate, width: MM = 2000, doors: Int = 2) -> ParametricSpec {
        var p = BuilderParams(); p.width = width; p.doors = doors
        return ParametricSpec(template: t, params: p)
    }

    @Test func editedFieldsStayTheRestFollows() {
        let old = spec(.cabinet, width: 800, doors: 3)
        var newer = spec(.cabinet, width: 1000, doors: 2); newer.params.height = 1200
        let r = ParamMerge.merge(current: old, proposed: newer, currentTemplateScore: 1, proposedTemplateScore: 1, keep: [.width])
        #expect(r.spec.params.width == 800)
        #expect(r.spec.params.doors == 2 && r.spec.params.height == 1200)
        #expect(r.kept == [.width])
        #expect(Set(r.changed) == [.doors, .height])
        #expect(!r.templateChanged)
    }

    @Test func templateSwitchesOnlyWithAClearLead() {
        let old = spec(.table), newer = spec(.sofa)
        let clear = ParamMerge.merge(current: old, proposed: newer, currentTemplateScore: 0.2, proposedTemplateScore: 1.0, keep: [])
        #expect(clear.spec.template == .sofa && clear.templateChanged && clear.suggestedTemplate == nil)
        let close = ParamMerge.merge(current: old, proposed: newer, currentTemplateScore: 0.8, proposedTemplateScore: 1.0, keep: [])
        #expect(close.spec.template == .table && !close.templateChanged && close.suggestedTemplate == .sofa)
        let edge = ParamMerge.merge(current: old, proposed: newer, currentTemplateScore: 0.5, proposedTemplateScore: 1.0, keep: [])
        #expect(edge.templateChanged)
    }

    @Test func keepingTheTemplateKeepsItsOwnParameters() {
        let old = spec(.cabinet, width: 800, doors: 3)
        var newer = spec(.sofa, width: 1500, doors: 2); newer.params.armWidth = 300; newer.params.seatHeight = 500
        let r = ParamMerge.merge(current: old, proposed: newer, currentTemplateScore: 0.8, proposedTemplateScore: 1.0, keep: [])
        #expect(r.spec.template == .cabinet && r.suggestedTemplate == .sofa)
        #expect(r.spec.params.width == 1500 && r.spec.params.doors == 3)
        #expect(r.spec.params.armWidth == old.params.armWidth && r.spec.params.seatHeight == old.params.seatHeight)
        #expect(Set(r.changed) == [.width])
    }

    @Test func mergedValuesAreClamped() {
        var wild = spec(.sofa); wild.params.armWidth = 9_999_999; wild.params.width = 400
        let r = ParamMerge.merge(current: spec(.sofa), proposed: wild, currentTemplateScore: 1, proposedTemplateScore: 1, keep: [])
        #expect(r.spec.params.armWidth <= 100)
    }

    @Test func nothingKeptMeansTheProposalWins() {
        let r = ParamMerge.merge(current: spec(.box, width: 500), proposed: spec(.box, width: 900), currentTemplateScore: 0, proposedTemplateScore: 0, keep: [])
        #expect(r.spec.params.width == 900 && r.kept.isEmpty)
    }

    @Test func givenDimensionsMapToFields() {
        #expect(ParamMerge.fields(of: PhotoDimensions(width: 1, height: 2)) == [.width, .height])
    }
}

// MARK: - Pipeline

@MainActor
@Suite struct FurnitureFromPhotoPipelineTests {
    @Test func proposalFromSofaPhoto() async throws {
        let p = try await FurnitureFromPhoto.propose(provider: FakeProvider(analysis: sofaAnalysis()), images: [PhotoImage(data: pngBytes(), fileExtension: "png")],
                                                     hint: "", dimensions: PhotoDimensions(width: 2200))
        #expect(p.template == .sofa)
        #expect(p.spec.params.width == 2200)
        #expect(p.spec.params.height == Int64((2200.0 / 2.4).rounded()))
        #expect(p.derived == ["depth", "height"])
        #expect(p.materialName == "Grey fabric")
        #expect(p.notes.contains { $0.contains("Estimated") })
    }

    @Test func fallbackAndAmbiguityAreExplained() async throws {
        let img = [PhotoImage(data: pngBytes(), fileExtension: "png")]
        let none = try await FurnitureFromPhoto.propose(provider: FakeProvider(analysis: PhotoAnalysis()), images: img, hint: "", dimensions: PhotoDimensions(width: 600))
        #expect(none.template == .box && none.choice.fallback)
        #expect(none.notes.contains { $0.contains("plain box") })
        let amb = try await FurnitureFromPhoto.propose(provider: FakeProvider(analysis: PhotoAnalysis(labels: [PhotoLabel("bookcase", 1)])), images: img,
                                                       hint: "cabinet", dimensions: PhotoDimensions(width: 600))
        #expect(amb.choice.ambiguous && amb.notes.contains { $0.contains("Could also be") })
    }

    @Test func inputIsValidatedBeforeTheProviderRuns() async {
        let boom = FakeProvider(analysis: PhotoAnalysis(), failure: "provider must not run")
        let img = PhotoImage(data: pngBytes(), fileExtension: "png")
        await #expect(throws: PhotoAnalysisError.self) { try await FurnitureFromPhoto.propose(provider: boom, images: [], hint: "", dimensions: PhotoDimensions(width: 1)) }
        await #expect(throws: PhotoAnalysisError.self) { try await FurnitureFromPhoto.propose(provider: boom, images: [img], hint: "", dimensions: PhotoDimensions()) }
        await #expect(throws: PhotoAnalysisError.self) {
            try await FurnitureFromPhoto.propose(provider: boom, images: Array(repeating: img, count: FurnitureFromPhoto.maxPhotos + 1), hint: "", dimensions: PhotoDimensions(width: 1))
        }
        do { _ = try await FurnitureFromPhoto.propose(provider: boom, images: [img], hint: "", dimensions: PhotoDimensions(width: 500)); Issue.record("expected the provider error") }
        catch let e as PhotoAnalysisError { #expect(e.message == "provider must not run") } catch { Issue.record("\(error)") }
    }

    @Test func savedEntryLandsInTheAISectionWithPhotosAndDefinition() async throws {
        let dir = try tempDir()
        let store = LibraryStore(root: dir.appendingPathComponent("Library"))
        let a = PhotoImage(data: pngBytes(1), fileExtension: "png"), b = PhotoImage(data: pngBytes(2), fileExtension: "png")
        let p = try await FurnitureFromPhoto.propose(provider: FakeProvider(analysis: sofaAnalysis()), images: [a, b], hint: "Corner sofa", dimensions: PhotoDimensions(width: 2400, depth: 950))
        let e = try FurnitureFromPhoto.save(proposal: p, name: nil, hint: "Corner sofa", images: [a, b, a], in: store)
        #expect(e.section == .ai && e.name == "Corner sofa")
        #expect(e.spec == p.spec)
        #expect(e.size.width == 2400 && e.size.depth == 950)
        #expect(e.tags == ["photo", "sofa"])
        #expect(e.materialNames.contains("Grey fabric"))
        #expect(e.photoAssetNames.count == 2)   // equal bytes share one file
        for n in e.photoAssetNames { #expect(store.assetURL(n) != nil) }
        let t = try store.transfer(for: e.id)
        #expect(t.definitions.count == 1 && t.definitions[0].name == "Corner sofa")
        #expect(store.entries().count == 1)
    }

    @Test func defaultNameUsesTemplateWhenHintIsLongOrEmpty() {
        #expect(FurnitureFromPhoto.defaultName(hint: "", template: .shelf) == "Shelf from photo")
        #expect(FurnitureFromPhoto.defaultName(hint: String(repeating: "x", count: 80), template: .box) == "Box from photo")
        #expect(FurnitureFromPhoto.defaultName(hint: "  Oak desk ", template: .table) == "Oak desk")
    }

    @Test func improveKeepsEditedFieldsAddsPhotosAndBumpsRev() async throws {
        let dir = try tempDir()
        let store = LibraryStore(root: dir.appendingPathComponent("Library"))
        let first = PhotoImage(data: pngBytes(1), fileExtension: "png"), second = PhotoImage(data: pngBytes(2), fileExtension: "png")
        let provider = FakeProvider(analysis: sofaAnalysis())
        let p1 = try await FurnitureFromPhoto.propose(provider: provider, images: [first], hint: "", dimensions: PhotoDimensions(width: 2000))
        let e = try FurnitureFromPhoto.save(proposal: p1, name: "Sofa", hint: "", images: [first], in: store)

        let dims = PhotoDimensions(height: 900)
        let p2 = try await FurnitureFromPhoto.propose(provider: provider, images: [second], hint: "", dimensions: dims)
        let r = try FurnitureFromPhoto.improve(entryId: e.id, proposal: p2, dimensions: dims, keep: [.width, .height], images: [second], in: store)
        #expect(r.entry.rev == e.rev + 1)
        #expect(r.entry.spec?.params.width == 2000)         // kept
        #expect(r.entry.spec?.params.height == 900)         // given in this call, so not kept
        #expect(r.entry.photoAssetNames.count == 2)
        #expect(r.entry.name == "Sofa" && r.entry.section == .ai)
        #expect(try store.transfer(for: e.id).definitions.count == 1)
        #expect(store.entries().count == 1)
    }

    @Test func editedDesignIsSavedWithoutRecipeWhenItDiffers() async throws {
        let dir = try tempDir()
        let store = LibraryStore(root: dir.appendingPathComponent("Library"))
        let p = try await FurnitureFromPhoto.propose(provider: FakeProvider(analysis: sofaAnalysis()), images: [PhotoImage(data: pngBytes(), fileExtension: "png")], hint: "", dimensions: PhotoDimensions(width: 2000))
        var def = p.spec.generate(name: "Sofa")
        #expect(FurnitureFromPhoto.follows(def, recipe: p.spec))
        def.components[0].size.height += 10
        #expect(!FurnitureFromPhoto.follows(def, recipe: p.spec))
        var other = p.spec; other.params.width += 100
        #expect(!FurnitureFromPhoto.follows(p.spec.generate(name: "Sofa"), recipe: other))
        let e = try FurnitureFromPhoto.save(definition: def, spec: nil, proposal: p, name: "Edited sofa", hint: "", images: [], in: store)
        #expect(e.spec == nil && e.section == .ai && e.name == "Edited sofa")
        #expect(try store.transfer(for: e.id).definitions[0].components[0].size.height == def.components[0].size.height)
    }

    @Test func improveNeedsARecipe() async throws {
        let dir = try tempDir()
        let store = LibraryStore(root: dir.appendingPathComponent("Library"))
        let p = try await FurnitureFromPhoto.propose(provider: FakeProvider(analysis: sofaAnalysis()), images: [PhotoImage(data: pngBytes(), fileExtension: "png")], hint: "", dimensions: PhotoDimensions(width: 2000))
        var e = try FurnitureFromPhoto.save(proposal: p, name: nil, hint: "", images: [], in: store)
        e = try store.update(e.id) { $0.spec = nil }
        #expect(throws: LibraryError.self) { try FurnitureFromPhoto.improve(entryId: e.id, proposal: p, dimensions: PhotoDimensions(width: 1000), keep: [], images: [], in: store) }
        #expect(throws: LibraryError.self) { try FurnitureFromPhoto.improve(entryId: UUID(), proposal: p, dimensions: PhotoDimensions(width: 1000), keep: [], images: [], in: store) }
    }
}

// MARK: - Tool

@MainActor
@Suite struct LibraryPhotoToolTests {
    private func args(_ path: String, _ extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = ["imagePath": .string(path), "dimensions": .object(["width": 2000])]
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    @Test func createsAnAIEntryFromAPhotoFile() async throws {
        let rig = try PhotoRig()
        let res = await rig.ok(args(try rig.writePhoto(), ["hint": "three seat sofa", "name": "Test sofa"]))
        #expect(res["entry"]?["section"]?.stringValue == "ai")
        #expect(res["entry"]?["name"]?.stringValue == "Test sofa")
        #expect(res["entry"]?["size"]?["width"]?.int64Value == 2000)
        #expect(res["improved"]?.boolValue == false)
        let s = try #require(res["suggestion"])
        #expect(s["template"]?.stringValue == "sofa")
        #expect(s["material"]?.stringValue == "Grey fabric")
        #expect(s["recognised"]?.boolValue == true)
        #expect(s["estimated"]?.arrayValue?.compactMap(\.stringValue) == ["depth", "height"])
        #expect(s["spec"]?["template"]?.stringValue == "sofa")
        let id = try #require(UUID(uuidString: res["entry"]?["id"]?.stringValue ?? ""))
        let e = try #require(rig.store.entry(id))
        #expect(e.photoAssetNames.count == 1 && e.spec?.template == .sofa)
    }

    @Test func acceptsBase64AndDataURLs() async throws {
        let rig = try PhotoRig()
        let b64 = pngBytes(7).base64EncodedString()
        let plain = await rig.ok(.object(["imageBase64": .string(b64), "dimensions": .object(["height": 850])]))
        #expect(plain["entry"]?["size"]?["height"]?.int64Value == 850)
        let url = await rig.ok(.object(["imageBase64": .string("data:image/png;base64," + b64), "dimensions": .object(["height": 850])]))
        #expect(url["entry"]?["id"]?.stringValue != plain["entry"]?["id"]?.stringValue)
        // Equal bytes share one stored photo.
        #expect(rig.store.entries().flatMap(\.photoAssetNames).reduce(into: Set<String>()) { $0.insert($1) }.count == 1)
    }

    @Test func severalPhotosShareOneEntry() async throws {
        let rig = try PhotoRig()
        let res = await rig.ok(args(try rig.writePhoto("a.png", pngBytes(1)), ["imagePaths": .array([.string(try rig.writePhoto("b.png", pngBytes(2)))])]))
        let id = try #require(UUID(uuidString: res["entry"]?["id"]?.stringValue ?? ""))
        #expect(rig.store.entry(id)?.photoAssetNames.count == 2)
    }

    @Test func missingDimensionsAreRejected() async throws {
        let rig = try PhotoRig()
        let p = try rig.writePhoto()
        for bad: JSONValue in [.object(["imagePath": .string(p)]),
                               .object(["imagePath": .string(p), "dimensions": .object([:])]),
                               .object(["imagePath": .string(p), "dimensions": .object(["width": 0])]),
                               .object(["imagePath": .string(p), "dimensions": .object(["height": 200_000])])] {
            let r = await rig.call(bad)
            #expect(!r.ok)
            #expect(r.error?.code == AgentError.invalidArgument, "\(bad)")
        }
        #expect(rig.store.entries().isEmpty)
    }

    @Test func unreadableOrUnsuitableImagesAreRejected() async throws {
        let rig = try PhotoRig()
        let r1 = await rig.call(args("relative/photo.png"))
        #expect(r1.error?.code == AgentError.invalidArgument)
        let r2 = await rig.call(args(rig.dir.appendingPathComponent("missing.png").path))
        #expect(r2.error?.code == AgentError.notFound)
        let r3 = await rig.call(args(rig.dir.path))
        #expect(r3.error?.code == AgentError.invalidArgument)
        let r4 = await rig.call(args(try rig.writePhoto("note.png", Data("just text".utf8))))
        #expect(r4.error?.code == AgentError.invalidArgument)
        #expect(r4.error?.message.contains("supported image") == true)
        let r5 = await rig.call(.object(["imageBase64": "@@@ not base64 @@@", "dimensions": .object(["width": 1000])]))
        #expect(r5.error?.code == AgentError.invalidArgument)
        let r6 = await rig.call(.object(["dimensions": .object(["width": 1000])]))
        #expect(r6.error?.code == AgentError.invalidArgument)
        #expect(rig.store.entries().isEmpty)
    }

    @Test func tooLargeBase64IsRejectedBeforeDecoding() async throws {
        let rig = try PhotoRig()
        let huge = String(repeating: "A", count: LibraryPhotoTools.maxBase64Chars + 4)
        let r = await rig.call(.object(["imageBase64": .string(huge), "dimensions": .object(["width": 1000])]))
        #expect(r.error?.code == AgentError.invalidArgument)
        #expect(r.error?.message.contains("too large") == true)
    }

    @Test func tooManyPhotosAreRejected() async throws {
        let rig = try PhotoRig()
        let p = try rig.writePhoto()
        let r = await rig.call(args(p, ["imagePaths": .array(Array(repeating: .string(p), count: FurnitureFromPhoto.maxPhotos))]))
        #expect(r.error?.code == AgentError.invalidArgument)
    }

    @Test func tooManyPathsAreRejectedBeforeAnyFileIsRead() async throws {
        let rig = try PhotoRig()
        let missing = rig.dir.appendingPathComponent("missing.png").path
        // The files do not exist: a count check after reading would report NOT_FOUND instead.
        let r = await rig.call(args(missing, ["imagePaths": .array(Array(repeating: .string(missing), count: FurnitureFromPhoto.maxPhotos))]))
        #expect(r.error?.code == AgentError.invalidArgument)
    }

    @Test func aLinkToAnOversizedFileIsRejected() async throws {
        let rig = try PhotoRig()
        let big = rig.dir.appendingPathComponent("big.png")
        #expect(FileManager.default.createFile(atPath: big.path, contents: pngBytes()))
        let h = try FileHandle(forWritingTo: big)
        try h.truncate(atOffset: UInt64(LibraryPhotoTools.maxFileBytes + 1))
        try h.close()
        let link = rig.dir.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: big)
        let r = await rig.call(args(link.path))
        #expect(r.error?.code == AgentError.invalidArgument)
        #expect(r.error?.message.contains("larger") == true)
        #expect(rig.store.entries().isEmpty)
    }

    @Test func aLinkToAPhotoIsFollowed() async throws {
        let rig = try PhotoRig()
        let link = rig.dir.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: try rig.writePhoto()))
        let r = await rig.call(args(link.path))
        #expect(r.error == nil)
    }

    @Test func specialFilesAreRejected() async throws {
        let rig = try PhotoRig()
        let fifo = rig.dir.appendingPathComponent("pipe.png").path
        #expect(mkfifo(fifo, 0o600) == 0)
        for path in [fifo, rig.dir.path] {
            let r = await rig.call(args(path))
            #expect(r.error?.code == AgentError.invalidArgument)
            #expect(r.error?.message.contains("regular file") == true)
        }
    }

    @Test func withoutTheAppItIsUnsupported() async throws {
        let rig = try PhotoRig(provider: nil)
        let r = await rig.call(args(try rig.writePhoto()))
        #expect(r.error?.code == ExportTools.unsupported)
        #expect(rig.store.entries().isEmpty)
    }

    @Test func writeAccessIsRequired() async throws {
        let rig = try PhotoRig(write: false)
        let r = await rig.call(args(try rig.writePhoto()))
        #expect(r.error?.code == AgentError.writeLocked)
    }

    @Test func providerFailureIsReportedWithoutSaving() async throws {
        let rig = try PhotoRig(provider: FakeProvider(analysis: PhotoAnalysis(), failure: "Vision could not read the picture"))
        let r = await rig.call(args(try rig.writePhoto()))
        #expect(!r.ok)
        #expect(r.error?.message.contains("Vision could not read the picture") == true)
        #expect(rig.store.entries().isEmpty)
    }

    @Test func unknownPhotoFallsBackToBoxWithANote() async throws {
        let rig = try PhotoRig(provider: FakeProvider(analysis: PhotoAnalysis(labels: [PhotoLabel("banana", 0.9)])))
        let res = await rig.ok(args(try rig.writePhoto()))
        let s = try #require(res["suggestion"])
        #expect(s["template"]?.stringValue == "box" && s["recognised"]?.boolValue == false)
        #expect(s["notes"]?.arrayValue?.contains { $0.stringValue?.contains("plain box") == true } == true)
    }

    @Test func improveUpdatesTheEntryAndKeepsFields() async throws {
        let rig = try PhotoRig()
        let created = await rig.ok(args(try rig.writePhoto("a.png", pngBytes(1))))
        let id = try #require(created["entry"]?["id"]?.stringValue)
        let res = await rig.ok(.object([
            "imagePath": .string(try rig.writePhoto("b.png", pngBytes(2))), "improveEntryId": .string(id),
            "dimensions": .object(["height": 700]), "keepFields": .array(["width"]),
        ]))
        #expect(res["improved"]?.boolValue == true)
        #expect(res["entry"]?["id"]?.stringValue == id)
        #expect(res["entry"]?["rev"]?.int64Value == 2)
        #expect(res["entry"]?["size"]?["width"]?.int64Value == 2000)
        #expect(res["entry"]?["size"]?["height"]?.int64Value == 700)
        #expect(rig.store.entries().count == 1)
        #expect(rig.store.entry(try #require(UUID(uuidString: id)))?.photoAssetNames.count == 2)
    }

    @Test func improveRejectsUnknownEntriesAndFields() async throws {
        let rig = try PhotoRig()
        let p = try rig.writePhoto()
        let missing = await rig.call(args(p, ["improveEntryId": .string(UUID().uuidString.lowercased())]))
        #expect(missing.error?.code == AgentError.notFound)
        let created = await rig.ok(args(p))
        let id = try #require(created["entry"]?["id"]?.stringValue)
        let bad = await rig.call(args(p, ["improveEntryId": .string(id), "keepFields": .array(["colour"])]))
        #expect(bad.error?.code == AgentError.invalidArgument)
        #expect(rig.store.entries().count == 1)
    }

    @Test func toolIsDescribedAsAWritingLibraryTool() async throws {
        let rig = try PhotoRig()
        let d = try #require(rig.registry.descriptors.first { $0.name == "library.create_from_photo" })
        #expect(!d.readOnly)
        #expect(d.inputSchema["required"]?.arrayValue?.compactMap(\.stringValue) == ["dimensions"])
    }
}
