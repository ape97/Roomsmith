import CoreGraphics
import Foundation
import Observation
import RoomsmithCore

/// Laser pointer for the presenter: a visible ring and dot drawn into the plan frame (the system cursor never reaches the TV).
/// The main window reports the position in plan millimetres (`report`); off by default.
@MainActor
@Observable
final class PresenterPointer {
    var isEnabled = false
    /// Last reported position in plan millimetres, nil while the mouse is outside the plan.
    private(set) var position: P2?

    func report(_ p: P2?) { position = p }

    /// The position to draw, nil while disabled or unknown.
    var visiblePosition: P2? { isEnabled ? position : nil }

    /// Draws the marker at a screen point of a flipped (y down) context.
    static func draw(in ctx: CGContext, at point: CGPoint) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let red = CGColor(srgbRed: 0.93, green: 0.14, blue: 0.14, alpha: 1)
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        // White halo first so the marker stays visible on dark and light drawings.
        ctx.setStrokeColor(white)
        ctx.setLineWidth(8)
        ctx.strokeEllipse(in: CGRect(x: point.x - 20, y: point.y - 20, width: 40, height: 40))
        ctx.setStrokeColor(red)
        ctx.setLineWidth(4)
        ctx.strokeEllipse(in: CGRect(x: point.x - 20, y: point.y - 20, width: 40, height: 40))
        ctx.setFillColor(white)
        ctx.fillEllipse(in: CGRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18))
        ctx.setFillColor(red)
        ctx.fillEllipse(in: CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14))
    }
}
