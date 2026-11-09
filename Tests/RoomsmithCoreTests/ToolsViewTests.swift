import Foundation
import Testing
@testable import RoomsmithCore

// View, camera preset/apply, render and project file tools (view.*, camera.preset, camera.apply, render.*, project.new/open/save_as).

@MainActor
private final class FakeBridge: AgentViewBridge {
    var state = AgentViewState(layout: .split, arrangement: .sideBySide, splitFraction: 0.5, sidebarTab: .levels, sidebar: true,
                               inspector: true, statusBar: true, sceneControls: true, showCeilings: false, showLamps: true, onlyActiveLevel: false,
                               wallOpacity: 1, planViewport: nil)
    var applied: [AgentViewChange] = []
    var presets: [(AgentCameraPreset, [UUID])] = []
    var renders: [(w: Int, h: Int, dark: Bool, camera: CameraState?)] = []
    var renderPresets: [(AgentCameraPreset?, [UUID])] = []
    var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
    var presetCamera = CameraState(mode: .top, target: P3(1000, 2000, 0), distance: 12000, yawDeg: 0, pitchDeg: -90)
    var renderError: Error?

    func viewState() -> AgentViewState { state }

    func applyView(_ c: AgentViewChange) -> AgentViewState {
        applied.append(c)
        if let v = c.layout { state.layout = v }
        if let v = c.arrangement { state.arrangement = v }
        if let v = c.splitFraction { state.splitFraction = v }
        if let v = c.sidebarTab { state.sidebarTab = v }
        if let v = c.sidebar { state.sidebar = v }
        if let v = c.inspector { state.inspector = v }
        if let v = c.statusBar { state.statusBar = v }
        if let v = c.sceneControls { state.sceneControls = v }
        if let v = c.showCeilings { state.showCeilings = v }
        if let v = c.showLamps { state.showLamps = v }
        if let v = c.onlyActiveLevel { state.onlyActiveLevel = v }
        if let v = c.wallOpacity { state.wallOpacity = v }
        if let v = c.detach3D { state.detach3D = v }
        if let v = c.planViewport { state.planViewport = v }
        return state
    }

    func cameraPreset(_ preset: AgentCameraPreset, ids: [UUID]) throws -> CameraState {
        presets.append((preset, ids))
        return presetCamera
    }

    func renderScene(width: Int, height: Int, dark: Bool, camera: CameraState?, preset: AgentCameraPreset?, ids: [UUID]) async throws -> Data {
        renders.append((width, height, dark, camera))
        renderPresets.append((preset, ids))
        if let renderError { throw renderError }
        return png
    }
}

@MainActor
private final class ViewContext: AgentAppContext {
    var selection: Set<UUID> = []
    var activeLevelId: UUID
    var fileURL: URL?
    var appVersion = "test"
    var bridge: FakeBridge?
    unowned var store: DocumentStore!
    var viewBridge: AgentViewBridge? { bridge }
    var measured: Size3 = Size3(2000, 900, 750)
    var measureError: AgentError?
    var measuredURLs: [URL] = []
    func measureModelForAgent(_ url: URL) async throws -> Size3 {
        measuredURLs.append(url)
        if let measureError { throw measureError }
        return measured
    }
    init(activeLevelId: UUID) { self.activeLevelId = activeLevelId }
    func saveForAgent() throws -> String { fileURL?.path ?? "/tmp/test.roomsmith" }
    func newProjectForAgent() throws {
        store.replaceProject(Project.empty(name: "Untitled"))
        fileURL = nil
        activeLevelId = store.project.levels[0].id
    }
    func openProjectForAgent(_ url: URL) throws -> [String] {
        let (p, warnings) = try ProjectPackage.load(from: url)
        store.replaceProject(p)
        fileURL = url
        activeLevelId = p.levels[0].id
        return warnings
    }
    func saveProjectAsForAgent(_ url: URL) throws {
        try ProjectPackage.save(store.project, to: url)
        store.markSaved()
        fileURL = url
    }
}

@MainActor
private struct VRig {
    let store: DocumentStore
    let context: ViewContext
    let bridge: FakeBridge
    let registry: ToolRegistry
    let dir: URL
    var levelId: UUID { store.project.levels[0].id }

