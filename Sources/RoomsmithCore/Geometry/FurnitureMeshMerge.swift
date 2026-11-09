import Foundation
import simd

/// Merges the primitive components of one piece of furniture into one mesh per material, so the 3D view draws a piece
/// with a few entities instead of one per component. Pure geometry: no RealityKit, no document lookups.
///
/// Every piece brings its unit body (`Meshes.unitPrimitive`, spanning -0.5...0.5) and its local component matrix
/// (`FurnitureResolver.componentMatrix`: unit body to definition space, not the world matrix). Positions go through the
/// matrix, normals through the inverse transpose of its upper 3x3 (renormalised, so non-uniform scale stays correct),
/// UVs are millimetres of the part's own surface (`surfaceUV`), so a pattern or texture keeps its real-world size on every
/// part; the renderer divides them by the material's texture tile.
public enum FurnitureMeshMerge {
    /// One component to merge.
    public struct Piece: Sendable {
        public var componentId: UUID
        public var unit: MeshData
        public var matrix: simd_double4x4
        /// Material of the component (nil = the default material). Pieces with the same id end up in one group.
        public var materialId: UUID?
        public var visible: Bool

        public init(componentId: UUID, unit: MeshData, matrix: simd_double4x4, materialId: UUID?, visible: Bool = true) {
            self.componentId = componentId; self.unit = unit; self.matrix = matrix
            self.materialId = materialId; self.visible = visible
        }
    }

    /// The merged geometry of all pieces that share a material. `mesh.parts` lists one part per piece
    /// (`.component(id)`), in input order.
    public struct Group: Sendable {
        public var materialId: UUID?
        public var mesh: MeshData
    }

    /// Groups by material in order of first appearance; pieces keep their input order inside a group. Invisible pieces
    /// and pieces without triangles are skipped, and a group is only returned when it has triangles.
    public static func merge(components: [Piece]) -> [Group] {
        var order: [UUID?] = []
        var groups: [UUID?: MeshData] = [:]
        for piece in components where piece.visible && !piece.unit.indices.isEmpty {
            let unit = piece.unit
            let m = piece.matrix
            let normalMatrix = normalTransform(m)
            let scale = SIMD3(simd_length(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z)),
                              simd_length(SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z)),
                              simd_length(SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)))
            let offset = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
            if groups[piece.materialId] == nil {
                order.append(piece.materialId)
                groups[piece.materialId] = MeshData()
            }
            var mesh = groups[piece.materialId]!
            let base = UInt32(mesh.positions.count)
            let firstIndex = mesh.indices.count
            mesh.positions.reserveCapacity(mesh.positions.count + unit.positions.count)
            for i in 0..<unit.positions.count {
                let q = m * SIMD4(unit.positions[i], 1)
                mesh.positions.append(SIMD3(q.x, q.y, q.z))
                let n = unit.normals.indices.contains(i) ? unit.normals[i] : SIMD3(0, 0, 1)
                mesh.normals.append(transformedNormal(n, by: normalMatrix))
                mesh.uvs.append(surfaceUV(position: unit.positions[i], normal: n, scale: scale, offset: offset))
            }
            mesh.indices.append(contentsOf: unit.indices.map { $0 + base })
            mesh.parts.append(MeshPart(role: .component(piece.componentId), indexRange: firstIndex..<mesh.indices.count))
            groups[piece.materialId] = mesh
        }
        return order.map { Group(materialId: $0, mesh: groups[$0]!) }
    }

    /// Box-projected UV in mm of one vertex: the face is picked by the dominant axis of the part's own normal, its two
    /// other axes give u and v, and v runs along the longer side of the part on that face. Wood grain (which follows v)
    /// therefore runs along a leg, a shelf board or a table top, and a door shows upright grain. `offset` (the part's
    /// position) keeps the pattern continuous across neighbouring unrotated parts. `normal` is the unit body's normal;
    /// dividing it by the scale gives the direction in the part's millimetre space.
    public static func surfaceUV(position p: SIMD3<Double>, normal n: SIMD3<Double>, scale s: SIMD3<Double>,
                                 offset: SIMD3<Double>) -> SIMD2<Double> {
        let safe = simd_max(s, SIMD3(repeating: 1e-9))
        let d = simd_abs(n / safe)
        let a = d.x >= d.y && d.x >= d.z ? 0 : (d.y >= d.z ? 1 : 2)
        var b = (a + 1) % 3, c = (a + 2) % 3
        if s[b] > s[c] { swap(&b, &c) }
        let q = p * s + offset
        return SIMD2(q[b], q[c])
    }

    /// Inverse transpose of the upper 3x3; for a singular matrix (a component with a zero size) the matrix itself,
    /// so normals stay finite.
    private static func normalTransform(_ m: simd_double4x4) -> simd_double3x3 {
        let l3 = simd_double3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                                SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                                SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        let det = simd_determinant(l3)
        guard det.isFinite, abs(det) > 1e-12 else { return l3 }
        return simd_inverse(l3).transpose
    }

    private static func transformedNormal(_ n: SIMD3<Double>, by nm: simd_double3x3) -> SIMD3<Double> {
        let t = nm * n
        let len = simd_length(t)
        return len > 1e-12 && len.isFinite ? t / len : n
    }

    // MARK: - Partition

    /// One visible primitive component of an instance and how the 3D view draws it: merged into the piece's mesh, or as
    /// its own entity (transparent material, so it keeps its own depth sorting).
    public struct Entry: Hashable, Sendable {
        public var componentId: UUID
        /// The material the instance actually uses: `materialOverrides[id] ?? option material ?? component.materialId`.
        public var materialId: UUID?
        public var separate: Bool
        public init(componentId: UUID, materialId: UUID?, separate: Bool) {
            self.componentId = componentId; self.materialId = materialId; self.separate = separate
        }
    }

    /// The visible primitive components of an instance in definition order. `.mesh` components are not part of it (they
    /// always stay their own entities); invisible ones are skipped. `separate(materialId)` says whether a material is
    /// transparent; it must look at the material's own opacity only, never at a highlight tint.
    public static func partition(of inst: FurnitureInstance, definition def: FurnitureDefinition,
                                 separate: (UUID?) -> Bool) -> [Entry] {
        let state = inst.stateId.flatMap { sid in def.states.first { $0.id == sid } }
        let options = FurnitureResolver.optionOutcome(of: inst, definition: def)
        var out: [Entry] = []
        for c in def.components where c.shape != .mesh {
            guard FurnitureResolver.pose(of: c, state: state).visible && inst.visible && !options.hidden.contains(c.id) else { continue }
            let mat = FurnitureResolver.materialId(of: c, inst: inst, options: options)
            out.append(Entry(componentId: c.id, materialId: mat, separate: separate(mat)))
        }
        return out
    }
}
