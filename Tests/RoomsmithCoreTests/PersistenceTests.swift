import Foundation
import Testing
@testable import RoomsmithCore

@Suite(.serialized)
struct PersistenceTests {
    // MARK: Helpers

    static func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("roomsmith-persist-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func u(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))! }

    static func richProject() -> Project {
        var p = Project(name: "Flat | Süd \\ 家 \"x\"\nzweite Zeile")
        p.id = u(1); p.revision = 42
        p.settings.displayUnit = .m
        p.settings.snap.enabled = false; p.settings.snap.grid = 25; p.settings.snap.angleStep = 7.5
        p.settings.collisionWarnings = false; p.settings.defaultWallThickness = 175
        p.camera = CameraState(mode: .firstPerson, target: P3(-1200, 3400, 1600), distance: 4321, yawDeg: -12.5, pitchDeg: 0.1, fovDeg: 72.25)

        var l1 = Level(id: u(10), name: "Ground | floor", elevation: -300, height: 2600); l1.rev = 3
        var l2 = Level(id: u(11), name: "-", elevation: 2900); l2.visible = false; l2.locked = true
        p.levels = [l1, l2]

        let m1 = u(20), m2 = u(21)
        var mat1 = Material(id: m1, name: "Eiche\nhell", color: RGBColor(0xAB, 0x0C, 0xFF), roughness: 0.1234567, metallic: 0.5, opacity: 0.75)
        mat1.textureAssetId = u(30); mat1.textureTile = 600; mat1.rev = 2
        p.materials = [mat1, Material(id: m2, name: "Putz", color: RGBColor(255, 255, 255))]

        var w1 = Wall(id: u(40), levelId: l1.id, start: P2(-4250, -10), end: P2(0, 0), thickness: 115, height: 2500)
        w1.leftMaterialId = m1; w1.locked = true; w1.rev = 5
        let w2 = Wall(id: u(41), levelId: l1.id, start: P2(0, 0), end: P2(4250, 3000))
        p.walls = [w1, w2]

        var room = Room(id: u(50), levelId: l1.id, name: "Küche | Essen \\ \r\n", points: [P2(-100, -100), P2(5000, -100), P2(5000, 4000)])
        room.floorMaterialId = m2; room.showCeiling = true; room.rev = 9
        p.rooms = [room, Room(id: u(51), levelId: l2.id, name: "", points: [])]

        var door = Opening(id: u(60), wallId: w1.id, kind: .door, name: "Tür | 1", offset: 900, width: 900, height: 2050, sill: 0)
        door.flipped = true; door.inward = false; door.frameMaterialId = m1
        p.openings = [door, Opening(id: u(61), wallId: w2.id, kind: .window, offset: 2000, width: 1200, height: 1300, sill: 900)]

        var dim = Dimension(id: u(70), levelId: l1.id, a: P2(-5, -6), b: P2(7, 8), offset: -300); dim.rev = 1
        p.dimensions = [dim]

        var asset = ProjectAsset(id: u(30), kind: .mesh, storedName: "0123456789abcdef.usdz", originalName: "Sofa | v2.usdz",
                                 sha256: String(repeating: "ab", count: 32), byteCount: 123_456)
        asset.measuredSize = Size3(2000, 900, 800); asset.importScale = 0.01; asset.notes = "line 1\nline 2 \\ |"; asset.rev = 4
        p.assets = [asset, ProjectAsset(id: u(31), kind: .background, storedName: "ffff.png", originalName: "plan.png", sha256: "00", byteCount: 1)]

        var bg = BackgroundImage(id: u(80), levelId: l1.id, assetId: u(31), calibrationA: P2(10, 20), calibrationB: P2(310, 20),
                                 calibrationLength: 3000, origin: P2(-500, 800))
        bg.opacity = 0.33; bg.visible = false
        p.backgrounds = [bg]

        var cam = SavedCamera(id: u(90), name: "Blick | Süden", state: CameraState(mode: .top, target: P3(1, -2, 3), distance: 12000, yawDeg: 180, pitchDeg: -90))
        cam.rev = 6
        p.cameras = [cam]

        // Definition with components, states (full / partial / empty), tracks and keyframes.
        let c1 = u(100), c2 = u(101), c3 = u(102)
        var comp1 = Component(id: c1, name: "Seat | base", shape: .cushion, position: P3(0, 0, 200), size: Size3(2000, 900, 400),
                              rotation: R3(0, 12.5, -90), pivot: P3(-1000, 0, 0), materialId: m1)
        comp1.visible = false
        var comp2 = Component(id: c2, name: "Back", shape: .mesh, position: P3(0, -400, 600), size: Size3(2000, 100, 600))
        comp2.meshAssetId = u(30)
        let comp3 = Component(id: c3, name: "Leg", shape: .cylinder, position: P3(900, 400, 50), size: Size3(50, 50, 100))
        var def = FurnitureDefinition(id: u(110), name: "Sofa | 3-sitzer", category: "-", size: Size3(2000, 900, 800), components: [comp1, comp2, comp3])
        let sA = u(120), sB = u(121), sC = u(122)
        def.states = [
            FurnitureState(id: sA, name: "folded", poses: [
                c1: ComponentPose(position: P3(0, 0, 100), rotation: R3(0, 0, 0.5), size: Size3(2000, 900, 200), visible: false),
                c2: ComponentPose(),
                c3: ComponentPose(visible: true),
            ], size: Size3(2000, 900, 300)),
            FurnitureState(id: sB, name: "open", poses: [c2: ComponentPose(rotation: R3(-100, 0, 0))]),
            FurnitureState(id: sC, name: "empty"),
        ]
        def.defaultStateId = sA
        var track = AnimationTrack(id: u(130), fromStateId: nil, toStateId: sB, durationMs: 1200, easing: .easeOut)
        track.keyframes = [
            .init(t: 0.25, poses: [c2: ComponentPose(rotation: R3(-30, 0, 0)), c1: ComponentPose(position: P3(0, 0, 150))]),
            .init(t: 0.75, poses: [:]),
        ]
        def.tracks = [track, AnimationTrack(id: u(131), fromStateId: sA, toStateId: sC)]
        def.productId = u(160); def.builtin = true; def.catalogKey = "sofa-3"; def.tags = ["wohnen", "a;b", "c, d", "x|y", " pad "]; def.rev = 8
        var def2 = FurnitureDefinition(id: u(111), name: "Tisch", category: "table", size: Size3(1600, 800, 740), components: [])
        def2.tags = []
        p.definitions = [def, def2]

        var inst = FurnitureInstance(id: u(140), definitionId: def.id, levelId: l1.id, name: "Sofa \"links\"\n", position: P3(-1500, 2200, 0), rotationDeg: 270.125)
        inst.size = Size3(2100, 950, 800); inst.materialOverrides = [c1: m2, c2: m1]; inst.stateId = sA
        inst.groupId = u(150); inst.productId = u(160); inst.visible = false; inst.locked = true; inst.rev = 7
        p.instances = [inst, FurnitureInstance(id: u(141), definitionId: def2.id, levelId: l2.id, name: "", position: .zero)]

        var group = FurnitureGroup(id: u(150), name: "Wohn | Gruppe", levelId: l1.id, origin: P3(-1000, 2000, 0), memberIds: [inst.id, u(141)])
        group.rotationDeg = 90; group.productId = u(160); group.locked = true; group.rev = 2
        let cfgA = u(151), cfgB = u(152), cfgC = u(153)
        group.configurations = [
            GroupConfiguration(id: cfgA, name: "default", poses: [
                inst.id: MemberPose(local: P3(10, -20, 0), rotationDeg: 45.5, visible: true, stateId: sA, materialOverrides: [c1: m1]),
                u(141): MemberPose(local: P3(0, 0, 0), rotationDeg: 0, visible: false, stateId: nil, materialOverrides: nil),
            ]),
            GroupConfiguration(id: cfgB, name: "leer", poses: [:]),
            GroupConfiguration(id: cfgC, name: "empty overrides", poses: [inst.id: MemberPose(local: P3(1, 2, 3), rotationDeg: 1, materialOverrides: [:])]),
        ]
        group.activeConfigurationId = cfgA
        p.groups = [group]

        var prod = CatalogProduct(id: u(160), name: "Sofa | \"Nordic\"")
        prod.category = "Sofa"; prod.description = "Mehrzeilig\nBeschreibung \\ mit | Pipe"; prod.notes = " lead and trail "
        prod.manufacturer = "Möbel & Co."; prod.model = "N-3"; prod.articleNumber = "-"
        prod.links = [ProductLink(id: u(161), title: "Shop | A", url: "https://example.com/a?b=1|2"), ProductLink(id: u(162), title: "", url: "")]
        prod.priceMinor = 129_999; prod.currency = "CHF"; prod.priceDate = "2026-11-08"
        prod.dimensions = Size3(2100, 950, 800); prod.weightGrams = 45_000
        prod.materialText = "Stoff"; prod.colorText = "grau"
        prod.fileAssetIds = [u(30)]; prod.imageAssetIds = [u(31), u(30)]
        prod.tags = ["a", "b;c"]; prod.status = .shortlisted; prod.variants = ["grau", "blau | hell"]
        prod.roomIds = [room.id]; prod.custom = ["Farbe": "grau", "a: b": "x\ny", "x|y": "-", "": "leer"]
        prod.definitionId = def.id; prod.rev = 3
        p.products = [prod, CatalogProduct(id: u(163), name: "-")]
        return p
    }

    static func scale(walls: Int, instances: Int) -> Project {
        var p = Project.empty(name: "Perf")
        p.id = u(1)
        let lv = p.levels[0].id
        let def = FurnitureDefinition(id: u(5000), name: "Box", category: "misc", size: Size3(500, 500, 500),
                                      components: [Component(id: u(5001), name: "Body", shape: .box, position: P3(0, 0, 250), size: Size3(500, 500, 500))])
        p.definitions = [def]
        for i in 0..<walls {
            var w = Wall(id: u(10_000 + i), levelId: lv, start: P2(Int64(i * 100) - 5000, -Int64(i)), end: P2(Int64(i * 100) + 4250, Int64(i)))
            w.leftMaterialId = i % 2 == 0 ? nil : u(20)
            p.walls.append(w)
        }
        for i in 0..<instances {
            var inst = FurnitureInstance(id: u(100_000 + i), definitionId: def.id, levelId: lv, name: "Möbel \(i)",
                                         position: P3(Int64(i * 37), -Int64(i * 11), 0), rotationDeg: Double(i % 360) + 0.5)
            if i % 3 == 0 { inst.materialOverrides = [u(5001): u(20)] }
            p.instances.append(inst)
        }
        return p
    }

    // MARK: Round trip

    @Test func encodedBytesSaveLikeTheDirectSave() throws {
        let p = Self.richProject()
        let a = Self.tempDir().appendingPathComponent("a.roomsmith"), b = Self.tempDir().appendingPathComponent("b.roomsmith")
        try ProjectPackage.save(p, to: a)
        let data = ProjectPackage.encoded(p)
        try ProjectPackage.save(encoded: data, to: b)
        #expect(try Data(contentsOf: ProjectPackage.projectFile(a)) == data)
        #expect(try Data(contentsOf: ProjectPackage.projectFile(b)) == data)
        #expect(try ProjectPackage.load(from: b).project == p)
        // Saving the same bytes again writes nothing new; changed bytes keep the old file as a backup.
        try ProjectPackage.save(encoded: data, to: b)
        #expect(ProjectPackage.listBackups(in: b).isEmpty)
        var q = p; q.name = "Other"
        try ProjectPackage.save(encoded: ProjectPackage.encoded(q), to: b)
        #expect(ProjectPackage.listBackups(in: b).count == 1)
        #expect(try ProjectPackage.load(from: b).project.name == "Other")
    }

    @Test func roundTripRichProject() throws {
        let original = Self.richProject()
        let text = RoomsmithMarkdown.encode(original)
        let (decoded, warnings) = try RoomsmithMarkdown.decode(text)
        #expect(warnings.isEmpty, "\(warnings)")
        #expect(decoded == original)
        // Deterministic: re-encoding gives identical text.
        #expect(RoomsmithMarkdown.encode(decoded) == text)
        // Per-field spot checks in case == hides a Hashable shortcut.
        #expect(decoded.products[0].custom == original.products[0].custom)
        #expect(decoded.definitions[0].states[0].poses == original.definitions[0].states[0].poses)
        #expect(decoded.rooms[0].name == "Küche | Essen \\ \r\n")
    }

    @Test func roundedAndTaperShapesRoundTrip() throws {
        var p = Project(name: "Shapes")
        let a = Component(id: Self.u(200), name: "Soft block", shape: .rounded, position: P3(0, 0, 100), size: Size3(800, 600, 200))
        let b = Component(id: Self.u(201), name: "Tapered leg", shape: .taper, position: P3(0, 0, 50), size: Size3(60, 60, 400))
        p.definitions = [FurnitureDefinition(id: Self.u(210), name: "Shapes", category: "-", size: Size3(800, 600, 400), components: [a, b])]
        let (decoded, warnings) = try RoomsmithMarkdown.decode(RoomsmithMarkdown.encode(p))
        #expect(warnings.isEmpty, "\(warnings)")
        #expect(decoded.definitions[0].components.map(\.shape) == [.rounded, .taper])
        #expect(decoded == p)
    }

    @Test func emptyProjectRoundTrip() throws {
        let p = Project.empty(name: "Leer")
        let (d, w) = try RoomsmithMarkdown.decode(RoomsmithMarkdown.encode(p))
        #expect(d == p)
        #expect(w.isEmpty)
    }

    // MARK: allowsOverlap

    private static func overlapProject(allows: Bool) -> Project {
        var p = Project.empty(name: "Overlap")
        let def = FurnitureDefinition(name: "Box", category: "t", size: Size3(500, 500, 500),
                                      components: [Component(name: "c", shape: .box, position: P3(0, 0, 250), size: Size3(500, 500, 500))])
        p.definitions = [def]
        var inst = FurnitureInstance(id: u(200), definitionId: def.id, levelId: p.levels[0].id, name: "Rug", position: P3(100, 200, 0))
        inst.allowsOverlap = allows
        p.instances = [inst]
        return p
    }

    /// Drops the named column from the Instances table, as an older writer would have produced it.
    private static func removingInstanceColumn(_ column: String, from text: String) -> String {
        var inTable = false, index: Int?
        var out: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") { inTable = line == "## Instances"; index = nil }
            guard inTable, line.hasPrefix("|") else { out.append(line); continue }
            var cells = line.dropFirst().dropLast().components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            if index == nil, let i = cells.firstIndex(of: column) { index = i }
            if let i = index, i < cells.count { cells.remove(at: i) }
            out.append("| " + cells.joined(separator: " | ") + " |")
        }
        return out.joined(separator: "\n")
    }

