import AppKit
import ImageIO

/// Small previews made with ImageIO, so a full-size photo is never decoded for a thumbnail.
enum ImageThumbnail {
    /// A thumbnail whose longer side is at most `maxPixel` pixels. Nil when the data is not an image.
    static func make(data: Data, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return make(source: source, maxPixel: maxPixel)
    }

    static func make(url: URL, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return make(source: source, maxPixel: maxPixel)
    }

    private static func make(source: CGImageSource, maxPixel: Int) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
