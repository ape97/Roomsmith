import Testing
import Foundation
import CoreGraphics
import ImageIO
import simd
@testable import RoomsmithCore

// MARK: helpers

private func wallProject(length: MM = 1000) -> (Project, UUID) {
    var p = Project.empty(name: "Scale test")
    let lid = p.levels[0].id
    p.walls = [Wall(levelId: lid, start: P2(0, 0), end: P2(length, 0), thickness: 100, height: 2500)]
    return (p, lid)
}

/// 12 m × 9 m shell with a door and a room label.
private func houseProject() -> (Project, UUID) {
    var p = Project.empty(name: "House")
    let lid = p.levels[0].id
    let pts = [P2(0, 0), P2(12000, 0), P2(12000, 9000), P2(0, 9000)]
    for i in 0..<4 {
        p.walls.append(Wall(levelId: lid, start: pts[i], end: pts[(i + 1) % 4], thickness: 200, height: 2500))
    }
    p.rooms = [Room(levelId: lid, name: "Hall", points: pts)]
    p.openings = [Opening(wallId: p.walls[0].id, kind: .door, offset: 2000, width: 900, height: 2100, sill: 0)]
    return (p, lid)
}

private func numbers(_ s: String) -> [Double] {
    s.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Double($0) }
}

/// X extent in SVG user units (= paper mm) of the first element of `tag` inside `<g id="group">`.
private func svgExtentX(_ svg: String, group: String, tag: String) throws -> Double {
    let start = try #require(svg.range(of: "<g id=\"\(group)\">"))
    let rest = svg[start.upperBound...]
    let line = try #require(rest.split(separator: "\n").first { $0.hasPrefix("<\(tag) ") })
    let pts = try #require(line.components(separatedBy: "points=\"").dropFirst().first?.components(separatedBy: "\"").first)
    let n = numbers(pts)
    let xs = stride(from: 0, to: n.count, by: 2).map { n[$0] }
    return xs.max()! - xs.min()!
}

/// Reads the path operators of the first PDF page and returns every sub-path in page points.
private final class PDFPaths {
    var ctm = CGAffineTransform.identity
    var stack: [CGAffineTransform] = []
    var paths: [[CGPoint]] = []

    static func read(_ data: Data) -> [[CGPoint]] {
        guard let provider = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(provider), let page = doc.page(at: 1) else { return [] }
        let collector = PDFPaths()
        let table = CGPDFOperatorTableCreate()!
        CGPDFOperatorTableSetCallback(table, "q") { _, info in let c = Unmanaged<PDFPaths>.fromOpaque(info!).takeUnretainedValue(); c.stack.append(c.ctm) }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in let c = Unmanaged<PDFPaths>.fromOpaque(info!).takeUnretainedValue(); if let t = c.stack.popLast() { c.ctm = t } }
        CGPDFOperatorTableSetCallback(table, "cm") { s, info in
            let c = Unmanaged<PDFPaths>.fromOpaque(info!).takeUnretainedValue()
            var v: [CGPDFReal] = []
            for _ in 0..<6 { var x: CGPDFReal = 0; CGPDFScannerPopNumber(s, &x); v.insert(x, at: 0) }
            c.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(c.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "m") { s, info in
            let c = Unmanaged<PDFPaths>.fromOpaque(info!).takeUnretainedValue()
            var y: CGPDFReal = 0, x: CGPDFReal = 0
            CGPDFScannerPopNumber(s, &y); CGPDFScannerPopNumber(s, &x)
            c.paths.append([CGPoint(x: x, y: y).applying(c.ctm)])
        }
        CGPDFOperatorTableSetCallback(table, "l") { s, info in
            let c = Unmanaged<PDFPaths>.fromOpaque(info!).takeUnretainedValue()
            var y: CGPDFReal = 0, x: CGPDFReal = 0
            CGPDFScannerPopNumber(s, &y); CGPDFScannerPopNumber(s, &x)
            if !c.paths.isEmpty { c.paths[c.paths.count - 1].append(CGPoint(x: x, y: y).applying(c.ctm)) }
        }
        CGPDFOperatorTableSetCallback(table, "re") { s, info in
            // CoreGraphics writes axis-aligned quads as rectangles.
            let c = Unmanaged<PDFPaths>.fromOpaque(info!).takeUnretainedValue()
            var h: CGPDFReal = 0, w: CGPDFReal = 0, y: CGPDFReal = 0, x: CGPDFReal = 0
            CGPDFScannerPopNumber(s, &h); CGPDFScannerPopNumber(s, &w); CGPDFScannerPopNumber(s, &y); CGPDFScannerPopNumber(s, &x)
            c.paths.append([CGPoint(x: x, y: y), CGPoint(x: x + w, y: y), CGPoint(x: x + w, y: y + h), CGPoint(x: x, y: y + h)].map { $0.applying(c.ctm) })
        }
        let stream = CGPDFContentStreamCreateWithPage(page)
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(collector).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(stream)
        CGPDFOperatorTableRelease(table)
        return collector.paths
    }
}

