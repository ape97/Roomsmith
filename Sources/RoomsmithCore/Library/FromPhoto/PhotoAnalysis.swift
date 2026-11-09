import Foundation

/// One reference photo as bytes plus the file extension it is stored under.
public struct PhotoImage: Sendable, Equatable {
    public var data: Data
    public var fileExtension: String
    public init(data: Data, fileExtension: String) { self.data = data; self.fileExtension = fileExtension }

    /// Extension from the leading bytes (JPEG, PNG, HEIC/HEIF, GIF, TIFF, WebP, BMP); nil when the bytes are none of these.
    public static func sniffExtension(_ d: Data) -> String? {
        let b = [UInt8](d.prefix(16))
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "jpg" }
        if b.count >= 8, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "png" }
        if b.count >= 6, b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return "gif" }
        if b.count >= 4, (b[0] == 0x49 && b[1] == 0x49 && b[2] == 0x2A && b[3] == 0) || (b[0] == 0x4D && b[1] == 0x4D && b[2] == 0 && b[3] == 0x2A) { return "tiff" }
        if b.count >= 12, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46, b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return "webp" }
        if b.count >= 12, b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 {
            let brand = String(decoding: b[8..<12], as: UTF8.self)
            return brand.hasPrefix("hei") || brand.hasPrefix("mif") ? "heic" : nil
        }
        if b.count >= 2, b[0] == 0x42, b[1] == 0x4D { return "bmp" }
        return nil
    }
}

/// A dominant colour of the furniture (mask pixels only) with its share of those pixels (0...1).
public struct PhotoColor: Sendable, Equatable {
    public var color: RGBColor
    public var weight: Double
    public init(_ color: RGBColor, weight: Double) { self.color = color; self.weight = weight }
}

/// A classifier label with its confidence (0...1).
public struct PhotoLabel: Sendable, Equatable {
    public var name: String
    public var confidence: Double
    public init(_ name: String, _ confidence: Double) { self.name = name; self.confidence = confidence }
}

/// What a provider (the Vision framework in the app, a fake in tests) found in the photo(s). Everything is optional:
/// the template chooser works with whatever evidence there is.
public struct PhotoAnalysis: Sendable, Equatable {
    /// Width / height of the furniture's bounding box as seen in the photo (a front view is assumed).
    public var aspectWH: Double?
    /// Depth / height when known (a side view); nil for a single front photo.
    public var aspectDH: Double?
    public var dominantColors: [PhotoColor]
    public var labels: [PhotoLabel]
    /// Extra keywords a provider already extracted; the free hint text is read separately.
    public var hintKeywords: Set<String>

    public init(aspectWH: Double? = nil, aspectDH: Double? = nil, dominantColors: [PhotoColor] = [], labels: [PhotoLabel] = [],
                hintKeywords: Set<String> = []) {
        self.aspectWH = aspectWH; self.aspectDH = aspectDH; self.dominantColors = dominantColors; self.labels = labels
        self.hintKeywords = hintKeywords
    }

    /// Several photos of one piece: the first photo (the front view) gives the proportions, labels keep their best
    /// confidence, colours are averaged by weight.
    public static func combine(_ list: [PhotoAnalysis]) -> PhotoAnalysis {
        guard var out = list.first else { return PhotoAnalysis() }
        var labels: [String: PhotoLabel] = [:]
        for l in list.flatMap(\.labels) where (labels[l.name]?.confidence ?? -1) < l.confidence { labels[l.name] = l }
        out.labels = labels.values.sorted { $0.confidence != $1.confidence ? $0.confidence > $1.confidence : $0.name < $1.name }
        out.aspectWH = list.compactMap(\.aspectWH).first
        out.aspectDH = list.compactMap(\.aspectDH).first
        out.hintKeywords = list.reduce(into: Set<String>()) { $0.formUnion($1.hintKeywords) }
        var colors: [RGBColor: Double] = [:]
        for c in list.flatMap(\.dominantColors) { colors[c.color, default: 0] += c.weight }
        let total = colors.values.reduce(0, +)
        out.dominantColors = colors.map { PhotoColor($0.key, weight: total > 0 ? $0.value / total : 0) }
            .sorted { $0.weight != $1.weight ? $0.weight > $1.weight : $0.color.hex < $1.color.hex }
        return out
    }
}

/// Dimensions the user knows (mm). At least one is required; the others are derived from the photo's proportions.
public struct PhotoDimensions: Sendable, Equatable {
    public var width: MM?
    public var depth: MM?
    public var height: MM?
    public init(width: MM? = nil, depth: MM? = nil, height: MM? = nil) { self.width = width; self.depth = depth; self.height = height }
    public var isEmpty: Bool { width == nil && depth == nil && height == nil }
}

/// Analyses reference photos. The app implements it with the Vision framework (on device, no network); tests use a fake.
public protocol FurnitureFromPhotoProvider: Sendable {
    func analyze(images: [PhotoImage], hint: String, dimensions: PhotoDimensions?) async throws -> PhotoAnalysis
}

public struct PhotoAnalysisError: Error, CustomStringConvertible, Sendable, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}