    @Test func allowsOverlapRoundTripsAtCurrentSchema() throws {
        let original = Self.overlapProject(allows: true)
        let text = RoomsmithMarkdown.encode(original)
        #expect(text.contains("schema: \(Project.currentSchemaVersion)"))
        #expect(text.contains("| allowsOverlap |"))
        let (decoded, warnings) = try RoomsmithMarkdown.decode(text)
        #expect(warnings.isEmpty, "\(warnings)")
        #expect(decoded.instances[0].allowsOverlap)
        #expect(decoded == original)
        #expect(RoomsmithMarkdown.encode(decoded) == text)
        // the default stays false
        let (off, _) = try RoomsmithMarkdown.decode(RoomsmithMarkdown.encode(Self.overlapProject(allows: false)))
        #expect(!off.instances[0].allowsOverlap)
    }

    @Test func oldFileWithoutAllowsOverlapColumnReadsFalse() throws {
        let text = Self.removingInstanceColumn("allowsOverlap", from: RoomsmithMarkdown.encode(Self.overlapProject(allows: true)))
        #expect(!text.contains("allowsOverlap"))
        let (p, warnings) = try RoomsmithMarkdown.decode(text)
        #expect(warnings.isEmpty, "\(warnings)")
        #expect(p.instances.count == 1 && p.instances[0].name == "Rug")
        #expect(p.instances[0].allowsOverlap == false)
        #expect(p.instances[0].lightOn)
    }

