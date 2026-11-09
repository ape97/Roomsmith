import AppKit
import Foundation
import RealityKit
import RoomsmithCore
import Testing
@testable import Roomsmith

/// A collision tint only recolours; it never changes opacity or blending, and the way back draws the original image.
@MainActor
struct CollisionTintTests {
    @Test func collisionKeepsOpaqueBlending() throws {
        let materials = SceneMaterials()
        let p = AppModel.starterProject()
        for tint in [SceneTint.none, .hover, .selected, .collision] {
            let m = try #require(materials.material(.componentDefault, tint: tint, project: p) as? PhysicallyBasedMaterial)
            guard case .opaque = m.blending else {
                Issue.record("blending of \(tint) is not opaque")
                continue
            }
        }
    }

    @Test func highlightedMeshMaterialKeepsOpaqueBlending() {
        let m = PhysicallyBasedMaterial()
        let h = SceneMaterials.highlighted(m, tint: .collision)
        guard let pbr = h as? PhysicallyBasedMaterial, case .opaque = pbr.blending else {
            Issue.record("collision highlight made the mesh material non-opaque")
            return
        }
    }

    /// Procedural furniture: one opaque part (drawn merged) and one transparent part (own entity).
    private func project() throws -> (AppModel, UUID) {
        let model = AppModel()
        var instId: UUID?
        model.perform("Collision tint fixture") { p in
            let glass = p.addMaterial(Material(name: "Smoke", color: RGBColor(60, 60, 70), opacity: 0.5))
            let body = Component(name: "Body", shape: .box, position: P3(0, 0, 375), size: Size3(1200, 600, 750))
            let top = Component(name: "Shelf", shape: .box, position: P3(0, 0, 800), size: Size3(1200, 600, 50), materialId: glass)
            let def = FurnitureDefinition(name: "Cabinet", category: "Test", size: Size3(1200, 600, 850), components: [body, top])
            _ = p.addDefinition(def)
            instId = try p.addInstance(definitionId: def.id, levelId: model.activeLevelId, position: P3(0, 0, 0))
        }
        return (model, try #require(instId))
    }

    @Test func proceduralRenderedImageIsTheSameAfterCollisionOnAndOff() async throws {
        let (model, id) = try project()
        let cam = CameraState(mode: .orbit, target: P3(0, 0, 400), distance: 3000, yawDeg: 30, pitchDeg: -25)
        let session = try await OffscreenSceneSession(model: model, size: CGSize(width: 400, height: 300), dark: false)
        defer { session.teardown() }
        _ = try await session.image(camera: cam)
        let a = try await session.image(camera: cam)
        let control = try await session.image(camera: cam)   // unchanged scene: the render noise floor (measured 0.0)
        session.scene.colliding = [id]
        session.scene.applyTints([id])
        _ = try await session.image(camera: cam)
        let b = try await session.image(camera: cam)
        session.scene.colliding = []
        session.scene.applyTints([id])
        _ = try await session.image(camera: cam)
        let c = try await session.image(camera: cam)
        #expect(diff(a, b) > 0.5)   // the tint is visible, so the comparison below is not vacuous
        // Before the reset fix this was 0.45 (a visible pink remnant) against a noise floor of 0.0; the margin is one level in 100 pixels.
        #expect(diff(a, c) <= diff(a, control) + 0.01)
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
