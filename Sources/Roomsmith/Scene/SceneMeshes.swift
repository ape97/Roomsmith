import AppKit
import Foundation
import RealityKit
import RoomsmithCore
import simd

/// The one place that maps document space to RealityKit space.
///
/// Document space: millimetres, X east, Y north, Z up. Everything below `SceneRenderer.contentRoot` stays in that
/// space (as Float); the root carries a uniform scale of 0.001 and a rotation of -90 degrees about X, which maps
/// (x, y, z) mm to (x, z, -y) / 1000 m. Lights, camera and gizmo live outside the root, in RealityKit metres.
enum SceneCoords {
    /// Model point in mm to RealityKit world metres.
    static func world(_ p: SIMD3<Double>) -> SIMD3<Float> {
        SIMD3(Float(p.x / 1000), Float(p.z / 1000), Float(-p.y / 1000))
    }
    /// Model direction (no scale) to RealityKit world direction.
    static func worldDirection(_ d: SIMD3<Double>) -> SIMD3<Float> {
        SIMD3(Float(d.x), Float(d.z), Float(-d.y))
    }
    /// RealityKit world metres to model mm.
    static func model(_ w: SIMD3<Float>) -> SIMD3<Double> {
        SIMD3(Double(w.x) * 1000, Double(-w.z) * 1000, Double(w.y) * 1000)
    }
    @MainActor static func apply(to root: Entity) {
        root.scale = SIMD3(repeating: 0.001)
        root.orientation = simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0))
    }
}

extension simd_float4x4 {
    init(_ m: simd_double4x4) {
        self.init(SIMD4<Float>(m.columns.0), SIMD4<Float>(m.columns.1), SIMD4<Float>(m.columns.2), SIMD4<Float>(m.columns.3))
    }
}

/// Converts renderer-independent meshes into RealityKit resources.
@MainActor
enum SceneMeshes {
    /// One `MeshResource` with one part per slot (parts of the same slot are merged). `used[k]` is the slot of part k,
    /// so the model's material array is `used.map(materialForSlot)`. UVs are divided by `tile(slot)` (mm per tile).
    static func resource(from data: MeshData, slotOf: (MeshRole) -> Int, tile: (Int) -> Double) -> (mesh: MeshResource, used: [Int])? {
        guard !data.isEmpty else { return nil }
        var bySlot: [Int: [Range<Int>]] = [:]
        for part in data.parts { bySlot[slotOf(part.role), default: []].append(part.indexRange) }
        var descriptors: [MeshDescriptor] = []
        var used: [Int] = []
        for slot in bySlot.keys.sorted() {
            var remap = [UInt32](repeating: .max, count: data.positions.count)
            var pos: [SIMD3<Float>] = [], nor: [SIMD3<Float>] = [], uv: [SIMD2<Float>] = [], idx: [UInt32] = []
            let inv = 1 / max(tile(slot), 1)
            for r in bySlot[slot]! {
                for i in r {
                    let v = Int(data.indices[i])
                    var m = remap[v]
                    if m == .max {
                        m = UInt32(pos.count)
                        remap[v] = m
                        pos.append(SIMD3<Float>(data.positions[v]))
                        nor.append(SIMD3<Float>(data.normals[v]))
                        uv.append(SIMD2<Float>(data.uvs[v] * inv))
                    }
                    idx.append(m)
                }
            }
            guard !idx.isEmpty else { continue }
            var d = MeshDescriptor(name: "part\(slot)")
            d.positions = MeshBuffers.Positions(pos)
            d.normals = MeshBuffers.Normals(nor)
            d.textureCoordinates = MeshBuffers.TextureCoordinates(uv)
            d.primitives = .triangles(idx)
            d.materials = .allFaces(UInt32(descriptors.count))
            descriptors.append(d)
            used.append(slot)
        }
        guard !descriptors.isEmpty, let mesh = try? MeshResource.generate(from: descriptors) else { return nil }
        return (mesh, used)
    }

