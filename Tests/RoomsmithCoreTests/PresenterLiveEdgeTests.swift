import Testing
@testable import RoomsmithCore

@Suite struct PresenterLiveEdgeTests {
    private func edge() -> PresenterLiveEdge { PresenterLiveEdge(threshold: 2.5, requiredSamples: 2, minInterval: 5) }

    @Test func belowAndAtThresholdNeverSeek() {
        var e = edge()
        for i in 0..<5 { #expect(e.evaluate(behind: 1.5, now: Double(i)) == .none) }
        for i in 5..<10 { #expect(e.evaluate(behind: 2.5, now: Double(i)) == .none) }
    }

    @Test func aboveThresholdNeedsTwoConsecutiveSamples() {
        var e = edge()
        #expect(e.evaluate(behind: 3.5, now: 0) == .none)
        #expect(e.evaluate(behind: 3.5, now: 1) == .seek)
    }

    @Test func justAboveThresholdCounts() {
        var e = edge()
        #expect(e.evaluate(behind: 2.51, now: 0) == .none)
        #expect(e.evaluate(behind: 2.51, now: 1) == .seek)
    }

    @Test func goodSampleResetsStreak() {
        var e = edge()
        #expect(e.evaluate(behind: 4, now: 0) == .none)
        #expect(e.evaluate(behind: 1, now: 1) == .none)
        #expect(e.evaluate(behind: 4, now: 2) == .none)
        #expect(e.evaluate(behind: 4, now: 3) == .seek)
    }

    @Test func rateLimitedToOncePerInterval() {
        var e = edge()
        _ = e.evaluate(behind: 4, now: 0)
        #expect(e.evaluate(behind: 4, now: 1) == .seek)
        for t in [2.0, 3.0, 4.0, 5.0] { #expect(e.evaluate(behind: 4, now: t) == .none) }
        // 6.0 is exactly 5 s after the seek at 1.0.
        #expect(e.evaluate(behind: 4, now: 6) == .seek)
    }

    @Test func nonFiniteSampleResets() {
        var e = edge()
        #expect(e.evaluate(behind: 4, now: 0) == .none)
        #expect(e.evaluate(behind: .nan, now: 1) == .none)
        #expect(e.evaluate(behind: 4, now: 2) == .none)
    }

    @Test func defaultsMatchTheContract() {
        var e = PresenterLiveEdge()
        #expect(e.threshold == 2.5 && e.requiredSamples == 2 && e.minInterval == 5)
        _ = e.evaluate(behind: 3, now: 0)
        #expect(e.evaluate(behind: 3, now: 1) == .seek)
        _ = e.evaluate(behind: 3, now: 2)
        #expect(e.evaluate(behind: 3, now: 5.99) == .none)
        #expect(e.evaluate(behind: 3, now: 6.0) == .seek)
    }
}
