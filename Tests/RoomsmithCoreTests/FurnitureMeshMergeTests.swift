import Foundation
import simd
import Testing
@testable import RoomsmithCore

// Contract tests of the furniture mesh merge. Expected values are computed independently of the implementation
// (point-wise matrix products, the ellipsoid gradient for normals), not by calling the merge's own helpers.

private func piece(_ shape: PrimitiveShape, _ m: simd_double4x4, mat: UUID? = nil, visible: Bool = true,
                   id: UUID = UUID()) -> FurnitureMeshMerge.Piece {
    FurnitureMeshMerge.Piece(componentId: id, unit: Meshes.unitPrimitive(shape), matrix: m, materialId: mat, visible: visible)
}

private func close(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ eps: Double = 1e-9) -> Bool { simd_length(a - b) < eps }
private func close(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ eps: Double = 1e-6) -> Bool { simd_length(a - b) < eps }

struct FurnitureMeshMergeTests {
    @Test func emptyAndInvisibleInputGiveNothing() {
        #expect(FurnitureMeshMerge.merge(components: []).isEmpty)
        let hidden = [piece(.box, matrix_identity_double4x4, visible: false), piece(.sphere, matrix_identity_double4x4, visible: false)]
        #expect(FurnitureMeshMerge.merge(components: hidden).isEmpty)
        // A piece without triangles creates no group either.
        let bare = FurnitureMeshMerge.Piece(componentId: UUID(), unit: MeshData(), matrix: matrix_identity_double4x4, materialId: nil)
        #expect(FurnitureMeshMerge.merge(components: [bare]).isEmpty)
    }

    @Test func countsAddUpAndIndicesAreOffset() {
        let box = Meshes.unitPrimitive(.box), cyl = Meshes.unitPrimitive(.cylinder), sph = Meshes.unitPrimitive(.sphere)
        let groups = FurnitureMeshMerge.merge(components: [piece(.box, matrix_identity_double4x4), piece(.cylinder, Transform.translation(100, 0, 0)),
                                                          piece(.sphere, Transform.translation(0, 100, 0))])
        #expect(groups.count == 1)
        let m = groups[0].mesh
        #expect(m.positions.count == box.positions.count + cyl.positions.count + sph.positions.count)
        #expect(m.normals.count == m.positions.count && m.uvs.count == m.positions.count)
        #expect(m.indices.count == box.indices.count + cyl.indices.count + sph.indices.count)
        // Each piece's indices are its unit indices shifted by the vertices before it.
        #expect(Array(m.indices[0..<box.indices.count]) == box.indices)
        let cylRange = box.indices.count..<(box.indices.count + cyl.indices.count)
        #expect(Array(m.indices[cylRange]) == cyl.indices.map { $0 + UInt32(box.positions.count) })
        let sphRange = cylRange.upperBound..<m.indices.count
        #expect(Array(m.indices[sphRange]) == sph.indices.map { $0 + UInt32(box.positions.count + cyl.positions.count) })
        #expect(m.indices.allSatisfy { Int($0) < m.positions.count })
        // One part per piece, covering the indices without gaps.
        #expect(m.parts.map(\.indexRange) == [0..<box.indices.count, cylRange, sphRange])
    }

    @Test func translationRotationAndNonUniformScaleMovePositionsAndNormals() {
        // Order of the resolver: translate * rotate (Z 90) * scale (2, 3, 4).
        let m = Transform.translation(100, 200, 300) * Transform.rotationZ(90) * Transform.scale(2, 3, 4)
        let unit = Meshes.unitPrimitive(.box)
        let g = FurnitureMeshMerge.merge(components: [piece(.box, m)])[0].mesh
        #expect(g.positions.count == unit.positions.count)
        for i in 0..<unit.positions.count {
            let u = unit.positions[i]
            // Scale (2,3,4), rotate 90 degrees about Z: (x, y, z) -> (-y, x, z), then translate.
            let expected = SIMD3(100 - 3 * u.y, 200 + 2 * u.x, 300 + 4 * u.z)
            #expect(close(g.positions[i], expected), "vertex \(i)")
            // Box normals are axis aligned: scaling keeps their direction, the rotation turns them.
            let n = unit.normals[i]
            #expect(close(g.normals[i], SIMD3(-n.y, n.x, n.z)), "normal \(i)")
            #expect(abs(simd_length(g.normals[i]) - 1) < 1e-9)
        }
    }