    init(write: Bool = true, bridge withBridge: Bool = true) {
        let project = Project.empty(name: "View")
        store = DocumentStore(project: project)
        store.agentWriteEnabled = write
        context = ViewContext(activeLevelId: project.levels[0].id)
        context.store = store
        bridge = FakeBridge()
        if withBridge { context.bridge = bridge }
        registry = ToolRegistry(store: store, context: context)
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rs-view-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }
    func path(_ name: String) -> String { dir.appendingPathComponent(name).path }

    @discardableResult
    func call(_ tool: String, _ args: JSONValue = .object([:])) async -> AgentResponse {
        await registry.call(AgentRequest(id: 1, token: "t", clientId: "test", tool: tool, arguments: args))
    }

    func ok(_ tool: String, _ args: JSONValue = .object([:]), sourceLocation: SourceLocation = #_sourceLocation) async -> JSONValue {
        let r = await call(tool, args)
        #expect(r.ok, "\(tool) failed: \(r.error?.code ?? "?") \(r.error?.message ?? "")", sourceLocation: sourceLocation)
        return r.result ?? .null
    }

    func errorCode(_ tool: String, _ args: JSONValue = .object([:])) async -> String? {
        let r = await call(tool, args)
        return r.ok ? nil : r.error?.code
    }
}

// MARK: - view.*

@MainActor
struct ViewToolTests {
    @Test func withoutBridgeEverythingIsUnsupported() async {
        let rig = VRig(bridge: false)
        defer { rig.cleanup() }
        #expect(await rig.errorCode("view.get") == "UNSUPPORTED")
        #expect(await rig.errorCode("view.set", ["sidebar": false]) == "UNSUPPORTED")
        #expect(await rig.errorCode("camera.preset", ["preset": "top"]) == "UNSUPPORTED")
        #expect(await rig.errorCode("render.scene_image") == "UNSUPPORTED")
    }

    @Test func viewGetReportsState() async {
        let rig = VRig()
        defer { rig.cleanup() }
        rig.bridge.state.planViewport = AgentPlanViewport(centerX: 1500, centerY: -200, mmPerPoint: 5)
        let r = await rig.ok("view.get")
        #expect(r["layout"]?.stringValue == "split")
        #expect(r["arrangement"]?.stringValue == "sideBySide")
        #expect(r["sidebarTab"]?.stringValue == "levels")
        #expect(r["wallOpacity"]?.doubleValue == 1)
        #expect(r["activeLevelId"]?.stringValue == rig.levelId.uuidString.lowercased())
        #expect(r["planViewport"]?["center"]?["x"]?.int64Value == 1500)
        #expect(r["planViewport"]?["mmPerPoint"]?.doubleValue == 5)
    }

    @Test func viewSetAppliesPartialChangeWithoutRevisionOrUndo() async {
        let rig = VRig()
        defer { rig.cleanup() }
        let rev = rig.store.project.revision
        let r = await rig.ok("view.set", ["layout": "plan", "sidebar": false, "wallOpacity": 0.4, "showCeilings": true,
                                          "planViewport": ["center": ["x": 100, "y": 200], "mmPerPoint": 10]])
        #expect(r["layout"]?.stringValue == "plan")
        #expect(r["sidebar"]?.boolValue == false)
        #expect(r["inspector"]?.boolValue == true)
        #expect(r["showCeilings"]?.boolValue == true)
        #expect(rig.bridge.applied.count == 1)
        #expect(rig.bridge.applied[0].planViewport == AgentPlanViewport(centerX: 100, centerY: 200, mmPerPoint: 10))
        #expect(rig.store.project.revision == rev)
        #expect(!rig.store.canUndo)
    }

    @Test func viewSetShowLampsOnlyChangesThatKey() async {
        let rig = VRig()
        defer { rig.cleanup() }
        #expect(await rig.ok("view.get")["showLamps"]?.boolValue == true)
        let r = await rig.ok("view.set", ["showLamps": false])
        #expect(r["showLamps"]?.boolValue == false)
        #expect(r["showCeilings"]?.boolValue == false)
        #expect(rig.bridge.applied.last?.showLamps == false)
        #expect(rig.bridge.applied.last?.showCeilings == nil)
        #expect(await rig.ok("view.set", ["showLamps": true])["showLamps"]?.boolValue == true)
    }