    private static var unitCache: [PrimitiveShape: MeshResource] = [:]

    /// Shared unit primitive (spans -0.5...0.5, scaled by the component transform). One resource per shape serves all
    /// objects; the cushion's corner radius is therefore fixed in unit space (same as the OBJ export).
    static func unit(_ shape: PrimitiveShape, size: Size3) -> MeshResource {
        if shape == .rounded { return rounded(size) }
        if let m = unitCache[shape] { return m }
        let data = Meshes.unitPrimitive(shape)
        let mesh = resource(from: data, slotOf: { _ in 0 }, tile: { _ in 1 })?.mesh ?? MeshResource.generateBox(size: 1)
        unitCache[shape] = mesh
        return mesh
    }

    private static var roundedCache: [Size3: MeshResource] = [:]

    /// The rounded box depends on the part's size (one mm radius on every edge); kept per size, bounded.
    private static func rounded(_ size: Size3) -> MeshResource {
        if let m = roundedCache[size] { return m }
        let data = Meshes.unitPrimitive(.rounded, size: size)
        let mesh = resource(from: data, slotOf: { _ in 0 }, tile: { _ in 1 })?.mesh ?? MeshResource.generateBox(size: 1)
        if roundedCache.count >= 256 { roundedCache.removeAll() }
        roundedCache[size] = mesh
        return mesh
    }

    struct PartKey: Hashable {
        var shape: PrimitiveShape
        var size: Size3
        /// The part's translation in definition space, whole mm.
        var offset: SIMD3<Int64>
    }

    private static var partCache: [PartKey: MeshResource] = [:]

    /// Unit body of one furniture part with the same millimetre UVs the merged mesh gives it
    /// (`FurnitureMeshMerge.surfaceUV`), so a pattern does not jump when a piece switches between merged and parts form.
    static func part(_ key: PartKey) -> MeshResource {
        if let m = partCache[key] { return m }
        var data = Meshes.unitPrimitive(key.shape, size: key.size)
        let s = SIMD3(Double(key.size.width), Double(key.size.depth), Double(key.size.height))
        let o = SIMD3<Double>(key.offset)
        for i in data.positions.indices {
            let n = data.normals.indices.contains(i) ? data.normals[i] : SIMD3(0, 0, 1)
            data.uvs[i] = FurnitureMeshMerge.surfaceUV(position: data.positions[i], normal: n, scale: s, offset: o)
        }
        let mesh = resource(from: data, slotOf: { _ in 0 }, tile: { _ in 1 })?.mesh ?? MeshResource.generateBox(size: 1)
        if partCache.count >= 512 { partCache.removeAll() }
        partCache[key] = mesh
        return mesh
    }

    /// Torus around +Z (document space or gizmo space), used for the rotation ring.
    static func torus(radius: Float, tube: Float, radial: Int = 72, sides: Int = 10) -> MeshResource? {
        var pos: [SIMD3<Float>] = [], nor: [SIMD3<Float>] = [], idx: [UInt32] = []
        for i in 0...radial {
            let a = Float(i) / Float(radial) * 2 * .pi
            let c = SIMD3<Float>(cos(a), sin(a), 0)
            for j in 0..<sides {
                let b = Float(j) / Float(sides) * 2 * .pi
                let n = c * cos(b) + SIMD3<Float>(0, 0, sin(b))
                pos.append(c * radius + n * tube)
                nor.append(n)
            }
        }
        for i in 0..<radial {
            for j in 0..<sides {
                let a = UInt32(i * sides + j), b = UInt32(i * sides + (j + 1) % sides)
                let c = UInt32((i + 1) * sides + j), d = UInt32((i + 1) * sides + (j + 1) % sides)
                idx += [a, c, b, b, c, d]
            }
        }
        var desc = MeshDescriptor(name: "ring")
        desc.positions = MeshBuffers.Positions(pos)
        desc.normals = MeshBuffers.Normals(nor)
        desc.primitives = .triangles(idx)
        return try? MeshResource.generate(from: [desc])
    }
}
