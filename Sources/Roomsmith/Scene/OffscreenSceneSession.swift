import CoreGraphics
import Foundation
import Metal
import RealityKit
import RoomsmithCore

/// One document's 3D scene kept ready for a series of offscreen pictures (`SceneSnapshot.render` makes a single one).
///
/// Building the scene graph, loading meshes and setting up a `RealityRenderer` costs far more than drawing a frame (about
/// 830 ms against 4.5 ms for a 35-piece flat at 960 x 1080), so a stream of pictures (the presenter's 3D pane) keeps one
/// session: a camera move only draws a frame; a document, level or view-setting change rebuilds the graph (mesh cache
/// kept); another document, file location or asset list also drops the texture and mesh caches (as the 3D view does on
/// `.reset`, asset changes and Save As); the lighting is re-applied when it changed. Size and appearance are fixed; make a new session for others.
/// The renderer does not observe the document: each `image(camera:)` compares what it built against the model.
@MainActor
final class OffscreenSceneSession {
    let width: Int
    let height: Int
    let dark: Bool
    private let model: AppModel
    let scene: SceneRenderer
    private let renderer: RealityRenderer
    private let texture: MTLTexture
    private let output: RealityRenderer.CameraOutput
    private var built: ContentKey
    private var lighting: LightingSettings
    private var closed = false

    /// What the scene graph was built from; a difference means a rebuild.
    private struct ContentKey: Equatable {
        /// The document without camera and revision: moving the camera bumps the revision but needs no rebuild.
        var content: Project
        var activeLevel: UUID?
        var options: SceneOptions
        var source: SourceKey
    }

    /// Where textures and meshes come from; a difference also drops the caches.
    private struct SourceKey: Equatable {
        var projectId: UUID
        var fileURL: URL?
        var assets: [ProjectAsset]
    }

    private static func key(_ model: AppModel) -> ContentKey {
        var content = model.project
        content.camera = .default
        content.revision = 0
        return ContentKey(content: content, activeLevel: model.activeLevelId, options: options(model),
                          source: SourceKey(projectId: model.project.id, fileURL: model.fileURL, assets: model.project.assets))
    }

