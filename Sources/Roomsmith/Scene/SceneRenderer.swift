import AppKit
import Combine
import Foundation
import Observation
import RealityKit
import RoomsmithCore
import simd

/// View settings that belong to the 3D view only (not to the document).
struct SceneOptions: Equatable {
    var showCeilings = false
    var onlyActiveLevel = false
    /// Opacity of walls: 1, 0.6 or 0.3. Furniture, floors and glass are not affected.
    var wallOpacity = 1.0
    /// false hides the pieces of furniture whose design has lamps. Their light is not touched.
    var showLamps = true
}

/// Builds and updates the RealityKit scene graph that mirrors the document, and owns the camera.
///
/// The graph (`worldRoot`) does not depend on a view: `SceneARView` adds it to an `ARView`, `SceneSnapshot.render`
/// to a `RealityRenderer`. Document changes arrive as `ChangeEvent`s from the store and touch only the entities of
/// the objects that changed; the whole graph is rebuilt only when the project is replaced or levels change.
///
/// Why `ARView` and not `RealityView`: the 3D view needs raw `NSEvent` access (scroll phases, magnify, rotate,
/// smart magnify, key up/down), a snapshot API and direct control over `environment.background` and lighting.
/// `RealityView` hides the backing view; `ARView` (non-AR mode on macOS) exposes all of it.
@MainActor
final class SceneRenderer {
    let model: AppModel
    /// false for the offscreen renderer: no observers, gizmo, collisions or animation.
    let interactive: Bool
    let materials = SceneMaterials()
    let pickIndex = PickIndex()
    let meshCache = MeshAssetCache()
    let camera: SceneCameraController

    // Scene graph
    let worldRoot = Entity()
    let contentRoot = Entity()
    let sun = DirectionalLight()
    let ground = ModelEntity()
    let cameraEntity = PerspectiveCamera()
    let gizmo = Gizmo()
    weak var arView: ARView?

    var options = SceneOptions()

    // Nodes by document id
    var levelRoots: [UUID: Entity] = [:]
    var levelInfo: [UUID: Level] = [:]
    var wallNodes: [UUID: WallNode] = [:]
    var roomNodes: [UUID: RoomNode] = [:]
    var instNodes: [UUID: InstNode] = [:]
    /// Merged furniture meshes shared between instances (see `MergedMeshCache`).
    let mergedMeshes = MergedMeshCache()
    var outlineCache: [UUID: [UUID: WallOutline]] = [:]
    /// Opening id to wall id; entries of removed openings are dropped when the change arrives (their old wall is marked dirty first).
    var openingWall: [UUID: UUID] = [:]

    // Observation
    var observerToken: UUID?
    var subscriptions: [any Cancellable] = []
    var stopped = false
    var lastActiveLevel: UUID
    var lastFrameRequest: Int
    var lastFileURL: URL?
    var selectedExpanded: Set<UUID> = []
    var hoveredExpanded: Set<UUID> = []
    var colliding: Set<UUID> = []
    var lastCollisionWarnings = true

    // Light (see SceneRenderer+Light.swift)
    /// Lamps live here, in metres and unscaled (a light's reach must not be scaled by `contentRoot`).
    let lampRoot = Entity()
    var lastDark = false
    var sunShadowsOn = true
    var appliedLook: AppliedLook?
    var lampSlots: [LampSlot] = []

    // Camera persistence
    var lastPersisted: CameraState
    /// A camera write is waiting for the movement to go quiet: `persistDeadline` moves with every change, one task waits for it.
    var persistPending = false
    var persistDeadline = ContinuousClock.now
    var persistTask: Task<Void, Never>?
    /// Set by `autoFrame`: the first real layout re-fits once, because the view size is only a guess before it.
    var refitOnLayout = false

    // Collisions
    var collisionGeneration = 0
    var collisionRevision: Int64 = -1

    // Animation
    var animations: [UUID: StateAnimation] = [:]

    // Input state (see SceneRenderer+Interaction)
    var pressedKeys: Set<UInt16> = []
    /// Free camera: velocity and smoothing of the flight (see `FreeFlight`, `tickFlight`).
    var flight = FreeFlight()
    /// Camera mode seen at the last `cameraChanged`; a difference triggers `modeDidChange`.
    var lastRigMode: CameraMode
    /// Walk mode: motion, collision, doors, pointer lock, game controller (see `WalkController`).
    lazy var walk = WalkController(renderer: self)
    var scroll = ScrollTracker()
    var drag: DragState?
    var pendingClick: PendingClick?
    /// Space is held down: temporary Hand tool (look only). Per view; cleared when the focus is lost.
    var spaceHeld = false
    /// Hand state seen at the last `handModeDidChange`, to notice tool changes made elsewhere (toolbar, plan).
    var lastHandActive = false
    /// Measure tool (see SceneRenderer+Measure): the clicked points, the cursor preview and the overlay that draws them.
    var measure = Measure3DState()
    var measurePreview: P3?
    var lastMeasureActive = false
    var measureOverlay: SceneMeasureOverlay?
    var hudText: String? { didSet { if hudText != oldValue { ui?.hud = hudText } } }
    /// Per-view UI state (mode, HUD); set by `SceneView`.
    var ui: SceneUIState?
    /// Document position of the gizmo, nil while hidden.
    var gizmoOrigin: D3?
    var lastMousePoint: SIMD2<Double>?

    // Diagnostics
    let env = ProcessInfo.processInfo.environment
    var perfEnabled: Bool { env["ROOMSMITH_PERF"] == "1" }
    var frameTicks = 0
    var lastBuildMs = 0.0
    var lastSyncMs = 0.0
    static var didPrintSceneLine = false

