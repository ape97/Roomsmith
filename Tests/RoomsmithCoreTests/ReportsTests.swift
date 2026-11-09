import Testing
import Foundation
import simd
@testable import RoomsmithCore

// MARK: - Helpers

private func boxDef(_ name: String = "Box", _ w: MM, _ d: MM, _ h: MM = 800) -> FurnitureDefinition {
    FurnitureDefinition(name: name, category: "t", size: Size3(w, d, h),
                        components: [Component(name: "c", shape: .box, position: P3(0, 0, h / 2), size: Size3(w, d, h))])
}

/// 4000 × 3000 room whose corners are the wall axes, with four 100 mm walls, level height 2500.
private func roomProject() -> (Project, UUID) {
    var p = Project.empty(name: "Flat")
    p.levels[0].height = 2500
    let lv = p.levels[0].id
    let pts = [P2(0, 0), P2(4000, 0), P2(4000, 3000), P2(0, 3000)]
    p.rooms = [Room(levelId: lv, name: "Living", points: pts)]
    for i in 0..<4 {
        p.walls.append(Wall(levelId: lv, start: pts[i], end: pts[(i + 1) % 4], thickness: 100, height: 2500))
    }
    return (p, lv)
}

private func place(_ p: inout Project, _ def: FurnitureDefinition, level: UUID, at: P2, rot: Double = 0, name: String? = nil) -> UUID {
    if !p.definitions.contains(where: { $0.id == def.id }) { p.definitions.append(def) }
    let i = FurnitureInstance(definitionId: def.id, levelId: level, name: name ?? def.name, position: P3(at.x, at.y, 0), rotationDeg: rot)
    p.instances.append(i)
    return i.id
}

private func boxDef(_ w: MM, _ d: MM, _ h: MM = 800) -> FurnitureDefinition { boxDef("Box", w, d, h) }

// MARK: - Room report

@Suite("RoomReport") struct RoomReportTests {
    @Test func areaPerimeterVolume() {
        let (p, _) = roomProject()
        let r = RoomReport.make(p)
        let row = r.levels[0].rooms[0]
        #expect(row.twiceFloorAreaMM2 == 24_000_000)
        #expect(row.floorAreaMM2 == 12_000_000)
        #expect(row.floorAreaSquareMetres == "12.00")
        #expect(row.perimeterMM == 14000)
        #expect(row.clearHeightMM == 2500)
        #expect(row.volumeMM3 == 30_000_000_000)
        #expect(ReportFormat.cubicMetres(row.volumeMM3!) == "30.000")
        #expect(r.twiceFloorAreaMM2 == 24_000_000)
    }

    @Test func squareMetreRoundingIsExact() {
        #expect(ReportFormat.squareMetres(twiceAreaMM2: 2_010_000) == "1.01") // 1.005 m² rounds half up
        #expect(ReportFormat.squareMetres(twiceAreaMM2: 2_009_998) == "1.00")
        #expect(ReportFormat.squareMetres(twiceAreaMM2: 0) == "0.00")
    }

    @Test func wallAreasMinusOpenings() {
        var (p, _) = roomProject()
        let south = p.walls[0]
        p.openings = [
            Opening(wallId: south.id, kind: .door, offset: 1000, width: 900, height: 2100, sill: 0),
            Opening(wallId: south.id, kind: .window, offset: 3000, width: 1000, height: 1200, sill: 900),
        ]
        let row = RoomReport.make(p).levels[0].rooms[0]
        #expect(row.wallMatchedLengthMM == 14000)
        #expect(row.unmatchedEdgeLengthMM == 0)
        #expect(row.wallAreaGrossMM2 == 35_000_000)
        // door 900 × 2100 = 1.89 m², window 1000 × 1200 = 1.2 m²
        #expect(abs(row.wallAreaNetMM2! - (35_000_000 - 1_890_000 - 1_200_000)) < 1e-3)
    }

    @Test func wallAreasOmittedWithoutWalls() {
        var (p, _) = roomProject()
        p.walls = []
        let row = RoomReport.make(p).levels[0].rooms[0]
        #expect(row.wallAreaGrossMM2 == nil)
        #expect(row.wallAreaNetMM2 == nil)
        #expect(row.unmatchedEdgeLengthMM == 14000)
        #expect(RoomReport.make(p).csv().contains("Living,12.00,14.00,2500,30.000,,,0"))
    }