    /// Builds the scene for `model` and draws it until lights and shaders settled (the first picture is then cheap).
    /// - Throws: `SceneSnapshot.Failure.badSize` outside 16...8192 pixels per side, `.noDevice` without a GPU.
    init(model: AppModel, size: CGSize, dark: Bool) async throws {
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        guard (16...8192).contains(width), (16...8192).contains(height) else { throw SceneSnapshot.Failure.badSize }
        guard let device = MTLCreateSystemDefaultDevice() else { throw SceneSnapshot.Failure.noDevice }
        self.width = width
        self.height = height
        self.dark = dark
        self.model = model

        let scene = SceneRenderer(model: model, interactive: false, camera: model.project.camera)
        scene.camera.viewSize = CGSize(width: width, height: height)
        scene.applyAppearance(dark: dark)
        let key = Self.key(model)
        // Same display settings as the 3D view (ceilings, only active level, wall opacity).
        scene.setOptions(key.options)
        scene.materials.packageURL = model.fileURL
        self.scene = scene
        built = key
        lighting = model.project.settings.lighting

        do {
            renderer = try RealityRenderer()
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead, .shaderWrite]
            desc.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: desc) else { throw SceneSnapshot.Failure.noDevice }
            self.texture = texture
            output = try RealityRenderer.CameraOutput(RealityRenderer.CameraOutput.Descriptor.singleProjection(colorTexture: texture))
        } catch {
            scene.teardown()
            throw error
        }
        renderer.entities.append(scene.worldRoot)
        renderer.activeCamera = scene.cameraEntity
        await applyEnvironment()
        await waitForMeshes()
    }

    /// The picture for `camera` (nil: the document camera, or the fitted aerial view when it was never moved) with the
    /// document as it is now. `openings` are the open poses of doors and windows to show (the live view's, when the
    /// caller has one); nil shows everything closed.
    func image(camera: CameraState?, openings: OpeningMotion? = nil) async throws -> CGImage {
        guard !closed else { throw SceneSnapshot.Failure.renderFailed("the session was closed") }
        // A new session draws a few frames so lights, environment and shaders settle; afterwards a camera move needs one.
        var frames = settled ? 1 : 3
        let now = Self.key(model)
        if now != built {
            if now.source != built.source {
                scene.materials.packageURL = model.fileURL
                scene.materials.invalidateTextures()
                scene.meshCache.reset()
            }
            built = now
            scene.setOptions(now.options)
            scene.fullRebuild()
            await waitForMeshes()
            frames = max(frames, 2)
        }
        if model.project.settings.lighting != lighting {
            lighting = model.project.settings.lighting
            scene.applyLighting()
            await applyEnvironment()
            frames = 3
        }
        // The awaits above may have overlapped a teardown.
        guard !closed else { throw SceneSnapshot.Failure.renderFailed("the session was closed") }
        // Selection and hover tints as a fresh render would draw them.
        scene.refreshSelectionTints()
        // Doors and windows in the given poses; entries that are gone from `openings` go back to closed.
        let wantedOpenings = openings ?? OpeningMotion()
        if wantedOpenings != shownOpenings {
            shownOpenings = wantedOpenings
            scene.walk.adopt(wantedOpenings)
        }
        place(camera)
        for _ in 0..<frames { try await frame() }
        settled = true
        guard let image = SceneSnapshot.cgImage(from: texture) else {
            throw SceneSnapshot.Failure.renderFailed("could not read the pixels")
        }
        return image
    }

    private var settled = false
    private var shownOpenings = OpeningMotion()

    /// Draws one frame into the texture (used for timing).
    func frame() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            do {
                try renderer.updateAndRender(deltaTime: 1.0 / 30.0, cameraOutput: output, onComplete: { _ in
                    cont.resume()
                })
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    /// Releases the scene. The session draws nothing afterwards.
    func teardown() {
        guard !closed else { return }
        closed = true
        renderer.entities.removeAll()
        scene.teardown()
    }

    // MARK: Parts

    private static func options(_ model: AppModel) -> SceneOptions {
        SceneOptions(showCeilings: model.showCeilings, onlyActiveLevel: model.onlyActiveLevel, wallOpacity: model.wallOpacity,
                     showLamps: model.showLamps)
    }

    private func place(_ camera: CameraState?) {
        if let camera {
            scene.camera.set(CameraRig(camera))
        } else if model.project.camera == CameraState.default {
            scene.autoFrame()
        } else {
            scene.camera.set(CameraRig(model.project.camera))
        }
        scene.applyCamera()
    }

    /// Sky, image-based light and exposure of the renderer (the scene's own sun and lamps follow `applyLighting`).
    private func applyEnvironment() async {
        let mood = lighting.mood
        let look = SunSkyLook(lighting)
        let bg = SceneEnvironment.backgroundColor(dark: dark, mood: mood).usingColorSpace(.sRGB) ?? .gray
        renderer.cameraSettings.colorBackground = .color(bg.cgColor)
        if let res = await SceneEnvironment.resource(mood: mood) { renderer.lighting.resource = res }
        renderer.lighting.intensityExponent = Float(log2(max(look.ambient, 0.001)) + look.exposureEV)
    }

    /// Meshes and textures (also pattern textures with their relief maps, rendered in the background) load asynchronously;
    /// give them up to 20 s so the picture does not show boxes or flat colours. A furnished project has a dozen or more
    /// patterns, which on a busy machine took longer than the former 3 s and left floors and fabrics as flat colour.
    private func waitForMeshes() async {
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline,
              scene.materials.isBusy
                || scene.meshCache.states.values.contains(where: { if case .loading = $0 { true } else { false } }) {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