    @Test func viewSetSwitchesActiveLevelAndFit() async {
        let rig = VRig()
        defer { rig.cleanup() }
        _ = await rig.ok("geometry.create_level", ["name": "Upstairs"])
        let second = rig.store.project.levels[1].id
        let r = await rig.ok("view.set", ["activeLevelId": .string(second.uuidString), "planFit": "selection"])
        #expect(rig.context.activeLevelId == second)
        #expect(r["activeLevelId"]?.stringValue == second.uuidString.lowercased())
        #expect(rig.bridge.applied.last?.planFit == .selection)
    }

    @Test func viewSetValidatesEverythingBeforeChangingAnything() async {
        let rig = VRig()
        defer { rig.cleanup() }
        #expect(await rig.errorCode("view.set") == "INVALID_ARGUMENT")
        #expect(await rig.errorCode("view.set", ["layout": "sideways"]) == "INVALID_ARGUMENT")
        #expect(await rig.errorCode("view.set", ["sidebar": false, "splitFraction": 0.95]) == "OUT_OF_RANGE")
        #expect(await rig.errorCode("view.set", ["sidebar": false, "wallOpacity": 1.5]) == "OUT_OF_RANGE")
        #expect(await rig.errorCode("view.set", ["planViewport": ["center": ["x": 0, "y": 0], "mmPerPoint": 0.1]]) == "OUT_OF_RANGE")
        #expect(await rig.errorCode("view.set", ["planViewport": ["center": ["x": 0, "y": 0], "mmPerPoint": 10], "planFit": "all"]) == "INVALID_ARGUMENT")
        #expect(await rig.errorCode("view.set", ["sidebar": false, "activeLevelId": .string(UUID().uuidString)]) == "NOT_FOUND")
        #expect(rig.bridge.applied.isEmpty)
        #expect(rig.bridge.state.sidebar == true)
    }

    @Test func detach3DIsReportedAndSet() async {
        let rig = VRig()
        defer { rig.cleanup() }
        #expect(await rig.ok("view.get")["detach3D"]?.boolValue == false)
        let r = await rig.ok("view.set", ["detach3D": true])
        #expect(r["detach3D"]?.boolValue == true)
        #expect(rig.bridge.applied.last?.detach3D == true)
        #expect(await rig.ok("view.get")["detach3D"]?.boolValue == true)
        let back = await rig.ok("view.set", ["detach3D": false, "layout": "split"])
        #expect(back["detach3D"]?.boolValue == false)
        #expect(!rig.store.canUndo)
    }

    @Test func detach3DRejectsBadInput() async {
        let rig = VRig()
        defer { rig.cleanup() }
        #expect(await rig.errorCode("view.set", ["detach3D": "yes"]) == "INVALID_ARGUMENT")
        #expect(await rig.errorCode("view.set", ["detach3D": true, "layout": "scene"]) == "INVALID_ARGUMENT")
        #expect(rig.bridge.applied.isEmpty)
        let locked = VRig(write: false)
        defer { locked.cleanup() }
        #expect(await locked.errorCode("view.set", ["detach3D": true]) == "WRITE_LOCKED")
    }

    @Test func viewSetNeedsWriteAccess() async {
        let rig = VRig(write: false)
        defer { rig.cleanup() }
        #expect(await rig.errorCode("view.set", ["sidebar": false]) == "WRITE_LOCKED")
        _ = await rig.ok("view.get")
    }
}

// MARK: - camera.preset / camera.apply

@MainActor
struct CameraPresetToolTests {
    @Test func presetMovesCameraThroughBridge() async {
        let rig = VRig()
        defer { rig.cleanup() }
        let r = await rig.ok("camera.preset", ["preset": "top"])
        #expect(r["camera"]?["mode"]?.stringValue == "top")
        #expect(r["camera"]?["distanceMm"]?.int64Value == 12000)
        #expect(rig.bridge.presets.count == 1)
        #expect(rig.bridge.presets[0].0 == .top)
    }

