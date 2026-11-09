import Foundation
import ImageIO

// MARK: - background.*

/// Background images (scanned plans) under a level. Pixel positions are image pixels from the top-left corner
/// (x right, y down). The scale comes from two pixels and their real distance, so it is exact to the stored
/// millimetre length: `mmPerPixel = realLengthMm / pixelDistance`.
enum BackgroundTools {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff", "heic", "gif", "bmp"]

    /// Pixel size of an image file (nil when it cannot be read as an image).
    static func pixelSize(of url: URL) -> (width: Int64, height: Int64)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value, w > 0, h > 0 else { return nil }
        return (w, h)
    }

    /// Pixel size of the stored asset when the project has a package on disk.
    @MainActor
    static func pixelSize(of asset: ProjectAsset, env: ToolEnv) -> (width: Int64, height: Int64)? {
        guard let pkg = env.context.fileURL else { return nil }
        return pixelSize(of: ProjectPackage.assetURL(asset, in: pkg))
    }

    static func row(_ p: Project, _ b: BackgroundImage, size: (width: Int64, height: Int64)?) -> JSONValue {
        let s = b.mmPerPixel
        var o: [String: JSONValue] = [
            "id": J.id(b.id), "levelId": J.id(b.levelId), "assetId": J.id(b.assetId), "rev": .int(b.rev),
            "pixelA": J.p2(b.calibrationA), "pixelB": J.p2(b.calibrationB), "realLengthMm": .int(b.calibrationLength),
            "mmPerPixel": .number(s), "originMm": J.p2(b.origin), "opacity": .number(b.opacity), "visible": .bool(b.visible),
        ]
        if let size {
            o["widthPx"] = .int(size.width); o["heightPx"] = .int(size.height)
            o["extentMm"] = .object(["minX": .int(b.origin.x), "maxX": J.mm(Double(b.origin.x) + Double(size.width) * s),
                                     "minY": J.mm(Double(b.origin.y) - Double(size.height) * s), "maxY": .int(b.origin.y)])
        }
        return .object(o)
    }

    private static func requirePoint(_ a: Args, _ key: String, size: (width: Int64, height: Int64)?) throws -> P2 {
        let pt = try a.requireP2(key)
        guard pt.x >= 0, pt.y >= 0 else { throw ToolError.invalid(key, "pixel positions must not be negative (origin = top-left corner)") }
        if let size, pt.x > size.width || pt.y > size.height {
            throw ToolError.invalid(key, "lies outside the image (\(size.width) x \(size.height) px)")
        }
        return pt
    }

    private static func requireLength(_ a: Args) throws -> MM {
        let l = try a.mm("realLengthMm") ?? { throw ToolError.missing("realLengthMm") }()
        guard sizeLimit.contains(l) else { throw outOfRange("realLengthMm", "must be between \(sizeLimit.lowerBound) and \(sizeLimit.upperBound) mm") }
        return l
    }

    private static func opacity(_ a: Args) throws -> Double? {
        guard let o = try a.double("opacity") else { return nil }
        guard (0...1).contains(o) else { throw ToolError.invalid("opacity", "must be between 0 and 1") }
        return o
    }

    /// A numeric range error (`OUT_OF_RANGE`), like the size limits of the other tools.
    private static func outOfRange(_ field: String, _ message: String) -> AgentError {
        AgentError(code: AgentError.outOfRange, message: "\(field): \(message)", details: .object(["field": .string(field)]))
    }

    /// Two pixels and a length that give `mmPerPixel`: exactly where a pixel distance up to 1000 px gives a whole
    /// number of mm; otherwise the longest pixel distance whose length stays within 100000 mm (so the length is at
    /// least 100000 − s ≥ 99900 mm), and the stored scale is off by at most 0.5 / 99900 ≈ 5e-6 relative over the whole range
    /// (e.g. 25.4/300 mm per pixel, a 300 dpi scan). The pair is synthetic and may lie outside the image.
    static func calibration(forMmPerPixel s: Double) throws -> (a: P2, b: P2, length: MM) {
        guard s.isFinite, s >= 0.001, s <= 100 else { throw outOfRange("mmPerPixel", "must be between 0.001 and 100 mm per pixel") }
        for n in [1, 2, 4, 5, 8, 10, 20, 25, 40, 50, 100, 125, 200, 250, 500, 1000] as [Int64] {
            let len = s * Double(n)
            if len.rounded() >= 1, abs(len - len.rounded()) <= 1e-9 * Double(n), sizeLimit.contains(MM(len.rounded())) {
                return (P2(0, 0), P2(n, 0), MM(len.rounded()))
            }
        }
        let n = min(coordinateLimit, Int64((Double(sizeLimit.upperBound) / s).rounded(.down)))
        let len = (s * Double(n)).rounded()
        guard n >= 1, len >= 1, sizeLimit.contains(MM(len)) else { throw outOfRange("mmPerPixel", "must be between 0.001 and 100 mm per pixel") }
        return (P2(0, 0), P2(n, 0), MM(len))
    }

    @MainActor
    static func specs() -> [ToolSpec] {
        [
            .write("background.add",
                   "Adds a background image (scanned floor plan) under a level and calibrates it. Give the image as `path` (absolute file; it is copied into the project package's assets/, so the project must have been saved once) or `assetId` (an existing image asset). Calibration is required: either two image pixels `pixelA`/`pixelB` plus the real distance between them `realLengthMm` (mm-exact: mmPerPixel = realLengthMm / pixel distance), or `mmPerPixel`. `originMm` is the world position of the top-left pixel. Pixel positions are whole pixels from the top-left corner (x right, y down).",
                   ["path": S.str("Absolute path of a PNG, JPEG, TIFF, HEIC, GIF or BMP file."),
                    "assetId": S.uuid("Existing image or background asset instead of `path`."),
                    "levelId": S.uuid("Level; default the active level."),
                    "pixelA": S.p2("First calibration pixel (not millimetres)."), "pixelB": S.p2("Second calibration pixel (not millimetres)."),
                    "realLengthMm": S.int("Real distance between pixelA and pixelB, 1...100000 mm."),
                    "mmPerPixel": S.num("Scale instead of the two pixels."),
                    "originMm": S.p2("World position of the top-left pixel (default 0,0)."),
                    "opacity": S.num("0...1, default 0.5."), "visible": S.bool("Default true.")]) { p, env, a in
                let level = try env.level(a, in: p)
                try p.ensureLevel(level)
                guard a.has("path") != a.has("assetId") else { throw ToolError.invalid(nil, "Give exactly one of: path, assetId") }
                var asset: ProjectAsset?
                var url: URL?
                var size: (width: Int64, height: Int64)?
                if let id = try a.uuid("assetId") {
                    guard let x = p.asset(id) else { throw ToolError.notFound("Asset", id) }
                    guard x.kind == .background || x.kind == .image else { throw ToolError.invalid("assetId", "must be an image or background asset (is \(x.kind.rawValue))") }
                    asset = x
                    size = pixelSize(of: x, env: env)
                } else {
                    let raw = try a.requireNonEmptyString("path")
                    guard raw.hasPrefix("/"), !raw.contains("\0") else { throw ToolError.invalid("path", "must be an absolute path") }
                    let u = URL(fileURLWithPath: raw).standardizedFileURL
                    guard imageExtensions.contains(u.pathExtension.lowercased()) else {
                        throw ToolError.invalid("path", "must be an image file (\(imageExtensions.sorted().joined(separator: ", ")))")
                    }
                    var isDir: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue else {
                        throw ToolError.notFoundText("No file at \(u.path)")
                    }
                    guard let s = pixelSize(of: u) else { throw ToolError.invalid("path", "is not a readable image") }
                    guard env.context.fileURL != nil else {
                        throw ToolError.invalid("path", "the project has no file yet; call project.save_as with a path first so the image can be stored in its assets/ folder")
                    }
                    url = u; size = s
                }
                // Calibration
                var pa: P2, pb: P2, length: MM
                let hasPixels = a.has("pixelA") || a.has("pixelB") || a.has("realLengthMm")
                if hasPixels {
                    guard !a.has("mmPerPixel") else { throw ToolError.invalid("mmPerPixel", "cannot be combined with pixelA/pixelB/realLengthMm") }
                    pa = try requirePoint(a, "pixelA", size: size); pb = try requirePoint(a, "pixelB", size: size)
                    guard pa != pb else { throw ToolError.invalid("pixelB", "must differ from pixelA") }
                    length = try requireLength(a)
                } else if let s = try a.double("mmPerPixel") {
                    (pa, pb, length) = try calibration(forMmPerPixel: s)
                } else {
                    throw ToolError.invalid(nil, "Calibration is required: give pixelA, pixelB and realLengthMm, or mmPerPixel")
                }
                let origin = try a.p2("originMm") ?? .zero
                let op = try opacity(a)
                let visible = try a.bool("visible")
                if let url {
                    // Content-addressed copy; a dry run (also of a whole app.batch) stores into a throw-away folder instead
                    // of the project package. A later failed commit can leave the unreferenced copy in assets/.
                    let dry = env.dryRun
                    let target = dry ? FileManager.default.temporaryDirectory.appendingPathComponent("rs-bg-\(UUID().uuidString).roomsmith")
                                     : env.context.fileURL!
                    defer { if dry { try? FileManager.default.removeItem(at: target) } }
                    do { asset = try ProjectPackage.importAsset(url, kind: .background, into: target) } catch {
                        throw AgentError(code: AgentError.internal, message: "Could not store the image: \(error)")
                    }
                    asset!.id = p.addAsset(asset!)
                }
                guard let stored = asset else { throw ToolError.invalid(nil, "No image") }
                let assetId = p.assets.first { $0.sha256 == stored.sha256 && $0.kind == stored.kind }?.id ?? stored.id
                var b = BackgroundImage(levelId: level, assetId: assetId, calibrationA: pa, calibrationB: pb, calibrationLength: length, origin: origin)
                if let op { b.opacity = op }
                if let visible { b.visible = visible }
                guard origin.isInRange else { throw ToolError.invalid("originMm", "outside the allowed coordinate range") }
                let id = try p.addBackground(b)
                var r = row(p, b, size: size).objectValue ?? [:]
                r["id"] = J.id(id)
                return .object(r)
            },
            .write("background.calibrate",
                   "Sets the scale of a background image from two image pixels and the real distance between them (mm-exact: mmPerPixel = realLengthMm / pixel distance; the two pixels are then exactly realLengthMm apart in the plan, up to 0.5 mm rounding of the stored origin). The world position of pixelA stays where it is, or moves to `worldA`. Pixel positions are whole pixels from the top-left corner (x right, y down).",
                   ["id": S.uuid("Background image id."), "pixelA": S.p2("First pixel (not millimetres)."), "pixelB": S.p2("Second pixel (not millimetres)."),
                    "realLengthMm": S.int("Real distance between the two pixels, 1...100000 mm."),
                    "worldA": S.p2("Optional new world position of pixelA (default: unchanged).")],
                   required: ["id", "pixelA", "pixelB", "realLengthMm"]) { p, env, a in
                let id = try a.requireUUID("id")
                guard let bg = p.background(id) else {
                    if p.kind(of: id) != nil { throw ToolError.invalid("id", "\(id.uuidString.lowercased()) is not a background image") }
                    throw ToolError.notFound("Background image", id)
                }
                let size = p.asset(bg.assetId).flatMap { pixelSize(of: $0, env: env) }
                let pa = try requirePoint(a, "pixelA", size: size), pb = try requirePoint(a, "pixelB", size: size)
                guard pa != pb else { throw ToolError.invalid("pixelB", "must differ from pixelA") }
                let length = try requireLength(a)
                let before = bg.mmPerPixel
                try p.calibrateBackground(id, pixelA: pa, pixelB: pb, realLength: length, worldA: try a.p2("worldA"))
                guard let now = p.background(id) else { throw ToolError.notFound("Background image", id) }
                let wa = p.backgroundWorld(now, pixel: pa), wb = p.backgroundWorld(now, pixel: pb)
                var r = row(p, now, size: size).objectValue ?? [:]
                r["previousMmPerPixel"] = .number(before)
                r["measuredDistanceMm"] = .number(((wb.x - wa.x) * (wb.x - wa.x) + (wb.y - wa.y) * (wb.y - wa.y)).squareRoot())
                return .object(r)
            },
            .write("background.update",
                   "Changes a background image: opacity, visibility, position of its top-left pixel (`originMm`) or its level. The scale is changed with background.calibrate. Only the given keys change.",
                   ["id": S.uuid("Background image id."), "opacity": S.num("0...1."), "visible": S.bool("Show or hide."),
                    "originMm": S.p2("World position of the top-left pixel."), "levelId": S.uuid("Move to this level.")],
                   required: ["id"]) { p, env, a in
                let id = try a.requireUUID("id")
                guard p.background(id) != nil else {
                    if p.kind(of: id) != nil { throw ToolError.invalid("id", "\(id.uuidString.lowercased()) is not a background image") }
                    throw ToolError.notFound("Background image", id)
                }
                let keys = ["opacity", "visible", "originMm", "levelId"]
                guard keys.contains(where: a.present) else { throw ToolError.invalid(nil, "Give at least one of: \(keys.joined(separator: ", "))") }
                let op = try opacity(a), visible = try a.bool("visible"), origin = try a.p2("originMm")
                let level = try a.uuid("levelId")
                try p.ensureEditable(id)
                if let level { guard p.level(level) != nil else { throw ToolError.notFound("Level", level) }; try p.ensureLevel(level) }
                try p.updateBackground(id) { b in
                    if let op { b.opacity = op }
                    if let visible { b.visible = visible }
                    if let origin { b.origin = origin }
                    if let level { b.levelId = level }
                }
                guard let now = p.background(id) else { throw ToolError.notFound("Background image", id) }
                return row(p, now, size: p.asset(now.assetId).flatMap { pixelSize(of: $0, env: env) })
            },
        ]
    }
}
