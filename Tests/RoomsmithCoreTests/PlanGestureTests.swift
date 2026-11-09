import Testing
import Foundation
import simd
@testable import RoomsmithCore

@Suite("PlanGesture")
struct PlanGestureTests {
    @Test func pinchFactorIsClampedAndPositive() {
        #expect(PlanGesture.pinchFactor(magnification: 0.1) == 1.1)
        #expect(PlanGesture.pinchFactor(magnification: -1) == 0.2)
        #expect(PlanGesture.pinchFactor(magnification: -7) == 0.2)
        #expect(PlanGesture.pinchFactor(magnification: 100) == 5)
        #expect(PlanGesture.pinchFactor(magnification: .nan) == 1)
        #expect(PlanGesture.pinchFactor(magnification: .infinity) == 1)
    }

    @Test func zoomKeepsPointUnderCursor() {
        let center = V2(4000, 3000), size = (w: 800.0, h: 600.0)
        let anchor = (x: 123.0, y: 457.0)
        func model(_ c: V2, _ s: Double) -> V2 {
            V2(c.x + (anchor.x - size.w / 2) / s, c.y - (anchor.y - size.h / 2) / s)
        }
        let before = model(center, 0.1)
        for f in [0.5, 1.3, 2.0, 0.2, 3.7] {
            let r = PlanGesture.zoomed(center: center, scale: 0.1, viewSize: size, factor: f, anchor: anchor, scaleRange: 0.002 ... 4)
            let after = model(r.center, r.scale)
            #expect(abs(after.x - before.x) < 1e-6 && abs(after.y - before.y) < 1e-6)
            #expect(abs(r.scale - 0.1 * f) < 1e-12)
        }
    }

    @Test func zoomRespectsLimitsAndStillAnchors() {
        let size = (w: 800.0, h: 600.0), anchor = (x: 700.0, y: 50.0)
        let hi = PlanGesture.zoomed(center: V2(0, 0), scale: 3.9, viewSize: size, factor: 5, anchor: anchor, scaleRange: 0.002 ... 4)
        #expect(hi.scale == 4)
        let lo = PlanGesture.zoomed(center: V2(0, 0), scale: 0.003, viewSize: size, factor: 0.2, anchor: anchor, scaleRange: 0.002 ... 4)
        #expect(lo.scale == 0.002)
        let m0 = V2((anchor.x - 400) / 3.9, -(anchor.y - 300) / 3.9)
        let m1 = V2(hi.center.x + (anchor.x - 400) / hi.scale, hi.center.y - (anchor.y - 300) / hi.scale)
        #expect(abs(m0.x - m1.x) < 1e-9 && abs(m0.y - m1.y) < 1e-9)
    }

    @Test func invalidFactorLeavesViewUntouched() {
        for f in [0.0, -1.0, .nan, .infinity] {
            let r = PlanGesture.zoomed(center: V2(1, 2), scale: 0.1, viewSize: (800, 600), factor: f, anchor: (10, 10), scaleRange: 0.002 ... 4)
            #expect(r.center == V2(1, 2) && r.scale == 0.1)
        }
    }

    @Test func wheelZoomsInFixedSteps() {
        #expect(PlanGesture.scrollZoomFactor(deltaY: 1, precise: false) == PlanGesture.wheelStep)
        #expect(PlanGesture.scrollZoomFactor(deltaY: 9, precise: false) == PlanGesture.wheelStep)
        #expect(PlanGesture.scrollZoomFactor(deltaY: -3, precise: false) == 1 / PlanGesture.wheelStep)
        #expect(PlanGesture.scrollZoomFactor(deltaY: 0, precise: false) == 1)
        let up = PlanGesture.scrollZoomFactor(deltaY: 10, precise: true), down = PlanGesture.scrollZoomFactor(deltaY: -10, precise: true)
        #expect(up > 1 && abs(up * down - 1) < 1e-12)
        #expect(PlanGesture.scrollZoomFactor(deltaY: .nan, precise: true) == 1)
    }