private let ptPerMM = 72.0 / 25.4

// MARK: pure fit logic

@Suite struct PlanFitLogicTests {
    @Test func sheetSizes() {
        #expect(PaperFormat.a4.size(landscape: false) == PaperSize(width: 210, height: 297))
        #expect(PaperFormat.a3.size(landscape: true) == PaperSize(width: 420, height: 297))
        #expect(PaperFormat.a0.portrait == PaperSize(width: 841, height: 1189))
        #expect(PaperFormat.letter.portrait == PaperSize(width: 215.9, height: 279.4))
        #expect(PaperFormat.allCases.map(\.rawValue) == ["A4", "A3", "A2", "A1", "A0", "Letter"])
    }

    @Test func fitsAndOrientation() {
        let wide = PaperSize(width: 280, height: 200)
        #expect(PlanFit.fits(wide, on: PaperFormat.a4.size(landscape: true)))
        #expect(!PlanFit.fits(wide, on: PaperFormat.a4.size(landscape: false)))
        #expect(PlanFit.orientation(for: wide, on: .a4, preferred: .auto) == true)
        #expect(PlanFit.orientation(for: wide, on: .a4, preferred: .landscape) == true)
        #expect(PlanFit.orientation(for: wide, on: .a4, preferred: .portrait) == nil)
        let tall = PaperSize(width: 200, height: 280)
        #expect(PlanFit.orientation(for: tall, on: .a4, preferred: .auto) == false)
        #expect(PlanFit.orientation(for: tall, on: .a4, preferred: .landscape) == nil)
        // exactly the sheet size fits; a hair more does not
        #expect(PlanFit.fits(PaperSize(width: 297, height: 210), on: PaperFormat.a4.size(landscape: true)))
        #expect(!PlanFit.fits(PaperSize(width: 297.01, height: 210), on: PaperFormat.a4.size(landscape: true)))
    }

    @Test func autoOrientationPicksTheOneThatFits() {
        // Taller than wide and only fits portrait; auto must not stay on landscape.
        let tall = PaperSize(width: 150, height: 250)
        #expect(PlanFit.orientation(for: tall, on: .a4, preferred: .auto) == false)
        // Wide but fits both: auto keeps the long side along the long edge.
        #expect(PlanFit.orientation(for: PaperSize(width: 150, height: 100), on: .a4, preferred: .auto) == true)
    }

    @Test func smallestLargerPaper() {
        let need = PaperSize(width: 260, height: 214)
        #expect(PlanFit.smallestPaper(fitting: [need], preferred: .auto, larger: .a4) == .a3)
        #expect(PlanFit.smallestPaper(fitting: [need], preferred: .auto) == .a3, "Letter is only offered when the current paper is Letter")
        #expect(PlanFit.smallestPaper(fitting: [need], preferred: .auto, larger: .letter) == .a3)
        #expect(PlanFit.smallestPaper(fitting: [PaperSize(width: 215, height: 270)], preferred: .auto, larger: .letter) == .a3)
        #expect(PlanFit.smallestPaper(fitting: [need], preferred: .auto, among: PaperFormat.allCases) == .letter)
        #expect(PlanFit.smallestPaper(fitting: [need], preferred: .auto, larger: .a3) == .a2)
        // all sizes must fit
        let big = PaperSize(width: 800, height: 500)
        #expect(PlanFit.smallestPaper(fitting: [need, big], preferred: .auto, larger: .a4) == .a1)
        #expect(PlanFit.smallestPaper(fitting: [PaperSize(width: 5000, height: 5000)], preferred: .auto) == nil)
    }

    @Test func pixelSizeInvariant() {
        func px(_ w: Double, _ h: Double, _ dpi: Double) -> (width: Int, height: Int, dpi: Double) {
            PlanFit.pixelSize(widthMM: w, heightMM: h, dpi: dpi)
        }
        let a = px(254, 254, 300)
        #expect(a.width == 3000 && a.height == 3000 && a.dpi == 300)
        let b = px(25.4, 25.4, 96)
        #expect(b.width == 96 && b.height == 96 && b.dpi == 96)
        let c = px(210, 297, 300)
        #expect(c.width == 2481 && c.height == 3508 && c.dpi == 300)
        let d = px(297, 420, 150)  // A3 at 150 dpi
        #expect(d.width == 1754 && d.height == 2481 && d.dpi == 150)
        let e = px(3000, 2000, 300)  // too large: dpi is lowered, pixel cap holds
        #expect(e.dpi < 300 && e.width * e.height <= PlanFit.maxPixels)
    }

