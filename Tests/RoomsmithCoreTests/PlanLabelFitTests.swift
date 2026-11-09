import Testing
import Foundation
@testable import RoomsmithCore

@Suite("Plan label fitting") struct PlanLabelFitTests {
    typealias Box = PlanLabelFit.Box

    @Test func dimensionTextNeedsTheSegmentToBeLongerThanTheText() {
        #expect(PlanLabelFit.dimensionTextFits(textWidth: 36, segmentPixels: 60))
        #expect(!PlanLabelFit.dimensionTextFits(textWidth: 36, segmentPixels: 40))
        #expect(PlanLabelFit.dimensionTextFits(textWidth: 36, segmentPixels: 44))
    }

    @Test func neighbouringLabelsAreNotDrawnOnTopOfEachOther() {
        let a = Box(centerX: 100, centerY: 50, halfWidth: 18, halfHeight: 7)
        let near = Box(centerX: 125, centerY: 50, halfWidth: 18, halfHeight: 7)
        let far = Box(centerX: 160, centerY: 50, halfWidth: 18, halfHeight: 7)
        let above = Box(centerX: 100, centerY: 80, halfWidth: 18, halfHeight: 7)
        #expect(PlanLabelFit.overlaps(a, near))
        #expect(!PlanLabelFit.overlaps(a, far))
        #expect(!PlanLabelFit.overlaps(a, above))
        #expect(!PlanLabelFit.shouldDrawDimension(textWidth: 36, segmentPixels: 200, box: near, placed: [a]))
        #expect(PlanLabelFit.shouldDrawDimension(textWidth: 36, segmentPixels: 200, box: far, placed: [a]))
        #expect(!PlanLabelFit.shouldDrawDimension(textWidth: 36, segmentPixels: 30, box: far, placed: []))
    }

    @Test func rotatedTextBoxSwapsItsExtent() {
        let b = Box(centerX: 0, centerY: 0, width: 40, height: 10, angle: .pi / 2)
        #expect(abs(b.halfWidth - 5) < 1e-9 && abs(b.halfHeight - 20) < 1e-9)
    }

    @Test func furnitureNameUsesTheFullBoxOfAlignedPieces() {
        // 120 x 60 px piece turned by 0 or 90 degrees: the box is the piece.
        #expect(PlanLabelFit.furnitureNameWidth(boxPixels: 120, longSidePixels: 120, shortSidePixels: 60) == 116)
        #expect(PlanLabelFit.furnitureNameWidth(boxPixels: 60, longSidePixels: 120, shortSidePixels: 60) == 56)
        // Slanted: box is wider than the piece, keep short side + overhang.
        #expect(PlanLabelFit.furnitureNameWidth(boxPixels: 100, longSidePixels: 120, shortSidePixels: 60) == 80)
    }

    @Test func furnitureNameShrinksBeforeItIsCut() {
        #expect(PlanLabelFit.furnitureNameFit(widthAtMax: 40, available: 50) == .init(fontSize: 10, truncated: false))
        let shrunk = PlanLabelFit.furnitureNameFit(widthAtMax: 50, available: 42)
        #expect(!shrunk.truncated && shrunk.fontSize < 10 && shrunk.fontSize >= 8)
        #expect(shrunk.fontSize * 50 / 10 <= 42)
        #expect(PlanLabelFit.furnitureNameFit(widthAtMax: 60, available: 40) == .init(fontSize: 8, truncated: true))
    }
}
