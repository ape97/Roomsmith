import Foundation
import simd

/// Pure math behind the trackpad and mouse gestures of the 2D plan (kept free of AppKit so it can be tested).
public enum PlanGesture {
    /// Zoom factor limits for one single pinch event.
    public static let pinchRange: ClosedRange<Double> = 0.2 ... 5
    /// Zoom factor of one notch of a mouse wheel without precise deltas.
    public static let wheelStep = 1.2
    /// View points moved per line of a mouse wheel without precise deltas (shift + wheel).
    public static let wheelPanPoints = 14.0

    /// Factor for a pinch event (`NSEvent.magnification`); never <= 0, NaN or wildly large.
    public static func pinchFactor(magnification: Double) -> Double {
        guard magnification.isFinite else { return 1 }
        return min(pinchRange.upperBound, max(pinchRange.lowerBound, 1 + magnification))
    }

    /// Factor for a scroll event used as zoom. Precise (trackpad) deltas zoom continuously, a wheel in fixed steps.
    public static func scrollZoomFactor(deltaY: Double, precise: Bool) -> Double {
        guard deltaY.isFinite, deltaY != 0 else { return 1 }
        if precise { return exp(min(60, max(-60, deltaY)) * 0.01) }
        return deltaY > 0 ? wheelStep : 1 / wheelStep
    }

    /// Horizontal pan (view points) of a mouse wheel notch with shift held. Systems that swap the axes report the
    /// delta in X already, others in Y.
    public static func shiftWheelPan(deltaX: Double, deltaY: Double) -> Double {
        let d = deltaX != 0 ? deltaX : deltaY
        guard d.isFinite else { return 0 }
        return d * wheelPanPoints
    }

    /// New view center and scale after zooming by `factor` so that the model point under `anchor` (view points,
    /// y down) stays under it. The scale is clamped to `scaleRange`.
    public static func zoomed(center: V2, scale: Double, viewSize: (w: Double, h: Double), factor: Double,
                              anchor: (x: Double, y: Double), scaleRange: ClosedRange<Double>) -> (center: V2, scale: Double) {
        guard factor.isFinite, factor > 0, scale > 0 else { return (center, scale) }
        let mx = center.x + (anchor.x - viewSize.w / 2) / scale
        let my = center.y - (anchor.y - viewSize.h / 2) / scale
        let s = min(scaleRange.upperBound, max(scaleRange.lowerBound, scale * factor))
        return (V2(mx - (anchor.x - viewSize.w / 2) / s, my + (anchor.y - viewSize.h / 2) / s), s)
    }

    /// Rotation delta in degrees (-180, 180] for a rotation gesture that has turned by `accumulated` degrees.
    /// With snapping the resulting absolute rotation (`startRotation + delta`) lands on the `step` grid.
    public static func rotationDelta(accumulated: Double, startRotation: Double, step: Double, snap: Bool) -> Double {
        guard accumulated.isFinite else { return 0 }
        let target = SnapEngine.snapAngle(startRotation + accumulated, step: step, enabled: snap)
        var delta = (target - startRotation).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 } else if delta <= -180 { delta += 360 }
        return delta
    }

    // MARK: Rotation gesture state machine

    public enum RotationPhase: Sendable { case began, changed, ended, cancelled }

    public enum RotationAction: Sendable, Equatable {
        /// Nothing to do.
        case none
        /// Start a gesture and apply the first change.
        case begin
        /// A stale gesture hangs around: restore it, then start a new one.
        case discardAndBegin
        /// Apply the change to the live preview.
        case update
        /// Finish with exactly one undo step.
        case commit
        /// Restore the original state.
        case cancel
    }

    /// What a rotation gesture event has to do. Only the gesture's own state decides about change/end/cancel: a mouse
    /// button going down or a changed selection cancels the running gesture (never leaves it dangling).
    public static func rotationAction(phase: RotationPhase, active: Bool, mouseDown: Bool, selectionChanged: Bool) -> RotationAction {
        switch phase {
        case .began:
            if mouseDown { return .none }
            return active ? .discardAndBegin : .begin
        case .changed, .ended:
            guard active else { return .none }
            if mouseDown || selectionChanged { return .cancel }
            return phase == .changed ? .update : .commit
        case .cancelled:
            return active ? .cancel : .none
        }
    }

    /// Angle shown to the user for a rotation delta: signed (-15 instead of 345), no negative zero, one decimal.
    public static func signedDisplayAngle(_ deg: Double) -> Double {
        var d = deg.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d <= -180 { d += 360 }
        d = (d * 10).rounded() / 10
        return d == 0 ? 0 : d
    }
}