    @Test func furnitureCountByPointInPolygon() {
        var (p, lv) = roomProject()
        let d = boxDef(500, 500)
        _ = place(&p, d, level: lv, at: P2(1000, 1000))
        _ = place(&p, d, level: lv, at: P2(3900, 2900))
        _ = place(&p, d, level: lv, at: P2(5000, 1000)) // outside
        let l = RoomReport.make(p).levels[0]
        #expect(l.rooms[0].furnitureCount == 2)
        #expect(l.furnitureOutsideRooms == 1)
        #expect(l.furnitureTotal == 3)
        let r = RoomReport.make(p)
        let csv = r.csv()
        #expect(csv.contains("(outside rooms)"))
        let projectLine = csv.components(separatedBy: "\r\n").first { $0.hasPrefix(",Project total") }!
        #expect(projectLine.hasSuffix(",3"))
        #expect(r.markdown().contains("(outside rooms)"))
    }

    @Test func csvQuotingAndTotals() {
        var (p, _) = roomProject()
        p.rooms[0].name = "Kitchen, \"big\""
        let csv = RoomReport.make(p).csv()
        #expect(csv.hasPrefix("Level,Room,Floor area (m²),"))
        #expect(csv.contains("\"Kitchen, \"\"big\"\"\""))
        #expect(csv.contains("Level total"))
        #expect(csv.contains("Project total"))
        #expect(csv.contains("\r\n"))
        #expect(ReportFormat.csvField("plain") == "plain")
        #expect(ReportFormat.csvField("a\nb") == "\"a\nb\"")
    }

    @Test func markdownEscapesPipes() {
        var (p, _) = roomProject()
        p.rooms[0].name = "A|B"
        let md = RoomReport.make(p).markdown()
        #expect(md.contains("A\\|B"))
        #expect(md.contains("| 12.00 |"))
        #expect(md.contains("no living-area factors"))
    }

    @Test func wallAreaRoundsDecimalHalfUp() {
        var p = Project.empty(name: "R")
        p.levels[0].height = 2500
        let lv = p.levels[0].id
        p.rooms = [Room(levelId: lv, name: "Strip", points: [P2(0, 0), P2(3010, 0), P2(3010, 1000), P2(0, 1000)])]
        p.walls = [Wall(levelId: lv, start: P2(0, 0), end: P2(3010, 0), thickness: 100, height: 2500)]
        let row = RoomReport.make(p).levels[0].rooms[0]
        #expect(row.wallAreaGrossMM2 == 7_525_000)
        #expect(ReportFormat.squareMetres(row.wallAreaGrossMM2!) == "7.53")
        #expect(RoomReport.make(p).csv().contains(",7.53,7.53,"))
    }

    @Test func volumeIsExactAndRoundedHalfUp() {
        var p = Project.empty(name: "V")
        p.levels[0].height = 1000
        let lv = p.levels[0].id
        // 2001 × 500 mm = 1 000 500 mm², × 1000 mm = 1.0005 m³
        p.rooms = [Room(levelId: lv, name: "Vol", points: [P2(0, 0), P2(2001, 0), P2(2001, 500), P2(0, 500)])]
        let r = RoomReport.make(p)
        #expect(r.levels[0].rooms[0].volumeCubicMetres == "1.001")
        #expect(r.csv().contains(",1.001,"))
        #expect(ReportFormat.metres(125) == "0.13")
    }

    @Test func fixedHasNoNegativeZero() {
        #expect(ReportFormat.fixed(0, 2) == "0.00")
        #expect(ReportFormat.fixed(-0.004, 2) == "0.00")
        #expect(ReportFormat.fixed(-1.005, 2) == "-1.01")
        #expect(ReportFormat.fixed(7.525, 2) == "7.53")
    }

    @Test func csvFieldBlocksFormulas() {
        #expect(ReportFormat.csvField("=HYPERLINK(1)").hasPrefix("'"))
        #expect(ReportFormat.csvField("@x").hasPrefix("'"))
        #expect(ReportFormat.csvField("-0.50") == "-0.50")
        #expect(ReportFormat.csvField("+5") == "+5")
    }