    @Test func normalsOfAnEllipsoidFollowTheInverseTranspose() {
        // Sphere scaled (2, 1, 0.5), tilted about X and Y, moved. For an ellipsoid the surface normal at a point q (relative
        // to the centre, in the ellipsoid's own axes) is proportional to (qx/a^2, qy/b^2, qz/c^2).
        let (a, b, c) = (2.0, 1.0, 0.5)
        let rot = Transform.rotation(R3(30, 20, 0))
        let m = Transform.translation(-50, 70, 10) * rot * Transform.scale(a, b, c)
        let g = FurnitureMeshMerge.merge(components: [piece(.sphere, m)])[0].mesh
        let rotInverse = rot.inverse
        for i in stride(from: 0, to: g.positions.count, by: 7) {
            let world = g.positions[i]
            let q4 = rotInverse * SIMD4(world.x + 50, world.y - 70, world.z - 10, 1)
            let q = SIMD3(q4.x, q4.y, q4.z)
            let localNormal = simd_normalize(SIMD3(q.x / (a * a), q.y / (b * b), q.z / (c * c)))
            let n4 = rot * SIMD4(localNormal.x, localNormal.y, localNormal.z, 0)
            let expected = SIMD3(n4.x, n4.y, n4.z)
            #expect(close(g.normals[i], expected, 1e-6), "vertex \(i)")
            #expect(abs(simd_length(g.normals[i]) - 1) < 1e-9)
        }
    }

    @Test func uvsAreMillimetresWithTheGrainAlongTheLongerSide() {
        // A board 1200 wide, 600 deep, 50 high at x 500: every face spans its real size in mm.
        let m = Transform.translation(500, 0, 0) * Transform.scale(1200, 600, 50)
        let g = FurnitureMeshMerge.merge(components: [piece(.box, m)])[0].mesh
        for i in g.positions.indices {
            let n = g.normals[i], q = g.positions[i], uv = g.uvs[i]
            if abs(n.z) > 0.9 {        // top/bottom: u across (y), v along the 1200 mm length (x)
                #expect(close(uv, SIMD2(q.y, q.x)), "top \(i)")
            } else if abs(n.y) > 0.9 { // front/back: 1200 x 50 face, v along x
                #expect(close(uv, SIMD2(q.z, q.x)), "front \(i)")
            } else {                   // ends: 600 x 50 face, v along y
                #expect(close(uv, SIMD2(q.z, q.y)), "end \(i)")
            }
        }
        // An upright leg gets its v (the grain) along the height.
        let leg = FurnitureMeshMerge.merge(components: [piece(.box, Transform.scale(40, 40, 700))])[0].mesh
        for i in leg.positions.indices where abs(leg.normals[i].z) < 0.1 {
            #expect(abs(leg.uvs[i].y - leg.positions[i].z) < 1e-6, "leg \(i)")
        }
    }

    @Test func uvsDoNotDependOnTheUnitMeshOfACurvedPart() {
        let m = Transform.scale(300, 300, 900)
        for shape in [PrimitiveShape.cushion, .cylinder, .sphere, .taper] {
            let g = FurnitureMeshMerge.merge(components: [piece(shape, m)])[0].mesh
            #expect(g.uvs.allSatisfy { $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 451 && abs($0.y) <= 451 }, "\(shape)")
        }
    }

    @Test func groupsFollowMaterialsInFirstSeenOrder() {
        let a = UUID(), b = UUID()
        let ids = (0..<5).map { _ in UUID() }
        let pieces = [piece(.box, matrix_identity_double4x4, mat: a, id: ids[0]),
                      piece(.box, Transform.translation(10, 0, 0), mat: b, id: ids[1]),
                      piece(.cylinder, Transform.translation(20, 0, 0), mat: a, id: ids[2]),
                      piece(.box, Transform.translation(30, 0, 0), mat: nil, id: ids[3]),
                      piece(.sphere, Transform.translation(40, 0, 0), mat: b, visible: false, id: ids[4])]
        let groups = FurnitureMeshMerge.merge(components: pieces)
        #expect(groups.map(\.materialId) == [a, b, nil])
        let box = Meshes.unitPrimitive(.box), cyl = Meshes.unitPrimitive(.cylinder)
        #expect(groups[0].mesh.positions.count == box.positions.count + cyl.positions.count)
        #expect(groups[1].mesh.positions.count == box.positions.count)   // the invisible sphere is not merged
        #expect(groups[2].mesh.positions.count == box.positions.count)
        #expect(groups[0].mesh.parts.map(\.role) == [.component(ids[0]), .component(ids[2])])
        // Pieces keep their input order inside a group: the box at x = 0 comes first, the cylinder follows it.
        let firstXs = groups[0].mesh.positions.prefix(box.positions.count).map(\.x)
        #expect(firstXs.max()! <= 0.5 + 1e-9)
        let secondXs = groups[0].mesh.positions.suffix(cyl.positions.count).map(\.x)
        #expect(secondXs.min()! >= 20 - 0.5 - 1e-9)
    }

    @Test func zeroSizedComponentKeepsFiniteNormals() {
        let g = FurnitureMeshMerge.merge(components: [piece(.box, Transform.scale(100, 0, 100))])[0].mesh
        #expect(g.normals.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        #expect(g.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
    }

