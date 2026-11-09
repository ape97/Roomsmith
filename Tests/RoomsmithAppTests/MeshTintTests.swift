import AppKit
import Foundation
import RealityKit
import RoomsmithCore
import Testing
@testable import Roomsmith

/// Three boxes with three different materials (black steel, oak, greige fabric), like the dining table and chair imports.
private let multiMaterialUSDA = """
#usda 1.0
(
    defaultPrim = "Root"
    metersPerUnit = 1
    upAxis = "Y"
)

def Xform "Root"
{
    def Scope "Materials"
    {
        def Material "steel"
        {
            token outputs:surface.connect = </Root/Materials/steel/Surface.outputs:surface>
            def Shader "Surface"
            {
                uniform token info:id = "UsdPreviewSurface"
                color3f inputs:diffuseColor = (0.06, 0.06, 0.06)
                float inputs:roughness = 0.6
                token outputs:surface
            }
        }
        def Material "oak"
        {
            token outputs:surface.connect = </Root/Materials/oak/Surface.outputs:surface>
            def Shader "Surface"
            {
                uniform token info:id = "UsdPreviewSurface"
                color3f inputs:diffuseColor = (0.7, 0.5, 0.3)
                float inputs:roughness = 0.8
                token outputs:surface
            }
        }
        def Material "fabric"
        {
            token outputs:surface.connect = </Root/Materials/fabric/Surface.outputs:surface>
            def Shader "Surface"
            {
                uniform token info:id = "UsdPreviewSurface"
                color3f inputs:diffuseColor = (0.6, 0.55, 0.5)
                float inputs:roughness = 0.9
                token outputs:surface
            }
        }
    }
\(box("steel", x: 0))
\(box("oak", x: 2))
\(box("fabric", x: 4))
}
"""

private func box(_ name: String, x: Double) -> String {
    let p = [(0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 1, 0), (0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1)]
        .map { "(\($0.0 + Int(x)), \($0.1), \($0.2))" }.joined(separator: ", ")
    return """
        def Mesh "\(name)" (prepend apiSchemas = ["MaterialBindingAPI"])
        {
            int[] faceVertexCounts = [4, 4, 4, 4, 4, 4]
            int[] faceVertexIndices = [0, 3, 2, 1, 4, 5, 6, 7, 0, 1, 5, 4, 1, 2, 6, 5, 2, 3, 7, 6, 3, 0, 4, 7]
            point3f[] points = [\(p)]
            rel material:binding = </Root/Materials/\(name)>
            uniform token subdivisionScheme = "none"
        }
    """
}

@MainActor
struct MeshTintTests {
    private func project(into pkg: URL) throws -> (AppModel, UUID) {
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("multi-\(UUID().uuidString).usda")
        try multiMaterialUSDA.write(to: src, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: src) }
        let asset = try ProjectPackage.importAsset(src, kind: .mesh, into: pkg)
        let model = AppModel()
        var instId: UUID?
        model.perform("Import") { p in
            let aid = p.addAsset(asset)
            var part = Component(name: "Model", shape: .mesh, position: P3(0, 0, 375), size: Size3(2000, 800, 750))
            part.meshAssetId = aid
            let def = FurnitureDefinition(name: "Table", category: "Imported", size: Size3(2000, 800, 750), components: [part])
            _ = p.addDefinition(def)
            instId = try p.addInstance(definitionId: def.id, levelId: model.activeLevelId, position: P3(0, 0, 0))
        }
        model.fileURL = pkg
        return (model, try #require(instId))
    }