    @Test func presetFrameTakesKnownIdsOnly() async {
        let rig = VRig()
        defer { rig.cleanup() }
        let wall = await rig.ok("geometry.create_wall", ["start": ["x": 0, "y": 0], "end": ["x": 2500, "y": 0]])
        let wallId = wall["changes"]?[0]?["id"]?.stringValue ?? ""
        _ = await rig.ok("camera.preset", ["preset": "frame", "ids": [.string(wallId)]])
        #expect(rig.bridge.presets.last?.1.count == 1)
        #expect(await rig.errorCode("camera.preset", ["preset": "frame", "ids": [.string(UUID().uuidString)]]) == "NOT_FOUND")
        #expect(await rig.errorCode("camera.preset", ["preset": "top", "ids": [.string(wallId)]]) == "INVALID_ARGUMENT")
        #expect(await rig.errorCode("camera.preset", ["preset": "sideways"]) == "INVALID_ARGUMENT")
    }

    @Test func presetNeedsWriteAccess() async {
        let rig = VRig(write: false)
        defer { rig.cleanup() }
        #expect(await rig.errorCode("camera.preset", ["preset": "reset"]) == "WRITE_LOCKED")
        #expect(rig.bridge.presets.isEmpty)
    }

    @Test func applyMovesToSavedViewByIdOrName() async {
        let rig = VRig()
        defer { rig.cleanup() }
        _ = await rig.ok("camera.set_state", ["target": ["x": 500, "y": 600, "z": 0], "distanceMm": 4000, "yawDeg": 10])
        let saved = await rig.ok("camera.save", ["name": "Kitchen"])
        let id = saved["id"]?.stringValue ?? ""
        _ = await rig.ok("camera.set_state", ["target": ["x": 0, "y": 0, "z": 0], "distanceMm": 9000])
        let undoBefore = rig.store.undoName
        let byName = await rig.ok("camera.apply", ["name": "kitchen"])
        #expect(byName["camera"]?["distanceMm"]?.int64Value == 4000)
        #expect(rig.store.project.camera.distance == 4000)
        _ = await rig.ok("camera.set_state", ["distanceMm": 9000])
        _ = await rig.ok("camera.apply", ["id": .string(id)])
        #expect(rig.store.project.camera.distance == 4000)
        #expect(rig.store.undoName == undoBefore)
    }

    @Test func applyRejectsBadSelectors() async {
        let rig = VRig()
        defer { rig.cleanup() }
        _ = await rig.ok("camera.save", ["name": "A"])
        _ = await rig.ok("camera.save", ["name": "a"])
        #expect(await rig.errorCode("camera.apply") == "INVALID_ARGUMENT")
        #expect(await rig.errorCode("camera.apply", ["name": "A", "id": .string(UUID().uuidString)]) == "INVALID_ARGUMENT")
        #expect(await rig.errorCode("camera.apply", ["name": "A"]) == "INVALID_ARGUMENT")  // ambiguous
        #expect(await rig.errorCode("camera.apply", ["name": "nope"]) == "NOT_FOUND")
        #expect(await rig.errorCode("camera.apply", ["id": .string(UUID().uuidString)]) == "NOT_FOUND")
    }

    @Test func freeModeIsAcceptedBySetStateSaveAndRender() async {
        let rig = VRig()
        defer { rig.cleanup() }
        let set = await rig.ok("camera.set_state", ["mode": "free", "target": ["x": 100, "y": 200, "z": 1700], "pitchDeg": -20])
        #expect(set["camera"]?["mode"]?.stringValue == "free")
        #expect(rig.store.project.camera.mode == .free)
        #expect(rig.store.project.camera.pitchDeg == -20)
        _ = await rig.ok("camera.save", ["name": "Fly"])
        #expect(rig.store.project.cameras.last?.state.mode == .free)
        _ = await rig.ok("camera.set_state", ["mode": "orbit"])
        let applied = await rig.ok("camera.apply", ["name": "Fly"])
        #expect(applied["camera"]?["mode"]?.stringValue == "free")
        #expect(rig.store.project.camera.mode == .free)
        _ = await rig.ok("render.scene_image", ["camera": ["mode": "free"]])
        #expect(rig.bridge.renders.last?.camera?.mode == .free)
        #expect(await rig.errorCode("camera.set_state", ["mode": "fly"]) == "INVALID_ARGUMENT")
        // Without a mode the current one stays.
        _ = await rig.ok("camera.set_state", ["yawDeg": 15])
        #expect(rig.store.project.camera.mode == .free)
    }
}

// MARK: - render.*

