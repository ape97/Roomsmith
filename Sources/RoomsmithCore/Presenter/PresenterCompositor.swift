import CoreGraphics
import CoreVideo
import Foundation
import VideoToolbox

/// A rendered source image (plan or 3D) handed to the compositor.
public enum PresenterImage: @unchecked Sendable {
    // Safe: both payloads are immutable once handed over (a CGImage is immutable; a pixel buffer is not written after rendering).
    case cgImage(CGImage)
    case pixelBuffer(CVPixelBuffer)

    public var cgImage: CGImage? {
        switch self {
        case .cgImage(let i): return i
        case .pixelBuffer(let b):
            var out: CGImage?
            VTCreateCGImageFromCVPixelBuffer(b, options: nil, imageOut: &out)
            return out
        }
    }
}

/// A finished frame on its way to the encoder and the presenter window. The buffer is not modified after composition.
public struct PresenterFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public init(_ pixelBuffer: CVPixelBuffer) { self.pixelBuffer = pixelBuffer }
}

/// Draws the pane images of a `PresenterComposition` into BGRA, IOSurface-backed pixel buffers.
/// Not thread-safe: use from one actor (the app uses the main actor).
public final class PresenterCompositor {
    public let composition: PresenterComposition
    public static let background = CGColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 1)
    private var pool: CVPixelBufferPool?

    public init(composition: PresenterComposition) {
        self.composition = composition
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: Int(composition.canvas.width),
            kCVPixelBufferHeightKey: Int(composition.canvas.height),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
        pool = p
    }

    /// New pixel buffer from the pool; nil if the pool is exhausted (consumers still hold too many frames).
    public func makeBuffer() -> CVPixelBuffer? {
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        let aux: [CFString: Any] = [kCVPixelBufferPoolAllocationThresholdKey: 12]
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, aux as CFDictionary, &out)
        return status == kCVReturnSuccess ? out : nil
    }

    /// Composes the panes of the layout. A missing source leaves its cell empty.
    public func compose(plan: PresenterImage?, scene: PresenterImage?) -> CVPixelBuffer? {
        guard let buffer = makeBuffer() else { return nil }
        guard compose(plan: plan, scene: scene, into: buffer) else { return nil }
        return buffer
    }

    @discardableResult
    public func compose(plan: PresenterImage?, scene: PresenterImage?, into buffer: CVPixelBuffer) -> Bool {
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        guard w == Int(composition.canvas.width), h == Int(composition.canvas.height) else { return false }
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return false }
        ctx.setFillColor(Self.background)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        for pane in composition.panes {
            guard let image = (pane.kind == .plan ? plan : scene)?.cgImage else { continue }
            let target = PresenterComposition.aspectFit(content: CGSize(width: image.width, height: image.height), in: pane.cell)
            // Composition rectangles are top-left based; the bitmap context is bottom-left based.
            let flipped = CGRect(x: target.minX, y: CGFloat(h) - target.maxY, width: target.width, height: target.height)
            ctx.draw(image, in: flipped)
        }
        return true
    }
}