    @Test func pngExportOfA4At300DpiHasExpectedSizeAndMetadata() throws {
        let (p, lid) = wallProject()
        let opts = PlanExport.Options(levelId: lid, scale: 50, page: .init(name: "A4", width: 210, height: 297))
        let (data, dpi) = try PlanRaster.pngData(fromPDF: PlanExport.pdf(p, options: opts), dpi: 300)
        #expect(dpi == 300)
        let src = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 2481)
        #expect(props[kCGImagePropertyPixelHeight] as? Int == 3508)
        #expect(props[kCGImagePropertyDPIWidth] as? Double == 300)
        #expect(props[kCGImagePropertyDPIHeight] as? Double == 300)
    }

    @Test func pngKeepsTopLeftOrientationAndScale() throws {
        // A4 page with a black 20 mm square in the top-left corner (PDF origin is bottom-left).
        let w = 210 * ptPerMM, h = 297 * ptPerMM, sq = 20 * ptPerMM
        let pdf = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: w, height: h)
        let consumer = try #require(CGDataConsumer(data: pdf))
        let pctx = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        pctx.beginPDFPage(nil)
        pctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        pctx.fill(CGRect(x: 0, y: h - sq, width: sq, height: sq))
        pctx.endPDFPage()
        pctx.closePDF()
        let (png, _) = try PlanRaster.pngData(fromPDF: pdf as Data, dpi: 300)
        let src = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let img = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let iw = img.width, ih = img.height
        #expect(iw == 2481 && ih == 3508)
        let rgba = try #require(CGContext(data: nil, width: iw, height: ih, bitsPerComponent: 8, bytesPerRow: iw * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        rgba.draw(img, in: CGRect(x: 0, y: 0, width: iw, height: ih))
        let buf = try #require(rgba.data).assumingMemoryBound(to: UInt8.self)
        func dark(_ x: Int, _ y: Int) -> Bool { buf[(y * iw + x) * 4] < 128 }  // y = 0 is the top row
        #expect(dark(10, 10))
        #expect(!dark(10, ih - 11), "bottom left stays white")
        #expect(!dark(iw - 11, 10), "top right stays white")
        var edgeX = 0
        while edgeX < iw && dark(edgeX, 10) { edgeX += 1 }
        var edgeY = 0
        while edgeY < ih && dark(10, edgeY) { edgeY += 1 }
        #expect(abs(edgeX - 236) <= 1, "square width \(edgeX) px")
        #expect(abs(edgeY - 236) <= 1, "square height \(edgeY) px")
    }

    @Test func pixelSizeCapsTotalPixels() {
        let a4 = PlanFit.pixelSize(widthMM: 210, heightMM: 297, dpi: 300)
        #expect(a4.width == 2481 && a4.height == 3508 && a4.dpi == 300)
        let a0 = PlanFit.pixelSize(widthMM: 841, heightMM: 1189, dpi: 300)
        #expect(a0.width * a0.height <= PlanFit.maxPixels)
        #expect(a0.dpi < 300 && a0.dpi > 100)
        let small = PlanFit.pixelSize(widthMM: 100, heightMM: 100, dpi: 300, maxPixels: 1000)
        #expect(small.width * small.height <= 1000)
    }

    /// Synthetic drawing of 12 m × 9 m content plus 20 mm margin and 14 mm legend.
    private func needs(_ scale: Int) -> PaperSize {
        PaperSize(width: 12000 / Double(scale) + 20, height: 9000 / Double(scale) + 34)
    }

    @Test(arguments: [(PaperFormat.a4, 20), (.a4, 50), (.a4, 100), (.a3, 20), (.a3, 50), (.a3, 100)])
    func fixedScaleKeepsItsRatio(_ paper: PaperFormat, _ scale: Int) {
        for o in PaperOrientation.allCases {
            let l = PlanFit.layout(scale: .ratio(scale), paper: paper, orientation: o, required: needs)
            #expect(l.scale == scale, "a fixed ratio is never silently changed")
            let landscapeFits = PlanFit.fits(needs(scale), on: paper.size(landscape: true))
            let portraitFits = PlanFit.fits(needs(scale), on: paper.size(landscape: false))
            let expected: Bool
            switch o {
            case .auto: expected = landscapeFits || portraitFits
            case .landscape: expected = landscapeFits
            case .portrait: expected = portraitFits
            }
            #expect(l.fits == expected)
            if l.fits { #expect(PlanFit.fits(l.required, on: l.sheet)) }
        }
    }

    @Test func knownFitResults() {
        func fits(_ scale: Int, _ paper: PaperFormat, _ o: PaperOrientation) -> Bool {
            PlanFit.layout(scale: .ratio(scale), paper: paper, orientation: o, required: needs).fits
        }
        // 12 × 9 m at 1:50 is 260 × 214 mm: too big for A4 either way, fine on A3.
        #expect(!fits(50, .a4, .auto) && !fits(50, .a4, .landscape) && !fits(50, .a4, .portrait))
        #expect(fits(50, .a3, .landscape))
        #expect(fits(50, .a3, .portrait))
        // 1:100 is 140 × 124 mm: A4 either way.
        #expect(fits(100, .a4, .portrait) && fits(100, .a4, .landscape))
        // 1:20 is 620 × 484 mm: not on A3, not on A2 portrait; A2 landscape (594 × 420) is too small too.
        #expect(!fits(20, .a3, .auto))
        #expect(!fits(20, .a2, .auto))
        #expect(fits(20, .a1, .landscape))
    }

    @Test func fitPicksLargestStandardScale() {
        let l = PlanFit.layout(scale: .fit, paper: .a4, orientation: .auto, required: needs)
        #expect(l.fits)
        #expect(PlanFit.fitScales.contains(l.scale))
        // one step larger would not fit
        if let i = PlanFit.fitScales.firstIndex(of: l.scale), i > 0 {
            let finer = PlanFit.layout(scale: .ratio(PlanFit.fitScales[i - 1]), paper: .a4, orientation: .auto, required: needs)
            #expect(!finer.fits)
        }
        let impossible = PlanFit.layout(scale: .fit, paper: .a4, orientation: .auto) { _ in PaperSize(width: 5000, height: 5000) }
        #expect(!impossible.fits)
    }

    @Test func offeredScalesAndPapers() {
        #expect(ScaleChoice.all == [.ratio(10), .ratio(20), .ratio(25), .ratio(50), .ratio(75), .ratio(100), .ratio(200), .fit])
    }
}