    @Test func allowsOverlapColumnWithoutOtherOptionalColumnsIsReadable() throws {
        var text = RoomsmithMarkdown.encode(Self.overlapProject(allows: true))
        for column in ["lightOn", "locked", "visible", "rev"] { text = Self.removingInstanceColumn(column, from: text) }
        #expect(text.contains("allowsOverlap") && !text.contains("| lightOn |"))
        let (p, warnings) = try RoomsmithMarkdown.decode(text)
        #expect(warnings.isEmpty, "\(warnings)")
        #expect(p.instances[0].allowsOverlap)
        #expect(p.instances[0].lightOn && !p.instances[0].locked)
    }

    @Test func columnOrderAndUnknownPartsAreTolerated() throws {
        let text = """
        ---
        format: roomsmith
        schema: 5
        id: 00000000-0000-4000-8000-000000000001
        name: T
        extra: 1
        ---
        # T

        Some free prose is fine.

        ## Notes
        - a: b

        ## Levels
        | rev | name | id | elevation | height | visible | locked | colour |
        |---|---|---|---|---|---|---|---|
        | 2 | A | 00000000-0000-4000-8000-000000000010 | 0 | 2500 | yes | no | red |
        """
        let (p, w) = try RoomsmithMarkdown.decode(text)
        #expect(p.levels.count == 1)
        #expect(p.levels[0].rev == 2 && p.levels[0].name == "A")
        #expect(w.count == 3, "\(w)")
        #expect(w.contains { $0.contains("unknown section 'Notes'") })
        #expect(w.contains { $0.contains("unknown column 'colour'") })
        #expect(w.contains { $0.contains("unknown front matter key 'extra'") })
    }

