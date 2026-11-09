import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import RoomsmithCore

// Agent tools for backgrounds, materials and furniture designs: exact calibration numbers, dry run, undo, errors.

@MainActor
private final class DesignContext: AgentAppContext {
    var selection: Set<UUID> = []
    var activeLevelId: UUID
    var fileURL: URL?
    var appVersion = "test"
    init(activeLevelId: UUID) { self.activeLevelId = activeLevelId }
    func saveForAgent() throws -> String { fileURL?.path ?? "/tmp/test.roomsmith" }
}

@MainActor
private struct DRig {
    let store: DocumentStore
    let context: DesignContext
    let registry: ToolRegistry
    var levelId: UUID { store.project.levels[0].id }
    var p: Project { store.project }

    init() {
        let project = Project.empty(name: "Design")
        store = DocumentStore(project: project)
        store.agentWriteEnabled = true
        context = DesignContext(activeLevelId: project.levels[0].id)
        registry = ToolRegistry(store: store, context: context)
    }

    @discardableResult
    func call(_ tool: String, _ args: JSONValue = .object([:])) async -> AgentResponse {
        await registry.call(AgentRequest(id: 1, token: "t", clientId: "test", tool: tool, arguments: args))
    }

    func ok(_ tool: String, _ args: JSONValue = .object([:]), sourceLocation: SourceLocation = #_sourceLocation) async -> JSONValue {
        let r = await call(tool, args)
        #expect(r.ok, "\(tool) failed: \(r.error?.code ?? "?") \(r.error?.message ?? "")", sourceLocation: sourceLocation)
        return r.result ?? .null
    }

    func error(_ tool: String, _ args: JSONValue = .object([:])) async -> AgentError? {
        let r = await call(tool, args)
        return r.ok ? nil : r.error
    }
}

private func xy(_ x: Int, _ y: Int) -> JSONValue { ["x": .int(Int64(x)), "y": .int(Int64(y))] }
private func xyz(_ x: Int, _ y: Int, _ z: Int = 0) -> JSONValue { ["x": .int(Int64(x)), "y": .int(Int64(y)), "z": .int(Int64(z))] }
private func size(_ w: Int, _ d: Int, _ h: Int) -> JSONValue { ["width": .int(Int64(w)), "depth": .int(Int64(d)), "height": .int(Int64(h))] }

private extension BackgroundImage {
    /// Undo restores content but stamps a new revision.
    var withoutRev: BackgroundImage { var c = self; c.rev = 0; return c }
}

private func scratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rs-design-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Writes a plain white PNG of the given pixel size.
private func writePNG(_ url: URL, width: Int, height: Int) throws {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    #expect(CGImageDestinationFinalize(dest))
}

// MARK: - Background

@MainActor
struct BackgroundToolTests {
    /// Rig with a saved-looking package folder and a 2000 x 1000 px scan.
    private func prepared() throws -> (DRig, image: URL, pkg: URL) {
        let rig = DRig()
        let dir = try scratch()
        let pkg = dir.appendingPathComponent("Test.roomsmith")
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        rig.context.fileURL = pkg
        let img = dir.appendingPathComponent("plan.png")
        try writePNG(img, width: 2000, height: 1000)
        return (rig, img, pkg)
    }

    @Test func addCalibratesExactlyAndCopiesIntoPackage() async throws {
        let (rig, img, pkg) = try prepared()
        // 400 px apart horizontally = 5000 mm  ->  12.5 mm per pixel, exactly.
        let r = await rig.ok("background.add", ["path": .string(img.path), "pixelA": xy(100, 200), "pixelB": xy(500, 200),
                                                "realLengthMm": 5000, "originMm": xy(1000, 20000)])
        #expect(r["mmPerPixel"]?.doubleValue == 12.5)
        #expect(r["widthPx"]?.int64Value == 2000)
        let maxX: Int64 = 26000, minY: Int64 = 7500
        #expect(r["extentMm"]?["maxX"]?.int64Value == maxX)
        #expect(r["extentMm"]?["minY"]?.int64Value == minY)
        let b = try #require(rig.p.backgrounds.first)
        #expect(b.mmPerPixel == 12.5)
        #expect(b.calibrationLength == 5000)
        #expect(b.opacity == 0.5)
        let asset = try #require(rig.p.asset(b.assetId))
        #expect(FileManager.default.fileExists(atPath: pkg.appendingPathComponent("assets").appendingPathComponent(asset.storedName).path))
        // The pixel top-left maps to the origin, the pixel (2000,1000) to origin + (25000, -12500).
        let tl = rig.p.backgroundWorld(b, pixel: P2(0, 0)), br = rig.p.backgroundWorld(b, pixel: P2(2000, 1000))
        #expect(tl == V2(1000, 20000))
        #expect(br == V2(26000, 7500))
    }