// MARK: drawing

@Suite struct PlanExportSheetTests {
    @Test func requiredSizeIncludesDoorSwingAndLabels() {
        let (house, lid) = houseProject()
        var noDoor = house
        noDoor.openings = []
        noDoor.rooms = []
        let opts = PlanExport.Options(levelId: lid, scale: 50)
        let with = PlanExport.requiredSize(house, options: opts)
        let without = PlanExport.requiredSize(noDoor, options: opts)
        // wall outline 12.2 × 9.2 m at 1:50 plus margin; the outward door swing is 900 mm = 18 mm further.
        #expect(without.width > 244 && without.width < 268)
        #expect(with.height >= without.height, "door swing and labels never shrink the sheet")
        // swing into the room does not grow the box, an outward swing does
        var outward = noDoor
        outward.openings = [Opening(wallId: outward.walls[0].id, kind: .door, offset: 2000, width: 900, height: 2100, sill: 0)]
        outward.openings[0].inward = false
        var inward = outward
        inward.openings[0].inward = true
        let o = PlanExport.requiredSize(outward, options: opts), i = PlanExport.requiredSize(inward, options: opts)
        #expect(max(o.height, i.height) - min(o.height, i.height) > 15, "one swing direction leaves the wall outline: \(o) vs \(i)")
    }

    @Test func requiredSizeIncludesDimensionText() {
        var (p, lid) = wallProject(length: 2000)
        let base = PlanExport.requiredSize(p, options: .init(levelId: lid, scale: 20))
        p.dimensions = [Dimension(levelId: lid, a: P2(0, 0), b: P2(2000, 0), offset: 600)]
        let dim = PlanExport.requiredSize(p, options: .init(levelId: lid, scale: 20))
        #expect(dim.height - base.height >= 550.0 / 20 - 0.5, "dimension line at 600 mm offset is part of the drawing")
    }

