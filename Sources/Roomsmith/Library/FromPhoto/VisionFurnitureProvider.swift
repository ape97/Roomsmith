import CoreImage
import Foundation
import ImageIO
import RoomsmithCore
import Vision

/// Reads photos with the Vision framework, on this Mac only (no network):
/// - the foreground instance mask gives the furniture's bounding box (the largest instance wins) and so its proportions,
/// - the image classifier gives labels such as "sofa" or "table",
/// - dominant colours are counted on mask pixels only (a coarse colour histogram over the cut-out).
struct VisionFurnitureProvider: FurnitureFromPhotoProvider {
    /// Longest side the photo is scaled to before analysis; plenty for proportions and colours, keeps it fast.
    static let analysisSide = 768

    func analyze(images: [PhotoImage], hint: String, dimensions: PhotoDimensions?) async throws -> PhotoAnalysis {
        var list: [PhotoAnalysis] = []
        for image in images {
            let data = image.data
            list.append(try await Task.detached(priority: .userInitiated) { try Self.analyzeOne(data) }.value)
        }
        return PhotoAnalysis.combine(list)
    }

    // MARK: One photo

    static func analyzeOne(_ data: Data) throws -> PhotoAnalysis {
        let (cg, pixels) = try load(data)
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        let classify = VNClassifyImageRequest()
        let mask = VNGenerateForegroundInstanceMaskRequest()
        do { try handler.perform([classify, mask]) } catch {
            throw PhotoAnalysisError("Vision could not analyse the photo: \(error.localizedDescription)")
        }
        let labels = (classify.results ?? []).filter { $0.confidence >= 0.05 }.prefix(20).map {
            PhotoLabel($0.identifier.replacingOccurrences(of: "_", with: " "), Double($0.confidence))
        }

        var aspect: Double?
        var colors: [PhotoColor] = []
        if let obs = mask.results?.first, let m = try largestInstance(obs, handler: handler, width: cg.width, height: cg.height) {
            if m.box.height > 0 { aspect = Double(m.box.width) / Double(m.box.height) }
            colors = dominantColors(pixels: pixels, width: cg.width, mask: m.covered)
        } else {
            // No foreground found: colours of the central area only, no proportions.
            var covered = [Bool](repeating: false, count: cg.width * cg.height)
            for y in cg.height / 4 ..< cg.height * 3 / 4 { for x in cg.width / 4 ..< cg.width * 3 / 4 { covered[y * cg.width + x] = true } }
            colors = dominantColors(pixels: pixels, width: cg.width, mask: covered)
        }
        return PhotoAnalysis(aspectWH: aspect, aspectDH: nil, dominantColors: colors, labels: Array(labels))
    }

    /// Decodes with the camera orientation applied and scales down. Returns the image and its RGBA bytes (premultiplied).
    private static func load(_ data: Data) throws -> (CGImage, [UInt8]) {
        guard var ci = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            throw PhotoAnalysisError("The photo could not be decoded")
        }
        let longest = max(ci.extent.width, ci.extent.height)
        guard longest >= 8 else { throw PhotoAnalysisError("The photo is too small to analyse") }
        if longest > CGFloat(analysisSide) {
            let s = CGFloat(analysisSide) / longest
            ci = ci.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        let rect = ci.extent.integral
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = context.createCGImage(ci, from: rect, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw PhotoAnalysisError("The photo could not be rendered for analysis")
        }
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = bytes.withUnsafeMutableBytes { buf -> Bool in
            guard let c = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw PhotoAnalysisError("The photo could not be read pixel by pixel") }
        return (cg, bytes)
    }

    // MARK: Mask

    struct Instance { var box: CGRect; var covered: [Bool]; var area: Int }

    /// The instance with the most pixels: its bounding box (pixels, top-left origin) and a per-pixel coverage map.
    private static func largestInstance(_ obs: VNInstanceMaskObservation, handler: VNImageRequestHandler, width: Int, height: Int) throws -> Instance? {
        var best: Instance?
        for index in obs.allInstances {
            let buffer: CVPixelBuffer
            do { buffer = try obs.generateScaledMaskForImage(forInstances: IndexSet(integer: index), from: handler) } catch { continue }
            guard let inst = read(buffer, width: width, height: height) else { continue }
            if inst.area > (best?.area ?? 0) { best = inst }
        }
        // Specks are no furniture.
        guard let b = best, b.area >= max(64, width * height / 200) else { return nil }
        return b
    }

    private static func read(_ buffer: CVPixelBuffer, width: Int, height: Int) -> Instance? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        guard w == width, h == height, let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        var covered = [Bool](repeating: false, count: w * h)
        var area = 0, minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0 ..< h {
            let row = base.advanced(by: y * stride)
            for x in 0 ..< w {
                let on: Bool
                switch format {
                case kCVPixelFormatType_OneComponent32Float: on = row.assumingMemoryBound(to: Float.self)[x] > 0.5
                case kCVPixelFormatType_OneComponent16Half: on = Float(row.assumingMemoryBound(to: Float16.self)[x]) > 0.5
                case kCVPixelFormatType_OneComponent8: on = row.assumingMemoryBound(to: UInt8.self)[x] > 127
                default: return nil
                }
                guard on else { continue }
                covered[y * w + x] = true
                area += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard area > 0 else { return nil }
        return Instance(box: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1), covered: covered, area: area)
    }

    // MARK: Colours

    /// Up to three dominant colours of the covered pixels: 4 bits per channel buckets, each averaged, weighted by share.
    static func dominantColors(pixels: [UInt8], width: Int, mask: [Bool]) -> [PhotoColor] {
        struct Bucket { var n = 0, r = 0, g = 0, b = 0 }
        var buckets: [Int: Bucket] = [:]
        var total = 0
        for i in 0 ..< mask.count where mask[i] {
            let o = i * 4
            let a = Int(pixels[o + 3])
            guard a > 200 else { continue }
            // Premultiplied alpha is ~1 here; undo it for safety on partly transparent pixels.
            let r = min(255, Int(pixels[o]) * 255 / a), g = min(255, Int(pixels[o + 1]) * 255 / a), b = min(255, Int(pixels[o + 2]) * 255 / a)
            let key = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)
            var bucket = buckets[key] ?? Bucket()
            bucket.n += 1; bucket.r += r; bucket.g += g; bucket.b += b
            buckets[key] = bucket
            total += 1
        }
        guard total > 0 else { return [] }
        return buckets.values.sorted { $0.n > $1.n }.prefix(3).map {
            PhotoColor(RGBColor(UInt8($0.r / $0.n), UInt8($0.g / $0.n), UInt8($0.b / $0.n)), weight: Double($0.n) / Double(total))
        }
    }
}
