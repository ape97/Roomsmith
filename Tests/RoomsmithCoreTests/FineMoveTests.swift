import Testing
@testable import RoomsmithCore

@Suite("FineMove") struct FineMoveTests {
    @Test func withoutFineTheOffsetIsTheRawOffset() {
        var m = FineMotion()
        #expect(m.advance(raw: V2(100, -40), fine: false) == V2(100, -40))
        #expect(m.advance(raw: V2(250, 10), fine: false) == V2(250, 10))
    }

    @Test func fineScalesTheTravelToATenth() {
        var m = FineMotion()
        let out = m.advance(raw: V2(100, -50), fine: true)
        #expect(abs(out.x - 10) < 1e-9 && abs(out.y + 5) < 1e-9)
    }

    @Test func pressingSpaceMidDragDoesNotJump() {
        var m = FineMotion()
        let before = m.advance(raw: V2(200, 0), fine: false)
        // The cursor stands still while Space goes down: the offset stays.
        #expect(m.advance(raw: V2(200, 0), fine: true) == before)
        // Further travel is scaled from where the piece is.
        let after = m.advance(raw: V2(300, 0), fine: true)
        #expect(abs(after.x - 210) < 1e-9)
    }

    @Test func releasingSpaceMidDragDoesNotJump() {
        var m = FineMotion()
        let a = m.advance(raw: V2(100, 0), fine: true)
        #expect(m.advance(raw: V2(100, 0), fine: false) == a)
        let b = m.advance(raw: V2(150, 0), fine: false)
        #expect(abs(b.x - (a.x + 50)) < 1e-9)
    }

    @Test func pressingSpaceAtASnappedOrStoppedPositionContinuesFromTheShownOffset() {
        var m = FineMotion()
        // The cursor ran 300 mm, but the piece stands stopped at 120 mm.
        _ = m.advance(raw: V2(300, 0), fine: false)
        m.show(V2(120, 0))
        #expect(m.advance(raw: V2(300, 0), fine: true) == V2(120, 0))
        let after = m.advance(raw: V2(400, 0), fine: true)
        #expect(abs(after.x - 130) < 1e-9)
        m.show(after)
        // Releasing continues from the fine position too.
        #expect(m.advance(raw: V2(400, 0), fine: false) == after)
    }

    @Test func movingBackReturnsAlongTheSamePathInFineMode() {
        var m = FineMotion()
        _ = m.advance(raw: V2(500, 0), fine: true)
        let back = m.advance(raw: V2(0, 0), fine: true)
        #expect(abs(back.x) < 1e-9)
    }

    @Test func axisVariantMatchesTheVectorVariant() {
        var a = FineMotion(), b = FineMotion()
        #expect(a.advance(raw: 80.0, fine: true) == b.advance(raw: V2(80, 0), fine: true).x)
    }
}