    @Test func fixedSheetKeepsPlanInsideAndLegendOutside() throws {
        let (p, lid) = houseProject()
        let layout = PlanExport.layout(p, levelId: lid, unit: .cm, scale: .ratio(50), paper: .a3, orientation: .auto)
        #expect(layout.fits)
        let opts = PlanExport.options(for: layout, paper: .a3, levelId: lid, unit: .cm)
        let d = PlanExport.makeDrawing(p, options: opts)
        #expect(d.width == layout.sheet.width && d.height == layout.sheet.height)
        let plan = d.layers.filter { $0.name != "legend" }
        let box = try #require(PlanExport.bounds(of: plan))
        let legend = try #require(PlanExport.bounds(of: d.layers.filter { $0.name == "legend" }))
        let m = 10.0
        #expect(box.min.x >= m - 1e-6 && box.max.x <= d.width - m + 1e-6)
        #expect(box.min.y >= m - 1e-6)
        #expect(box.max.y <= legend.min.y, "the legend never covers the plan")
        #expect(box.max.y <= d.height - m - PlanExport.legendHeightMM + 1e-6)
        #expect(legend.max.x <= d.width - m + 1e-6)
    }

    @Test func legendNamesScaleAndPaper() {
        let (p, lid) = wallProject(length: 2000)
        let a3 = PlanExport.Options(levelId: lid, scale: 50, page: .init(name: "A3", width: 420, height: 297))
        let svg = PlanExport.svg(p, options: a3)
        #expect(svg.contains(">Scale<") && svg.contains(">1:50<") && svg.contains(">(at A3)<"))
        #expect(svg.contains("width=\"420mm\" height=\"297mm\""))
        let auto = PlanExport.svg(p, options: .init(levelId: lid, scale: 50))
        #expect(auto.contains(">Scale<") && auto.contains(">1:50<") && !auto.contains("(at "))
    }

    @Test func scaleBarMatchesScale() throws {
        let (p, lid) = wallProject(length: 4000)
        for scale in [20, 50, 100, 200] {
            let svg = PlanExport.svg(p, options: .init(levelId: lid, scale: scale))
            let bar = try svgExtentX(svg, group: "legend", tag: "polyline")
            let nice = [100.0, 200, 500, 1000, 2000, 5000, 10000, 20000, 50000].last { $0 / Double(scale) <= 50 }!
            #expect(abs(bar - nice / Double(scale)) < 1e-3, "1:\(scale)")
        }
    }

    @Test func pdfSheetIsExactlyThePaper() throws {
        let (p, lid) = houseProject()
        let layout = PlanExport.layout(p, levelId: lid, unit: .cm, scale: .ratio(50), paper: .a3, orientation: .auto)
        let data = PlanExport.pdf(p, options: PlanExport.options(for: layout, paper: .a3, levelId: lid, unit: .cm))
        let provider = try #require(CGDataProvider(data: data as CFData))
        let doc = try #require(CGPDFDocument(provider))
        let page = try #require(doc.page(at: 1))
        let box = page.getBoxRect(.mediaBox)
        #expect(abs(box.width - 420 * ptPerMM) < 1e-3 && abs(box.height - 297 * ptPerMM) < 1e-3)
    }
}

// MARK: measured scale

@Suite struct PlanScaleFidelityTests {
    static let scales = [10, 20, 25, 50, 75, 100, 200]

    /// A 1000 mm wall measures 1000/scale mm in SVG and 1000/scale × 72/25.4 pt in the PDF, on automatic pages and on fixed sheets.
    @Test(arguments: scales)
    func thousandMillimetreWall(_ scale: Int) throws {
        let (p, lid) = wallProject(length: 1000)
        let expectedMM = 1000.0 / Double(scale)
        let pages: [PlanExport.Page?] = [nil, .init(name: "A4", width: 297, height: 210), .init(name: "A0", width: 1189, height: 841)]
        for page in pages {
            let opts = PlanExport.Options(levelId: lid, scale: scale, page: page)
            let svg = PlanExport.svg(p, options: opts)
            let w = try svgExtentX(svg, group: "walls", tag: "polygon")
            #expect(abs(w - expectedMM) < 0.001, "SVG 1:\(scale) \(page?.name ?? "auto"): \(w) vs \(expectedMM)")

            let paths = PDFPaths.read(PlanExport.pdf(p, options: opts))
            let wall = try #require(paths.first { path in
                let xs = path.map(\.x), ys = path.map(\.y)
                return path.count >= 4 && (ys.max()! - ys.min()!) < 20 * ptPerMM && (xs.max()! - xs.min()!) > 0.1
            })
            let xs = wall.map(\.x)
            let pdfPt = xs.max()! - xs.min()!
            #expect(abs(pdfPt - expectedMM * ptPerMM) < 0.001, "PDF 1:\(scale) \(page?.name ?? "auto"): \(pdfPt) vs \(expectedMM * ptPerMM)")
        }
    }

    @Test func oneToFiftyIsTwentyMillimetres() {
        #expect(abs(1000.0 / 50 * ptPerMM - 56.6929) < 0.0001)
    }
}
