import AppKit
import Foundation
import RealityKit
import RoomsmithCore
import simd

// Entity bookkeeping of the 3D view: one node per document object, so a change touches only its own entities.

/// Everything a wall's mesh depends on. If it is unchanged the wall entity is left alone.
struct WallSignature: Equatable {
    var wall: Wall
    var outline: WallOutline
    var openings: [Opening]
    var elevation: MM
}

struct RoomSignature: Equatable {
    var room: Room
    var elevation: MM
    var levelHeight: MM
    /// Draw-time layering rank (see `RenderLayering`).
    var rank: Int
}

@MainActor
final class FrameNode {
    let entity: ModelEntity
    /// Slot of each material of the mesh (0 frame, 1 glass) and the matching document materials.
    let used: [Int]
    let keys: [MatKey]
    /// The swinging leaf of a door (own part, pivot at the hinge); nil for windows and plain openings.
    var leaf: DoorLeafNode?
    /// The sashes of a movable window (own parts, hinged in the frame); empty for doors, fixed and too small windows.
    var sashes: [SashNode] = []
    init(entity: ModelEntity, used: [Int], keys: [MatKey]) { self.entity = entity; self.used = used; self.keys = keys }
}

/// A door leaf: `pivot` sits at the hinge and turns about Z between the closed and the open yaw (degrees).
@MainActor
final class DoorLeafNode {
    let pivot: Entity
    let model: ModelEntity
    let used: [Int]
    let closedYaw: Double
    let openYaw: Double
    init(pivot: Entity, model: ModelEntity, used: [Int], closedYaw: Double, openYaw: Double) {
        self.pivot = pivot; self.model = model; self.used = used; self.closedYaw = closedYaw; self.openYaw = openYaw
    }
}

/// A window sash. `turnPivot` sits at the hinge edge and turns about Z; its child `tiltPivot` tilts about the sash's own
/// bottom edge (X). The angles are the open poses in degrees, the closed yaw the sash direction along the wall.
@MainActor
final class SashNode {
    let turnPivot: Entity
    let tiltPivot: Entity
    let model: ModelEntity
    let used: [Int]
    let closedYaw: Double
    let turnOpenDeg: Double
    let tiltOpenDeg: Double
    /// Only the sash with the handle tilts.
    let hasHandle: Bool
    init(turnPivot: Entity, tiltPivot: Entity, model: ModelEntity, used: [Int], placement: Meshes.SashPlacement) {
        self.turnPivot = turnPivot; self.tiltPivot = tiltPivot; self.model = model; self.used = used
        closedYaw = placement.closedYawDeg; turnOpenDeg = placement.turnOpenDeg; tiltOpenDeg = placement.tiltOpenDeg
        hasHandle = placement.hasHandle
    }
}

@MainActor
final class WallNode {
    let levelId: UUID
    let entity: ModelEntity
    var signature: WallSignature
    var used: [Int]
    var keys: [MatKey]
    var frames: [UUID: FrameNode] = [:]
    init(levelId: UUID, entity: ModelEntity, signature: WallSignature, used: [Int], keys: [MatKey]) {
        self.levelId = levelId; self.entity = entity; self.signature = signature; self.used = used; self.keys = keys
    }
}

@MainActor
final class RoomNode {
    let levelId: UUID
    var signature: RoomSignature
    var floor: ModelEntity?
    var ceiling: ModelEntity?
    var floorKey: MatKey
    var ceilingKey: MatKey
    init(levelId: UUID, signature: RoomSignature, floorKey: MatKey, ceilingKey: MatKey) {
        self.levelId = levelId; self.signature = signature; self.floorKey = floorKey; self.ceilingKey = ceilingKey
    }
}

@MainActor
final class CompNode {
    let entity: ModelEntity
    var key: MatKey = .componentDefault
    var shape: PrimitiveShape = .box
    /// The part mesh this entity wears (`SceneMeshes.part`); nil for a `.mesh` component, which keeps the unit box.
    var partKey: SceneMeshes.PartKey?
    var meshAssetId: UUID?
    var meshChild: Entity?
    /// Original materials of every model inside the loaded mesh, restored when the highlight tint goes away.
    var meshMaterials: [(ModelEntity, [any RealityKit.Material])] = []
    /// The unit-primitive model while a loaded mesh replaces it (restored when the mesh goes away).
    var boxModel: ModelComponent?
    var local = matrix_identity_double4x4
    var visible = true
    /// An option of the instance hides this part (kept apart from `visible`: animation poses override that one).
    var optionHidden = false
    /// Tint of the materials currently applied (nil = none applied yet).
    var tint: SceneTint?
    init(entity: ModelEntity) { self.entity = entity }
}

