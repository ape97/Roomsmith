import Foundation

// MARK: - render.*

/// PNG images of the plan and the 3D scene. A PNG is returned inline (`image` in the result, which the MCP bridge turns
/// into an image content block) and/or written to `path`. Nothing here changes the project.
enum RenderTools {
    /// Largest PNG returned inline; bigger images must be written to a file.
    static let maxInlineBytes = 4 * 1024 * 1024
    static let dpiRange = 36.0...600.0
    static let sceneSizeRange: ClosedRange<Int64> = 16...8192
    static let defaultSceneSize = (width: Int64(1280), height: Int64(800))

    /// Where an image goes: inline, to a file, or both.
    struct Output {
        var path: ExportTools.Target?
        var inline: Bool
    }

    @MainActor
    static func output(_ env: ToolEnv, _ a: Args) throws -> Output {
        let overwrite = try a.bool("overwrite") ?? false
        let wantsInline = try a.bool("inline")
        var target: ExportTools.Target?
        if let raw = try a.string("path") {
            try env.requireWriteAccess("render writes a file")
            target = try ExportTools.target(raw, ext: "png", project: env.context.fileURL)
            try ExportTools.requireFree([target!.url], overwrite: overwrite)
        } else if a.has("overwrite") {
            throw ToolError.invalid("overwrite", "only applies together with path")
        }
        // Inline by default when nothing is written; with a path only on request.
        return Output(path: target, inline: wantsInline ?? (target == nil))
    }

    /// Writes and/or attaches `png`, and returns the answer fields.
    @MainActor
    static func deliver(_ png: Data, _ out: Output, dryRun: Bool, into o: inout [String: JSONValue]) throws {
        o["bytes"] = .int(Int64(png.count))
        if out.inline {
            guard png.count <= maxInlineBytes else {
                throw AgentError(code: AgentError.outOfRange,
                                 message: "The image is \(png.count / 1024) KiB; inline images are limited to \(maxInlineBytes / 1024) KiB. Pass a smaller size (or lower dpi), or pass `path` to write it to a file.",
                                 details: .object(["bytes": .int(Int64(png.count)), "maxInlineBytes": .int(Int64(maxInlineBytes))]))
            }
            o["image"] = .object(["mimeType": "image/png", "base64": .string(png.base64EncodedString())])
        }
        if let t = out.path {
            o["path"] = .string(t.url.path)
            if dryRun {
                o["written"] = false
            } else {
                do { try png.write(to: t.url, options: .atomic) } catch {
                    throw AgentError(code: AgentError.internal, message: "Could not write \(t.url.path): \(error.localizedDescription)")
                }
                o["written"] = true
            }
        }
    }

    static let outputProperties: [String: JSONValue] = [
        "path": S.str("Absolute target file ending in .png (outside the project package). Needs write access."),
        "inline": S.bool("Return the image in the answer. Default true without `path`, false with it. Limited to 4 MiB."),
        "overwrite": S.bool("Replace an existing file at `path` (default false)."),
    ]

    @MainActor
    static func specs() -> [ToolSpec] {
        [
            sceneImage(),
            planImage(),
        ]
    }

