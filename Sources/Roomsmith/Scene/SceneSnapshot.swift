import AppKit
import CoreGraphics
import Foundation
import Metal
import RealityKit
import RoomsmithCore
import UniformTypeIdentifiers

/// Pictures of the 3D scene: the live view as PNG (`SceneSnapshot.capture`) and an offscreen render for export
/// (`SceneSnapshot.render`). Both show what the document contains; neither changes it.
@MainActor
enum SceneSnapshot {
    enum Failure: Error, LocalizedError {
        case noView, noDevice, badSize, renderFailed(String)
        var errorDescription: String? {
            switch self {
            case .noView: "No 3D view is open."
            case .noDevice: "No GPU available."
            case .badSize: "The image size must be between 16 and 8192 pixels."
            case .renderFailed(let m): "Rendering failed: \(m)"
            }
        }
    }

    // MARK: Live view

    private struct WeakView { weak var view: SceneARView? }
    private static var views: [WeakView] = []

    static func register(_ view: SceneARView) {
        views.removeAll { $0.view == nil }
        if !views.contains(where: { $0.view === view }) { views.append(WeakView(view: view)) }
    }

    static func unregister(_ view: SceneARView) {
        views.removeAll { $0.view == nil || $0.view === view }
    }

    /// The 3D views shown in `window`.
    static func liveViews(in window: NSWindow?) -> [SceneARView] {
        guard let window else { return [] }
        return views.compactMap(\.view).filter { $0.window === window && !$0.isHiddenOrHasHiddenAncestor }
    }

    /// The 3D view of `model` that is on screen (key window first), if any. Several projects can be open at once
    /// (tabs, compare split), so a caller always names the model whose picture or camera it wants.
    static func liveView(for model: AppModel) -> SceneARView? {
        let alive = views.compactMap(\.view).filter { $0.window != nil && $0.renderer.model === model }
        return alive.first { $0.window?.isKeyWindow == true && !$0.isHiddenOrHasHiddenAncestor }
            ?? alive.first { $0.window?.isVisible == true && !$0.isHiddenOrHasHiddenAncestor } ?? alive.first
    }