@MainActor
struct RenderToolTests {
    @Test func sceneImageInlineAndFile() async throws {
        let rig = VRig()
        defer { rig.cleanup() }
        let r = await rig.ok("render.scene_image", ["width": 320, "height": 200, "dark": true])
        #expect(r["image"]?["mimeType"]?.stringValue == "image/png")
        #expect(Data(base64Encoded: r["image"]?["base64"]?.stringValue ?? "") == rig.bridge.png)
        #expect(rig.bridge.renders.last?.w == 320)
        #expect(rig.bridge.renders.last?.dark == true)
        #expect(rig.bridge.renders.last?.camera == nil)

        let path = rig.path("scene.png")
        let f = await rig.ok("render.scene_image", ["path": .string(path), "camera": ["yawDeg": 90]])
        #expect(f["image"] == nil)
        #expect(f["path"]?.stringValue == URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == rig.bridge.png)
        #expect(rig.bridge.renders.last?.camera?.yawDeg == 90)
        #expect(rig.bridge.renders.last?.w == 1280 && rig.bridge.renders.last?.h == 800)

        #expect(await rig.errorCode("render.scene_image", ["path": .string(path)]) == "INVALID_ARGUMENT")
        // The camera override obeys the same limits as `camera.set_state`.
        #expect(await rig.errorCode("render.scene_image", ["camera": ["fovDeg": 500]]) == "OUT_OF_RANGE")
        _ = await rig.ok("render.scene_image", ["path": .string(path), "overwrite": true, "inline": true])
    }

    @Test func sceneImagePresetIsPassedToTheBridgeAndExclusive() async {
        let rig = VRig()
        defer { rig.cleanup() }
        _ = await rig.ok("render.scene_image", ["width": 1280, "height": 720, "preset": "aerial"])
        #expect(rig.bridge.renderPresets.last?.0 == .aerial)
        #expect(rig.bridge.renders.last?.camera == nil)
        let wall = await rig.ok("geometry.create_wall", ["start": ["x": 0, "y": 0], "end": ["x": 2500, "y": 0]])
        let wallId = wall["changes"]?[0]?["id"]?.stringValue ?? ""
        _ = await rig.ok("render.scene_image", ["preset": "frame", "ids": [.string(wallId)]])
        #expect(rig.bridge.renderPresets.last?.0 == .frame)
        #expect(rig.bridge.renderPresets.last?.1.map { $0.uuidString.lowercased() } == [wallId.lowercased()])
        let count = rig.bridge.renders.count
        #expect(await rig.errorCode("render.scene_image", ["preset": "aerial", "camera": ["yawDeg": 90]]) == "INVALID_ARGUMENT")
        #expect(await rig.errorCode("render.scene_image", ["preset": "top", "ids": [.string(wallId)]]) == "INVALID_ARGUMENT")
        #expect(await rig.errorCode("render.scene_image", ["ids": [.string(wallId)]]) == "INVALID_ARGUMENT")
        #expect(await rig.errorCode("render.scene_image", ["preset": "frame", "ids": [.string(UUID().uuidString)]]) == "NOT_FOUND")
        #expect(await rig.errorCode("render.scene_image", ["preset": "sideways"]) == "INVALID_ARGUMENT")
        #expect(rig.bridge.renders.count == count)
    }

    @Test func sceneImageValidation() async {
        let rig = VRig()
        defer { rig.cleanup() }
        #expect(await rig.errorCode("render.scene_image", ["width": 8]) == "OUT_OF_RANGE")
        #expect(await rig.errorCode("render.scene_image", ["height": 9000]) == "OUT_OF_RANGE")
        #expect(await rig.errorCode("render.scene_image", ["camera": [:]]) == "INVALID_ARGUMENT")
        #expect(await rig.errorCode("render.scene_image", ["path": "relative.png"]) == "INVALID_ARGUMENT")
        #expect(await rig.errorCode("render.scene_image", ["path": .string(rig.path("x.jpg"))]) == "INVALID_ARGUMENT")
        #expect(await rig.errorCode("render.scene_image", ["overwrite": true]) == "INVALID_ARGUMENT")
        #expect(rig.bridge.renders.isEmpty)
    }