    init(model: AppModel, interactive: Bool, camera cameraState: CameraState? = nil) {
        self.model = model
        self.interactive = interactive
        let p = model.project
        let state = cameraState ?? p.camera
        camera = SceneCameraController(state: state)
        lastRigMode = camera.rig.mode
        lastActiveLevel = model.activeLevelId
        lastFrameRequest = model.frameSelectionRequest
        lastFileURL = model.fileURL
        lastPersisted = p.camera
        lastCollisionWarnings = p.settings.collisionWarnings
        buildStaticGraph()
        materials.packageURL = model.fileURL
        materials.onTexturesReady = { [weak self] in self?.texturesReady() }
        meshCache.onLoaded = { [weak self] id in self?.meshLoaded(id) }
        camera.onChange = { [weak self] in self?.cameraChanged() }
        camera.eyeHeight = { WalkSettingsStore.shared.settings.eyeHeightMm }
        if cameraState == nil { lastPersisted = camera.rig.state }
        SceneSelfTest.runIfRequested()
        fullRebuild()
        if cameraState == nil, p.camera == CameraState.default { autoFrame() }
        applyCamera()
    }

    /// Connects to the document and the model. Interactive renderers only.
    func start() {
        guard interactive, observerToken == nil else { return }
        observerToken = model.store.addObserver { [weak self] event in self?.handle(event) }
        observeModel()
        refreshSelectionTints()
        scheduleCollisions()
    }

    func teardown() {
        stopped = true
        if let t = observerToken { model.store.removeObserver(t); observerToken = nil }
        subscriptions.forEach { $0.cancel() }
        subscriptions.removeAll()
        flushCameraPersistence()
        persistTask?.cancel(); persistTask = nil
        walk.shutdown()
        if interactive { model.store.endInteraction(nil) }
        arView = nil
        ui?.hud = nil
    }

    // MARK: Static graph

    private func buildStaticGraph() {
        SceneCoords.apply(to: contentRoot)
        worldRoot.addChild(contentRoot)

        sun.light.color = .white
        sun.light.intensity = 3200
        sun.shadow = DirectionalLightComponent.Shadow(maximumDistance: 40, depthBias: 2)
        sun.look(at: .zero, from: SIMD3(-4, 9, 6), relativeTo: nil)
        worldRoot.addChild(sun)
        worldRoot.addChild(lampRoot)

        ground.model = ModelComponent(mesh: .generatePlane(width: Float(Self.groundSize), depth: Float(Self.groundSize)),
                                      materials: [SceneRenderer.groundMaterial(dark: false)])
        worldRoot.addChild(ground)

        cameraEntity.camera.fieldOfViewOrientation = .vertical
        worldRoot.addChild(cameraEntity)

        if interactive { worldRoot.addChild(gizmo.root) }
    }

    /// Edge length of the ground mesh in metres before scaling (see `followGround`).
    static let groundSize = 400.0

    /// Shadow range in metres for a view distance: 40 m, doubled until it covers 2.5 x the distance (max 640 m).
    static func shadowRange(viewDistanceMM: Double) -> Float {
        var r: Float = 40
        let need = Float(viewDistanceMM / 1000 * 2.5)
        while r < need && r < 640 { r *= 2 }
        return r
    }

