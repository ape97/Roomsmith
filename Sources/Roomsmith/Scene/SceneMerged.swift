import AppKit
import Foundation
import RealityKit
import RoomsmithCore
import simd

/// The merged meshes of furniture, shared between instances. A piece draws all its opaque primitive components as one
/// entity with one mesh part per material (`FurnitureMeshMerge`); instances with an equal key share the `MeshResource`.
///
/// The key is the definition, its revision, the state and the partition (which component is merged with which resolved
/// material, which stays separate). The instance size is not in it: it is the root scale, the mesh lives in definition
/// space. Entries of a definition are dropped as soon as a newer revision shows up.
@MainActor
final class MergedMeshCache {
    struct Key: Hashable {
        var definitionId: UUID
        var rev: Int64
        var stateId: UUID?
        var partition: [FurnitureMeshMerge.Entry]
    }

    struct Value {
        let mesh: MeshResource
        /// Material of each mesh part, in part order (first appearance in the definition).
        let materialIds: [UUID?]
    }

    private struct PerDefinition {
        var rev: Int64
        var order: [Key] = []
        var values: [Key: Value] = [:]
    }

    /// Variants of one definition kept at once (states times material overrides times option picks); the oldest go first.
    static let perDefinitionLimit = 32

    private var byDefinition: [UUID: PerDefinition] = [:]
    private var units: [PrimitiveShape: MeshData] = [:]
    /// Meshes built since start (cache misses); the tests and the perf log read it.
    private(set) var builds = 0

    func reset() { byDefinition.removeAll() }

    func value(for key: Key, definition def: FurnitureDefinition) -> Value? {
        var entry = byDefinition[key.definitionId]
        if entry?.rev != key.rev { entry = PerDefinition(rev: key.rev) }
        if let v = entry?.values[key] { return v }
        guard var e = entry, let v = build(key, def) else { return nil }
        builds += 1
        e.order.append(key)
        e.values[key] = v
        while e.order.count > Self.perDefinitionLimit { e.values[e.order.removeFirst()] = nil }
        byDefinition[key.definitionId] = e
        return v
    }

    private func unit(_ shape: PrimitiveShape, size: Size3) -> MeshData {
        // The rounded box depends on the part's size; the merged result is cached per definition anyway.
        if shape == .rounded { return Meshes.unitPrimitive(shape, size: size) }
        if let u = units[shape] { return u }
        let u = Meshes.unitPrimitive(shape)
        units[shape] = u
        return u
    }

    private func build(_ key: Key, _ def: FurnitureDefinition) -> Value? {
        let state = key.stateId.flatMap { sid in def.states.first { $0.id == sid } }
        let merged = Dictionary(key.partition.filter { !$0.separate }.map { ($0.componentId, $0) }, uniquingKeysWith: { a, _ in a })
        var pieces: [FurnitureMeshMerge.Piece] = []
        for c in def.components where c.shape != .mesh {
            guard let e = merged[c.id] else { continue }
            let p = FurnitureResolver.pose(of: c, state: state)
            let m = FurnitureResolver.componentMatrix(position: p.position, size: p.size, rotation: p.rotation, pivot: c.pivot)
            pieces.append(FurnitureMeshMerge.Piece(componentId: c.id, unit: unit(c.shape, size: p.size), matrix: m, materialId: e.materialId))
        }
        let groups = FurnitureMeshMerge.merge(components: pieces)
        guard !groups.isEmpty else { return nil }
        var descriptors: [MeshDescriptor] = []
        for g in groups {
            var d = MeshDescriptor(name: "merged\(descriptors.count)")
            d.positions = MeshBuffers.Positions(g.mesh.positions.map { SIMD3<Float>($0) })
            d.normals = MeshBuffers.Normals(g.mesh.normals.map { SIMD3<Float>($0) })
            d.textureCoordinates = MeshBuffers.TextureCoordinates(g.mesh.uvs.map { SIMD2<Float>($0) })
            d.primitives = .triangles(g.mesh.indices)
            d.materials = .allFaces(UInt32(descriptors.count))
            descriptors.append(d)
        }
        guard let mesh = try? MeshResource.generate(from: descriptors) else { return nil }
        return Value(mesh: mesh, materialIds: groups.map(\.materialId))
    }
}

extension SceneRenderer {
    /// Classification of the visible primitive components of an instance from the document as it is now. Transparency
    /// comes from the material's own opacity, so a highlight tint never changes it.
    func furniturePartition(_ inst: FurnitureInstance, _ def: FurnitureDefinition, project p: Project) -> [FurnitureMeshMerge.Entry] {
        var memo: [UUID?: Bool] = [:]
        return FurnitureMeshMerge.partition(of: inst, definition: def) { id in
            if let known = memo[id] { return known }
            let separate = SceneMaterials.isTransparent(opacity: SceneMaterials.baseOpacity(ofMaterial: id, project: p))
            memo[id] = separate
            return separate
        }
    }

    /// Puts the merged entity of `partition` on the node (reusing it when the mesh is unchanged). False when the mesh could
    /// not be made; the caller then draws the piece in parts form so nothing disappears.
    func syncMerged(_ node: InstNode, inst: FurnitureInstance, def: FurnitureDefinition, partition: [FurnitureMeshMerge.Entry]) -> Bool {
        guard partition.contains(where: { !$0.separate }) else {
            dropMerged(node)
            return true
        }
        let key = MergedMeshCache.Key(definitionId: def.id, rev: def.rev, stateId: inst.stateId, partition: partition)
        if let m = node.merged, m.cacheKey == key { return true }
        guard let v = mergedMeshes.value(for: key, definition: def) else {
            dropMerged(node)
            return false
        }
        let keys = v.materialIds.map { MatKey.of($0, .componentDefault) }
        if let m = node.merged {
            m.entity.model = ModelComponent(mesh: v.mesh, materials: [])
            m.cacheKey = key
            m.keys = keys
            m.tint = nil
        } else {
            let e = ModelEntity(mesh: v.mesh, materials: [])
            e.name = "merged"
            node.root.addChild(e)
            node.merged = MergedPart(entity: e, cacheKey: key, keys: keys)
        }
        return true
    }

    func dropMerged(_ node: InstNode) {
        node.merged?.entity.removeFromParent()
        node.merged = nil
    }

    /// Re-skins one instance after a document material changed. When a component crosses the opaque/transparent line the
    /// piece is rebuilt (the part leaves or joins the merge); otherwise only the materials are swapped. "Before" is the
    /// partition stored on the node, because the document already holds the new material.
    func reskinInstance(_ id: UUID, project p: Project, instances: [UUID: FurnitureInstance]) {
        guard let n = instNodes[id] else { return }
        if animations[id] == nil, let inst = instances[id], let def = p.definition(inst.definitionId),
           furniturePartition(inst, def, project: p) != n.partition {
            syncInstance(id, force: true, instances: instances)
        }
        applyInstanceMaterials(id, force: true)
    }

    static func instanceTable(_ p: Project) -> [UUID: FurnitureInstance] {
        Dictionary(p.instances.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    static func definitionTable(_ p: Project) -> [UUID: FurnitureDefinition] {
        Dictionary(p.definitions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }
}