    /// PNG of the live 3D view as it looks on screen (including the selection highlight and gizmo, without the
    /// SwiftUI overlay). Nil without an open 3D view. Does not activate the app.
    static func capture(model: AppModel) async -> Data? {
        guard let view = liveView(for: model) else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            // ARView only delivers a snapshot while its window is visible; give up after 3 s instead of hanging.
            let box = ResumeOnce(cont)
            view.snapshot(saveToHDR: false) { image in
                box.resume(image.flatMap { png(from: $0) })
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                box.resume(nil)
            }
        }
    }

    @MainActor private final class ResumeOnce {
        private var cont: CheckedContinuation<Data?, Never>?
        init(_ cont: CheckedContinuation<Data?, Never>) { self.cont = cont }
        func resume(_ value: Data?) { cont?.resume(returning: value); cont = nil }
    }

    // MARK: Offscreen render

    /// Renders the document's 3D scene without any window.
    ///
    /// - Parameters:
    ///   - model: the open document (read only).
    ///   - camera: the camera to use; nil uses the camera stored in the document (the fitted aerial view when it was never moved). To export what the user sees, pass
    ///     `liveView(for: model)?.renderer.camera.rig.state`.
    ///   - size: pixel size of the image (16...8192 per side). The field of view is vertical, so a different
    ///     aspect ratio shows more or less to the sides.
    ///   - dark: render with the dark sky and ground (default light).
    ///   - openings: open poses of doors and windows to show; nil shows everything closed.
    /// - Returns: an sRGB `CGImage` of `size`. Use `png(from:)` for file data.
    static func render(model: AppModel, camera: CameraState? = nil, size: CGSize, dark: Bool = false,
                       openings: OpeningMotion? = nil) async throws -> CGImage {
        try await renderTimed(model: model, camera: camera, size: size, dark: dark, timedFrames: 0, openings: openings).image
    }

    /// Like `render`, then renders `timedFrames` more frames of the same scene one after another and returns the
    /// time of each (scene update plus render, from submitting the frame to its completion), in milliseconds. Used by
    /// the benchmark: it measures the frame time of the scene without needing a visible window.
    static func renderTimed(model: AppModel, camera: CameraState? = nil, size: CGSize, dark: Bool = false,
                            timedFrames: Int, openings: OpeningMotion? = nil) async throws -> (image: CGImage, frameMs: [Double]) {
        let session = try await OffscreenSceneSession(model: model, size: size, dark: dark)
        defer { session.teardown() }
        let image = try await session.image(camera: camera, openings: openings)
        var frameMs: [Double] = []
        for _ in 0..<max(timedFrames, 0) {
            let t0 = ContinuousClock.now
            try await session.frame()
            frameMs.append((ContinuousClock.now - t0).ms)
        }
        return (image, frameMs)
    }

    static func cgImage(from texture: MTLTexture) -> CGImage? {
        let w = texture.width, h = texture.height
        let bytesPerRow = w * 4
        // BGRA with `noneSkipFirst`: the alpha byte is ignored when drawing, so the pixels need no opaque pass.
        var data = Data(count: bytesPerRow * h)
        data.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: PNG

    static func png(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    static func png(from image: NSImage) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return png(from: cg)
    }

    // MARK: Test hooks (environment)

    /// `ROOMSMITH_OFFSCREEN_BENCH=1`: prints one `ROOMSMITH_OFFSCREEN` line comparing a fresh render per picture (as
    /// before the presenter kept its session) with a kept `OffscreenSceneSession` at 960 x 1080 when only the camera
    /// moves, and the largest channel difference between the kept and a fresh picture of the same camera.
    private static func offscreenBench(model: AppModel) async {
        let size = CGSize(width: 960, height: 1080)
        var cams: [CameraState] = []
        for i in 0..<8 {
            var cam = model.project.camera
            cam.yawDeg += Double(i) * 4
            cams.append(cam)
        }
        do {
            var freshMs: [Double] = []
            for cam in cams.prefix(4) {
                let t0 = ContinuousClock.now
                _ = try await render(model: model, camera: cam, size: size)
                freshMs.append((ContinuousClock.now - t0).ms)
            }
            let session = try await OffscreenSceneSession(model: model, size: size, dark: false)
            defer { session.teardown() }
            var keptMs: [Double] = []
            var last: CGImage?
            for cam in cams {
                let t0 = ContinuousClock.now
                last = try await session.image(camera: cam)
                keptMs.append((ContinuousClock.now - t0).ms)
            }
            let fresh = try await render(model: model, camera: cams.last, size: size)
            let diff = last.map { maxDifference($0, fresh) } ?? -1
            func median(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
            PerfLog.line(String(format: "ROOMSMITH_OFFSCREEN pieces=%d size=960x1080 freshMedianMs=%.1f keptMedianMs=%.1f keptMaxMs=%.1f maxChannelDiff=%d",
                                model.project.instances.count, median(freshMs), median(keptMs), keptMs.max() ?? 0, diff))
        } catch {
            PerfLog.line("ROOMSMITH_OFFSCREEN failed: \(error.localizedDescription)")
        }
    }

    /// Largest difference of any colour channel between two pictures of the same size (-1 for different sizes).
    static func maxDifference(_ a: CGImage, _ b: CGImage) -> Int {
        guard a.width == b.width, a.height == b.height else { return -1 }
        func bytes(_ img: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: img.width * img.height * 4)
            data.withUnsafeMutableBytes { buf in
                let ctx = CGContext(data: buf.baseAddress, width: img.width, height: img.height, bitsPerComponent: 8,
                                    bytesPerRow: img.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                ctx?.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            }
            return data
        }
        let x = bytes(a), y = bytes(b)
        var worst = 0
        for i in x.indices where i % 4 != 3 { worst = max(worst, abs(Int(x[i]) - Int(y[i]))) }
        return worst
    }

    /// `ROOMSMITH_SCENE_SELECT=1` selects the first piece of furniture; `ROOMSMITH_SCENE_SNAPSHOT=<path>` writes the live
    /// view as PNG after the scene has settled; `ROOMSMITH_SCENE_OFFSCREEN=<path>` writes an offscreen render
    /// (1280 x 800); `ROOMSMITH_SCENE_OPEN=turn|tilt[:progress]` opens all doors and windows in it; `ROOMSMITH_SHOW_LAMPS=0|1` switches the "Lamps" view option. Used for checks without simulated input; only under `ROOMSMITH_TEST_MODE=1`.
    private static var hooksRan = false

    /// `ROOMSMITH_SCENE_OPEN=turn|tilt[:progress]` shows every movable door and window in that pose (progress 0...1,
    /// default 1). Nil when unset or not understood.
    private static func hookOpenings(_ spec: String?, model: AppModel) -> OpeningMotion? {
        guard let spec, !spec.isEmpty else { return nil }
        let parts = spec.split(separator: ":").map(String.init)
        guard let mode = OpeningMode(rawValue: parts[0]), mode != .closed else { return nil }
        let progress = parts.count > 1 ? Double(parts[1]) ?? 1 : 1
        var m = OpeningMotion()
        for (id, sig) in OpeningSignature.map(model.project) { m.setPose(id, mode: mode, progress: progress, signature: sig) }
        return m
    }

    static func runEnvHooksIfRequested(model: AppModel) {
        guard AppDefaults.isTestMode, !hooksRan else { return }
        hooksRan = true
        let env = ProcessInfo.processInfo.environment
        if env["ROOMSMITH_SCENE_SELECT"] == "1", let first = model.project.instances.first {
            model.selection = [first.id]
        }
        if let v = env["ROOMSMITH_SHOW_LAMPS"], !v.isEmpty { model.showLamps = v != "0" }
        // `ROOMSMITH_SCENE_MEASURE=x1,y1,x2,y2` (fractions of the view, from its top left) switches to the Measure tool and
        // clicks both points through the real picking path, so a screenshot shows a finished 3D measurement.
        if let spec = env["ROOMSMITH_SCENE_MEASURE"] {
            let f = spec.split(separator: ",").compactMap { Double($0) }
            if f.count == 4 {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    guard let view = liveView(for: model) else { return }
                    let size = view.renderer.camera.viewSize
                    model.tool = .measure
                    for (x, y) in [(f[0], f[1]), (f[2], f[3])] {
                        view.renderer.measureClick(at: SIMD2(x * Double(size.width), (1 - y) * Double(size.height)))
                    }
                }
            }
        }
        if let path = env["ROOMSMITH_SCENE_OFFSCREEN"], !path.isEmpty {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                do {
                    let image = try await render(model: model, size: CGSize(width: 1280, height: 800), openings: hookOpenings(env["ROOMSMITH_SCENE_OPEN"], model: model))
                    try png(from: image)?.write(to: URL(fileURLWithPath: path))
                    PerfLog.line("ROOMSMITH_SCENE_OFFSCREEN wrote \(path) \(image.width)x\(image.height)")
                } catch {
                    PerfLog.line("ROOMSMITH_SCENE_OFFSCREEN failed: \(error.localizedDescription)")
                }
            }
        }
        // `ROOMSMITH_BENCHMARK=1` (stress project) or `ROOMSMITH_RENDER_BENCH=1` (the opened project): prints one
        // `ROOMSMITH_RENDER pieces=… size=… frames=… medianMs=… p95Ms=… fps=…` line with the frame time (update plus render) of the
        // whole scene at 1920 x 1080, offscreen, so it can be measured while the window is hidden or covered (then the
        // live view gets no frames and its fps reads `n/a`).
        if env["ROOMSMITH_BENCHMARK"] == "1" || env["ROOMSMITH_RENDER_BENCH"] == "1" {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                do {
                    let frames = try await renderTimed(model: model, size: CGSize(width: 1920, height: 1080), timedFrames: 120).frameMs
                    let sorted = frames.sorted()
                    let median = sorted[sorted.count / 2], p95 = sorted[min(sorted.count - 1, sorted.count * 95 / 100)]
                    PerfLog.line(String(format: "ROOMSMITH_RENDER pieces=%d size=1920x1080 frames=%d medianMs=%.2f p95Ms=%.2f fps=%.1f",
                                        model.project.instances.count, frames.count, median, p95, 1000 / median))
                } catch {
                    PerfLog.line("ROOMSMITH_RENDER failed: \(error.localizedDescription)")
                }
            }
        }
        if env["ROOMSMITH_OFFSCREEN_BENCH"] == "1" {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                await offscreenBench(model: model)
            }
        }
        if let path = env["ROOMSMITH_SCENE_SNAPSHOT"], !path.isEmpty {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                if let data = await capture(model: model) {
                    try? data.write(to: URL(fileURLWithPath: path))
                    PerfLog.line("ROOMSMITH_SCENE_SNAPSHOT wrote \(path) \(data.count) bytes")
                } else {
                    PerfLog.line("ROOMSMITH_SCENE_SNAPSHOT failed (no view, or its window is not visible)")
                }
            }
        }
    }
}