    @Test func wallHeightBelowLevelHeightIsUsed() {
        var (p, _) = roomProject()
        for i in p.walls.indices { p.walls[i].height = 2000 }
        p.openings = [Opening(wallId: p.walls[0].id, kind: .door, offset: 1000, width: 900, height: 2100, sill: 0)]
        let row = RoomReport.make(p).levels[0].rooms[0]
        #expect(row.wallAreaGrossMM2 == 28_000_000)
        // The door is clipped to the wall height: 900 × 2000.
        #expect(row.wallAreaNetMM2 == 26_200_000.0)
        #expect(BillOfMaterials.make(p).walls.areaMM2 == 28_000_000)
    }

    @Test func wallTallerThanLevelIsCappedInReportAndBOM() {
        var (p, _) = roomProject()
        let levelH = p.levels[0].height
        for i in p.walls.indices { p.walls[i].height = levelH + 500 }
        let row = RoomReport.make(p).levels[0].rooms[0]
        let bom = BillOfMaterials.make(p).walls
        // Both reports cap at the level's clear height and agree.
        #expect(bom.areaMM2 == bom.totalLengthMM * Double(levelH))
        #expect(row.wallAreaGrossMM2 == bom.areaMM2)
    }

    @Test func markdownCellEscapesBackslashBeforePipe() {
        #expect(ReportFormat.mdCell("A\\|B") == "A\\\\\\|B")
        #expect(ReportFormat.mdCell("a|b") == "a\\|b")
    }

    @Test func wallAreasWithoutKnownLevelHeightUseWallHeight() {
        var p = Project.empty(name: "U")
        let ghost = UUID() // level not in the project: clear height unknown
        p.rooms = [Room(levelId: ghost, name: "G", points: [P2(0, 0), P2(4000, 0), P2(4000, 3000), P2(0, 3000)])]
        p.walls = [Wall(levelId: ghost, start: P2(0, 0), end: P2(4000, 0), thickness: 100, height: 2400)]
        let row = RoomReport.make(p).levels.first { $0.name == "(unknown level)" }!.rooms[0]
        #expect(row.clearHeightMM == nil)
        #expect(row.twiceVolumeMM3 == nil)
        #expect(row.wallAreaGrossMM2 == 9_600_000)
    }

    @Test func duplicateWallCountsOnce() {
        var (p, lv) = roomProject()
        let south = p.walls[0]
        p.walls.append(Wall(levelId: lv, start: south.start, end: south.end, thickness: 100, height: 2500))
        let row = RoomReport.make(p).levels[0].rooms[0]
        #expect(row.wallMatchedLengthMM == 14000)
        #expect(row.unmatchedEdgeLengthMM == 0)
        #expect(row.wallAreaGrossMM2 == 35_000_000)
        #expect(row.overlappingWallLengthMM == 4000)
        #expect(RoomReport.make(p).markdown().contains("more than one wall"))
        let (clean, _) = roomProject()
        #expect(RoomReport.make(clean).levels[0].rooms[0].overlappingWallLengthMM == 0)
        #expect(!RoomReport.make(clean).markdown().contains("more than one wall"))
    }

    @Test func overlapUsesTallestWallAndItsOpenings() {
        var (p, lv) = roomProject()
        // A shorter duplicate (2000) with a door; the taller original (2500) is the owner and has no opening.
        let low = Wall(levelId: lv, start: p.walls[0].start, end: p.walls[0].end, thickness: 100, height: 2000)
        p.walls.append(low)
        p.openings = [Opening(wallId: low.id, kind: .door, offset: 1000, width: 900, height: 2100, sill: 0)]
        let row = RoomReport.make(p).levels[0].rooms[0]
        #expect(row.wallAreaGrossMM2 == 35_000_000)
        #expect(row.wallAreaNetMM2 == 35_000_000)
    }

