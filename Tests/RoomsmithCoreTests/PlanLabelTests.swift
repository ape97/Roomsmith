import Testing
import Foundation
import simd
@testable import RoomsmithCore

@Suite("Plan export furniture labels") struct PlanLabelTests {
    /// Paper-space rectangle (mm) centred at the origin, rotated by `deg`.
    func rect(_ w: Double, _ h: Double, deg: Double = 0) -> [V2] {
        let r = deg * .pi / 180, c = cos(r), s = sin(r)
        return [V2(-w / 2, -h / 2), V2(w / 2, -h / 2), V2(w / 2, h / 2), V2(-w / 2, h / 2)].map { V2($0.x * c - $0.y * s, $0.x * s + $0.y * c) }
    }

    @Test func shortNameFitsLongNameIsCutTinyPieceHasNone() {
        #expect(PlanExport.furnitureLabel("Sofa", footprint: rect(20, 9)) == "Sofa")
        let cut = PlanExport.furnitureLabel("Refrigerator with freezer", footprint: rect(14, 9))
        #expect(cut?.hasSuffix("…") == true)
        if let cut { #expect(PlanExport.textWidth(cut, size: PlanExport.furnitureLabelSize, bold: false) <= 14 - 0.6) }
        if let cut { #expect(cut.count - 1 >= PlanExport.furnitureLabelMinChars) }
        // Only a stub ("Off…") would fit: no label at all.
        #expect(PlanExport.furnitureLabel("Office chair", footprint: rect(6, 6)) == nil)
        #expect(PlanExport.furnitureLabel("Table lamp", footprint: rect(3, 3)) == nil)
        #expect(PlanExport.furnitureLabel("   ", footprint: rect(30, 30)) == nil)
    }

    @Test func roomFollowsTheHorizontalChordOfRotatedPieces() {
        // A 40 x 5 mm piece rotated by 90 degrees is 5 mm wide on paper: no full name fits.
        #expect(PlanExport.furnitureLabel("Bookshelf", footprint: rect(40, 5, deg: 90)) == nil)
        // Square of side 10 rotated by 45 degrees: the horizontal chord through the centre is 10·√2 ≈ 14.1 mm.
        let w = PlanExport.textWidth("Desk lamp", size: PlanExport.furnitureLabelSize, bold: false)
        #expect(w < 13.5)
        #expect(PlanExport.furnitureLabel("Desk lamp", footprint: rect(10, 10, deg: 45)) == "Desk lamp")
    }

    @Test func textBoxCornersMustStayInsideSlantedPieces() {
        // 30 x 4 mm rotated by 20 degrees: the chord through the centre is about 11.7 mm and would take "Desk lamp"
        // (about 10.4 mm), but the top and bottom of the text would stick out of the slanted long sides.
        let w = PlanExport.textWidth("Desk lamp", size: PlanExport.furnitureLabelSize, bold: false)
        #expect(w < 11)
        #expect(PlanExport.furnitureLabel("Desk lamp", footprint: rect(30, 4, deg: 20)) == nil)
        // Unrotated the same piece has room for it.
        #expect(PlanExport.furnitureLabel("Desk lamp", footprint: rect(30, 4)) == "Desk lamp")
    }
}

@Suite("Plan export room label backdrop") struct RoomLabelBackdropTests {
    /// Square room of side `side` mm enclosed by 240 mm walls on its outline, exported at 1:50.
    func backdrops(side: MM, name: String) -> Int {
        var p = Project.empty(name: "Backdrop")
        let lid = p.levels[0].id
        let pts = [P2(0, 0), P2(side, 0), P2(side, side), P2(0, side)]
        for i in 0..<4 { p.walls.append(Wall(levelId: lid, start: pts[i], end: pts[(i + 1) % 4], thickness: 240, height: 2500)) }
        p.rooms = [Room(levelId: lid, name: name, points: pts)]
        let d = PlanExport.makeDrawing(p, options: .init(levelId: lid, scale: 50))
        let labels = d.layers.first { $0.name == "labels" }?.items ?? []
        return labels.filter { if case .polygon = $0 { return true } else { return false } }.count
    }

    @Test func backdropOnlyWhereItCoversNothingButTheFloor() {
        #expect(backdrops(side: 5000, name: "Living room") == 1)
        // 1 m x 1 m at 1:50 is 20 mm on paper minus the walls: the name box would paint over the walls.
        #expect(backdrops(side: 1000, name: "Storage cupboard") == 0)
    }

    @Test func boxGeometryHelpers() {
        let square = [V2(0, 0), V2(10, 0), V2(10, 10), V2(0, 10)]
        #expect(PlanExport.boxInside(CGRect(x: 2, y: 2, width: 3, height: 3), square))
        #expect(!PlanExport.boxInside(CGRect(x: 8, y: 2, width: 3, height: 3), square))
        // U shape: the box spans the notch with all four corners on the arms.
        let u = [V2(0, 0), V2(10, 0), V2(10, 10), V2(6, 10), V2(6, 3), V2(4, 3), V2(4, 10), V2(0, 10)]
        #expect(!PlanExport.boxInside(CGRect(x: 1, y: 5, width: 8, height: 2), u))
        #expect(PlanExport.boxTouches(CGRect(x: 9, y: 9, width: 3, height: 3), square))
        #expect(!PlanExport.boxTouches(CGRect(x: 11, y: 11, width: 2, height: 2), square))
    }
}