/// All opaque primitive components of a piece of furniture as one entity (one mesh part per material).
@MainActor
final class MergedPart {
    let entity: ModelEntity
    /// Cache key of the mesh now on the entity (see `MergedMeshCache`).
    var cacheKey: MergedMeshCache.Key
    /// Material of each mesh part, in part order.
    var keys: [MatKey]
    /// Tint of the materials currently applied (nil = none applied yet).
    var tint: SceneTint?
    init(entity: ModelEntity, cacheKey: MergedMeshCache.Key, keys: [MatKey]) {
        self.entity = entity; self.cacheKey = cacheKey; self.keys = keys
    }
}

@MainActor
final class InstNode {
    let root = Entity()
    var levelId: UUID
    /// Own entities per component. While the piece is merged only `.mesh` components and transparent ones are here; while
    /// it is in parts form (state animation running, or the merge failed) every component is.
    var comps: [UUID: CompNode] = [:]
    /// The merged entity of the opaque primitive components; nil in parts form or when there is nothing to merge.
    var merged: MergedPart?
    /// How the last sync classified the visible primitive components. Material changes compare against this (never against
    /// the document, which has already changed by then) to see whether a component changes class.
    var partition: [FurnitureMeshMerge.Entry] = []
    /// The last sync had at least one component (an empty design has nothing to animate).
    var populated = false
    /// Parts lit by the lamp when the materials were last assigned (`LampGlow`).
    var glow: LampGlow.Glow?
    var last: FurnitureInstance
    var defRev: Int64
    var elevation: MM
    init(levelId: UUID, last: FurnitureInstance, defRev: Int64, elevation: MM) {
        self.levelId = levelId; self.last = last; self.defRev = defRev; self.elevation = elevation
    }
}

/// Loads `.mesh` assets (USDZ) from the project package once per asset and hands out clones.
///
/// Only files inside the package are read (`ProjectPackage.assetURL`); without a saved package the box stays.
@MainActor
final class MeshAssetCache {
    enum State { case loading, loaded(Entity), failed }

    private(set) var states: [UUID: State] = [:]
    var onLoaded: ((UUID) -> Void)?

    /// Bumped by `reset`; a load that started before it belongs to the old package and must not store its result.
    /// `assetEpoch` does the same for one replaced or removed asset.
    private var epoch = 0
    private var assetEpoch: [UUID: Int] = [:]

    func reset() { epoch += 1; states.removeAll() }

    /// Forgets only these assets; a load still running for one of them is discarded when it returns.
    func invalidate(assets ids: Set<UUID>) {
        for id in ids {
            states[id] = nil
            assetEpoch[id, default: 0] += 1
        }
    }

    /// The loaded prototype, or nil while loading, failed, or not loadable (starts loading on first use).
    func prototype(for assetId: UUID, project: Project, packageURL: URL?) -> Entity? {
        if let s = states[assetId] {
            if case .loaded(let e) = s { return e }
            return nil
        }
        guard let package = packageURL, let asset = project.asset(assetId), asset.kind == .mesh else { return nil }
        states[assetId] = .loading
        let url = ProjectPackage.assetURL(asset, in: package)
        let stamp = (epoch, assetEpoch[assetId] ?? 0)
        Task { @MainActor [weak self] in
            do {
                let loaded = try await Entity(contentsOf: url)
                guard let self, self.isCurrent(assetId, stamp) else { return }
                guard let wrapper = Self.fit(loaded) else { self.states[assetId] = .failed; return }
                self.states[assetId] = .loaded(wrapper)
                self.onLoaded?(assetId)
            } catch {
                guard let self, self.isCurrent(assetId, stamp) else { return }
                self.states[assetId] = .failed
            }
        }
        return nil
    }

    private func isCurrent(_ assetId: UUID, _ stamp: (Int, Int)) -> Bool {
        epoch == stamp.0 && (assetEpoch[assetId] ?? 0) == stamp.1
    }

    /// Wraps the model so that its bounds fill the unit box of a component (-0.5...0.5 on x, y, z).
    /// USD is y-up and RealityKit is y-up too, so the model is read as is; the wrapper only turns it into the
    /// component's z-up space: (x, y, z) -> (x, -z, y), then centres and scales each axis to the box.
    static func fit(_ loaded: Entity) -> Entity? {
        let wrapper = Entity()
        wrapper.addChild(loaded)
        let b = loaded.visualBounds(relativeTo: wrapper)
        let e = b.extents
        guard e.x.isFinite, e.y.isFinite, e.z.isFinite, e.x > 0 || e.y > 0 || e.z > 0 else { return nil }
        let ex = max(e.x, 1e-5), ey = max(e.y, 1e-5), ez = max(e.z, 1e-5)
        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4(-b.center, 1)
        let r = simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(1, 0, 0)))
        let s = simd_float4x4(diagonal: SIMD4(1 / ex, 1 / ez, 1 / ey, 1))
        wrapper.transform.matrix = s * r * t
        return wrapper
    }
}