    @Test func mergedPiecesMatchTheResolverMatrices() {
        // Same numbers the 3D view feeds in: the instance-local component matrix of a resolved definition.
        let body = Component(name: "body", shape: .box, position: P3(0, 0, 400), size: Size3(800, 400, 800))
        var door = Component(name: "door", shape: .box, position: P3(0, -200, 400), size: Size3(800, 20, 700), rotation: R3(0, 0, 40),
                             pivot: P3(-400, -200, 400))
        door.visible = true
        let def = FurnitureDefinition(name: "Cabinet", category: "t", size: Size3(800, 400, 800), components: [body, door])
        let inst = FurnitureInstance(definitionId: def.id, levelId: UUID(), name: "c", position: P3(0, 0, 0))
        let unit = Meshes.unitPrimitive(.box)
        let pieces = def.components.map { c in
            FurnitureMeshMerge.Piece(componentId: c.id, unit: unit,
                                     matrix: FurnitureResolver.componentMatrix(position: c.position, size: c.size, rotation: c.rotation, pivot: c.pivot),
                                     materialId: nil)
        }
        let merged = FurnitureMeshMerge.merge(components: pieces)[0].mesh
        // The resolver's world matrix with an identity instance transform must give the same points.
        let resolved = FurnitureResolver.resolve(inst, definition: def)
        var expected: [SIMD3<Double>] = []
        for rc in resolved { for u in unit.positions { let q = rc.worldMatrix * SIMD4(u, 1); expected.append(SIMD3(q.x, q.y, q.z)) } }
        #expect(merged.positions.count == expected.count)
        for (p, e) in zip(merged.positions, expected) { #expect(close(p, e, 1e-6)) }
    }
}

struct FurniturePartitionTests {
    private let opaque = UUID(), glass = UUID(), other = UUID()
    private func isGlass(_ id: UUID?) -> Bool { id == glass }

    private func definition() -> (FurnitureDefinition, [UUID]) {
        let a = Component(name: "a", shape: .box, position: P3(0, 0, 0), size: Size3(100, 100, 100), materialId: opaque)
        let b = Component(name: "b", shape: .box, position: P3(0, 0, 0), size: Size3(100, 100, 100), materialId: glass)
        let m = Component(name: "mesh", shape: .mesh, position: P3(0, 0, 0), size: Size3(100, 100, 100))
        var c = Component(name: "c", shape: .cylinder, position: P3(0, 0, 0), size: Size3(100, 100, 100))
        c.visible = false
        let d = Component(name: "d", shape: .sphere, position: P3(0, 0, 0), size: Size3(100, 100, 100))
        let def = FurnitureDefinition(name: "t", category: "t", size: Size3(100, 100, 100), components: [a, b, m, c, d])
        return (def, def.components.map(\.id))
    }

    @Test func classesFollowTheResolvedMaterialAndSkipMeshAndInvisible() {
        let (def, ids) = definition()
        let inst = FurnitureInstance(definitionId: def.id, levelId: UUID(), name: "i", position: P3(0, 0, 0))
        let p = FurnitureMeshMerge.partition(of: inst, definition: def, separate: isGlass)
        #expect(p.map(\.componentId) == [ids[0], ids[1], ids[4]])   // mesh and invisible component are not listed
        #expect(p.map(\.separate) == [false, true, false])
        #expect(p.map(\.materialId) == [opaque, glass, nil])
    }

    @Test func overridesDecideTheClassAndTheKey() {
        let (def, ids) = definition()
        var plain = FurnitureInstance(definitionId: def.id, levelId: UUID(), name: "i", position: P3(0, 0, 0))
        var glassy = plain
        glassy.materialOverrides[ids[0]] = glass
        plain.materialOverrides[ids[1]] = other   // the glass part becomes opaque
        let pp = FurnitureMeshMerge.partition(of: plain, definition: def, separate: isGlass)
        let pg = FurnitureMeshMerge.partition(of: glassy, definition: def, separate: isGlass)
        #expect(pp.map(\.separate) == [false, false, false])
        #expect(pg.map(\.separate) == [true, true, false])
        #expect(pp != pg)   // different split, so no shared mesh
    }

    @Test func statePoseVisibilityAndHiddenInstanceChangeThePartition() {
        let (base, ids) = definition()
        var def = base
        let state = FurnitureState(name: "open", poses: [ids[3]: ComponentPose(visible: true), ids[0]: ComponentPose(visible: false)])
        def.states = [state]
        var inst = FurnitureInstance(definitionId: def.id, levelId: UUID(), name: "i", position: P3(0, 0, 0))
        inst.stateId = state.id
        let p = FurnitureMeshMerge.partition(of: inst, definition: def, separate: isGlass)
        #expect(p.map(\.componentId) == [ids[1], ids[3], ids[4]])
        inst.visible = false
        #expect(FurnitureMeshMerge.partition(of: inst, definition: def, separate: isGlass).isEmpty)
    }
}