    @Test func wallCoversPartOfEdge() {
        var (p, lv) = roomProject()
        p.walls = [Wall(levelId: lv, start: P2(0, 0), end: P2(2000, 0), thickness: 100, height: 2500)]
        let row = RoomReport.make(p).levels[0].rooms[0]
        #expect(row.wallMatchedLengthMM == 2000)
        #expect(row.unmatchedEdgeLengthMM == 12000)
        #expect(row.wallAreaGrossMM2 == 5_000_000)
        // Two walls on one edge with a gap between them.
        p.walls.append(Wall(levelId: lv, start: P2(3000, 0), end: P2(4000, 0), thickness: 100, height: 2500))
        let row2 = RoomReport.make(p).levels[0].rooms[0]
        #expect(row2.wallMatchedLengthMM == 3000)
        #expect(row2.wallAreaGrossMM2 == 7_500_000)
        #expect(row2.overlappingWallLengthMM == 0)
    }

    @Test func clockwiseRoomGivesSameResult() {
        var (p, _) = roomProject()
        p.rooms[0].points = p.rooms[0].points.reversed()
        let row = RoomReport.make(p).levels[0].rooms[0]
        #expect(row.floorAreaSquareMetres == "12.00")
        #expect(row.wallAreaGrossMM2 == 35_000_000)
        #expect(row.perimeterMM == 14000)
    }

    @Test func emptyProject() {
        let p = Project.empty(name: "Empty")
        let r = RoomReport.make(p)
        #expect(r.twiceFloorAreaMM2 == 0)
        #expect(r.twiceVolumeMM3 == 0)
        #expect(r.csv().contains("Project total"))
        #expect(!r.markdown().isEmpty)
        let b = BillOfMaterials.make(p)
        #expect(b.furnitureCount == 0)
        #expect(!b.csv().isEmpty && !b.markdown().isEmpty)
    }

    @Test func volumeTotalIsEmptyWhenALevelIsUnknown() {
        var (p, _) = roomProject()
        p.rooms.append(Room(levelId: UUID(), name: "Ghost", points: [P2(0, 0), P2(1000, 0), P2(1000, 1000), P2(0, 1000)]))
        let r = RoomReport.make(p)
        #expect(r.twiceVolumeMM3 == nil)
        #expect(r.levels[0].twiceVolumeMM3 == 60_000_000_000)
        let line = r.csv().components(separatedBy: "\r\n").first { $0.hasPrefix(",Project total") }!
        #expect(line.components(separatedBy: ",")[5] == "")
        #expect(r.markdown().contains("Volume totals are empty"))
    }

    @Test func roomsWithoutWallsNoteAndProjectNameEscaped() {
        var (p, _) = roomProject()
        p.walls = []
        p.name = "A|B"
        let md = RoomReport.make(p).markdown()
        #expect(md.contains("1 room without matching walls is not included in wall-area totals"))
        #expect(md.hasPrefix("# Room report: A\\|B"))
        #expect(BillOfMaterials.make(p).markdown().hasPrefix("# Bill of materials: A\\|B"))
    }
}

// MARK: - Bill of materials

@Suite("BillOfMaterials") struct BOMTests {
    @Test func groupsPricesAndWalls() {
        var (p, lv) = roomProject()
        var prod = CatalogProduct(name: "Chair X")
        prod.priceMinor = 12_345
        prod.materialText = "Oak"
        p.products = [prod]
        var chair = boxDef("Chair", 450, 500, 900)
        chair.productId = prod.id
        let table = boxDef("Table", 1600, 800, 740)
        _ = place(&p, chair, level: lv, at: P2(500, 500))
        _ = place(&p, chair, level: lv, at: P2(1500, 500))
        _ = place(&p, chair, level: lv, at: P2(2500, 500))
        _ = place(&p, table, level: lv, at: P2(2000, 1500))
        p.instances.append(FurnitureInstance(definitionId: UUID(), levelId: lv, name: "ghost", position: .zero))
        p.openings = [
            Opening(wallId: p.walls[0].id, kind: .door, offset: 1000, width: 900, height: 2100, sill: 0),
            Opening(wallId: p.walls[1].id, kind: .door, offset: 1000, width: 900, height: 2100, sill: 0),
            Opening(wallId: p.walls[2].id, kind: .window, offset: 1000, width: 1200, height: 1200, sill: 900),
        ]
        let bom = BillOfMaterials.make(p)
        #expect(bom.furnitureCount == 4)
        #expect(bom.instancesWithoutDefinition == 1)
        let c = bom.furniture.first { $0.name == "Chair" }!
        #expect(c.count == 3)
        #expect(c.unitPriceMinor == 12_345)
        #expect(c.totalPriceMinor == 37_035)
        #expect(c.material == "Oak")
        #expect((c.width, c.depth, c.height) == (450, 500, 900))
        #expect(bom.totalsMinor == ["EUR": 37_035])
        #expect(bom.unpricedCount == 1)
        #expect(bom.walls.count == 4)
        #expect(bom.walls.totalLengthMM == 14000)
        #expect(bom.walls.areaMM2 == 35_000_000)
        #expect(bom.openingCount(.door) == 2)
        #expect(bom.openings.first { $0.kind == .door }?.count == 2)
        let csv = bom.csv()
        #expect(csv.contains("furniture,Chair,3,450,500,900,Oak,EUR,123.45,370.35,,"))
        #expect(csv.contains("walls,Walls,4,,,,,,,,14.00,35.00"))
        #expect(csv.contains("openings,door,2,900,,2100"))
        #expect(bom.markdown().contains("| furniture | Chair | 3 |"))
    }