    @Test func addByMmPerPixelPicksExactCalibration() async throws {
        let (rig, img, _) = try prepared()
        let r = await rig.ok("background.add", ["path": .string(img.path), "mmPerPixel": 2.5])
        #expect(r["mmPerPixel"]?.doubleValue == 2.5)
        #expect(rig.p.backgrounds[0].mmPerPixel == 2.5)
    }

    @Test func addDryRunLeavesPackageAndProjectUntouched() async throws {
        let (rig, img, pkg) = try prepared()
        let rev = rig.store.project.revision
        _ = await rig.ok("background.add", ["path": .string(img.path), "mmPerPixel": 10, "dryRun": true])
        #expect(rig.p.backgrounds.isEmpty)
        #expect(rig.p.assets.isEmpty)
        #expect(rig.p.revision == rev)
        let assets = pkg.appendingPathComponent("assets")
        #expect(!FileManager.default.fileExists(atPath: assets.path) || ((try? FileManager.default.contentsOfDirectory(atPath: assets.path))?.isEmpty ?? true))
    }

    @Test func addIsUndoable() async throws {
        let (rig, img, _) = try prepared()
        _ = await rig.ok("background.add", ["path": .string(img.path), "mmPerPixel": 10])
        #expect(rig.p.backgrounds.count == 1)
        _ = await rig.ok("history.undo")
        #expect(rig.p.backgrounds.isEmpty)
    }

    @Test func addRejectsBadInput() async throws {
        let (rig, img, _) = try prepared()
        let path = JSONValue.string(img.path)
        // No calibration at all.
        #expect(await rig.error("background.add", ["path": path])?.code == AgentError.invalidArgument)
        // Identical calibration pixels.
        #expect(await rig.error("background.add", ["path": path, "pixelA": xy(5, 5), "pixelB": xy(5, 5), "realLengthMm": 1000])?.code == AgentError.invalidArgument)
        // Pixel outside the 2000 x 1000 image.
        #expect(await rig.error("background.add", ["path": path, "pixelA": xy(0, 0), "pixelB": xy(2001, 0), "realLengthMm": 1000])?.code == AgentError.invalidArgument)
        // Negative pixel.
        #expect(await rig.error("background.add", ["path": path, "pixelA": xy(-1, 0), "pixelB": xy(10, 0), "realLengthMm": 1000])?.code == AgentError.invalidArgument)
        // Zero and oversized length.
        #expect(await rig.error("background.add", ["path": path, "pixelA": xy(0, 0), "pixelB": xy(10, 0), "realLengthMm": 0])?.code == AgentError.outOfRange)
        #expect(await rig.error("background.add", ["path": path, "pixelA": xy(0, 0), "pixelB": xy(10, 0), "realLengthMm": 100001])?.code == AgentError.outOfRange)
        // Both scale forms, path and assetId together, relative path, missing file, non-image.
        #expect(await rig.error("background.add", ["path": path, "pixelA": xy(0, 0), "pixelB": xy(10, 0), "realLengthMm": 100, "mmPerPixel": 1])?.code == AgentError.invalidArgument)
        #expect(await rig.error("background.add", ["path": path, "assetId": .string(UUID().uuidString), "mmPerPixel": 1])?.code == AgentError.invalidArgument)
        #expect(await rig.error("background.add", ["path": "plan.png", "mmPerPixel": 1])?.code == AgentError.invalidArgument)
        #expect(await rig.error("background.add", ["path": "/nonexistent/plan.png", "mmPerPixel": 1])?.code == AgentError.notFound)
        let txt = img.deletingLastPathComponent().appendingPathComponent("plan.txt")
        try "x".write(to: txt, atomically: true, encoding: .utf8)
        #expect(await rig.error("background.add", ["path": .string(txt.path), "mmPerPixel": 1])?.code == AgentError.invalidArgument)
        #expect(await rig.error("background.add", ["path": path, "mmPerPixel": 0])?.code == AgentError.outOfRange)
        #expect(await rig.error("background.add", ["path": path, "mmPerPixel": 1, "opacity": 2])?.code == AgentError.invalidArgument)
        #expect(rig.p.backgrounds.isEmpty)
    }

    @Test func addNeedsSavedProject() async throws {
        let (rig, img, _) = try prepared()
        rig.context.fileURL = nil
        #expect(await rig.error("background.add", ["path": .string(img.path), "mmPerPixel": 1])?.code == AgentError.invalidArgument)
    }