    @Test func sceneImagePathNeedsWriteAccessAndInlineHasLimit() async {
        let rig = VRig(write: false)
        defer { rig.cleanup() }
        #expect(await rig.errorCode("render.scene_image", ["path": .string(rig.path("a.png"))]) == "WRITE_LOCKED")
        _ = await rig.ok("render.scene_image")
        rig.bridge.png = Data(count: RenderTools.maxInlineBytes + 1)
        #expect(await rig.errorCode("render.scene_image") == "OUT_OF_RANGE")
    }

    @Test func sceneImageWrapsRendererFailure() async {
        let rig = VRig()
        defer { rig.cleanup() }
        rig.bridge.renderError = NSError(domain: "t", code: 1)
        #expect(await rig.errorCode("render.scene_image") == "INTERNAL")
    }

    @Test func planImageIsPNGInlineAndOnDisk() async throws {
        let rig = VRig()
        defer { rig.cleanup() }
        _ = await rig.ok("geometry.create_wall", ["start": ["x": 0, "y": 0], "end": ["x": 4000, "y": 0]])
        let header = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let r = await rig.ok("render.plan_image", ["paper": "A4", "scale": 50, "dpi": 50])
        let png = try #require(Data(base64Encoded: r["image"]?["base64"]?.stringValue ?? ""))
        #expect(png.prefix(8) == header)
        #expect(r["scale"]?.int64Value == 50)
        #expect(r["paper"]?.stringValue == "A4")
        #expect(r["bytes"]?.int64Value == Int64(png.count))
        #expect((r["width"]?.int64Value ?? 0) > 0)

        let path = rig.path("plan.png")
        let f = await rig.ok("render.plan_image", ["path": .string(path), "paper": "A4", "scale": 50, "dpi": 50])
        #expect(f["image"] == nil)
        #expect(f["written"]?.boolValue == true)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)).prefix(8) == header)
        #expect(await rig.errorCode("render.plan_image", ["path": .string(path)]) == "INVALID_ARGUMENT")
        _ = await rig.ok("render.plan_image", ["path": .string(path), "overwrite": true, "paper": "A4", "scale": 50, "dpi": 50])
    }

    @Test func planImageValidationAndFit() async {
        let rig = VRig()
        defer { rig.cleanup() }
        _ = await rig.ok("geometry.create_wall", ["start": ["x": 0, "y": 0], "end": ["x": 40000, "y": 0]])
        #expect(await rig.errorCode("render.plan_image", ["dpi": 10]) == "OUT_OF_RANGE")
        #expect(await rig.errorCode("render.plan_image", ["dpi": 1000]) == "OUT_OF_RANGE")
        #expect(await rig.errorCode("render.plan_image", ["levelId": .string(UUID().uuidString)]) == "NOT_FOUND")
        #expect(await rig.errorCode("render.plan_image", ["paper": "A0x"]) == "INVALID_ARGUMENT")
        #expect(await rig.errorCode("render.plan_image", ["paper": "A4", "scale": 10]) == "OUT_OF_RANGE")
        #expect(await rig.errorCode("render.plan_image", ["path": .string(rig.path("p.png")), "inline": false]) == nil)
    }

    @Test func exportPlanNoLongerAcceptsPng() async {
        let rig = VRig()
        defer { rig.cleanup() }
        #expect(await rig.errorCode("export.plan", ["format": "png", "path": .string(rig.path("e.png"))]) == "INVALID_ARGUMENT")
    }
}

// MARK: - project.new / open / save_as

@MainActor
struct ProjectFileToolTests {
    @Test func saveAsWritesPackageAndSwitchesFile() async throws {
        let rig = VRig()
        defer { rig.cleanup() }
        _ = await rig.ok("geometry.create_wall", ["start": ["x": 0, "y": 0], "end": ["x": 3000, "y": 0]])
        #expect(rig.store.isDirty)
        let path = rig.path("House.roomsmith")
        let r = await rig.ok("project.save_as", ["path": .string(path)])
        #expect(r["saved"]?.boolValue == true)
        #expect(r["dirty"]?.boolValue == false)
        #expect(rig.context.fileURL?.lastPathComponent == "House.roomsmith")
        #expect(FileManager.default.fileExists(atPath: path + "/project.md"))
        // Existing package needs overwrite; the own package is never a target.
        #expect(await rig.errorCode("project.save_as", ["path": .string(path)]) == "INVALID_ARGUMENT")
        #expect(await rig.errorCode("project.save_as", ["path": .string(rig.path("n.txt"))]) == "INVALID_ARGUMENT")
        #expect(await rig.errorCode("project.save_as", ["path": "relative.roomsmith"]) == "INVALID_ARGUMENT")
    }