    @Test func sizeAndMaterialSplitLines() {
        var (p, lv) = roomProject()
        let mat = Material(name: "Walnut, dark", color: RGBColor(80, 50, 30))
        p.materials = [mat]
        let d = boxDef("Shelf", 800, 300, 1800)
        let a = place(&p, d, level: lv, at: P2(500, 500))
        _ = place(&p, d, level: lv, at: P2(1500, 500))
        let i = p.instances.firstIndex { $0.id == a }!
        p.instances[i].size = Size3(1000, 300, 1800)
        p.instances[i].materialOverrides = [d.components[0].id: mat.id]
        let bom = BillOfMaterials.make(p)
        #expect(bom.furniture.count == 2)
        #expect(bom.furniture.contains { $0.width == 1000 && $0.material == "Walnut, dark" })
        #expect(bom.csv().contains("\"Walnut, dark\""))
    }
}

// MARK: - Clearance

@Suite("ClearanceCheck") struct ClearanceTests {
    @Test func alignedBoxesFiveHundredApart() {
        let a = OrientedRect(center: V2(0, 0), halfSize: V2(500, 500), rotationDeg: 0)
        let b = OrientedRect(center: V2(1500, 0), halfSize: V2(500, 500), rotationDeg: 0)
        let r = ClearanceGeometry.distance(a, b)
        #expect(abs(r.distance - 500) < 1e-9)
        #expect(!r.overlaps)
    }

    @Test func rotated45ExactDistance() {
        // Square 1000 rotated 45°: its nearest corner lies 500·√2 from its centre on the x axis.
        let a = OrientedRect(center: V2(0, 0), halfSize: V2(500, 500), rotationDeg: 0)
        let cx = 500 + 500 + 500 * 2.0.squareRoot() // gap of exactly 500 mm
        let b = OrientedRect(center: V2(cx, 0), halfSize: V2(500, 500), rotationDeg: 45)
        #expect(abs(ClearanceGeometry.distance(a, b).distance - 500) < 1e-9)
        // Integer centre: 2000 → gap = 1500 - 500√2
        let c = OrientedRect(center: V2(2000, 0), halfSize: V2(500, 500), rotationDeg: 45)
        #expect(abs(ClearanceGeometry.distance(a, c).distance - (1500 - 500 * 2.0.squareRoot())) < 1e-9)
    }

    @Test func touchingAndOverlap() {
        let a = OrientedRect(center: V2(0, 0), halfSize: V2(500, 500), rotationDeg: 0)
        let touching = OrientedRect(center: V2(1000, 0), halfSize: V2(500, 500), rotationDeg: 0)
        let t = ClearanceGeometry.distance(a, touching)
        #expect(t.distance == 0 && !t.overlaps)
        let over = OrientedRect(center: V2(900, 0), halfSize: V2(500, 500), rotationDeg: 30)
        let o = ClearanceGeometry.distance(a, over)
        #expect(o.distance == 0 && o.overlaps)
    }