    // MARK: G01 – exact millimetres through disk

    @Test func g01WallLengthSurvivesSaveAndLoad() throws {
        let dir = Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = dir.appendingPathComponent("G01.roomsmith")
        var p = Project.empty(name: "G01")
        p.walls = [Wall(levelId: p.levels[0].id, start: P2(0, 0), end: P2(4250, 0))]
        try ProjectPackage.save(p, to: pkg)
        let loaded = try ProjectPackage.load(from: pkg).project
        #expect(loaded.walls[0].end.x - loaded.walls[0].start.x == 4250)
        #expect(loaded == p)
        let text = try String(contentsOf: pkg.appendingPathComponent("project.md"), encoding: .utf8)
        #expect(text.contains("| 0,0 | 4250,0 |"))
    }

    // MARK: Defective input

    private func expectError(_ text: String, line: Int, contains: String, sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            _ = try RoomsmithMarkdown.decode(text)
            Issue.record("expected an error", sourceLocation: sourceLocation)
        } catch let e as PersistenceError {
            #expect(e.line == line, "got \(e)", sourceLocation: sourceLocation)
            #expect(e.message.contains(contains), "got \(e)", sourceLocation: sourceLocation)
        } catch {
            Issue.record("wrong error type \(error)", sourceLocation: sourceLocation)
        }
    }

    static let head = """
    ---
    format: roomsmith
    schema: 5
    id: 00000000-0000-4000-8000-000000000001
    name: T
    revision: 0
    ---
    # T

    """

    @Test func missingFrontMatter() {
        expectError("# Title\n\n## Levels\n", line: 1, contains: "front matter")
        expectError("", line: 1, contains: "front matter")
        expectError("---\nformat: roomsmith\nschema: 4\n", line: 3, contains: "not closed")
    }

    @Test func brokenFrontMatterValues() {
        expectError("---\nformat: other\nschema: 4\nid: 00000000-0000-4000-8000-000000000001\nname: x\n---\n", line: 2, contains: "roomsmith")
        expectError("---\nformat: roomsmith\nschema: 4\nid: nope\nname: x\n---\n", line: 4, contains: "invalid value")
        expectError("---\nformat: roomsmith\nschema: 9\nid: 00000000-0000-4000-8000-000000000001\nname: x\n---\n", line: 3, contains: "newer")
    }

    @Test func brokenTableRow() {
        let text = Self.head + """

        ## Levels
        | id | name | elevation | height | visible | locked | rev |
        |---|---|---|---|---|---|---|
        | 00000000-0000-4000-8000-000000000010 | A | 0 | 2500 | yes | no | 1 |
        | 00000000-0000-4000-8000-000000000011 | B | 0 | 2500 |
        """
        expectError(text, line: 14, contains: "4 cells, expected 7")
    }

    @Test func wrongNumber() {
        let text = Self.head + """

        ## Levels
        | id | name | elevation | height | visible | locked | rev |
        |---|---|---|---|---|---|---|
        | 00000000-0000-4000-8000-000000000010 | A | 12.5 | 2500 | yes | no | 1 |
        """
        expectError(text, line: 13, contains: "invalid value '12.5' for 'elevation'")
    }

    @Test func wrongBoolPointAndUuid() {
        let lv = "00000000-0000-4000-8000-000000000010"
        let wallHead = "\n## Walls\n| id | level | start | end | thickness | height |\n|---|---|---|---|---|---|\n"
        expectError(Self.head + wallHead + "| 00000000-0000-4000-8000-000000000020 | \(lv) | 0;0 | 10,0 | 115 | 2500 |", line: 13, contains: "'start'")
        expectError(Self.head + wallHead + "| not-a-uuid | \(lv) | 0,0 | 10,0 | 115 | 2500 |", line: 13, contains: "'id'")
        expectError(Self.head + "\n## Walls\n| id | level |\n|---|---|\n| 00000000-0000-4000-8000-000000000020 | \(lv) |", line: 11, contains: "missing column or key 'start'")
        expectError(Self.head + "\n## Walls\n| id | level |\n| 00000000-0000-4000-8000-000000000020 | \(lv) |", line: 12, contains: "separator")
    }

    @Test func orphanStateRow() {
        let text = Self.head + """

        ## Definitions

        ### 00000000-0000-4000-8000-000000000110 · D
        - size: 1x1x1

        #### States
        | id | name | component | position | rotation | size | visible |
        |---|---|---|---|---|---|---|
        | 00000000-0000-4000-8000-000000000120 | - | 00000000-0000-4000-8000-000000000100 | - | - | - | - |
        """
        expectError(text, line: 18, contains: "before its header row")
    }

    // MARK: Packages

    @Test func backupRotationKeepsTen() throws {
        let dir = Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = dir.appendingPathComponent("R.roomsmith")
        var p = Project.empty(name: "R")
        for rev in 0..<13 {
            p.revision = Int64(rev)
            try ProjectPackage.save(p, to: pkg)
        }
        let backups = ProjectPackage.listBackups(in: pkg)
        #expect(backups.count == 10)
        let revs = try backups.map { try RoomsmithMarkdown.decode(String(contentsOf: $0, encoding: .utf8)).project.revision }
        #expect(revs == Array((2...11).reversed().map(Int64.init)))   // newest first; revisions 0 and 1 rotated out
        #expect(try ProjectPackage.load(from: pkg).project.revision == 12)
        let name = backups[0].lastPathComponent
        #expect(name.range(of: #"^project-\d{8}-\d{6}-\d{3}\.md$"#, options: .regularExpression) != nil, "\(name)")
        // Saving unchanged content writes no new backup.
        try ProjectPackage.save(p, to: pkg)
        #expect(ProjectPackage.listBackups(in: pkg).count == 10)
    }

    @Test func d01FailedSaveKeepsOriginal() throws {
        let dir = Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = dir.appendingPathComponent("D01.roomsmith")
        let original = Self.richProject()
        try ProjectPackage.save(original, to: pkg)
        let file = pkg.appendingPathComponent("project.md")
        let before = try Data(contentsOf: file)

        var changed = original
        changed.name = "Changed"; changed.revision += 1
        #expect(throws: PersistenceError.self) {
            try ProjectPackage.save(changed, to: pkg, afterTempWrite: {
                // The temp file really exists at this point.
                let tmp = try FileManager.default.contentsOfDirectory(atPath: pkg.path).filter { $0.hasPrefix("project.md.tmp-") }
                #expect(tmp.count == 1)
                throw PersistenceError("simulated crash after temp write")
            })
        }
        #expect(try Data(contentsOf: file) == before)
        #expect(try ProjectPackage.load(from: pkg).project == original)
        #expect(ProjectPackage.listBackups(in: pkg).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: pkg.path).filter { $0.hasPrefix("project.md.tmp-") }.isEmpty)

        // A stray temp file from a crashed save is ignored on load, and the next save still works.
        try Data("garbage".utf8).write(to: pkg.appendingPathComponent("project.md.tmp-\(UUID().uuidString.lowercased())"))
        #expect(try ProjectPackage.load(from: pkg).project == original)
        try ProjectPackage.save(changed, to: pkg)
        #expect(try ProjectPackage.load(from: pkg).project == changed)
        #expect(ProjectPackage.listBackups(in: pkg).count == 1)
    }

    @Test func loadReportsPathAndLine() throws {
        let dir = Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = dir.appendingPathComponent("L.roomsmith")
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        #expect(throws: PersistenceError.self) { try ProjectPackage.load(from: pkg) }   // no project.md
        try Data("no front matter".utf8).write(to: pkg.appendingPathComponent("project.md"))
        do { _ = try ProjectPackage.load(from: pkg); Issue.record("expected error") } catch let e as PersistenceError {
            #expect(e.line == 1)
            #expect(e.path?.hasSuffix("project.md") == true)
        }
    }

    // MARK: Migration

    static let v1 = """
    ---
    format: roomsmith
    schema: 1
    id: 00000000-0000-4000-8000-000000000001
    name: Alt
    revision: 7
    ---
    # Alt

    ## Levels
    | id | name | elevation | height | visible | locked | rev |
    |---|---|---|---|---|---|---|
    | 00000000-0000-4000-8000-000000000010 | EG | 0 | 2500 | yes | no | 1 |

    ## Walls
    | id | level | start | end | thickness | height |
    |---|---|---|---|---|---|
    | 00000000-0000-4000-8000-000000000020 | 00000000-0000-4000-8000-000000000010 | 0,0 | 4250,0 | 115 | 2500 |

    ## Openings
    | id | wall | kind | name | offset | width | height | elevation |
    |---|---|---|---|---|---|---|---|
    | 00000000-0000-4000-8000-000000000030 | 00000000-0000-4000-8000-000000000020 | window | W | 2000 | 1200 | 1300 | 900 |
    """

    @Test func migrationV1ToV2() throws {
        let (text, notes) = try ProjectMigration.migrate(Self.v1)
        #expect(notes.count == 6, "\(notes)")
        #expect(notes.first == "schema 1 → 2" && notes.last == "schema 4 → 5", "\(notes)")
        #expect(text.contains("schema: 5"))
        #expect(!text.contains("| elevation |\n") && text.contains("| sill |"))
        #expect(text.contains("## Settings"))
        // Line numbers of old content are unchanged (Settings is appended); only schema and the Openings header differ.
        let old = Self.v1.components(separatedBy: "\n")
        let new = text.components(separatedBy: "\n")
        for (i, line) in old.enumerated() {
            let expected = i == 2 ? "schema: 5" : line.hasSuffix("| height | elevation |") ? line.replacingOccurrences(of: "elevation", with: "sill") : line
            #expect(new[i] == expected, "line \(i + 1)")
        }

        let (p, warnings) = try RoomsmithMarkdown.decode(Self.v1)
        #expect(p.openings[0].sill == 900)
        #expect(p.settings == ProjectSettings())
        #expect(p.walls[0].end == P2(4250, 0))
        #expect(p.revision == 7 && p.name == "Alt")
        #expect(warnings.contains { $0.hasPrefix("migrated:") })

        // Migrated text is stable: v5 passes through unchanged, and the migrated result decodes without notes.
        #expect(try ProjectMigration.migrate(text).notes.isEmpty)
        #expect(try ProjectMigration.migrate(text).text == text)
        #expect(try RoomsmithMarkdown.decode(text).warnings.isEmpty)
    }

    @Test func migrationV2ToV5IsStampOnly() throws {
        let v2 = Self.head.replacingOccurrences(of: "schema: 5", with: "schema: 2") + "\n\n## Levels\n| id | name | elevation | height | visible | locked | rev |\n|---|---|---|---|---|---|---|\n| 00000000-0000-4000-8000-000000000010 | EG | 0 | 2500 | yes | no | 1 |\n"
        let (text, notes) = try ProjectMigration.migrate(v2)
        #expect(notes == ["schema 2 → 3", "schema 3 → 4", "schema 4 → 5"], "\(notes)")
        let old = v2.components(separatedBy: "\n")
        let new = text.components(separatedBy: "\n")
        #expect(new.count == old.count)
        for (i, line) in old.enumerated() {
            #expect(new[i] == (line == "schema: 2" ? "schema: 5" : line), "line \(i + 1)")
        }
        let (_, warnings) = try RoomsmithMarkdown.decode(v2)
        #expect(warnings.contains { $0.hasPrefix("migrated:") })
    }

    @Test func migrationV3ToV5IsStampOnly() throws {
        let v3 = Self.head.replacingOccurrences(of: "schema: 5", with: "schema: 3") + "\n\n## Levels\n| id | name | elevation | height | visible | locked | rev |\n|---|---|---|---|---|---|---|\n| 00000000-0000-4000-8000-000000000010 | EG | 0 | 2500 | yes | no | 1 |\n"
        let (text, notes) = try ProjectMigration.migrate(v3)
        #expect(notes == ["schema 3 → 4", "schema 4 → 5"], "\(notes)")
        let old = v3.components(separatedBy: "\n")
        let new = text.components(separatedBy: "\n")
        #expect(new.count == old.count)
        for (i, line) in old.enumerated() {
            #expect(new[i] == (line == "schema: 3" ? "schema: 5" : line), "line \(i + 1)")
        }
        let (_, warnings) = try RoomsmithMarkdown.decode(v3)
        #expect(warnings.contains { $0.hasPrefix("migrated:") })
    }

    @Test func migrationV4ToV5IsStampOnly() throws {
        let v4 = Self.head.replacingOccurrences(of: "schema: 5", with: "schema: 4") + "\n\n## Levels\n| id | name | elevation | height | visible | locked | rev |\n|---|---|---|---|---|---|---|\n| 00000000-0000-4000-8000-000000000010 | A | 0 | 2500 | yes | no | 0 |"
        let (text, notes) = try ProjectMigration.migrate(v4)
        #expect(notes == ["schema 4 → 5"], "\(notes)")
        let old = v4.components(separatedBy: "\n")
        let new = text.components(separatedBy: "\n")
        #expect(new.count == old.count)
        for (i, line) in old.enumerated() {
            #expect(new[i] == (line == "schema: 4" ? "schema: 5" : line), "line \(i + 1)")
        }
        let (p, warnings) = try RoomsmithMarkdown.decode(v4)
        #expect(warnings.contains { $0.hasPrefix("migrated:") })
        #expect(p.instances.isEmpty && p.definitions.isEmpty)
    }

    @Test func freeCameraModeRoundTripsWithSchema5() throws {
        var p = Self.richProject()
        p.camera = CameraState(mode: .free, target: P3(1500, -2200, 1700), distance: 3000, yawDeg: 41.5, pitchDeg: -12.25, fovDeg: 70)
        p.cameras = [SavedCamera(id: Self.u(900), name: "Fly", state: CameraState(mode: .free, target: P3(10, 20, 1800), distance: 3000, yawDeg: -90, pitchDeg: 30))]
        let text = RoomsmithMarkdown.encode(p)
        #expect(text.contains("schema: 5"))
        #expect(text.contains("free"))
        let (q, warnings) = try RoomsmithMarkdown.decode(text)
        #expect(warnings.isEmpty, "\(warnings)")
        #expect(q.camera.mode == .free && q.camera == p.camera)
        #expect(q.cameras.first?.state.mode == .free)
        #expect(q == p)
    }

    @Test func migrationRejectsNewerSchema() {
        let newer = Self.v1.replacingOccurrences(of: "schema: 1", with: "schema: 6")
        #expect { try ProjectMigration.migrate(newer) } throws: { ($0 as? PersistenceError)?.message.contains("newer") == true }
        #expect(throws: PersistenceError.self) { try RoomsmithMarkdown.decode(newer) }
    }

    @Test func migrationStopsAtSectionBoundary() throws {
        // Schema 1 with an Openings section without a table, followed by Levels with an `elevation` column.
        let doc = """
        ---
        format: roomsmith
        schema: 1
        ---
        # Project

        ## Openings

        ## Levels

        | id | name | elevation |
        | --- | --- | --- |
        | a | Ground | 0 |
        """
        let (text, notes) = try ProjectMigration.migrate(doc)
        #expect(text.contains("| id | name | elevation |"))
        #expect(!text.contains("sill"))
        #expect(!notes.contains { $0.contains("renamed") })
    }

    @Test func migrationRejectsUnknownSchema() {
        let bad = Self.v1.replacingOccurrences(of: "schema: 1", with: "schema: 0")
        #expect(throws: PersistenceError.self) { try ProjectMigration.migrate(bad) }
        #expect(throws: PersistenceError.self) { try ProjectMigration.migrate("---\nformat: roomsmith\n---\n") }
    }

    @Test func v1PackageLoadsAndResavesAsCurrentSchema() throws {
        let dir = Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = dir.appendingPathComponent("V1.roomsmith")
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try Data(Self.v1.utf8).write(to: pkg.appendingPathComponent("project.md"))
        let (p, warnings) = try ProjectPackage.load(from: pkg)
        #expect(!warnings.isEmpty)
        try ProjectPackage.save(p, to: pkg)
        #expect(try ProjectPackage.load(from: pkg).warnings.isEmpty)
        #expect(ProjectPackage.listBackups(in: pkg).count == 1)   // the v1 file is kept as a backup
    }

    // MARK: Assets

    @Test func assetImport() throws {
        let dir = Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("Plan Skizze.PNG")
        try Data("hello".utf8).write(to: src)
        let pkg = dir.appendingPathComponent("A.roomsmith")
        let a = try ProjectPackage.importAsset(src, kind: .image, into: pkg)
        #expect(a.sha256 == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        #expect(a.storedName == "2cf24dba5fb0a30e.png")
        #expect(a.originalName == "Plan Skizze.PNG")
        #expect(a.byteCount == 5 && a.kind == .image)
        let url = ProjectPackage.assetURL(a, in: pkg)
        #expect(url.path.hasSuffix("A.roomsmith/assets/2cf24dba5fb0a30e.png"))
        #expect(try Data(contentsOf: url) == Data("hello".utf8))

        // Same content again: same stored file, no duplicate.
        let again = try ProjectPackage.importAsset(src, kind: .image, into: pkg)
        #expect(again.storedName == a.storedName)
        #expect(try FileManager.default.contentsOfDirectory(atPath: pkg.appendingPathComponent("assets").path).count == 1)

        // Asset records survive save/load; a hostile stored name cannot leave assets/.
        var p = Project.empty(name: "A")
        p.assets = [a]
        try ProjectPackage.save(p, to: pkg)
        #expect(try ProjectPackage.load(from: pkg).project.assets == [a])
        var evil = a; evil.storedName = "../../etc/passwd"
        #expect(ProjectPackage.assetURL(evil, in: pkg).path.hasSuffix("A.roomsmith/assets/passwd"))
    }

    // MARK: Performance

    @Test func performance300WallsThousandInstances() throws {
        let p = Self.scale(walls: 300, instances: 1000)
        let clock = ContinuousClock()
        var text = ""
        let encodeTime = clock.measure { text = RoomsmithMarkdown.encode(p) }
        var decoded: Project?
        let decodeTime = try clock.measure { decoded = try RoomsmithMarkdown.decode(text).project }
        let total = encodeTime + decodeTime
        print("PERF encode=\(encodeTime) decode=\(decodeTime) total=\(total) bytes=\(text.utf8.count)")
        #expect(decoded == p)
        #expect(total < .milliseconds(250), "encode+decode took \(total)")
    }

    // MARK: Save As copies assets

    /// Package A with two imported assets (distinct bytes) and a project that references them.
    static func packageWithAssets() throws -> (a: URL, project: Project, files: [Data]) {
        let dir = tempDir(), a = dir.appendingPathComponent("A.roomsmith")
        var p = Project(name: "SaveAs")
        var files: [Data] = []
        for (i, ext) in ["usdz", "png"].enumerated() {
            let data = Data((0..<64).map { UInt8(($0 &* 7 &+ i &* 91) & 0xFF) })
            let src = dir.appendingPathComponent("src\(i).\(ext)")
            try data.write(to: src)
            p.assets.append(try ProjectPackage.importAsset(src, kind: i == 0 ? .mesh : .image, into: a))
            files.append(data)
        }
        try ProjectPackage.save(p, to: a)
        return (a, p, files)
    }

    @Test func saveAsCopiesAssetsByteIdentical() throws {
        let (a, p, files) = try Self.packageWithAssets()
        let b = a.deletingLastPathComponent().appendingPathComponent("B.roomsmith")
        try ProjectPackage.save(p, to: b, copyingAssetsFrom: a)
        for (asset, data) in zip(p.assets, files) {
            #expect(try Data(contentsOf: ProjectPackage.assetURL(asset, in: b)) == data)
            #expect(FileManager.default.fileExists(atPath: ProjectPackage.assetURL(asset, in: a).path))
        }
        #expect(try ProjectPackage.load(from: b).project == p)
    }

    @Test func saveAsKeepsExistingTargetFile() throws {
        let (a, p, files) = try Self.packageWithAssets()
        let b = a.deletingLastPathComponent().appendingPathComponent("B.roomsmith")
        try FileManager.default.createDirectory(at: ProjectPackage.assetsDir(b), withIntermediateDirectories: true)
        let keep = Data("keep me".utf8)
        try keep.write(to: ProjectPackage.assetURL(p.assets[0], in: b))
        try ProjectPackage.save(p, to: b, copyingAssetsFrom: a)
        #expect(try Data(contentsOf: ProjectPackage.assetURL(p.assets[0], in: b)) == keep)
        #expect(try Data(contentsOf: ProjectPackage.assetURL(p.assets[1], in: b)) == files[1])
    }

    @Test func saveAsSkipsMissingSourceButCopiesOthers() throws {
        let (a, p, files) = try Self.packageWithAssets()
        try FileManager.default.removeItem(at: ProjectPackage.assetURL(p.assets[0], in: a))
        let b = a.deletingLastPathComponent().appendingPathComponent("B.roomsmith")
        try ProjectPackage.save(p, to: b, copyingAssetsFrom: a)
        #expect(!FileManager.default.fileExists(atPath: ProjectPackage.assetURL(p.assets[0], in: b).path))
        #expect(try Data(contentsOf: ProjectPackage.assetURL(p.assets[1], in: b)) == files[1])
    }

    @Test func saveToSamePackageCopiesNothing() throws {
        let (a, p, _) = try Self.packageWithAssets()
        #expect(try ProjectPackage.copyAssets(from: a, to: a, project: p).isEmpty)
        var q = p; q.name = "Renamed"
        try ProjectPackage.save(q, to: a, copyingAssetsFrom: a)
        let names = try FileManager.default.contentsOfDirectory(atPath: ProjectPackage.assetsDir(a).path)
        #expect(Set(names) == Set(p.assets.map(\.storedName)))
    }
}