    @Test func saveAsRefusesToReplaceForeignFolder() async throws {
        let rig = VRig()
        defer { rig.cleanup() }
        let folder = rig.dir.appendingPathComponent("Other.roomsmith")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(await rig.errorCode("project.save_as", ["path": .string(folder.path), "overwrite": true]) == "INVALID_ARGUMENT")
    }

    @Test func newAndOpenGuardUnsavedChanges() async throws {
        let rig = VRig()
        defer { rig.cleanup() }
        let path = rig.path("A.roomsmith")
        _ = await rig.ok("project.save_as", ["path": .string(path)])
        _ = await rig.ok("geometry.create_wall", ["start": ["x": 0, "y": 0], "end": ["x": 3000, "y": 0]])
        #expect(rig.store.isDirty)
        #expect(await rig.errorCode("project.new") == "CONFLICT")
        #expect(await rig.errorCode("project.open", ["path": .string(path)]) == "CONFLICT")
        #expect(rig.store.project.walls.count == 1)

        let opened = await rig.ok("project.open", ["path": .string(path), "discard": true])
        #expect(opened["name"]?.stringValue == "View")
        #expect(rig.store.project.walls.isEmpty)
        #expect(!rig.store.isDirty)
        // Clean project: no discard needed.
        let fresh = await rig.ok("project.new")
        #expect(fresh["name"]?.stringValue == "Untitled")
        #expect(fresh["path"]?.isNull == true)
        _ = await rig.ok("geometry.create_wall", ["start": ["x": 0, "y": 0], "end": ["x": 1000, "y": 0]])
        _ = await rig.ok("project.new", ["discard": true])
        #expect(rig.store.project.walls.isEmpty)
    }

    @Test func openValidatesPath() async {
        let rig = VRig()
        defer { rig.cleanup() }
        #expect(await rig.errorCode("project.open", ["path": "A.roomsmith"]) == "INVALID_ARGUMENT")
        #expect(await rig.errorCode("project.open", ["path": .string(rig.path("A.txt"))]) == "INVALID_ARGUMENT")
        #expect(await rig.errorCode("project.open", ["path": .string(rig.path("Missing.roomsmith"))]) == "NOT_FOUND")
        #expect(await rig.errorCode("project.open") == "INVALID_ARGUMENT")
    }

    @Test func projectFileToolsNeedWriteAccess() async {
        let rig = VRig(write: false)
        defer { rig.cleanup() }
        #expect(await rig.errorCode("project.new") == "WRITE_LOCKED")
        #expect(await rig.errorCode("project.open", ["path": .string(rig.path("A.roomsmith"))]) == "WRITE_LOCKED")
        #expect(await rig.errorCode("project.save_as", ["path": .string(rig.path("A.roomsmith"))]) == "WRITE_LOCKED")
    }
}


// MARK: - catalog.import_model

@MainActor
struct ImportModelToolTests {
    /// A saved project in the rig's temp folder and a fake model file.
    private func savedRig(write: Bool = true, ext: String = "usdz") async -> (VRig, URL) {
        let rig = VRig(write: write)
        let pkg = URL(fileURLWithPath: rig.path("p.roomsmith"))
        try? ProjectPackage.save(rig.store.project, to: pkg)
        rig.context.fileURL = pkg
        let file = rig.dir.appendingPathComponent("chair.\(ext)")
        try? Data("fake model".utf8).write(to: file)
        return (rig, file)
    }