    @Test func furnitureFindings() {
        var p = Project.empty(name: "C")
        let lv = p.levels[0].id
        let d = boxDef(1000, 1000)
        let a = place(&p, d, level: lv, at: P2(0, 0))
        let b = place(&p, d, level: lv, at: P2(2000, 0), rot: 45) // gap 1500 - 500√2 = 792.9: silent
        let near = place(&p, d, level: lv, at: P2(-1000 - 600 + 100, 0)) // gap 500
        let ov = place(&p, d, level: lv, at: P2(0, 900)) // overlaps a
        let f = ClearanceCheck.run(p)
        #expect(!f.contains { $0.instanceId == b || $0.otherId == b })
        let gap = f.first { Set([$0.instanceId, $0.otherId]) == Set([a, near]) }
        #expect(gap != nil)
        #expect(abs(gap!.distanceMM - 500) < 1e-9)
        #expect(gap!.limitMM == 600 && !gap!.overlaps && gap!.kind == .furnitureGap)
        let over = f.first { Set([$0.instanceId, $0.otherId]) == Set([a, ov]) }
        #expect(over?.distanceMM == 0 && over?.overlaps == true)
        // 45° piece moved closer: 1800 → 1300 - 707.1 = 592.9 < 600
        p.instances[p.instances.firstIndex { $0.id == b }!].position = P3(1800, 0, 0)
        let f2 = ClearanceCheck.run(p)
        let g2 = f2.first { Set([$0.instanceId, $0.otherId]) == Set([a, b]) }
        #expect(g2 != nil)
        #expect(abs(g2!.distanceMM - (1300 - 500 * 2.0.squareRoot())) < 1e-6)
        // Raising the walkway rule changes nothing for pieces above the limit and nothing is reported with 0.
        var rules = ClearanceRules()
        rules.minWalkwayMM = 100
        let strict = ClearanceCheck.run(p, rules: rules)
        #expect(!strict.isEmpty)
        #expect(strict.allSatisfy { $0.distanceMM < 100 })
    }

    @Test func differentHeightsAreNoObstacle() {
        var p = Project.empty(name: "C")
        let lv = p.levels[0].id
        let d = boxDef(1000, 1000, 500)
        _ = place(&p, d, level: lv, at: P2(0, 0))
        let hi = place(&p, d, level: lv, at: P2(0, 0))
        p.instances[p.instances.firstIndex { $0.id == hi }!].position = P3(0, 0, 1500)
        #expect(ClearanceCheck.run(p).isEmpty)
    }

    @Test func wallGap() {
        var p = Project.empty(name: "W")
        let lv = p.levels[0].id
        p.walls = [Wall(levelId: lv, start: P2(0, 0), end: P2(4000, 0), thickness: 100, height: 2500)]
        let d = boxDef(500, 500)
        let near = place(&p, d, level: lv, at: P2(3000, 350)) // bottom y=100, wall face y=50
        _ = place(&p, d, level: lv, at: P2(1000, 1500)) // 1200 away: silent
        _ = place(&p, d, level: lv, at: P2(300, 300)) // flush: bottom y=50
        let f = ClearanceCheck.run(p)
        #expect(f.count == 1)
        #expect(f[0].kind == .wallGap && f[0].instanceId == near && f[0].otherKind == .wall)
        #expect(abs(f[0].distanceMM - 50) < 1e-9)
        #expect(f[0].position == P2(2750, 75))
        // Furniture on the wall itself overlaps it.
        _ = place(&p, d, level: lv, at: P2(2000, 0))
        #expect(ClearanceCheck.run(p).contains { $0.overlaps && $0.kind == .wallGap })
    }

