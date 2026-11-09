import CoreGraphics
import Foundation
import RoomsmithCore

/// View transform of the plan: model millimetres (X east, Y north) <-> view points (y grows downwards).
struct PlanViewport: Equatable {
    static let minScale = 0.002
    static let maxScale = 4.0

    /// Model point shown in the middle of the view.
    var center = V2(4000, 3000)
    /// Points per millimetre.
    var scale = 0.1
    var size = CGSize(width: 800, height: 600)

    func screen(_ p: V2) -> CGPoint {
        CGPoint(x: (p.x - center.x) * scale + size.width / 2, y: size.height / 2 - (p.y - center.y) * scale)
    }
    func screen(_ p: P2) -> CGPoint { screen(p.v) }

    func model(_ s: CGPoint) -> V2 {
        V2(center.x + (Double(s.x) - Double(size.width) / 2) / scale, center.y - (Double(s.y) - Double(size.height) / 2) / scale)
    }

    /// Length in mm of `px` view points at the current zoom.
    func mm(_ px: Double) -> Double { px / scale }

    /// Visible model rectangle.
    var visible: (lo: V2, hi: V2) {
        let a = model(CGPoint(x: 0, y: size.height)), b = model(CGPoint(x: size.width, y: 0))
        return (V2(min(a.x, b.x), min(a.y, b.y)), V2(max(a.x, b.x), max(a.y, b.y)))
    }

    /// Zooms by `factor`, keeping the model point under `anchor` fixed.
    mutating func zoom(by factor: Double, around anchor: CGPoint) {
        let r = PlanGesture.zoomed(center: center, scale: scale, viewSize: (Double(size.width), Double(size.height)), factor: factor,
                                   anchor: (Double(anchor.x), Double(anchor.y)), scaleRange: Self.minScale ... Self.maxScale)
        center = r.center
        scale = r.scale
    }

    /// Moves the content by (dx, dy) view points (content follows the fingers).
    mutating func pan(dx: Double, dy: Double) {
        center = V2(center.x - dx / scale, center.y + dy / scale)
    }

    /// Fits the model rectangle into the view with a margin in points.
    mutating func fit(lo: V2, hi: V2, margin: Double = 56, maxScale: Double = 0.4) {
        guard size.width > 0, size.height > 0 else { return }
        let w = max(hi.x - lo.x, 200), h = max(hi.y - lo.y, 200)
        let sx = max(Double(size.width) - 2 * margin, 40) / w
        let sy = max(Double(size.height) - 2 * margin, 40) / h
        scale = min(maxScale, max(Self.minScale, min(sx, sy)))
        center = (lo + hi) / 2
    }
}

/// Grid spacing and scale bar lengths that adapt to the zoom.
enum PlanGrid {
    private static let steps: [Double] = {
        var out: [Double] = []
        var decade = 10.0
        while decade <= 1_000_000 { out += [decade, decade * 2, decade * 5]; decade *= 10 }
        return out
    }()

    /// Minor spacing is the first step that is at least `minPx` wide; major lines are every power of ten above it.
    static func spacing(scale: Double, minPx: Double = 11) -> (minor: Double, major: Double) {
        let minor = steps.first { $0 * scale >= minPx } ?? steps.last!
        let major = pow(10, ceil(log10(minor * 1.5)))
        return (minor, major)
    }

    /// A round length (mm) whose bar is between 70 and ~170 points long.
    static func scaleBarLength(scale: Double) -> Double {
        steps.first { $0 * scale >= 70 } ?? steps.last!
    }
}
