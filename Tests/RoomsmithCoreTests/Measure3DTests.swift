import Testing
@testable import RoomsmithCore

@Suite("Measure3D") struct Measure3DTests {
    @Test func distanceIsStraightLineIncludingHeight() {
        let m = Measurement3D(a: P3(0, 0, 0), b: P3(3000, 4000, 0))
        #expect(m.distanceMm == 5000)
        let up = Measurement3D(a: P3(0, 0, 0), b: P3(2000, 3000, 6000))
        #expect(up.distanceMm == 7000)
        #expect(up.dx == 2000 && up.dy == 3000 && up.dz == 6000)
    }

    @Test func componentsAreSignedFromAToB() {
        let m = Measurement3D(a: P3(1000, 2000, 500), b: P3(400, 2600, 2500))
        #expect(m.dx == -600 && m.dy == 600 && m.dz == 2000)
        #expect(m.componentsText(unit: .mm) == "dx -600 mm   dy 600 mm   dz 2000 mm")
        #expect(m.componentsText(unit: .m) == "dx -0.6 m   dy 0.6 m   dz 2 m")
    }

    @Test func distanceRoundsToWholeMillimetres() {
        // sqrt(1 + 1) = 1.414... -> 1
        #expect(Measurement3D(a: .zero, b: P3(1, 1, 0)).distanceMm == 1)
        // sqrt(1000^2 + 1000^2) = 1414.21... -> 1414
        #expect(Measurement3D(a: .zero, b: P3(1000, 1000, 0)).distanceMm == 1414)
        #expect(Measurement3D(a: .zero, b: .zero).distanceMm == 0)
    }

    @Test func textMatchesThePlanFormat() {
        #expect(DistanceText.text(mm: 4250, unit: .mm) == "4250 mm")
        #expect(DistanceText.text(mm: 4250, unit: .cm) == "425 cm  (4250 mm)")
        #expect(DistanceText.text(mm: 4250, unit: .m) == "4.25 m  (4250 mm)")
        let m = Measurement3D(a: .zero, b: P3(3000, 4000, 0))
        #expect(m.distanceText(unit: .m) == "5 m  (5000 mm)")
        #expect(m.labelLines(unit: .mm) == ["5000 mm", "dx 3000 mm   dy 4000 mm   dz 0 mm"])
    }

    @Test func clicksCycleThroughAThenBThenRestart() {
        var s = Measure3DState()
        #expect(s.isEmpty && s.finished == nil)
        s.click(P3(0, 0, 0))
        #expect(s.isPending && s.finished == nil)
        s.click(P3(0, 0, 0)) // same point: ignored
        #expect(s.isPending)
        s.click(P3(1000, 0, 0))
        #expect(!s.isPending)
        #expect(s.finished == Measurement3D(a: .zero, b: P3(1000, 0, 0)))
        s.click(P3(500, 500, 0)) // third click starts over
        #expect(s.isPending && s.a == P3(500, 500, 0) && s.b == nil)
        s.clear()
        #expect(s.isEmpty)
    }
}