    @MainActor
    private static func sceneImage() -> ToolSpec {
        var spec = ToolSpec.asyncRead("render.scene_image",
                       "Renders the 3D scene as PNG with the user's 3D display options (ceilings, only active level, wall opacity). Needs the Roomsmith window. Without `camera` it shows what the user sees, else the project camera; `camera` overrides single keys of that. `preset` instead frames the picture like the view buttons, fitted to `width` x `height` (the live view and the stored camera stay as they are). Returned inline as an image and/or written to `path` (which needs write access).",
                       outputProperties.merging([
                           "width": S.int("Pixel width 16...8192 (default 1280)."),
                           "height": S.int("Pixel height 16...8192 (default 800)."),
                           "dark": S.bool("Dark appearance (default false)."),
                           "camera": S.obj("Camera keys that override the base camera.", CameraTools.properties),
                           "preset": S.str("Frame the picture like a view button, fitted to its size: aerial, top, reset or frame. Not with `camera`.",
                                           values: AgentCameraPreset.allCases.map(\.rawValue)),
                           "ids": S.uuids("Only with preset `frame`: objects to frame (default the whole scene)."),
                       ]) { a, _ in a }) { env, a in
                let bridge = try env.requireBridge("render.scene_image")
                let w = try a.int("width") ?? defaultSceneSize.width, h = try a.int("height") ?? defaultSceneSize.height
                guard sceneSizeRange.contains(w) else { throw ViewTools.rangeError("width", "must be between 16 and 8192") }
                guard sceneSizeRange.contains(h) else { throw ViewTools.rangeError("height", "must be between 16 and 8192") }
                var override: CameraState?
                if let cam = try a.object("camera") {
                    guard CameraTools.properties.keys.contains(where: cam.has) else {
                        throw ToolError.invalid("camera", "give at least one camera key: \(CameraTools.properties.keys.sorted().joined(separator: ", "))")
                    }
                    var c = env.project.camera
                    try CameraTools.apply(cam, to: &c)
                    try Validator.validateCamera(c)  // same limits as camera.set_state (fov 10...120, distance)
                    override = c
                }
                let preset = try a.enumValue("preset", AgentCameraPreset.self)
                if preset != nil, override != nil { throw ToolError.invalid("preset", "cannot be combined with camera") }
                let ids = try a.uuidList("ids") ?? []
                if !ids.isEmpty {
                    guard preset == .frame else { throw ToolError.invalid("ids", "is only used with preset frame") }
                    try env.project.requireAll(ids)
                }
                let out = try output(env, a)
                let png: Data
                do {
                    png = try await bridge.renderScene(width: Int(w), height: Int(h), dark: try a.bool("dark") ?? false, camera: override,
                                                       preset: preset, ids: ids)
                } catch let e as AgentError { throw e } catch {
                    throw AgentError(code: AgentError.internal, message: "Could not render the scene: \(error.localizedDescription)")
                }
                var o: [String: JSONValue] = ["width": .int(w), "height": .int(h)]
                try deliver(png, out, dryRun: false, into: &o)
                return .object(o)
            }
        spec.readOnly = false  // writes a file when `path` is given
        return spec
    }

    @MainActor
    private static func planImage() -> ToolSpec {
        .action("render.plan_image",
                  "Renders the floor plan of a level as PNG, laid out exactly like export.plan (true to scale on a paper sheet; the same fit rules apply). Returned inline as an image and/or written to `path`.",
                  ["levelId": S.uuid("Level; default the active level."),
                   "paper": S.str("Sheet (default A3).", values: PaperFormat.allCases.map(\.rawValue)),
                   "orientation": S.str("Default auto.", values: ["auto", "landscape", "portrait"]),
                   "scale": .object(["description": "Drawing scale: whole number N for 1:N (default 100), or \"fit\"."]),
                   "dpi": S.num("Resolution 36...600 (default 100); lowered automatically for huge sheets.")]
                    .merging(outputProperties) { a, _ in a }, readOnly: false) { env, a in
                let p = env.project
                let levelId = try env.level(a, in: p)
                guard let level = p.level(levelId) else { throw ToolError.notFound("Level", levelId) }
                let paper = try ExportTools.parsePaper(a), orientation = try ExportTools.parseOrientation(a)
                let scale = try ExportTools.parseScale(a)
                let dpi = try a.double("dpi") ?? 100
                guard dpi.isFinite, dpiRange.contains(dpi) else { throw ViewTools.rangeError("dpi", "must be between 36 and 600") }
                let out = try output(env, a)
                let unit = p.settings.displayUnit
                let layout = PlanExport.layout(p, levelId: levelId, unit: unit, scale: scale, paper: paper, orientation: orientation)
                try ExportTools.requireFits([layout], paper: paper, orientation: orientation)
                let opts = PlanExport.options(for: layout, paper: paper, levelId: levelId, unit: unit)
                let pdf = PlanExport.pdf(p, options: opts)
                let raster: (data: Data, dpi: Double)
                do { raster = try PlanRaster.pngData(fromPDF: pdf, dpi: dpi) } catch {
                    throw AgentError(code: AgentError.internal, message: "Could not render the plan: \(error)")
                }
                let px = PlanFit.pixelSize(widthMM: layout.sheet.width, heightMM: layout.sheet.height, dpi: dpi)
                var o: [String: JSONValue] = [
                    "levelId": J.id(levelId), "level": .string(level.name), "scale": .int(Int64(layout.scale)),
                    "paper": .string(paper.rawValue), "landscape": .bool(layout.landscape), "dpi": .number(raster.dpi),
                    "width": .int(Int64(px.width)), "height": .int(Int64(px.height)),
                ]
                try deliver(raster.data, out, dryRun: env.dryRun, into: &o)
                return .object(o)
            }
    }
}