    /// Base colours of every material of the loaded mesh, in model order.
    private func colours(_ comp: CompNode) -> [SIMD3<Double>] {
        guard let child = comp.meshChild else { return [] }
        return SceneRenderer.modelEntities(in: child).flatMap { e in
            (e.model?.materials ?? []).map { m in
                let c = (m as? PhysicallyBasedMaterial)?.baseColor.tint.usingColorSpace(.sRGB) ?? .black
                return SIMD3(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
            }
        }.sorted { $0.x < $1.x }
    }

    private func meshNode(_ scene: SceneRenderer, _ id: UUID) async throws -> CompNode {
        for _ in 0..<100 {
            if let c = scene.instNodes[id]?.comps.values.first, c.meshChild != nil { return c }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw TestFailure("mesh did not load")
    }

    @Test func hoverKeepsPerMaterialColoursAndClearRestoresThem() async throws {
        let pkg = FileManager.default.temporaryDirectory.appendingPathComponent("tint-\(UUID().uuidString).roomsmith")
        defer { try? FileManager.default.removeItem(at: pkg) }
        let (model, id) = try project(into: pkg)
        let scene = SceneRenderer(model: model, interactive: false)
        scene.materials.packageURL = pkg
        let comp = try await meshNode(scene, id)
        let before = colours(comp)
        #expect(Set(before).count == 3)

        scene.hoveredExpanded = [id]
        scene.applyTints([id])
        let hovered = colours(try #require(scene.instNodes[id]?.comps.values.first))
        #expect(Set(hovered).count == 3)   // still three different colours, not one flat highlight
        #expect(hovered != before)

        scene.hoveredExpanded = []
        scene.applyTints([id])
        #expect(colours(try #require(scene.instNodes[id]?.comps.values.first)) == before)
    }

    /// The values alone are not enough (RealityKit ignored the restored materials): compare what is actually drawn.
    @Test func renderedImageIsTheSameAfterHoverOnAndOff() async throws {
        let pkg = FileManager.default.temporaryDirectory.appendingPathComponent("tint-\(UUID().uuidString).roomsmith")
        defer { try? FileManager.default.removeItem(at: pkg) }
        let (model, id) = try project(into: pkg)
        let cam = CameraState(mode: .orbit, target: P3(0, 0, 375), distance: 3000, yawDeg: 30, pitchDeg: -25)
        let session = try await OffscreenSceneSession(model: model, size: CGSize(width: 400, height: 300), dark: false)
        defer { session.teardown() }
        _ = try await session.image(camera: cam)
        let a = try await session.image(camera: cam)
        model.hoveredId = id
        let b = try await session.image(camera: cam)
        model.hoveredId = nil
        _ = try await session.image(camera: cam)
        let c = try await session.image(camera: cam)
        #expect(diff(a, b) > 0.5)   // the hover is visible, so the comparison below is not vacuous
        #expect(diff(a, c) < 0.5)
    }

    /// A collision tint re-clones the mesh; going back to no tint must draw the original materials again.
    @Test func renderedImageIsTheSameAfterCollisionTintOnAndOff() async throws {
        let pkg = FileManager.default.temporaryDirectory.appendingPathComponent("tint-\(UUID().uuidString).roomsmith")
        defer { try? FileManager.default.removeItem(at: pkg) }
        let (model, id) = try project(into: pkg)
        let cam = CameraState(mode: .orbit, target: P3(0, 0, 375), distance: 3000, yawDeg: 30, pitchDeg: -25)
        let session = try await OffscreenSceneSession(model: model, size: CGSize(width: 400, height: 300), dark: false)
        defer { session.teardown() }
        _ = try await session.image(camera: cam)
        let a = try await session.image(camera: cam)
        session.scene.colliding = [id]
        session.scene.applyTints([id])
        _ = try await session.image(camera: cam)
        let b = try await session.image(camera: cam)
        session.scene.colliding = []
        session.scene.applyTints([id])
        _ = try await session.image(camera: cam)
        let c = try await session.image(camera: cam)
        #expect(diff(a, b) > 0.5)   // the collision tint is visible, so the comparison below is not vacuous
        #expect(diff(a, c) < 0.5)
    }

    private func diff(_ x: CGImage, _ y: CGImage) -> Double {
        func bytes(_ i: CGImage) -> [UInt8] {
            var d = [UInt8](repeating: 0, count: i.width * i.height * 4)
            let ctx = CGContext(data: &d, width: i.width, height: i.height, bitsPerComponent: 8, bytesPerRow: i.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(i, in: CGRect(x: 0, y: 0, width: i.width, height: i.height))
            return d
        }
        let p = bytes(x), q = bytes(y)
        var t = 0.0
        for i in 0..<p.count { t += abs(Double(p[i]) - Double(q[i])) }
        return t / Double(p.count)
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}
