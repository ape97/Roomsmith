import Foundation
import CoreGraphics
import ImageIO

/// Rasterises a one-page plan PDF to PNG (CoreGraphics and ImageIO only).
public enum PlanRaster {
    public struct Failure: Error, CustomStringConvertible, Sendable {
        public var description: String
        init(_ d: String) { description = d }
    }

    /// Rasterises the first PDF page at `dpi` (total pixels capped, see `PlanFit.pixelSize`). Returns the PNG and the dpi actually used.
    public static func pngData(fromPDF pdf: Data, dpi: Double) throws -> (data: Data, dpi: Double) {
        guard let provider = CGDataProvider(data: pdf as CFData), let doc = CGPDFDocument(provider), let page = doc.page(at: 1) else {
            throw Failure("could not render the plan page")
        }
        let box = page.getBoxRect(.mediaBox)
        let px = PlanFit.pixelSize(widthMM: box.width / 72 * 25.4, heightMM: box.height / 72 * 25.4, dpi: dpi)
        let w = px.width, h = px.height
        // Exactly dpi/72 pixels per point, so the dpi metadata matches the content; the canvas is rounded up, the rest stays white.
        let s = px.dpi / 72
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure("could not create a \(w) × \(h) pixel image")
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: Double(h) - box.height * s)  // keep the top-left corner of the page at the top-left of the image
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(page)
        guard let image = ctx.makeImage() else { throw Failure("could not render the plan image") }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else {
            throw Failure("could not encode PNG")
        }
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: px.dpi, kCGImagePropertyDPIHeight: px.dpi] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure("could not encode PNG") }
        return (out as Data, px.dpi)
    }
}