    static func groundMaterial(dark: Bool, mood: LightMood = .daylight) -> RealityKit.Material {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: SceneEnvironment.groundColor(dark: dark, mood: mood))
        m.roughness = 1.0
        m.metallic = 0.0
        return m
    }

    func applyAppearance(dark: Bool) {
        lastDark = dark
        applyLighting(force: true)
    }

    // MARK: Predicates

    func levelShown(_ id: UUID) -> Bool {
        guard let level = model.project.level(id), level.visible else { return false }
        return !options.onlyActiveLevel || id == model.activeLevelId
    }

    /// Whether the 3D view draws and picks this piece: lamp furniture is hidden while "Lamps" is off.
    /// Only the piece goes; its light lives in `lampRoot` and is driven by `applyLighting`.
    func instanceShown(_ inst: FurnitureInstance) -> Bool {
        model.project.isInstanceShown(inst, showLamps: options.showLamps)
    }

    private func applyInstanceVisibility(_ id: UUID) {
        guard let n = instNodes[id], let inst = model.project.instance(id) else { return }
        n.root.isEnabled = instanceShown(inst)
    }

    func setOptions(_ new: SceneOptions) {
        guard new != options else { return }
        let old = options
        options = new
        if old.showCeilings != new.showCeilings {
            for r in model.project.rooms { syncRoom(r.id) }
        }
        if old.showLamps != new.showLamps {
            for id in instNodes.keys { applyInstanceVisibility(id) }
        }
        if old.wallOpacity != new.wallOpacity {
            for id in wallNodes.keys { applyWallMaterials(id) }
        }
        if old.onlyActiveLevel != new.onlyActiveLevel { updateLevelVisibility() }
        updateGizmo()
    }

    func updateLevelVisibility() {
        for (id, root) in levelRoots { root.isEnabled = levelShown(id) }
        applyLighting()
    }

    // MARK: Full rebuild

    func fullRebuild() {
        let t0 = ContinuousClock.now
        let p = model.project
        for c in Array(contentRoot.children) { c.removeFromParent() }
        levelRoots = [:]; levelInfo = [:]; wallNodes = [:]; roomNodes = [:]; instNodes = [:]
        outlineCache = [:]; openingWall = [:]; animations = [:]
        pickIndex.invalidateAll()
        for level in p.levels {
            let root = Entity()
            root.name = "level"
            contentRoot.addChild(root)
            levelRoots[level.id] = root
            levelInfo[level.id] = level
        }
        for o in p.openings { openingWall[o.id] = o.wallId }
        for level in p.levels { syncWalls(levelId: level.id, only: nil) }
        for r in p.rooms { syncRoom(r.id) }
        mergedMeshes.reset()
        let table = Self.instanceTable(p)
        for i in p.instances { syncInstance(i.id, force: true, instances: table) }
        updateLevelVisibility()
        placeGround()
        refreshSelectionTints()
        lastBuildMs = (ContinuousClock.now - t0).ms
        reportSceneLineIfNeeded()
    }

    func placeGround() {
        let low = model.project.levels.map(\.elevation).min() ?? 0
        ground.position.y = Float(low) / 1000 - 0.012
    }

    // MARK: Walls

    /// Rebuilds the wall entities of a level. `only` limits the work to some walls (outlines come from the cache).
    func syncWalls(levelId: UUID, only: Set<UUID>?) {
        let p = model.project
        walk.pruneOpenings()
        guard levelRoots[levelId] != nil, let level = p.level(levelId) else { return }
        let walls = p.walls.filter { $0.levelId == levelId }
        if only == nil || outlineCache[levelId] == nil { outlineCache[levelId] = WallOutline.compute(walls, levelId: levelId) }
        var byWall: [UUID: [Opening]] = [:]
        for o in p.openings { byWall[o.wallId, default: []].append(o) }
        let ids = Set(walls.map(\.id))
        for (id, node) in wallNodes where node.levelId == levelId && !ids.contains(id) { removeWall(id) }
        for w in walls where only == nil || only!.contains(w.id) {
            syncWall(w, level: level, openings: byWall[w.id] ?? [])
        }
    }

    private func syncWall(_ w: Wall, level: Level, openings: [Opening]) {
        guard let outline = outlineCache[level.id]?[w.id] else { return }
        let sig = WallSignature(wall: w, outline: outline, openings: openings, elevation: level.elevation)
        if let n = wallNodes[w.id], n.signature == sig { return }
        removeWall(w.id)
        guard let levelRoot = levelRoots[level.id] else { return }
        let p = model.project
        let data = Meshes.wall(w, outline: outline, openings: openings, baseZ: level.elevation)
        let tileL = Double(w.leftMaterialId.flatMap { p.material($0)?.textureTile } ?? 1000)
        let tileR = Double(w.rightMaterialId.flatMap { p.material($0)?.textureTile } ?? 1000)
        guard let built = SceneMeshes.resource(from: data, slotOf: { role in
            switch role { case .wallLeft: 0; case .wallRight: 1; default: 2 }
        }, tile: { slot in slot == 0 ? tileL : (slot == 1 ? tileR : 1000) }) else { return }
        let entity = ModelEntity(mesh: built.mesh, materials: [])
        entity.name = "wall"
        levelRoot.addChild(entity)
        let keys: [MatKey] = [.of(w.leftMaterialId, .wallDefault), .of(w.rightMaterialId, .wallDefault), .wallDefault]
        let node = WallNode(levelId: level.id, entity: entity, signature: sig, used: built.used, keys: keys)
        for o in openings {
            let leafMesh = Meshes.doorLeaf(o, wall: w, baseZ: level.elevation)
            let placement = leafMesh.indices.isEmpty ? nil : Meshes.doorLeafPlacement(o, wall: w, baseZ: level.elevation)
            let sashes = o.kind == .window ? Meshes.windowSashes(o, wall: w, baseZ: level.elevation) : []
            let fd = Meshes.openingFrame(o, wall: w, baseZ: level.elevation, includeLeaf: placement == nil, includeSashes: sashes.isEmpty)
            guard let fb = SceneMeshes.resource(from: fd, slotOf: SceneRenderer.openingSlot, tile: { _ in 1000 }) else { continue }
            let fe = ModelEntity(mesh: fb.mesh, materials: [])
            fe.name = "opening"
            entity.addChild(fe)
            let frame = FrameNode(entity: fe, used: fb.used, keys: [.of(o.frameMaterialId, .frameDefault), .glass, .glassFrosted, .glassTinted, .hardware])
            if let pl = placement, let lb = SceneMeshes.resource(from: leafMesh, slotOf: SceneRenderer.openingSlot, tile: { _ in 1000 }) {
                let pivot = Entity()
                pivot.name = "doorLeaf"
                pivot.position = SIMD3(Float(pl.hinge.x), Float(pl.hinge.y), Float(pl.hinge.z))
                let leafEntity = ModelEntity(mesh: lb.mesh, materials: [])
                pivot.addChild(leafEntity)
                fe.addChild(pivot)
                frame.leaf = DoorLeafNode(pivot: pivot, model: leafEntity, used: lb.used, closedYaw: pl.closedYawDeg, openYaw: pl.openYawDeg)
            }
            for sash in sashes {
                guard let sb = SceneMeshes.resource(from: sash.mesh, slotOf: SceneRenderer.openingSlot, tile: { _ in 1000 }) else { continue }
                let pl = sash.placement
                let turn = Entity()
                turn.name = "sash"
                turn.position = SIMD3(Float(pl.pivot.x), Float(pl.pivot.y), Float(pl.pivot.z))
                turn.orientation = simd_quatf(angle: Float(pl.closedYawDeg * .pi / 180), axis: SIMD3(0, 0, 1))
                let tilt = Entity()
                let sashEntity = ModelEntity(mesh: sb.mesh, materials: [])
                tilt.addChild(sashEntity)
                turn.addChild(tilt)
                fe.addChild(turn)
                frame.sashes.append(SashNode(turnPivot: turn, tiltPivot: tilt, model: sashEntity, used: sb.used, placement: pl))
            }
            node.frames[o.id] = frame
        }
        wallNodes[w.id] = node
        applyWallMaterials(w.id)
        for o in openings where node.frames[o.id]?.leaf != nil || !(node.frames[o.id]?.sashes.isEmpty ?? true) { walk.applyPose(o.id) }
    }

    /// Material slot of an opening mesh part: 0 frame, 1 clear glass, 2 frosted glass, 3 tinted glass, 4 hardware.
    nonisolated static func openingSlot(_ role: MeshRole) -> Int {
        switch role {
        case .glass: 1
        case .glassFrosted: 2
        case .glassTinted: 3
        case .hardware: 4
        default: 0
        }
    }

    func removeWall(_ id: UUID) {
        guard let n = wallNodes.removeValue(forKey: id) else { return }
        n.entity.removeFromParent()
    }

    func applyWallMaterials(_ id: UUID) {
        guard let n = wallNodes[id] else { return }
        let p = model.project
        let t = tint(for: id)
        n.entity.model?.materials = n.used.map { materials.material(n.keys[$0], tint: t, project: p, opacityScale: options.wallOpacity) }
        for (oid, f) in n.frames {
            let ft = tint(for: oid)
            f.entity.model?.materials = f.used.map { materials.material(f.keys[$0], tint: ft, project: p) }
            f.leaf?.model.model?.materials = (f.leaf?.used ?? []).map { materials.material(f.keys[$0], tint: ft, project: p) }
            for s in f.sashes { s.model.model?.materials = s.used.map { materials.material(f.keys[$0], tint: ft, project: p) } }
        }
    }

    // MARK: Rooms

    func syncRoom(_ id: UUID) {
        let p = model.project
        guard let r = p.room(id), let level = p.level(r.levelId), let levelRoot = levelRoots[r.levelId] else { removeRoom(id); return }
        let wantFloor = r.showFloor && r.points.count >= 3
        let wantCeiling = (r.showCeiling || options.showCeilings) && r.points.count >= 3
        let sig = RoomSignature(room: r, elevation: level.elevation, levelHeight: level.height, rank: RenderLayering.roomRank(r, in: p))
        if let n = roomNodes[id], n.signature == sig, (n.floor != nil) == wantFloor, (n.ceiling != nil) == wantCeiling { return }
        removeRoom(id)
        let node = RoomNode(levelId: r.levelId, signature: sig, floorKey: .of(r.floorMaterialId, .floorDefault),
                            ceilingKey: .of(r.ceilingMaterialId, .ceilingDefault))
        if wantFloor {
            let tile = Double(r.floorMaterialId.flatMap { p.material($0)?.textureTile } ?? 1000)
            if let b = SceneMeshes.resource(from: Meshes.roomFloor(r, z: level.elevation), slotOf: { _ in 0 }, tile: { _ in tile }) {
                let e = ModelEntity(mesh: b.mesh, materials: [])
                e.name = "floor"
                // Draw-time lift only (stored heights stay exact): equally high overlapping floors must not flicker.
                e.position.z = Float(RenderLayering.offsetMm(rank: sig.rank))
                levelRoot.addChild(e)
                node.floor = e
            }
        }
        if wantCeiling {
            let tile = Double(r.ceilingMaterialId.flatMap { p.material($0)?.textureTile } ?? 1000)
            if let b = SceneMeshes.resource(from: Meshes.roomCeiling(r, z: level.elevation + level.height), slotOf: { _ in 0 }, tile: { _ in tile }) {
                let e = ModelEntity(mesh: b.mesh, materials: [])
                e.name = "ceiling"
                levelRoot.addChild(e)
                node.ceiling = e
            }
        }
        roomNodes[id] = node
        applyRoomMaterials(id)
    }

    func removeRoom(_ id: UUID) {
        guard let n = roomNodes.removeValue(forKey: id) else { return }
        n.floor?.removeFromParent()
        n.ceiling?.removeFromParent()
    }

    func applyRoomMaterials(_ id: UUID) {
        guard let n = roomNodes[id] else { return }
        let p = model.project
        n.floor?.model?.materials = [materials.material(n.floorKey, tint: tint(for: id), project: p)]
        n.ceiling?.model?.materials = [materials.material(n.ceilingKey, tint: .none, project: p)]
    }

    // MARK: Furniture

    func removeInstance(_ id: UUID) {
        animations[id] = nil
        pickIndex.invalidate(id)
        guard let n = instNodes.removeValue(forKey: id) else { return }
        n.root.removeFromParent()
    }

    private func isMoveOnly(_ a: FurnitureInstance, _ b: FurnitureInstance) -> Bool {
        var x = a
        x.position = b.position; x.rotationDeg = b.rotationDeg; x.rev = b.rev; x.name = b.name
        x.locked = b.locked; x.groupId = b.groupId; x.productId = b.productId
        return x == b
    }

    /// Brings the entities of one instance in line with the document. A move or rotation only sets one matrix.
    /// `force` skips that shortcut and ends running animations (used at the end of a state transition).
    /// `instances` is an id table for bulk callers (full rebuild, many ids); it saves the linear `instance(_:)` lookup per piece.
    func syncInstance(_ id: UUID, force: Bool = false, instances: [UUID: FurnitureInstance]? = nil) {
        let p = model.project
        guard let inst = instances?[id] ?? p.instance(id), let def = p.definition(inst.definitionId), let level = p.level(inst.levelId),
              let levelRoot = levelRoots[inst.levelId] else {
            removeInstance(id)
            return
        }
        pickIndex.invalidate(id)
        var rootMatrix = simd_float4x4(FurnitureResolver.instanceMatrix(inst, definition: def, levelElevation: level.elevation))
        // Draw-time lift only: overlapping rugs of equal height must not flicker. Stored position and collisions are untouched.
        rootMatrix.columns.3.z += Float(RenderLayering.offsetMm(rank: RenderLayering.flatPieceRank(inst, in: p)))

        if !force, let node = instNodes[id], node.levelId == inst.levelId, node.defRev == def.rev,
           node.elevation == level.elevation, isMoveOnly(node.last, inst) {
            node.root.transform.matrix = rootMatrix
            node.last = inst
            return
        }

        let node: InstNode
        if let existing = instNodes[id] {
            node = existing
            if node.levelId != inst.levelId {
                node.root.removeFromParent()
                levelRoot.addChild(node.root)
                node.levelId = inst.levelId
            }
        } else {
            node = InstNode(levelId: inst.levelId, last: inst, defRev: def.rev, elevation: level.elevation)
            node.root.name = "furniture"
            levelRoot.addChild(node.root)
            instNodes[id] = node
        }
        node.root.transform.matrix = rootMatrix

        let old = node.last
        let resolved = FurnitureResolver.resolve(inst, definition: def, levelElevation: level.elevation)

        // State transition with an animation track?
        var starting: StateAnimation?
        if interactive, !force, old.stateId != inst.stateId, old.definitionId == inst.definitionId, node.populated,
           let newState = inst.stateId,
           let track = def.tracks.first(where: { $0.toStateId == newState && $0.fromStateId == old.stateId })
            ?? def.tracks.first(where: { $0.toStateId == newState && $0.fromStateId == nil }) {
            let oldState = old.stateId.flatMap { sid in def.states.first { $0.id == sid } }
            let newS = def.states.first { $0.id == newState }
            var start: [UUID: StateAnimation.Pose] = animations[id]?.current ?? [:]
            var end: [UUID: StateAnimation.Pose] = [:]
            for c in def.components {
                if start[c.id] == nil { start[c.id] = StateAnimation.Pose(FurnitureResolver.pose(of: c, state: oldState)) }
                end[c.id] = StateAnimation.Pose(FurnitureResolver.pose(of: c, state: newS))
            }
            starting = StateAnimation.make(instanceId: id, def: def, track: track, start: start, end: end)
        }
        // A forced sync (end of a transition, reload) or any other slow-path change replaces a running animation.
        animations[id] = force ? nil : starting

        // Merged or parts form is decided only now, after the animation is settled: a running transition needs every
        // component as its own entity; a sync that ends (or never had) an animation returns to the merged form.
        let partition = furniturePartition(inst, def, project: p)
        var useParts = animations[id] != nil
        if !useParts, !syncMerged(node, inst: inst, def: def, partition: partition) { useParts = true }
        if useParts { dropMerged(node) }
        let separateIds = Set(partition.lazy.filter(\.separate).map(\.componentId))
        node.partition = partition

        let optionHidden = FurnitureResolver.optionOutcome(of: inst, definition: def).hidden
        var seen: Set<UUID> = []
        for rc in resolved {
            // Merged form keeps own entities only for loaded meshes and transparent components.
            guard useParts || rc.shape == .mesh || separateIds.contains(rc.componentId) else { continue }
            seen.insert(rc.componentId)
            let comp: CompNode
            let local = FurnitureResolver.componentMatrix(position: rc.position, size: rc.size, rotation: rc.rotation, pivot: rc.pivot)
            let partKey = rc.shape == .mesh ? nil : SceneMeshes.PartKey(
                shape: rc.shape, size: rc.size,
                offset: SIMD3<Int64>(SIMD3(local.columns.3.x, local.columns.3.y, local.columns.3.z).rounded(.toNearestOrEven)))
            if let c = node.comps[rc.componentId], c.shape == rc.shape, c.partKey == partKey {
                comp = c
            } else {
                node.comps[rc.componentId]?.entity.removeFromParent()
                let e = ModelEntity(mesh: partKey.map(SceneMeshes.part) ?? SceneMeshes.unit(rc.shape, size: rc.size), materials: [])
                e.name = "component"
                node.root.addChild(e)
                comp = CompNode(entity: e)
                comp.shape = rc.shape
                comp.partKey = partKey
                node.comps[rc.componentId] = comp
            }
            let key = MatKey.of(rc.materialId, .componentDefault)
            if comp.key != key {
                comp.key = key
                comp.tint = nil
                // A loaded mesh may still wear a highlight tint and nil would read as pristine: start from a fresh clone.
                if comp.meshChild != nil, rc.shape == .mesh, rc.meshAssetId != nil {
                    comp.meshChild?.removeFromParent()
                    comp.meshChild = nil
                    comp.meshMaterials = []
                }
            }
            comp.optionHidden = optionHidden.contains(rc.componentId)   // also while animating: poses never see options
            if animations[id] == nil {
                let m = local
                comp.local = m
                comp.entity.transform.matrix = simd_float4x4(m)
                comp.entity.isEnabled = rc.visible
                comp.visible = rc.visible
            }
            attachMesh(comp, assetId: rc.shape == .mesh ? rc.meshAssetId : nil)
        }
        for (cid, c) in node.comps where !seen.contains(cid) {
            c.entity.removeFromParent()
            node.comps[cid] = nil
        }
        if let a = animations[id] {
            // First frame of the transition: still the start pose.
            var copy = a
            applyPoses(node, copy.advance(0))
            animations[id] = copy
        }
        node.last = inst
        node.defRev = def.rev
        node.elevation = level.elevation
        node.populated = !resolved.isEmpty
        applyInstanceVisibility(id)
        applyInstanceMaterials(id)
    }

    /// Same rule as `FurnitureResolver.resolve` (`visible`): pose, instance and the selected options must all allow it.
    static func poseShown(_ poseVisible: Bool, instanceVisible: Bool, optionHidden: Bool) -> Bool {
        poseVisible && instanceVisible && !optionHidden
    }

    func applyPoses(_ node: InstNode, _ poses: [(UUID, StateAnimation.Pose, P3?)]) {
        for (cid, pose, pivot) in poses {
            guard let c = node.comps[cid] else { continue }
            c.entity.transform.matrix = simd_float4x4(StateAnimation.matrix(pose, pivot: pivot))
            c.entity.isEnabled = Self.poseShown(pose.visible, instanceVisible: node.last.visible, optionHidden: c.optionHidden)
        }
    }

    func applyInstanceMaterials(_ id: UUID, force: Bool = false) {
        guard let n = instNodes[id] else { return }
        let p = model.project
        let t = tint(for: id)
        // A lamp that was switched, moved to another state or re-designed changes which parts glow: re-skin everything.
        let glow = lampGlow(n)
        let force = force || glow != n.glow
        n.glow = glow
        let glowColour = glow.map { $0.color * Self.lampGlowStrength }
        if let m = n.merged, force || m.tint != t {
            // Slot k wears the material of keys[k]; it glows when a glowing component is merged with that material.
            let lit = Set(n.partition.lazy.filter { !$0.separate && (glow?.componentIds.contains($0.componentId) ?? false) }
                .map { MatKey.of($0.materialId, .componentDefault) })
            Self.assign(m.entity, m.keys.map {
                materials.material($0, tint: t, project: p, metricUV: true, glow: lit.contains($0) ? glowColour : nil)
            }, fresh: Self.leavesHighlight(from: m.tint, to: t))
            m.tint = t
        }
        for (cid, c) in n.comps where force || c.tint != t {
            if c.meshChild != nil {
                retintMesh(c, tint: t)
            } else {
                let lit = glow?.componentIds.contains(cid) ?? false
                Self.assign(c.entity, [materials.material(c.key, tint: t, project: p, metricUV: c.partKey != nil,
                                                          glow: lit ? glowColour : nil)],
                            fresh: Self.leavesHighlight(from: c.tint, to: t))
            }
            c.tint = t
        }
    }

    /// Emissive strength of a lit lamp part (times the lamp colour); bright enough to read as a light source in daylight.
    static let lampGlowStrength = 1.6

    /// The glowing parts of a switched-on, visible lamp in its current state; nil for everything else.
    private func lampGlow(_ n: InstNode) -> LampGlow.Glow? {
        let inst = n.last
        guard inst.lightOn, inst.visible, let def = model.project.definition(inst.definitionId), !def.lights.isEmpty else { return nil }
        return LampGlow.glow(definition: def, state: inst.stateId.flatMap { sid in def.states.first { $0.id == sid } })
    }

    /// True when a highlight tint goes away: the way back must be drawn visibly anew.
    private static func leavesHighlight(from old: SceneTint?, to new: SceneTint) -> Bool {
        guard let old else { return false }
        return new == SceneTint.none && old != SceneTint.none
    }

    /// Puts materials on a model. On the way back from a highlight the whole `ModelComponent` is rebuilt, because
    /// re-assigning the cached opaque material alone did not always redraw (a faint pink stayed until hover or click).
    private static func assign(_ entity: ModelEntity, _ mats: [any RealityKit.Material], fresh: Bool) {
        guard let mc = entity.model else { return }
        if fresh {
            // Materials are set in a second step, as when the part was first built: a component created with its materials
            // already in place kept drawing the highlight on procedural parts (a pink remnant, measured as 0.45 mean level).
            entity.model = ModelComponent(mesh: mc.mesh, materials: [])
            entity.model?.materials = mats
        } else {
            entity.model?.materials = mats
        }
    }

    /// Loaded USDZ: its own materials, each highlighted separately. The mesh is rebuilt from the prototype on every tint
    /// change instead of re-assigning the old materials: RealityKit does not render original materials that are put back
    /// on a model after other materials were assigned (the furniture then stays grey or white).
    private func retintMesh(_ comp: CompNode, tint: SceneTint) {
        guard let aid = comp.meshAssetId, meshCache.prototype(for: aid, project: model.project, packageURL: model.fileURL) != nil else { return }
        if let applied = comp.tint, applied != .none {   // nil or .none: the mesh still has its pristine materials
            comp.meshChild?.removeFromParent()
            comp.meshChild = nil
            attachMesh(comp, assetId: aid)
        }
        guard tint != .none else { return }
        for (e, original) in comp.meshMaterials { e.model?.materials = original.map { SceneMaterials.highlighted($0, tint: tint) } }
    }

    /// Shows the loaded USDZ in place of the box (or the box again when the asset is gone).
    private func attachMesh(_ comp: CompNode, assetId: UUID?) {
        if let aid = assetId, let proto = meshCache.prototype(for: aid, project: model.project, packageURL: model.fileURL) {
            if comp.meshChild == nil || comp.meshAssetId != aid {
                comp.meshChild?.removeFromParent()
                if comp.boxModel == nil { comp.boxModel = comp.entity.model }
                comp.entity.model = nil
                let clone = proto.clone(recursive: true)
                comp.entity.addChild(clone)
                comp.meshChild = clone
                comp.meshAssetId = aid
                comp.meshMaterials = Self.modelEntities(in: clone).compactMap { e in e.model.map { (e, $0.materials) } }
                comp.tint = nil   // re-apply the current tint to the new mesh
            }
        } else if comp.meshChild != nil {
            comp.meshChild?.removeFromParent()
            comp.meshChild = nil
            comp.meshAssetId = nil
            comp.meshMaterials = []
            if let m = comp.boxModel { comp.entity.model = m }
            comp.boxModel = nil
            comp.tint = nil
        }
    }

    /// Re-syncs only the instances whose definition uses this asset (not every mesh piece in the scene).
    private func meshLoaded(_ assetId: UUID) {
        guard !stopped else { return }
        let p = model.project
        let table = Self.instanceTable(p)
        for (id, node) in instNodes where node.comps.values.contains(where: { $0.shape == .mesh }) {
            guard let inst = table[id], let def = p.definition(inst.definitionId),
                  def.components.contains(where: { $0.meshAssetId == assetId }) else { continue }
            syncInstance(id, force: true, instances: table)
        }
    }

    static func modelEntities(in root: Entity) -> [ModelEntity] {
        var out: [ModelEntity] = []
        var stack: [Entity] = [root]
        while let e = stack.popLast() {
            if let m = e as? ModelEntity { out.append(m) }
            stack.append(contentsOf: e.children)
        }
        return out
    }

    func refreshAllMaterials() {
        materials.reset()
        for id in wallNodes.keys { applyWallMaterials(id) }
        for id in roomNodes.keys { applyRoomMaterials(id) }
        let p = model.project
        let table = Self.instanceTable(p)
        for id in Array(instNodes.keys) { reskinInstance(id, project: p, instances: table) }
    }

    /// Re-skins only the objects that use one of these document materials (a slider step touches one material, not the scene).
    /// The cached RealityKit materials of the given ids are dropped first; the cache key carries the revision, so any other
    /// entry stays valid.
    func refreshMaterials(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        materials.drop(materials: ids)
        func hit(_ k: MatKey) -> Bool { if case .doc(let id) = k { ids.contains(id) } else { false } }
        for (id, n) in wallNodes where n.keys.contains(where: hit) || n.frames.values.contains(where: { $0.keys.contains(where: hit) }) {
            applyWallMaterials(id)
        }
        for (id, n) in roomNodes where hit(n.floorKey) || hit(n.ceilingKey) { applyRoomMaterials(id) }
        let hitInstances = Array(instNodes.filter { _, n in
            n.merged?.keys.contains(where: hit) == true || n.comps.values.contains(where: { hit($0.key) })
        }.keys)
        if !hitInstances.isEmpty {
            let p = model.project
            let table = Self.instanceTable(p)
            for id in hitInstances { reskinInstance(id, project: p, instances: table) }
        }
    }

    /// Textures finished loading or rendering: re-skin the materials that use them (and nothing else).
    private func texturesReady() {
        guard !stopped else { return }
        let ready = materials.takeReady()
        let ids = Set(model.project.materials.compactMap { m -> UUID? in
            if let a = m.textureAssetId { return ready.assets.contains(a) ? m.id : nil }
            guard let params = ProceduralTexture.params(for: m) else { return nil }
            return ready.params.contains(params) ? m.id : nil
        })
        refreshMaterials(ids)
    }

    /// Replaced, removed or added files: forget only those textures and meshes and refresh what uses them. Backgrounds,
    /// images and other files never show in 3D, so they cost nothing here.
    private func assetsChanged(_ ids: Set<UUID>) {
        let p = model.project
        materials.invalidate(assets: ids)
        meshCache.invalidate(assets: ids)
        refreshMaterials(Set(p.materials.compactMap { m in m.textureAssetId.flatMap { ids.contains($0) ? m.id : nil } }))
        var touched = false
        let table = Self.instanceTable(p)
        for (id, node) in instNodes where node.comps.values.contains(where: { $0.shape == .mesh || $0.meshAssetId != nil }) {
            guard let inst = table[id], let def = p.definition(inst.definitionId),
                  def.components.contains(where: { $0.meshAssetId.map(ids.contains) ?? false }) else { continue }
            syncInstance(id, force: true, instances: table)
            touched = true
        }
        if touched { scheduleCollisions() }
    }

    // MARK: Tints

    func tint(for id: UUID) -> SceneTint {
        // First person is for walking and looking only: no selection and no hover tint (the selection itself stays).
        let editing = camera.rig.mode.allowsSelectionEditing
        return SceneTint.resolve(selected: editing && selectedExpanded.contains(id), hovered: editing && hoveredExpanded.contains(id),
                          colliding: model.project.settings.collisionWarnings && colliding.contains(id))
    }

    /// Re-applies the materials of the given objects (walls, rooms, openings, furniture).
    func applyTints(_ ids: Set<UUID>) {
        var walls: Set<UUID> = []
        for id in ids {
            if instNodes[id] != nil { applyInstanceMaterials(id) }
            else if wallNodes[id] != nil { walls.insert(id) }
            else if roomNodes[id] != nil { applyRoomMaterials(id) }
            else if let w = openingWall[id] { walls.insert(w) }
        }
        for w in walls { applyWallMaterials(w) }
    }

    func expand(_ ids: Set<UUID>) -> Set<UUID> {
        var out = ids
        let p = model.project
        for id in ids { if let g = p.group(id) { out.formUnion(g.memberIds) } }
        return out
    }

    /// Recomputes selection and hover and refreshes only the objects whose tint changed.
    func refreshSelectionTints() {
        let newSel = expand(model.selection)
        let newHover = model.hoveredId.map { expand([$0]) } ?? []
        let changed = selectedExpanded.symmetricDifference(newSel).union(hoveredExpanded.symmetricDifference(newHover))
        selectedExpanded = newSel
        hoveredExpanded = newHover
        applyTints(changed)
    }

    // MARK: Document events

    func handle(_ event: ChangeEvent) {
        guard !stopped else { return }
        let t0 = ContinuousClock.now
        defer {
            lastSyncMs = (ContinuousClock.now - t0).ms
            if perfEnabled { PerfLog.sync(event.name, ms: lastSyncMs, objects: event.changes.objects.count) }
        }
        let p = model.project
        let cs = event.changes

        if event.kind == .reset {
            materials.invalidateTextures()
            meshCache.reset()
            lastCollisionWarnings = p.settings.collisionWarnings
            materials.packageURL = model.fileURL
            // Before the rebuild: a reopened document keeps its UUIDs, and stale collision tints would survive.
            colliding = []
            fullRebuild()
            camera.set(CameraRig(p.camera))
            adoptProjectCamera()
            if p.camera == CameraState.default { autoFrame() }
            updateGizmo()
            scheduleCollisions()
            return
        }

        if cs.contains(kind: .asset) { assetsChanged(Set(cs.ids(.asset))) }

        // Levels: elevation or height changes move everything; add/remove changes the root list.
        if cs.contains(kind: .level) {
            let structural = cs.objects.contains { $0.kind == .level && $0.op != .modified }
            let geometric = p.levels.contains { l in
                guard let old = levelInfo[l.id] else { return true }
                return old.elevation != l.elevation || old.height != l.height
            }
            if structural || geometric || p.levels.count != levelInfo.count {
                fullRebuild()
                updateGizmo()
                scheduleCollisions()
                return
            }
            for l in p.levels { levelInfo[l.id] = l }
            updateLevelVisibility()
        }

        // Materials: re-skin everything that uses a changed material.
        let changedMaterials = Set(cs.ids(.material))
        if !changedMaterials.isEmpty { refreshMaterials(changedMaterials) }

        // Definitions: rebuild their instances.
        let changedDefs = Set(cs.ids(.definition))
        var instanceIds = Set(cs.ids(.furniture))
        if !changedDefs.isEmpty {
            for i in p.instances where changedDefs.contains(i.definitionId) { instanceIds.insert(i.id) }
        }

        // Walls and openings.
        var dirtyLevels: Set<UUID> = []
        var dirtyWalls: Set<UUID> = []
        for c in cs.objects where c.kind == .wall {
            if let w = p.wall(c.id) { dirtyLevels.insert(w.levelId); dirtyWalls.insert(w.id) }
            else if let n = wallNodes[c.id] { dirtyLevels.insert(n.levelId); removeWall(c.id) }
        }
        for c in cs.objects where c.kind == .opening {
            // Read the previous wall first: an opening moved to another wall must rebuild both.
            if let old = openingWall[c.id] { dirtyWalls.insert(old) }
            if let o = p.opening(c.id) { openingWall[o.id] = o.wallId; dirtyWalls.insert(o.wallId) }
            else { openingWall[c.id] = nil }
        }
        for lid in dirtyLevels { syncWalls(levelId: lid, only: nil) }
        let remaining = dirtyWalls.filter { id in
            guard let w = p.wall(id) else { return false }
            return !dirtyLevels.contains(w.levelId)
        }
        for wid in remaining {
            if let w = p.wall(wid) { syncWalls(levelId: w.levelId, only: [wid]) }
        }

        // The draw rank of a room or rug depends on the other ones of its level (RenderLayering), so a changed one re-syncs the
        // unchanged ones too; their signature or move-only path keeps that cheap. Only rooms and flat pieces take part.
        var roomLevels: Set<UUID> = []
        let changedRooms = Set(cs.objects.filter { $0.kind == .room }.map(\.id))
        for id in changedRooms {
            if let r = p.room(id) { roomLevels.insert(r.levelId) }
            if let n = roomNodes[id] { roomLevels.insert(n.levelId) }
        }
        for id in changedRooms { syncRoom(id) }
        if !roomLevels.isEmpty {
            for r in p.rooms where roomLevels.contains(r.levelId) && !changedRooms.contains(r.id) { syncRoom(r.id) }
        }
        // Flat before or after the change, so a rug that stops being flat (or is deleted) also frees its neighbours.
        // Bulk changes run per drag frame: look pieces and definitions up in tables, a linear scan per id would be quadratic.
        var flatLevels: Set<UUID> = []
        let bulk = instanceIds.count > 4
        let bulkInstances = bulk ? Self.instanceTable(p) : nil
        let bulkDefinitions = bulk ? Self.definitionTable(p) : nil
        for id in instanceIds {
            if let n = instNodes[id], let d = bulkDefinitions.map({ $0[n.last.definitionId] }) ?? p.definition(n.last.definitionId),
               CollisionChecker.isFlatOnFloor(n.last, definition: d) {
                flatLevels.insert(n.levelId)
            }
            if let i = bulkInstances.map({ $0[id] }) ?? p.instance(id), let d = bulkDefinitions.map({ $0[i.definitionId] }) ?? p.definition(i.definitionId),
               CollisionChecker.isFlatOnFloor(i, definition: d) {
                flatLevels.insert(i.levelId)
            }
        }
        let table = bulkInstances ?? (flatLevels.isEmpty ? nil : Self.instanceTable(p))
        for id in instanceIds { syncInstance(id, instances: table) }
        if !flatLevels.isEmpty {
            let definitions = bulkDefinitions ?? Self.definitionTable(p)
            for i in p.instances where flatLevels.contains(i.levelId) && !instanceIds.contains(i.id) {
                if let d = definitions[i.definitionId], CollisionChecker.isFlatOnFloor(i, definition: d) { syncInstance(i.id, instances: table) }
            }
        }

        if cs.contains(kind: .group) || !cs.ids(.furniture).isEmpty || !cs.ids(.wall).isEmpty {
            selectedExpanded = expand(model.selection)
        }
        // Objects that now have a different look from their stored state.
        if cs.contains(kind: .group) { refreshSelectionTints() }
        colliding.formIntersection(Set(p.instances.map(\.id)))

        if cs.settingsChanged, p.settings.collisionWarnings != lastCollisionWarnings {
            lastCollisionWarnings = p.settings.collisionWarnings
            applyTints(colliding)
            scheduleCollisions()
        }
        if cs.cameraChanged, p.camera != lastPersisted {
            camera.set(CameraRig(p.camera))
            adoptProjectCamera()
        }
        if !cs.objects.isEmpty {
            placeGround()
            updateGizmo()
            scheduleCollisions()
        }
        if cs.settingsChanged || !cs.objects.isEmpty { applyLighting() }
    }

    // MARK: Model observation

    func observeModel() {
        guard !stopped else { return }
        withObservationTracking {
            _ = model.selection
            _ = model.tool
            _ = model.hoveredId
            _ = model.activeLevelId
            _ = model.frameSelectionRequest
            _ = model.fileURL
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.modelChanged()
                self.observeModel()
            }
        }
    }

    private func modelChanged() {
        refreshSelectionTints()
        if handActive != lastHandActive { handModeDidChange() }
        if measureActive != lastMeasureActive { measureToolDidChange() }
        if model.activeLevelId != lastActiveLevel {
            lastActiveLevel = model.activeLevelId
            if options.onlyActiveLevel { updateLevelVisibility() }
        }
        if model.fileURL != lastFileURL {
            lastFileURL = model.fileURL
            materials.packageURL = model.fileURL
            materials.invalidateTextures()
            meshCache.reset()
            refreshAllMaterials()
            let table = Self.instanceTable(model.project)
            for id in Array(instNodes.keys) { syncInstance(id, force: true, instances: table) }
        }
        if model.frameSelectionRequest != lastFrameRequest {
            lastFrameRequest = model.frameSelectionRequest
            frameSelection()
        }
        updateGizmo()
    }
}