    @Test func doorSwingAndApproach() {
        var p = Project.empty(name: "D")
        let lv = p.levels[0].id
        let w = Wall(levelId: lv, start: P2(0, 0), end: P2(4000, 0), thickness: 100, height: 2500)
        p.walls = [w]
        let door = Opening(wallId: w.id, kind: .door, offset: 2000, width: 900, height: 2100, sill: 0)
        p.openings = [door] // inward = true: swings to +Y
        let d = boxDef(500, 500)
        let inSwing = place(&p, d, level: lv, at: P2(2000, 700))
        let behind = place(&p, d, level: lv, at: P2(2000, -450)) // approach strip on the other side, y -950..-50
        let far = place(&p, d, level: lv, at: P2(3500, 3000))
        let f = ClearanceCheck.run(p).filter { $0.otherKind == .door }
        let swing = f.first { $0.kind == .doorSwing }
        #expect(swing?.instanceId == inSwing && swing?.overlaps == true && abs(swing!.distanceMM - 400) < 1e-9)
        #expect(!f.contains { $0.instanceId == far })
        let app = f.first { $0.kind == .doorApproach }
        #expect(app?.instanceId == behind)
        #expect(app?.limitMM == 900)
        // Box spans y -700…-200 relative to the door line at y=-50: distance 150.
        #expect(abs(app!.distanceMM - 150) < 1e-9)
        var rules = ClearanceRules()
        rules.checkDoorSwing = false
        #expect(!ClearanceCheck.run(p, rules: rules).contains { $0.kind == .doorSwing })
    }

    @Test func doorSwingIsQuarterCircleNotSquare() {
        var p = Project.empty(name: "D")
        let lv = p.levels[0].id
        let w = Wall(levelId: lv, start: P2(0, 0), end: P2(4000, 0), thickness: 100, height: 2500)
        p.walls = [w]
        p.openings = [Opening(wallId: w.id, kind: .door, offset: 2000, width: 900, height: 2100, sill: 0)]
        // Hinge at (1550, 50), radius 900: the square corner region is outside the arc.
        let corner = place(&p, boxDef(100, 100), level: lv, at: P2(2400, 900)) // nearest corner 1131 mm from the hinge
        let inArc = place(&p, boxDef(100, 100), level: lv, at: P2(2000, 600)) // 500 mm from the hinge
        let f = ClearanceCheck.run(p).filter { $0.otherKind == .door }
        #expect(!f.contains { $0.instanceId == corner })
        #expect(f.contains { $0.instanceId == inArc && $0.kind == .doorSwing })
        // Flipped door: the hinge moves to the other end (2450, 50); the same corner box is now inside the arc.
        p.openings[0].flipped = true
        let g = ClearanceCheck.run(p).filter { $0.otherKind == .door }
        #expect(g.contains { $0.instanceId == corner && $0.kind == .doorSwing })
    }

    @Test func swingPieceIsNotAlsoReportedAsApproach() {
        var p = Project.empty(name: "D")
        let lv = p.levels[0].id
        let w = Wall(levelId: lv, start: P2(0, 0), end: P2(4000, 0), thickness: 100, height: 2500)
        p.walls = [w]
        p.openings = [Opening(wallId: w.id, kind: .door, offset: 2000, width: 900, height: 2100, sill: 0)]
        let inSwing = place(&p, boxDef(500, 500), level: lv, at: P2(2000, 700))
        let beyond = place(&p, boxDef(500, 500), level: lv, at: P2(2000, 1400)) // outside the arc, inside the strip
        var rules = ClearanceRules()
        rules.doorApproachMM = 1500
        let f = ClearanceCheck.run(p, rules: rules).filter { $0.otherKind == .door }
        #expect(f.contains { $0.instanceId == inSwing && $0.kind == .doorSwing })
        #expect(!f.contains { $0.instanceId == inSwing && $0.kind == .doorApproach })
        #expect(f.contains { $0.instanceId == beyond && $0.kind == .doorApproach })
        #expect(!f.contains { $0.instanceId == beyond && $0.kind == .doorSwing })
    }

    @Test func passableOpeningIsNotWall() {
        var p = Project.empty(name: "D")
        let lv = p.levels[0].id
        let w = Wall(levelId: lv, start: P2(0, 0), end: P2(4000, 0), thickness: 100, height: 2500)
        p.walls = [w]
        p.openings = [Opening(wallId: w.id, kind: .opening, offset: 2000, width: 1000, height: 2100, sill: 0)]
        _ = place(&p, boxDef(400, 400), level: lv, at: P2(2000, 0)) // inside the opening, no wall overlap
        #expect(!ClearanceCheck.run(p).contains { $0.overlaps && $0.kind == .wallGap && $0.distanceMM == 0 })
    }
}