    @Test func calibrateGivesExactScaleAndKeepsAnchor() async throws {
        let (rig, img, _) = try prepared()
        let added = await rig.ok("background.add", ["path": .string(img.path), "mmPerPixel": 10, "originMm": xy(3000, 8000)])
        let id = try #require(added["id"]?.stringValue)
        let anchorBefore = rig.p.backgroundWorld(rig.p.backgrounds[0], pixel: P2(300, 100))
        // 3-4-5 triangle: 300 px / 400 px apart = 500 px, 4000 mm  ->  8 mm per pixel exactly.
        let r = await rig.ok("background.calibrate", ["id": .string(id), "pixelA": xy(300, 100), "pixelB": xy(600, 500), "realLengthMm": 4000])
        #expect(r["mmPerPixel"]?.doubleValue == 8)
        #expect(r["previousMmPerPixel"]?.doubleValue == 10)
        #expect(r["measuredDistanceMm"]?.doubleValue == 4000)
        let b = rig.p.backgrounds[0]
        #expect(b.mmPerPixel == 8)
        #expect(b.calibrationLength == 4000)
        #expect(b.calibrationA == P2(300, 100) && b.calibrationB == P2(600, 500))
        // Anchor pixel A stays put (origin is whole mm: 3000 + 300*10 - 300*8 = 3600, 8000 - 1000 + 800 = 7800).
        #expect(rig.p.backgroundWorld(b, pixel: P2(300, 100)) == V2(Double(anchorBefore.x), Double(anchorBefore.y)))
        #expect(b.origin == P2(3600, 7800))
        let wa = rig.p.backgroundWorld(b, pixel: b.calibrationA), wb = rig.p.backgroundWorld(b, pixel: b.calibrationB)
        #expect(((wb.x - wa.x) * (wb.x - wa.x) + (wb.y - wa.y) * (wb.y - wa.y)).squareRoot() == 4000)
    }

    @Test func calibrateWithWorldAnchorAndUndo() async throws {
        let (rig, img, _) = try prepared()
        let added = await rig.ok("background.add", ["path": .string(img.path), "mmPerPixel": 10])
        let id = try #require(added["id"]?.stringValue)
        let before = rig.p.backgrounds[0]
        // 1000 px = 25000 mm -> 25 mm per pixel; pixel (200,100) goes to world (5000, 5000): origin = (5000-5000, 5000+2500).
        _ = await rig.ok("background.calibrate", ["id": .string(id), "pixelA": xy(200, 100), "pixelB": xy(1200, 100), "realLengthMm": 25000,
                                                  "worldA": xy(5000, 5000)])
        let b = rig.p.backgrounds[0]
        #expect(b.mmPerPixel == 25)
        #expect(b.origin == P2(0, 7500))
        #expect(rig.p.backgroundWorld(b, pixel: P2(200, 100)) == V2(5000, 5000))
        _ = await rig.ok("history.undo")
        #expect(rig.p.backgrounds[0].withoutRev == before.withoutRev)
    }