    @Test func importsDesignAndPlacesInstance() async {
        let (rig, file) = await savedRig()
        defer { rig.cleanup() }
        let r = await rig.ok("catalog.import_model", ["path": .string(file.path), "name": "Chair",
                                                      "place": ["position": ["x": 1000, "y": 2000]]])
        #expect(r["size"]?["width"]?.int64Value == 2000)
        #expect(r["size"]?["height"]?.int64Value == 750)
        let def = rig.store.project.definitions.first { $0.name == "Chair" }
        #expect(def?.id.uuidString.lowercased() == r["designId"]?.stringValue)
        #expect(def?.components.first?.shape == .mesh)
        #expect(def?.size == Size3(2000, 900, 750))
        let inst = rig.store.project.instances.first
        #expect(inst?.id.uuidString.lowercased() == r["instanceId"]?.stringValue)
        #expect(inst?.position == P3(1000, 2000, 0))
        #expect(rig.store.project.assets.count == 1)
        let stored = ProjectPackage.assetURL(rig.store.project.assets[0], in: rig.context.fileURL!)
        #expect(FileManager.default.fileExists(atPath: stored.path))
        // One undo step removes design and instance.
        _ = await rig.ok("history.undo")
        #expect(rig.store.project.definitions.allSatisfy { $0.name != "Chair" })
        #expect(rig.store.project.instances.isEmpty)
    }

    @Test func importWithoutPlaceOnlyCreatesDesign() async {
        let (rig, file) = await savedRig(ext: "USDC")
        defer { rig.cleanup() }
        let r = await rig.ok("catalog.import_model", ["path": .string(file.path)])
        #expect(r["instanceId"] == nil)
        #expect(r["name"]?.stringValue == "chair")
        #expect(rig.store.project.instances.isEmpty)
        #expect(rig.store.project.definitions.contains { $0.name == "chair" && $0.category == "Imported" })
    }

    @Test func importWarnsAboutImplausibleScale() async {
        let (rig, file) = await savedRig()
        defer { rig.cleanup() }
        rig.context.measured = Size3(5, 5, 5)
        let r = await rig.ok("catalog.import_model", ["path": .string(file.path)])
        #expect(r["warning"]?.stringValue?.contains("scale") == true)
    }

    @Test func importValidatesBeforeChangingAnything() async {
        let (rig, file) = await savedRig()
        defer { rig.cleanup() }
        let rev = rig.store.project.revision
        #expect(await rig.errorCode("catalog.import_model", ["path": "relative.usdz"]) == "INVALID_ARGUMENT")
        #expect(await rig.errorCode("catalog.import_model", ["path": "/tmp/x.obj"]) == "INVALID_ARGUMENT")
        #expect(await rig.errorCode("catalog.import_model", ["path": .string(rig.path("missing.usdz"))]) == "NOT_FOUND")
        #expect(await rig.errorCode("catalog.import_model", ["path": .string(rig.dir.path + "/x.usdz")]) == "NOT_FOUND")
        #expect(await rig.errorCode("catalog.import_model", ["path": .string(file.path), "place": ["position": ["x": 0, "y": 0], "levelId": .string(UUID().uuidString)]]) == "NOT_FOUND")
        #expect(await rig.errorCode("catalog.import_model", ["path": .string(file.path), "place": ["levelId": .string(rig.levelId.uuidString)]]) == "INVALID_ARGUMENT")
        #expect(rig.store.project.revision == rev)
        #expect(rig.context.measuredURLs.isEmpty)
    }

    @Test func importNeedsSavedProjectAndWriteAccess() async {
        let (locked, lockedFile) = await savedRig(write: false)
        defer { locked.cleanup() }
        #expect(await locked.errorCode("catalog.import_model", ["path": .string(lockedFile.path)]) == "WRITE_LOCKED")
        let (rig, file) = await savedRig()
        defer { rig.cleanup() }
        rig.context.fileURL = nil
        #expect(await rig.errorCode("catalog.import_model", ["path": .string(file.path)]) == "NO_FILE")
    }

    @Test func unreadableModelFailsCleanlyAndLeavesNoAsset() async {
        let (rig, file) = await savedRig()
        defer { rig.cleanup() }
        rig.context.measureError = AgentError(code: AgentError.invalidArgument, message: "not a model")
        #expect(await rig.errorCode("catalog.import_model", ["path": .string(file.path)]) == "INVALID_ARGUMENT")
        #expect(rig.store.project.assets.isEmpty)
        let assets = rig.context.fileURL!.appendingPathComponent("assets")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: assets.path)) ?? []).isEmpty)
    }

    @Test func withoutAppSupportItIsUnsupported() async {
        let (rig, file) = await savedRig()
        defer { rig.cleanup() }
        rig.context.measureError = .unsupportedFeature("no app")
        #expect(await rig.errorCode("catalog.import_model", ["path": .string(file.path)]) == "UNSUPPORTED")
    }
}