    @Test func shiftWheelPansHorizontally() {
        #expect(PlanGesture.shiftWheelPan(deltaX: 2, deltaY: 0) == 2 * PlanGesture.wheelPanPoints)
        #expect(PlanGesture.shiftWheelPan(deltaX: 0, deltaY: -1) == -PlanGesture.wheelPanPoints)
        #expect(PlanGesture.shiftWheelPan(deltaX: .nan, deltaY: 0) == 0)
    }

    @Test func rotationSnapsToStepAndWrapsShortWay() {
        #expect(PlanGesture.rotationDelta(accumulated: 7, startRotation: 0, step: 15, snap: true) == 0)
        #expect(PlanGesture.rotationDelta(accumulated: 8, startRotation: 0, step: 15, snap: true) == 15)
        #expect(PlanGesture.rotationDelta(accumulated: 10, startRotation: 12, step: 15, snap: true) == 3) // 22 -> 15
        #expect(PlanGesture.rotationDelta(accumulated: 8.4, startRotation: 0, step: 15, snap: false) == 8.4)
        #expect(PlanGesture.rotationDelta(accumulated: -30, startRotation: 10, step: 15, snap: true) == -25) // -20 -> -15 = 345
        #expect(PlanGesture.rotationDelta(accumulated: 200, startRotation: 0, step: 15, snap: false) == -160)
        #expect(PlanGesture.rotationDelta(accumulated: .nan, startRotation: 0, step: 15, snap: true) == 0)
    }

    @Test func rotatingByGestureDeltaTurnsSelectionAroundItsCentre() throws {
        var p = Project.empty(name: "T")
        let lvl = p.levels[0].id
        let a = Wall(levelId: lvl, start: P2(0, 0), end: P2(2000, 0))
        p.walls.append(a)
        let d = PlanGesture.rotationDelta(accumulated: 91, startRotation: 0, step: 15, snap: true)
        #expect(d == 90)
        try p.rotateObjects([a.id], by: d)
        let w = try #require(p.wall(a.id))
        #expect(abs(Double(w.start.x) - 1000) < 1 && abs(Double(w.start.y) - (-1000)) < 1)
        #expect(abs(Double(w.end.x) - 1000) < 1 && abs(Double(w.end.y) - 1000) < 1)
    }

    @Test func rotationStateMachine() {
        typealias G = PlanGesture
        func a(_ p: G.RotationPhase, active: Bool = false, mouse: Bool = false, sel: Bool = false) -> G.RotationAction {
            G.rotationAction(phase: p, active: active, mouseDown: mouse, selectionChanged: sel)
        }
        #expect(a(.began) == .begin)
        #expect(a(.began, mouse: true) == .none)
        #expect(a(.began, active: true) == .discardAndBegin) // orphaned gesture is restored first
        #expect(a(.changed) == .none)
        #expect(a(.changed, active: true) == .update)
        #expect(a(.ended, active: true) == .commit)
        // a pressed button or a changed selection cancels (restore) instead of being ignored
        #expect(a(.changed, active: true, mouse: true) == .cancel)
        #expect(a(.ended, active: true, mouse: true) == .cancel)
        #expect(a(.ended, active: true, sel: true) == .cancel)
        #expect(a(.cancelled, active: true) == .cancel)
        #expect(a(.cancelled) == .none)
        #expect(a(.ended) == .none)
    }

    @Test func signedDisplayAngle() {
        #expect(PlanGesture.signedDisplayAngle(345) == -15)
        #expect(PlanGesture.signedDisplayAngle(-15) == -15)
        #expect(PlanGesture.signedDisplayAngle(15) == 15)
        #expect(PlanGesture.signedDisplayAngle(-0.04) == 0)
        #expect(String(format: "%+.1f", PlanGesture.signedDisplayAngle(-0.04)) == "+0.0")
        #expect(PlanGesture.signedDisplayAngle(180) == 180)
    }
}