    @Test func calibrateRejectsBadInput() async throws {
        let (rig, img, _) = try prepared()
        let added = await rig.ok("background.add", ["path": .string(img.path), "mmPerPixel": 10])
        let id = JSONValue.string(try #require(added["id"]?.stringValue))
        let before = rig.p.backgrounds[0]
        #expect(await rig.error("background.calibrate", ["id": id, "pixelA": xy(5, 5), "pixelB": xy(5, 5), "realLengthMm": 100])?.code == AgentError.invalidArgument)
        #expect(await rig.error("background.calibrate", ["id": id, "pixelA": xy(0, 0), "pixelB": xy(10, 0), "realLengthMm": 0])?.code == AgentError.outOfRange)
        #expect(await rig.error("background.calibrate", ["id": id, "pixelA": xy(0, 0), "pixelB": xy(5000, 0), "realLengthMm": 100])?.code == AgentError.invalidArgument)
        #expect(await rig.error("background.calibrate", ["id": id, "pixelA": xy(0, 0), "pixelB": xy(10, 0)])?.code == AgentError.invalidArgument)
        #expect(await rig.error("background.calibrate", ["id": .string(UUID().uuidString), "pixelA": xy(0, 0), "pixelB": xy(10, 0), "realLengthMm": 100])?.code == AgentError.notFound)
        #expect(await rig.error("background.calibrate", ["id": .string(rig.levelId.uuidString), "pixelA": xy(0, 0), "pixelB": xy(10, 0), "realLengthMm": 100])?.code == AgentError.invalidArgument)
        #expect(rig.p.backgrounds[0] == before)
    }

    @Test func updateChangesOnlyGivenKeys() async throws {
        let (rig, img, _) = try prepared()
        let added = await rig.ok("background.add", ["path": .string(img.path), "mmPerPixel": 10])
        let id = JSONValue.string(try #require(added["id"]?.stringValue))
        let before = rig.p.backgrounds[0]
        _ = await rig.ok("background.update", ["id": id, "opacity": 0.25, "visible": false, "originMm": xy(-500, 700)])
        var b = rig.p.backgrounds[0]
        #expect(b.opacity == 0.25 && b.visible == false && b.origin == P2(-500, 700))
        #expect(b.calibrationLength == before.calibrationLength && b.mmPerPixel == before.mmPerPixel && b.assetId == before.assetId)
        #expect(await rig.error("background.update", ["id": id])?.code == AgentError.invalidArgument)
        #expect(await rig.error("background.update", ["id": id, "opacity": -0.1])?.code == AgentError.invalidArgument)
        #expect(await rig.error("background.update", ["id": id, "levelId": .string(UUID().uuidString)])?.code == AgentError.notFound)
        _ = await rig.ok("history.undo")
        b = rig.p.backgrounds[0]
        #expect(b.withoutRev == before.withoutRev)
    }

    @Test func existingAssetCanBeReusedWithoutFile() async throws {
        let (rig, img, _) = try prepared()
        _ = await rig.ok("background.add", ["path": .string(img.path), "mmPerPixel": 10])
        let assetId = rig.p.backgrounds[0].assetId
        // Same image again by path reuses the content-addressed stored file.
        _ = await rig.ok("background.add", ["assetId": .string(assetId.uuidString.lowercased()), "mmPerPixel": 4])
        #expect(rig.p.backgrounds.count == 2)
        #expect(rig.p.backgrounds[1].assetId == assetId)
        #expect(rig.p.backgrounds[1].mmPerPixel == 4)
    }
}

// MARK: - Material

@MainActor
struct MaterialToolTests {
    @Test func createAndUpdate() async throws {
        let rig = DRig()
        let r = await rig.ok("material.create", ["name": "Oak", "color": "#B08D57", "roughness": 0.4, "metallic": 0.1, "opacity": 0.9, "textureTileMm": 600])
        let id = try #require(r["id"]?.stringValue)
        let m = try #require(rig.p.materials.first { $0.name == "Oak" })
        #expect(m.color.hex == "#B08D57" && m.roughness == 0.4 && m.metallic == 0.1 && m.opacity == 0.9 && m.textureTile == 600)
        let u = await rig.ok("material.update", ["id": .string(id), "color": "#112233", "name": "Dark oak"])
        #expect(u["color"]?.stringValue == "#112233")
        let n = try #require(rig.p.material(m.id))
        #expect(n.name == "Dark oak" && n.roughness == 0.4 && n.color.hex == "#112233")
        _ = await rig.ok("history.undo")
        #expect(rig.p.material(m.id)?.name == "Oak")
    }

    @Test func secondColourCanBeRemovedWithNullOrEmptyString() async throws {
        let rig = DRig()
        let r = await rig.ok("material.create", ["name": "Stripes", "color": "#B08D57", "pattern": "stripes", "color2": "#112233"])
        let id = try #require(r["id"]?.stringValue)
        let mid = try #require(rig.p.materials.first { $0.name == "Stripes" }?.id)
        #expect(rig.p.material(mid)?.color2?.hex == "#112233")
        // An unrelated update keeps it.
        _ = await rig.ok("material.update", ["id": .string(id), "roughness": 0.3])
        #expect(rig.p.material(mid)?.color2?.hex == "#112233")
        let a = await rig.ok("material.update", ["id": .string(id), "color2": .null])
        #expect(rig.p.material(mid)?.color2 == nil)
        #expect(a["color2"]?.isNull == true)
        _ = await rig.ok("material.update", ["id": .string(id), "color2": "#445566"])
        #expect(rig.p.material(mid)?.color2?.hex == "#445566")
        _ = await rig.ok("material.update", ["id": .string(id), "color2": ""])
        #expect(rig.p.material(mid)?.color2 == nil)
        // A bad value is still refused.
        #expect(await rig.error("material.update", ["id": .string(id), "color2": "red"])?.code == AgentError.invalidArgument)
    }

    @Test func createDefaultsAndDryRun() async throws {
        let rig = DRig()
        _ = await rig.ok("material.create", ["name": "Plain", "color": "#FFFFFF", "dryRun": true])
        #expect(rig.p.materials.isEmpty)
        _ = await rig.ok("material.create", ["name": "Plain", "color": "#FFFFFF"])
        let m = try #require(rig.p.materials.first)
        #expect(m.roughness == 0.7 && m.metallic == 0 && m.opacity == 1 && m.textureTile == 1000)
    }

    @Test func rejectsBadValues() async throws {
        let rig = DRig()
        _ = await rig.ok("material.create", ["name": "Oak", "color": "#B08D57"])
        let id = JSONValue.string(rig.p.materials[0].id.uuidString.lowercased())
        #expect(await rig.error("material.create", ["name": "oak", "color": "#000000"])?.code == AgentError.invalidArgument)
        #expect(await rig.error("material.create", ["name": "Bad", "color": "red"])?.code == AgentError.invalidArgument)
        #expect(await rig.error("material.create", ["name": "Bad", "color": "#000000", "roughness": 1.5])?.code == AgentError.invalidArgument)
        #expect(await rig.error("material.create", ["name": "Bad", "color": "#000000", "opacity": -0.1])?.code == AgentError.invalidArgument)
        #expect(await rig.error("material.create", ["name": "Bad", "color": "#000000", "textureTileMm": 0])?.code == AgentError.invalidArgument)
        #expect(await rig.error("material.create", ["name": " ", "color": "#000000"])?.code == AgentError.invalidArgument)
        #expect(await rig.error("material.update", ["id": id])?.code == AgentError.invalidArgument)
        #expect(await rig.error("material.update", ["id": id, "metallic": 2])?.code == AgentError.invalidArgument)
        #expect(await rig.error("material.update", ["id": .string(UUID().uuidString), "color": "#000000"])?.code == AgentError.notFound)
        #expect(await rig.error("material.update", ["id": .string(rig.levelId.uuidString), "color": "#000000"])?.code == AgentError.invalidArgument)
        #expect(rig.p.materials.count == 1)
    }

    @Test func renameToExistingNameIsRejectedButSameNameIsFine() async throws {
        let rig = DRig()
        _ = await rig.ok("material.create", ["name": "A", "color": "#000000"])
        _ = await rig.ok("material.create", ["name": "B", "color": "#000000"])
        let a = JSONValue.string(rig.p.materials[0].id.uuidString.lowercased())
        #expect(await rig.error("material.update", ["id": a, "name": "b"])?.code == AgentError.invalidArgument)
        _ = await rig.ok("material.update", ["id": a, "name": "A"])
    }

    @Test func createdMaterialIsUsableByName() async throws {
        let rig = DRig()
        _ = await rig.ok("material.create", ["name": "Teal", "color": "#008080"])
        let r = await rig.ok("furniture.create_from_template", ["template": "box", "name": "Crate", "size": size(500, 500, 500), "material": "teal"])
        let defId = try #require(r["id"]?.stringValue)
        let def = try #require(rig.p.definition(UUID(uuidString: defId)!))
        #expect(def.components.allSatisfy { $0.materialId == rig.p.materials[0].id })
    }
}

// MARK: - Furniture design tools

@MainActor
struct FurnitureDesignToolTests {
    private func table(_ rig: DRig) async throws -> UUID {
        let r = await rig.ok("furniture.create_definition", [
            "name": "Desk", "category": "Test", "size": size(1200, 600, 750), "defaultState": "up",
            "components": [["name": "top", "shape": "box", "position": xyz(0, 0, 735), "size": size(1200, 600, 30)],
                           ["name": "leg", "shape": "box", "position": xyz(500, 250, 360), "size": size(50, 50, 720)]],
            "states": [["name": "up", "poses": ["top": ["position": xyz(0, 0, 735)], "leg": ["visible": true]]],
                       ["name": "down", "poses": ["top": ["position": xyz(0, 0, 400)]]]],
        ])
        return UUID(uuidString: try #require(r["id"]?.stringValue))!
    }

    @Test func templatesCreateValidDesigns() async throws {
        let rig = DRig()
        let cases: [(String, JSONValue)] = [
            ("cabinet", ["shelves": 3, "doors": 2, "plinth": 80]), ("table", ["legInset": 60, "topThickness": 25]),
            ("shelf", ["boards": 5]), ("sofa", ["armWidth": 200, "seatHeight": 450]), ("box", [:]),
        ]
        for (t, extra) in cases {
            var args: [String: JSONValue] = ["template": .string(t), "name": .string("T-\(t)"), "size": size(1800, 900, 1000)]
            for (k, v) in extra.objectValue ?? [:] { args[k] = v }
            let r = await rig.ok("furniture.create_from_template", .object(args))
            let defId = try #require(r["id"]?.stringValue)
        let def = try #require(rig.p.definition(UUID(uuidString: defId)!))
            #expect(def.name == "T-\(t)" && def.size == Size3(1800, 900, 1000))
            #expect(!def.components.isEmpty && r["componentCount"]?.int64Value == Int64(def.components.count))
        }
        #expect(rig.p.definitions.count == 5)
        // Defaults and instance placement work.
        let id = rig.p.definitions[0].id.uuidString.lowercased()
        _ = await rig.ok("furniture.create_instance", ["definitionId": .string(id), "position": xyz(0, 0)])
    }

    @Test func cabinetShelvesChangeComponentCount() async throws {
        let rig = DRig()
        let a = await rig.ok("furniture.create_from_template", ["template": "shelf", "name": "S2", "size": size(800, 300, 1800), "boards": 2])
        let b = await rig.ok("furniture.create_from_template", ["template": "shelf", "name": "S6", "size": size(800, 300, 1800), "boards": 6])
        #expect((b["componentCount"]?.int64Value ?? 0) - (a["componentCount"]?.int64Value ?? 0) == 4)
    }

    @Test func templateRejectsBadInput() async throws {
        let rig = DRig()
        let base: [String: JSONValue] = ["template": "cabinet", "name": "X", "size": size(800, 400, 900)]
        func with(_ k: String, _ v: JSONValue) -> JSONValue { var d = base; d[k] = v; return .object(d) }
        #expect(await rig.error("furniture.create_from_template", with("template", "spaceship"))?.code == AgentError.invalidArgument)
        #expect(await rig.error("furniture.create_from_template", with("name", " "))?.code == AgentError.invalidArgument)
        #expect(await rig.error("furniture.create_from_template", with("size", size(0, 400, 900)))?.code == AgentError.invalidArgument)
        #expect(await rig.error("furniture.create_from_template", with("shelves", 99))?.code == AgentError.invalidArgument)
        #expect(await rig.error("furniture.create_from_template", with("doors", -1))?.code == AgentError.invalidArgument)
        #expect(await rig.error("furniture.create_from_template", with("material", "no such material"))?.code == AgentError.notFound)
        #expect(rig.p.definitions.isEmpty)
    }

    @Test func templateDryRunAndUndo() async throws {
        let rig = DRig()
        _ = await rig.ok("furniture.create_from_template", ["template": "box", "name": "Dry", "size": size(100, 100, 100), "dryRun": true])
        #expect(rig.p.definitions.isEmpty)
        _ = await rig.ok("furniture.create_from_template", ["template": "box", "name": "Real", "size": size(100, 100, 100)])
        #expect(rig.p.definitions.count == 1)
        _ = await rig.ok("history.undo")
        #expect(rig.p.definitions.isEmpty)
    }

    @Test func updateDefinitionKeepsInstancesAndStatesValid() async throws {
        let rig = DRig()
        let id = try await table(rig)
        let idStr = JSONValue.string(id.uuidString.lowercased())
        let inst = await rig.ok("furniture.create_instance", ["definitionId": idStr, "position": xyz(0, 0)])
        let instId = UUID(uuidString: try #require(inst["id"]?.stringValue))!
        _ = await rig.ok("material.create", ["name": "Oak", "color": "#B08D57"])
        let leg = try #require(rig.p.definition(id)?.components.first { $0.name == "leg" })
        let top = try #require(rig.p.definition(id)?.components.first { $0.name == "top" })
        _ = await rig.ok("scene.set_material", ["ids": [.string(instId.uuidString.lowercased())], "slot": .string("component:\(leg.id.uuidString.lowercased())"), "material": "Oak"])
        let revBefore = rig.p.definition(id)?.rev ?? 0

        let r = await rig.ok("furniture.update_definition", [
            "id": idStr, "name": "Big desk", "size": size(1600, 800, 750),
            "updateComponents": [["component": "top", "size": size(1600, 800, 30), "material": "Oak"]],
            "addComponents": [["name": "leg2", "shape": "box", "position": xyz(-500, 250, 360), "size": size(50, 50, 720)]],
        ])
        #expect(r["componentCount"]?.int64Value == 3)
        #expect(r["instanceCount"]?.int64Value == 1)
        let d = try #require(rig.p.definition(id))
        #expect(d.name == "Big desk" && d.size == Size3(1600, 800, 750))
        #expect(d.components.first { $0.id == top.id }?.size == Size3(1600, 800, 30))
        #expect(d.components.first { $0.id == top.id }?.materialId == rig.p.materials[0].id)
        #expect(d.components.contains { $0.id == leg.id })
        #expect(d.states.count == 2 && d.defaultStateId != nil)
        #expect(d.rev > revBefore)
        #expect(rig.p.instances.first { $0.id == instId }?.materialOverrides[leg.id] != nil)

        // Remove a part: states lose its poses, the instance override is dropped, everything still validates.
        _ = await rig.ok("furniture.update_definition", ["id": idStr, "removeComponents": ["leg"]])
        let d2 = try #require(rig.p.definition(id))
        #expect(!d2.components.contains { $0.id == leg.id })
        #expect(d2.states.allSatisfy { !$0.poses.keys.contains(leg.id) })
        #expect(rig.p.instances.first { $0.id == instId }?.materialOverrides[leg.id] == nil)
        // Undo restores the part together with the override.
        _ = await rig.ok("history.undo")
        #expect(rig.p.definition(id)?.components.contains { $0.id == leg.id } == true)
        #expect(rig.p.instances.first { $0.id == instId }?.materialOverrides[leg.id] != nil)
    }

    @Test func updateDefinitionRenamesPartKeepingId() async throws {
        let rig = DRig()
        let id = try await table(rig)
        let top = try #require(rig.p.definition(id)?.components.first { $0.name == "top" })
        _ = await rig.ok("furniture.update_definition", ["id": .string(id.uuidString.lowercased()),
                                                         "updateComponents": [["component": "top", "name": "board", "position": xyz(0, 0, 740), "visible": true]]])
        let now = try #require(rig.p.definition(id)?.components.first { $0.id == top.id })
        #expect(now.name == "board" && now.position == P3(0, 0, 740))
    }

    @Test func updateDefinitionRejectsBadInput() async throws {
        let rig = DRig()
        let id = try await table(rig)
        let idStr = JSONValue.string(id.uuidString.lowercased())
        let before = try #require(rig.p.definition(id))
        #expect(await rig.error("furniture.update_definition", ["id": idStr])?.code == AgentError.invalidArgument)
        #expect(await rig.error("furniture.update_definition", ["id": idStr, "size": size(0, 1, 1)])?.code == AgentError.invalidArgument)
        #expect(await rig.error("furniture.update_definition", ["id": idStr, "removeComponents": ["top", "leg"]])?.code == AgentError.invalidArgument)
        #expect(await rig.error("furniture.update_definition", ["id": idStr, "removeComponents": ["nope"]])?.code == AgentError.notFound)
        #expect(await rig.error("furniture.update_definition", ["id": idStr, "updateComponents": [["component": "top", "name": "leg"]]])?.code == AgentError.invalidArgument)
        #expect(await rig.error("furniture.update_definition", ["id": idStr, "updateComponents": [["component": "top", "size": size(0, 5, 5)]]])?.code == AgentError.invalidArgument)
        #expect(await rig.error("furniture.update_definition", ["id": idStr, "updateComponents": [["component": "top", "bogus": 1]]])?.code == AgentError.invalidArgument)
        #expect(await rig.error("furniture.update_definition", ["id": idStr, "addComponents": [["name": "TOP", "shape": "box", "position": xyz(0, 0, 0), "size": size(1, 1, 1)]]])?.code == AgentError.invalidArgument)
        #expect(await rig.error("furniture.update_definition", ["id": idStr, "addComponents": [["name": "m", "shape": "mesh", "position": xyz(0, 0, 0), "size": size(1, 1, 1)]]])?.code == AgentError.invalidArgument)
        #expect(await rig.error("furniture.update_definition", ["id": idStr, "updateComponents": [["component": "top", "material": "no such"]]])?.code == AgentError.notFound)
        #expect(await rig.error("furniture.update_definition", ["id": .string(UUID().uuidString), "name": "x"])?.code == AgentError.notFound)
        #expect(await rig.error("furniture.update_definition", ["id": .string(rig.levelId.uuidString), "name": "x"])?.code == AgentError.invalidArgument)
        #expect(rig.p.definition(id) == before)
    }

    @Test func updateDefinitionDryRunChangesNothing() async throws {
        let rig = DRig()
        let id = try await table(rig)
        let before = try #require(rig.p.definition(id))
        _ = await rig.ok("furniture.update_definition", ["id": .string(id.uuidString.lowercased()), "name": "Other", "dryRun": true])
        #expect(rig.p.definition(id) == before)
    }
}

/// Review fixes: free mmPerPixel values, dry runs inside app.batch, the write lock, size limits.
@MainActor
struct ParityReviewFixTests {
    private func prepared() throws -> (DRig, image: URL, pkg: URL) {
        let rig = DRig()
        let dir = try scratch()
        let pkg = dir.appendingPathComponent("Fix.roomsmith")
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        rig.context.fileURL = pkg
        let img = dir.appendingPathComponent("scan.png")
        try writePNG(img, width: 300, height: 200)
        return (rig, img, pkg)
    }

    private func assetFiles(_ pkg: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: pkg.appendingPathComponent("assets").path)) ?? []
    }

    @Test func freeMmPerPixelStaysAccurate() async throws {
        for s in [25.4 / 300, 25.4 / 1200, 0.00123456, 0.0017, 0.1234, 0.2646, 0.001, 99.999, 100] {
            let (rig, img, _) = try prepared()
            _ = await rig.ok("background.add", ["path": .string(img.path), "mmPerPixel": .number(s)])
            let stored = try #require(rig.p.backgrounds.first).mmPerPixel
            #expect(abs(stored - s) / s < 1e-5, "mmPerPixel \(s) stored as \(stored)")
        }
        // A 300 dpi scan: 3000 px are 254 mm, at most 0.01 mm off.
        let c = try BackgroundTools.calibration(forMmPerPixel: 25.4 / 300)
        let mmFor3000 = Double(c.length) / Double(c.b.x - c.a.x) * 3000
        #expect(abs(mmFor3000 - 254) < 0.01)
    }

    @Test func mmPerPixelOutsideRangeIsRejected() async throws {
        let (rig, img, _) = try prepared()
        for s in [0.0009, 100.5, -1] {
            #expect(await rig.error("background.add", ["path": .string(img.path), "mmPerPixel": .number(s)])?.code == AgentError.outOfRange)
        }
    }

    @Test func batchDryRunCopiesNoFile() async throws {
        let (rig, img, pkg) = try prepared()
        let rev = rig.p.revision
        _ = await rig.ok("app.batch", ["dryRun": true, "steps": [["tool": "background.add",
                                                                  "arguments": ["path": .string(img.path), "mmPerPixel": 2]]]])
        #expect(rig.p.backgrounds.isEmpty)
        #expect(rig.p.assets.isEmpty)
        #expect(rig.p.revision == rev)
        #expect(assetFiles(pkg).isEmpty)
        // The same batch for real stores exactly one file.
        _ = await rig.ok("app.batch", ["steps": [["tool": "background.add", "arguments": ["path": .string(img.path), "mmPerPixel": 2]]]])
        #expect(rig.p.backgrounds.count == 1)
        #expect(assetFiles(pkg).count == 1)
    }

    @Test func writeLockBlocksNewToolsAndCopiesNothing() async throws {
        let (rig, img, pkg) = try prepared()
        rig.store.agentWriteEnabled = false
        #expect(await rig.error("background.add", ["path": .string(img.path), "mmPerPixel": 2])?.code == AgentError.writeLocked)
        #expect(await rig.error("material.create", ["name": "Oak", "color": "#B08D57"])?.code == AgentError.writeLocked)
        #expect(await rig.error("furniture.create_from_template", ["template": "box", "name": "B", "size": size(100, 100, 100)])?.code == AgentError.writeLocked)
        #expect(assetFiles(pkg).isEmpty)
        #expect(rig.p.materials.allSatisfy { $0.name != "Oak" })
    }

    @Test func staleObjectRevisionIsAConflict() async throws {
        let (rig, img, _) = try prepared()
        let r = await rig.ok("background.add", ["path": .string(img.path), "mmPerPixel": 2])
        let id = try #require(r["id"]?.stringValue)
        let rev = try #require(rig.p.backgrounds.first).rev
        _ = await rig.ok("background.update", ["id": .string(id), "opacity": 0.8])
        let e = await rig.error("background.update", ["id": .string(id), "opacity": 0.3, "expectedObjectRevisions": [id: .int(rev)]])
        #expect(e?.code == AgentError.conflict)
        #expect(rig.p.backgrounds[0].opacity == 0.8)
    }

    @Test func calibrateDryRunChangesNothing() async throws {
        let (rig, img, _) = try prepared()
        let r = await rig.ok("background.add", ["path": .string(img.path), "mmPerPixel": 2])
        let id = try #require(r["id"]?.stringValue)
        let before = try #require(rig.p.backgrounds.first)
        let dry = await rig.ok("background.calibrate", ["id": .string(id), "pixelA": xy(0, 0), "pixelB": xy(100, 0), "realLengthMm": 1000, "dryRun": true])
        #expect(dry["dryRun"]?.boolValue == true)
        #expect(rig.p.backgrounds.first == before)
    }

    @Test func templateRejectsOversizeAndTooManyDoors() async throws {
        let rig = DRig()
        let big = await rig.error("furniture.create_from_template", ["template": "box", "name": "Big", "size": size(200_000, 400, 900)])
        #expect(big?.code == AgentError.outOfRange)
        // 400 mm wide: at most 2 doors of 150 mm.
        let doors = await rig.error("furniture.create_from_template", ["template": "cabinet", "name": "C", "size": size(400, 400, 900), "doors": 3])
        #expect(doors?.code == AgentError.invalidArgument)
        _ = await rig.ok("furniture.create_from_template", ["template": "cabinet", "name": "C", "size": size(400, 400, 900), "doors": 2])
        #expect(rig.p.definitions.count == 1)
    }

    @Test func nominalSizeChangeReportsFollowingInstances() async throws {
        let rig = DRig()
        let d = await rig.ok("furniture.create_from_template", ["template": "box", "name": "B", "size": size(1000, 500, 500)])
        let defId = try #require(d["id"]?.stringValue)
        let a = await rig.ok("furniture.create_instance", ["definitionId": .string(defId), "position": xyz(0, 0)])
        let b = await rig.ok("furniture.create_instance", ["definitionId": .string(defId), "position": xyz(3000, 0), "size": size(1200, 500, 500)])
        let aId = UUID(uuidString: try #require(a["id"]?.stringValue))!, bId = UUID(uuidString: try #require(b["id"]?.stringValue))!
        let r = await rig.ok("furniture.update_definition", ["id": .string(defId), "size": size(2000, 500, 500)])
        #expect(r["instanceCount"]?.int64Value == 2)
        #expect(r["followingInstances"]?.int64Value == 1)
        let p = rig.p
        let ea = try #require(p.instances.first { $0.id == aId }), eb = try #require(p.instances.first { $0.id == bId })
        #expect(ea.size == nil)
        #expect(eb.size == Size3(1200, 500, 500))
        let r2 = await rig.ok("furniture.update_definition", ["id": .string(defId), "name": "Renamed"])
        #expect(r2["followingInstances"]?.int64Value == 0)
    }
}
