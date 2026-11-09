import Testing
import Foundation
import simd
@testable import RoomsmithCore

@Suite("LengthParse") struct LengthParseTests {
    @Test func rejectsMalformed() {
        for bad in ["5-3", "-", "--5", "1.2.3", "1,5,5", "", " ", "abc", "5 x", "5mm3", "m", "1e3", "+-5", "5..3"] {
            #expect(LengthUnit.parse(bad, defaultUnit: .mm) == nil, "\(bad)")
        }
    }

    @Test func acceptsUnitsAndSeparators() {
        #expect(LengthUnit.parse("2.5 m") == 2500)
        #expect(LengthUnit.parse("250 cm") == 2500)
        #expect(LengthUnit.parse("2500 mm") == 2500)
        #expect(LengthUnit.parse("2,5m") == 2500)
        #expect(LengthUnit.parse("3.5 M") == 3500)
        #expect(LengthUnit.parse("-1.5m") == -1500)
        #expect(LengthUnit.parse("- 20 cm") == -200)
        #expect(LengthUnit.parse("0.5 mm") == nil)
    }

    @Test func bareNumbersUseDefaultUnit() {
        #expect(LengthUnit.parse("250", defaultUnit: .cm) == 2500)
        #expect(LengthUnit.parse("2.5", defaultUnit: .m) == 2500)
        #expect(LengthUnit.parse("2500", defaultUnit: .mm) == 2500)
    }

    @Test func hintNamesUnit() {
        #expect(LengthUnit.cm.bareNumberHint == "cm unless you add mm or m")
    }

    @Test func pointAtLengthIsAccurate() {
        let origins = [P2(0, 0), P2(1234, -5678), P2(-100_001, 77_777)]
        var worst = 0.0
        for o in origins {
            for deg in stride(from: 0.0, to: 360.0, by: 15.0) + [1.0, 7.3, 33.3, 44.9] {
                let r = deg * .pi / 180
                let dir = V2(cos(r), sin(r))
                for len in [1.0, 37.0, 1000.0, 3517.0, 12_345.0, 99_999.0] {
                    let p = P2(origin: o, direction: dir, length: len)
                    let err = abs(simd_length(p.v - o.v) - len)
                    worst = max(worst, err)
                    #expect(err <= 0.5 + 1e-9, "\(deg) \(len) \(err)")
                }
            }
        }
        #expect(worst <= 0.5 + 1e-9)
    }

    @Test func axisParallelIsExact() {
        let o = P2(100, 200)
        #expect(P2(origin: o, direction: V2(1, 0), length: 3500) == P2(3600, 200))
        #expect(P2(origin: o, direction: V2(0, 1), length: 3500) == P2(100, 3700))
        #expect(P2(origin: o, direction: V2(cos(Double.pi / 2), 1), length: 3500) == P2(100, 3700))
        #expect(P2(origin: o, direction: V2(-1, 0), length: 10) == P2(90, 200))
    }

    @Test func rejectsNonAsciiDigitsAndOverflow() {
        #expect(LengthUnit.parse("5\u{0663}", defaultUnit: .cm) == nil)
        #expect(LengthUnit.parse("\u{FF11}\u{FF12}") == nil)
        #expect(LengthUnit.parse("100001 m") == nil)
        #expect(LengthUnit.parse("100000 m") == 100_000_000)
        #expect(LengthUnit.parse("1,000") == 1)
        #expect(LengthUnit.parse("1.0000001 m") == nil)
    }
}
