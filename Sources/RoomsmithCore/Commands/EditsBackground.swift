import Foundation

/// Background image calibration. Pixel positions are image pixels from the top-left corner (x right, y down); the
/// world position of pixel (px, py) is `origin + (px * mmPerPixel, -py * mmPerPixel)`.
public extension Project {
    /// World position (mm, unrounded) of an image pixel of a background.
    func backgroundWorld(_ b: BackgroundImage, pixel: P2) -> V2 {
        let s = b.mmPerPixel
        return V2(Double(b.origin.x) + Double(pixel.x) * s, Double(b.origin.y) - Double(pixel.y) * s)
    }

    /// Sets the scale from two image pixels and their real distance: `mmPerPixel = realLength / |pixelB - pixelA|`
    /// (exact in Double; `realLength` is stored as given). The world position of pixel A stays where it is, or moves
    /// to `worldA` when given; the stored origin is rounded to whole mm (at most 0.5 mm off per axis).
    mutating func calibrateBackground(_ id: UUID, pixelA: P2, pixelB: P2, realLength: MM, worldA: P2? = nil) throws {
        try ensureEditable(id)
        guard let bg = background(id) else { throw CommandError.notFound("Background image", id) }
        guard pixelA.x >= 0, pixelA.y >= 0, pixelB.x >= 0, pixelB.y >= 0 else {
            throw CommandError.invalid("Calibration pixels must not be negative", ids: [id])
        }
        guard pixelA.isInRange, pixelB.isInRange else { throw CommandError.range("Calibration pixels out of range", ids: [id]) }
        guard pixelA != pixelB else { throw CommandError.invalid("Calibration points must differ", ids: [id]) }
        guard sizeLimit.contains(realLength) else {
            throw CommandError.range("Calibration length must be between \(sizeLimit.lowerBound) and \(sizeLimit.upperBound) mm", ids: [id])
        }
        let anchor = worldA.map { V2(Double($0.x), Double($0.y)) } ?? backgroundWorld(bg, pixel: pixelA)
        let dx = Double(pixelB.x) - Double(pixelA.x), dy = Double(pixelB.y) - Double(pixelA.y)
        let mmpp = Double(realLength) / (dx * dx + dy * dy).squareRoot()
        let ox = (anchor.x - Double(pixelA.x) * mmpp).rounded(.toNearestOrAwayFromZero)
        let oy = (anchor.y + Double(pixelA.y) * mmpp).rounded(.toNearestOrAwayFromZero)
        guard let origin = Self.exactPoint(ox, oy), origin.isInRange else {
            throw CommandError.range("The calibrated image would lie outside ±\(coordinateLimit) mm", ids: [id])
        }
        try updateBackground(id) { b in
            b.calibrationA = pixelA; b.calibrationB = pixelB; b.calibrationLength = realLength; b.origin = origin
        }
    }

    private static func exactPoint(_ x: Double, _ y: Double) -> P2? {
        guard let ix = Int64(exactly: x), let iy = Int64(exactly: y) else { return nil }
        return P2(ix, iy)
    }
}
