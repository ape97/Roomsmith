import Foundation
import CoreGraphics
import CoreText
import simd

/// 2D plan export (SVG and one-page PDF). Scale fidelity is purely computational: 1 drawing unit = 1 paper mm
/// at the chosen ratio. Nothing here promises physical print accuracy.
public enum PlanExport {
    public struct Options: Sendable {
        public var levelId: UUID
        /// Drawing scale 1:scale.
        public var scale: Int
        /// Blank border on the paper (paper mm).
        public var marginMM: MM
        public var showDimensions: Bool
        public var showFurniture: Bool
        public var showRoomLabels: Bool
        public var unit: LengthUnit
        /// Fixed sheet. nil: the page is exactly as large as the drawing needs.
        public var page: Page?
        public init(levelId: UUID, scale: Int = 50, marginMM: MM = 10, showDimensions: Bool = true,
                    showFurniture: Bool = true, showRoomLabels: Bool = true, unit: LengthUnit = .cm, page: Page? = nil) {
            self.levelId = levelId; self.scale = scale; self.marginMM = marginMM
            self.showDimensions = showDimensions; self.showFurniture = showFurniture
            self.showRoomLabels = showRoomLabels; self.unit = unit; self.page = page
        }
    }

    /// A sheet of paper in mm. `name` ("A3", "Letter") is printed in the legend; nil for a custom size.
    public struct Page: Sendable, Equatable {
        public var name: String?
        public var width: Double
        public var height: Double
        public init(name: String?, width: Double, height: Double) { self.name = name; self.width = width; self.height = height }
    }

    /// Paper size: drawing extent / scale + 2 × margin in X; in Y additionally `legendHeightMM` for scale bar and title.
    public static let legendHeightMM = 14.0

    // MARK: drawing model (paper mm, Y down, origin top-left)

    struct Color {
        var r: Double, g: Double, b: Double, a: Double = 1
        var hex: String { String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded())) }
        static func gray(_ v: Double, a: Double = 1) -> Color { Color(r: v, g: v, b: v, a: a) }
        static let black = Color.gray(0)
        static let white = Color.gray(1)
    }

    enum Anchor { case start, middle, end }

    enum Item {
        case polygon([V2], fill: Color?, stroke: Color?, width: Double)
        case polyline([V2], stroke: Color, width: Double)
        case text(String, at: V2, size: Double, anchor: Anchor, rotation: Double, color: Color, bold: Bool)

        func translated(by d: V2) -> Item {
            switch self {
            case let .polygon(pts, fill, stroke, width): .polygon(pts.map { $0 + d }, fill: fill, stroke: stroke, width: width)
            case let .polyline(pts, stroke, width): .polyline(pts.map { $0 + d }, stroke: stroke, width: width)
            case let .text(s, at, size, anchor, rot, color, bold): .text(s, at: at + d, size: size, anchor: anchor, rotation: rot, color: color, bold: bold)
            }
        }
    }

    struct Layer { var name: String; var items: [Item] = [] }

    struct Drawing {
        var width: Double
        var height: Double
        var layers: [Layer]
    }

    // MARK: public API

    public static func svg(_ p: Project, options: Options) -> String {
        SVGWriter.write(makeDrawing(p, options: options), title: title(p, options))
    }

    public static func pdf(_ p: Project, options: Options) -> Data {
        PDFWriter.write(makeDrawing(p, options: options))
    }

    /// Paper size (mm) of the export, as written to the SVG `width`/`height` and used for the PDF page.
    public static func paperSize(_ p: Project, options: Options) -> (width: Double, height: Double) {
        let d = makeDrawing(p, options: options)
        return (d.width, d.height)
    }

    /// Smallest sheet (mm) that holds the drawing at `options.scale`: margin, every drawn item (door swings, labels,
    /// dimension text), the legend strip below the plan and the legend's own width. Ignores `options.page`.
    /// Not the same as `paperSize` on an automatic page, which does not widen for the legend.
    public static func requiredSize(_ p: Project, options: Options) -> PaperSize {
        var o = options
        o.page = nil
        let d = makeDrawing(p, options: o)
        let margin = Double(max(0, o.marginMM))
        let legendWidth = margin + legendMetrics(scale: Double(max(1, o.scale))).barLen + legendTextOffset
            + legendTextWidth(scale: Int(max(1, o.scale)), suffix: "(at Letter)") + margin
        return PaperSize(width: max(d.width, legendWidth), height: d.height)
    }

    private static func title(_ p: Project, _ o: Options) -> String {
        let level = p.levels.first { $0.id == o.levelId }?.name ?? ""
        return level.isEmpty ? p.name : "\(p.name) – \(level)"
    }

    // MARK: building

    static func makeDrawing(_ p: Project, options o: Options) -> Drawing {
        let scale = Double(max(1, o.scale))
        let margin = Double(max(0, o.marginMM))
        let walls = p.walls.filter { $0.levelId == o.levelId }
        let outlines = WallOutline.compute(walls, levelId: o.levelId)
        let rooms = p.rooms.filter { $0.levelId == o.levelId }
        let wallIds = Set(walls.map(\.id))
        let openings = p.openings.filter { wallIds.contains($0.wallId) }
        let dimensions = o.showDimensions ? p.dimensions.filter { $0.levelId == o.levelId } : []

        struct Placed { var inst: FurnitureInstance; var rect: OrientedRect }
        var furniture: [Placed] = []
        if o.showFurniture {
            for inst in p.instances where inst.levelId == o.levelId && inst.visible {
                guard let def = p.definitions.first(where: { $0.id == inst.definitionId }) else { continue }
                furniture.append(Placed(inst: inst, rect: FurnitureResolver.footprint(of: inst, definition: def)))
            }
        }

        // World bounds.
        var pts: [V2] = []
        for w in walls { if let ol = outlines[w.id] { pts += ol.polygon } }
        for r in rooms { pts += r.points.map(\.v) }
        for f in furniture { pts += f.rect.corners }
        for d in dimensions {
            let ax = Geo.axis(d.a, d.b)
            let off = ax.normal * Double(d.offset)
            pts += [d.a.v, d.b.v, d.a.v + off, d.b.v + off]
        }
        var minP = V2(0, 0), maxP = V2(1000, 1000)
        if let first = pts.first {
            minP = first; maxP = first
            for q in pts { minP = simd_min(minP, q); maxP = simd_max(maxP, q) }
        }
        // Paper mm, Y down, origin at the world minimum; moved into place below once all items are known.
        func map(_ w: V2) -> V2 { V2((w.x - minP.x) / scale, (maxP.y - w.y) / scale) }

        let ink = Color.gray(0.1)
        var roomLayer = Layer(name: "rooms")
        var wallLayer = Layer(name: "walls")
        var openingLayer = Layer(name: "openings")
        var furnitureLayer = Layer(name: "furniture")
        var labelLayer = Layer(name: "labels")
        var dimLayer = Layer(name: "dimensions")

        /// Paper boxes of the room names and areas; furniture names that would run into them are left out.
        var roomLabelBoxes: [CGRect] = []
        for r in rooms where r.points.count >= 3 {
            roomLayer.items.append(.polygon(r.points.map { map($0.v) }, fill: Color(r: 0.95, g: 0.93, b: 0.88), stroke: nil, width: 0))
            if o.showRoomLabels {
                let c = map(centroid(r.points))
                let area = String(format: "%.2f m²", Geo.area(r.points) / 1_000_000)
                let box = labelBox(r.name, at: V2(c.x, c.y - 0.6), size: 3.2, bold: true)
                    .union(labelBox(area, at: V2(c.x, c.y + 3.2), size: 2.6, bold: false))
                roomLabelBoxes.append(box)
                // Floor-coloured backdrop so the name stays readable over furniture outlines; only where it covers
                // nothing but this room's floor (in small rooms it would otherwise paint over walls).
                let paperRoom = r.points.map { map($0.v) }
                if boxInside(box, paperRoom),
                   !walls.contains(where: { w in outlines[w.id].map { boxTouches(box, $0.polygon.map(map)) } ?? false }) {
                    labelLayer.items.append(.polygon([V2(box.minX, box.minY), V2(box.maxX, box.minY), V2(box.maxX, box.maxY), V2(box.minX, box.maxY)],
                                                     fill: Color(r: 0.95, g: 0.93, b: 0.88, a: 0.85), stroke: nil, width: 0))
                }
                labelLayer.items.append(.text(r.name, at: V2(c.x, c.y - 0.6), size: 3.2, anchor: .middle, rotation: 0, color: ink, bold: true))
                labelLayer.items.append(.text(area, at: V2(c.x, c.y + 3.2), size: 2.6, anchor: .middle, rotation: 0, color: ink, bold: false))
            }
        }

        for w in walls {
            guard let ol = outlines[w.id] else { continue }
            wallLayer.items.append(.polygon(ol.polygon.map(map), fill: Color.gray(0.3), stroke: Color.black, width: 0.15))
        }

        for op in openings {
            guard let w = walls.first(where: { $0.id == op.wallId }), let ol = outlines[w.id] else { continue }
            let ax = Geo.axis(w.start, w.end)
            let s0 = max(0, Double(op.offset) - Double(op.width) / 2)
            let s1 = min(ax.length, Double(op.offset) + Double(op.width) / 2)
            guard s1 - s0 > 1e-9 else { continue }
            let r0 = ol.facePoint(wall: w, s: s0, left: false), l0 = ol.facePoint(wall: w, s: s0, left: true)
            let r1 = ol.facePoint(wall: w, s: s1, left: false), l1 = ol.facePoint(wall: w, s: s1, left: true)
            openingLayer.items.append(.polygon([r0, r1, l1, l0].map(map), fill: Color.white, stroke: nil, width: 0))
            openingLayer.items.append(.polyline([map(r0), map(l0)], stroke: Color.black, width: 0.2))
            openingLayer.items.append(.polyline([map(r1), map(l1)], stroke: Color.black, width: 0.2))
            let t = Double(w.thickness)
            let a0 = w.start.v + ax.dir * s0, a1 = w.start.v + ax.dir * s1
            switch op.kind {
            case .window:
                openingLayer.items.append(.polyline([map(r0), map(r1)], stroke: Color.black, width: 0.2))
                openingLayer.items.append(.polyline([map(l0), map(l1)], stroke: Color.black, width: 0.2))
                for k in [-1.0, 1.0] {
                    let off = ax.normal * (t / 6 * k)
                    openingLayer.items.append(.polyline([map(a0 + off), map(a1 + off)], stroke: Color.black, width: 0.15))
                }
            case .door:
                let width = s1 - s0
                let hinge = op.flipped ? a1 : a0
                let closed = op.flipped ? -ax.dir : ax.dir
                let openDir = ax.normal * (op.inward ? 1.0 : -1.0)
                let sweep = (closed.x * openDir.y - closed.y * openDir.x) > 0 ? 90.0 : -90.0
                var arc: [V2] = []
                for i in 0...24 {
                    let v = Geo.rotate(closed, deg: sweep * Double(i) / 24)
                    arc.append(map(hinge + v * width))
                }
                openingLayer.items.append(.polyline(arc, stroke: Color.gray(0.35), width: 0.15))
                openingLayer.items.append(.polyline([map(hinge), map(hinge + openDir * width)], stroke: Color.black, width: 0.25))
            case .opening:
                break
            }
        }

        for f in furniture {
            let corners = f.rect.corners
            furnitureLayer.items.append(.polygon(corners.map(map), fill: Color(r: 0.80, g: 0.85, b: 0.90, a: 0.6), stroke: Color(r: 0.2, g: 0.3, b: 0.45), width: 0.2))
            let c = map(f.rect.center)
            if let label = furnitureLabel(f.inst.name, footprint: corners.map(map)),
               !roomLabelBoxes.contains(where: { $0.intersects(labelBox(label, at: V2(c.x, c.y + 0.9), size: furnitureLabelSize, bold: false)) }) {
                furnitureLayer.items.append(.text(label, at: V2(c.x, c.y + 0.9), size: furnitureLabelSize, anchor: .middle, rotation: 0, color: Color(r: 0.1, g: 0.2, b: 0.35), bold: false))
            }
        }

        let dimColor = Color(r: 0.7, g: 0.1, b: 0.1)
        for d in dimensions {
            let ax = Geo.axis(d.a, d.b)
            guard ax.length > 0 else { continue }
            let off = ax.normal * Double(d.offset)
            let a = map(d.a.v), b = map(d.b.v)
            let a2 = map(d.a.v + off), b2 = map(d.b.v + off)
            let pd = b2 - a2
            let plen = simd_length(pd)
            guard plen > 1e-9 else { continue }
            let pdir = pd / plen
            let ext = simd_length(a2 - a) > 1e-9 ? simd_normalize(a2 - a) * 1.5 : V2(0, 0)
            dimLayer.items.append(.polyline([a, a2 + ext], stroke: dimColor, width: 0.1))
            dimLayer.items.append(.polyline([b, b2 + ext], stroke: dimColor, width: 0.1))
            dimLayer.items.append(.polyline([a2, b2], stroke: dimColor, width: 0.15))
            let tick = V2(pdir.x - pdir.y, pdir.y + pdir.x) * (1.0 / 2.0.squareRoot()) * 1.2
            for e in [a2, b2] { dimLayer.items.append(.polyline([e - tick, e + tick], stroke: dimColor, width: 0.25)) }
            var ang = atan2(pdir.y, pdir.x) * 180 / .pi
            if ang > 90 { ang -= 180 } else if ang <= -90 { ang += 180 }
            let mid = (a2 + b2) / 2
            let up = V2(sin(ang * .pi / 180), -cos(ang * .pi / 180)) * 0.8
            let len = MM(Geo.distance(d.a, d.b).rounded())
            dimLayer.items.append(.text(o.unit.format(len), at: mid + up, size: 2.2, anchor: .middle, rotation: ang, color: dimColor, bold: false))
        }

        // Place the drawing: automatic pages hug it, fixed sheets centre it above the legend strip.
        var layers = [roomLayer, wallLayer, openingLayer, furnitureLayer, labelLayer, dimLayer]
        let box = bounds(of: layers) ?? (min: V2(0, 0), max: V2(1000 / scale, 1000 / scale))
        let contentW = box.max.x - box.min.x, contentH = box.max.y - box.min.y
        let width: Double, height: Double
        var origin = V2(margin, margin)
        if let page = o.page {
            width = page.width; height = page.height
            origin = V2(margin + (page.width - 2 * margin - contentW) / 2,
                        margin + (page.height - 2 * margin - legendHeightMM - contentH) / 2)
        } else {
            width = contentW + 2 * margin
            height = contentH + 2 * margin + legendHeightMM
        }
        let shift = origin - box.min
        for i in layers.indices { layers[i].items = layers[i].items.map { $0.translated(by: shift) } }

        // Scale bar and scale note in the bottom strip, title right-aligned if there is room for it.
        var legendLayer = Layer(name: "legend")
        let barY = height - 6.0
        let (barWorld, barLen) = legendMetrics(scale: scale)
        let x0 = margin
        legendLayer.items.append(.polyline([V2(x0, barY), V2(x0 + barLen, barY)], stroke: Color.black, width: 0.4))
        for x in [x0, x0 + barLen] { legendLayer.items.append(.polyline([V2(x, barY - 1.2), V2(x, barY + 1.2)], stroke: Color.black, width: 0.3)) }
        legendLayer.items.append(.text("0", at: V2(x0, barY + 4), size: 2.2, anchor: .middle, rotation: 0, color: Color.black, bold: false))
        legendLayer.items.append(.text(o.unit.format(MM(barWorld)), at: V2(x0 + barLen, barY + 4), size: 2.2, anchor: .middle, rotation: 0, color: Color.black, bold: false))
        let noteX = x0 + barLen + legendTextOffset
        let ratio = "1:\(Int(scale))"
        let suffix = o.page?.name.map { "(at \($0))" } ?? ""
        let gap = textWidth(" ", size: 3.2, bold: false)
        legendLayer.items.append(.text("Scale", at: V2(noteX, barY + 0.8), size: 3.2, anchor: .start, rotation: 0, color: Color.black, bold: false))
        let ratioX = noteX + textWidth("Scale", size: 3.2, bold: false) + gap
        legendLayer.items.append(.text(ratio, at: V2(ratioX, barY + 0.8), size: 3.2, anchor: .start, rotation: 0, color: Color.black, bold: true))
        var noteEnd = ratioX + textWidth(ratio, size: 3.2, bold: true)
        if !suffix.isEmpty {
            legendLayer.items.append(.text(suffix, at: V2(noteEnd + gap, barY + 0.8), size: 3.2, anchor: .start, rotation: 0, color: Color.black, bold: false))
            noteEnd += gap + textWidth(suffix, size: 3.2, bold: false)
        }
        let titleText = title(p, o)
        if width - margin - textWidth(titleText, size: 2.6, bold: false) > noteEnd + 4 {
            legendLayer.items.append(.text(titleText, at: V2(width - margin, barY + 0.8), size: 2.6, anchor: .end, rotation: 0, color: Color.gray(0.3), bold: false))
        }
        layers.append(legendLayer)

        return Drawing(width: width, height: height, layers: layers)
    }

    // MARK: legend and text metrics

    /// Gap between the scale bar and the scale note (paper mm).
    static let legendTextOffset = 4.0

    /// Length of the scale bar in world mm and in paper mm: the longest "nice" length up to 50 paper mm.
    static func legendMetrics(scale: Double) -> (barWorld: Double, barLen: Double) {
        let nice: [Double] = [100, 200, 500, 1000, 2000, 5000, 10000, 20000, 50000]
        let w = nice.last { $0 / scale <= 50 } ?? nice[0]
        return (w, w / scale)
    }

    static func legendTextWidth(scale: Int, suffix: String) -> Double {
        let gap = textWidth(" ", size: 3.2, bold: false)
        return textWidth("Scale", size: 3.2, bold: false) + gap + textWidth("1:\(scale)", size: 3.2, bold: true)
            + (suffix.isEmpty ? 0 : gap + textWidth(suffix, size: 3.2, bold: false))
    }

    static let furnitureLabelSize = 2.2
    /// Half the height of a furniture name box around the piece centre (paper mm): the name sits with its baseline
    /// 0.9 mm below the centre, so cap height above and descenders below reach about 1.45 mm from it.
    static let furnitureLabelHalfHeight = 1.45
    /// A cut furniture name keeps at least this many characters before the ellipsis; less says nothing ("Of…").
    static let furnitureLabelMinChars = 5

    static func boxCorners(_ b: CGRect) -> [V2] {
        [V2(b.minX, b.minY), V2(b.maxX, b.minY), V2(b.maxX, b.maxY), V2(b.minX, b.maxY)]
    }

    /// Proper crossing of segments p1–p2 and q1–q2 (touching endpoints count as crossing).
    static func segmentsCross(_ p1: V2, _ p2: V2, _ q1: V2, _ q2: V2) -> Bool {
        func orient(_ a: V2, _ b: V2, _ c: V2) -> Double { (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) }
        let d1 = orient(q1, q2, p1), d2 = orient(q1, q2, p2), d3 = orient(p1, p2, q1), d4 = orient(p1, p2, q2)
        return (d1 * d2 <= 0) && (d3 * d4 <= 0)
            && max(p1.x, p2.x) >= min(q1.x, q2.x) && max(q1.x, q2.x) >= min(p1.x, p2.x)
            && max(p1.y, p2.y) >= min(q1.y, q2.y) && max(q1.y, q2.y) >= min(p1.y, p2.y)
    }

    /// Some edge of `polygon` crosses an edge of `box`.
    static func edgesCross(_ box: CGRect, _ polygon: [V2]) -> Bool {
        let c = boxCorners(box)
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            for k in 0..<4 where segmentsCross(a, b, c[k], c[(k + 1) % 4]) { return true }
        }
        return false
    }

    /// `box` lies completely inside `polygon` (paper coordinates).
    static func boxInside(_ box: CGRect, _ polygon: [V2]) -> Bool {
        guard polygon.count >= 3 else { return false }
        return boxCorners(box).allSatisfy { Geo.contains(polygon, $0) } && !edgesCross(box, polygon)
    }

    /// `box` and `polygon` share any area or boundary.
    static func boxTouches(_ box: CGRect, _ polygon: [V2]) -> Bool {
        guard polygon.count >= 3 else { return false }
        if polygon.contains(where: { box.contains(CGPoint(x: $0.x, y: $0.y)) }) { return true }
        if boxCorners(box).contains(where: { Geo.contains(polygon, $0) }) { return true }
        return edgesCross(box, polygon)
    }

    /// Paper box of a centred one-line text with its baseline at `at` (y grows downwards on paper), with a small margin.
    static func labelBox(_ s: String, at: V2, size: Double, bold: Bool) -> CGRect {
        let w = textWidth(s, size: size, bold: bold), pad = 0.3
        return CGRect(x: at.x - w / 2 - pad, y: at.y - size * 0.75 - pad, width: w + 2 * pad, height: size + 2 * pad)
    }

    /// The furniture name as it fits inside the piece on paper (`footprint` in paper mm), like the plan editor: the
    /// name is cut with an ellipsis when only part fits (keeping at least `furnitureLabelMinChars` characters) and
    /// dropped when the piece is too small, so names of tightly placed furniture never run into each other. The labels
    /// are horizontal, so the room is the widest horizontal text box (height `furnitureLabelHalfHeight` above and below
    /// the centre) whose corners all stay inside the piece; for rotated pieces that is narrower than the chord through
    /// the centre, because the top and bottom edges of the text meet the slanted sides first.
    static func furnitureLabel(_ name: String, footprint: [V2]) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, footprint.count == 4 else { return nil }
        let ea = footprint[1] - footprint[0], eb = footprint[2] - footprint[1]
        let a = simd_length(ea), b = simd_length(eb)
        guard a > 0, b > 0 else { return nil }
        let u = ea / a, v = eb / b
        /// Length of the line through the centre along unit `d` that stays inside the piece.
        func chord(_ d: V2) -> Double {
            let du = abs(simd_dot(d, u)), dv = abs(simd_dot(d, v))
            return 2 * min(du > 1e-9 ? (a / 2) / du : .infinity, dv > 1e-9 ? (b / 2) / dv : .infinity)
        }
        /// Widest horizontal box of half-height `hh` centred in the piece: each corner (±w/2, ±hh) must satisfy
        /// |corner · axis| <= half side for both piece axes.
        func boxWidth(_ hh: Double) -> Double {
            var w = Double.infinity
            for (axis, half) in [(u, a / 2), (v, b / 2)] {
                let ax = abs(axis.x), ay = abs(axis.y)
                let left = half - hh * ay
                if left < 0 { return 0 }
                if ax > 1e-9 { w = min(w, 2 * left / ax) }
            }
            return w
        }
        let room = boxWidth(furnitureLabelHalfHeight) - 0.6
        guard chord(V2(0, 1)) >= furnitureLabelSize * 1.6, room > 0 else { return nil }
        if textWidth(name, size: furnitureLabelSize, bold: false) <= room { return name }
        var chars = Array(name)
        while chars.count > furnitureLabelMinChars {
            chars.removeLast()
            let cut = String(chars).trimmingCharacters(in: .whitespaces) + "…"
            if textWidth(cut, size: furnitureLabelSize, bold: false) <= room { return cut }
        }
        return nil
    }

    /// Width in paper mm of `s` set in Helvetica at `size` mm (the face the PDF uses).
    static func textWidth(_ s: String, size: Double, bold: Bool) -> Double {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, 100, nil)
        let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        return CTLineGetTypographicBounds(line, nil, nil, nil) * size / 100
    }

    /// Bounding box of everything drawn: geometry points and (rotated) text boxes. Stroke widths are not included.
    static func bounds(of layers: [Layer]) -> (min: V2, max: V2)? {
        var lo = V2(.infinity, .infinity), hi = V2(-.infinity, -.infinity)
        var any = false
        func add(_ q: V2) { lo = simd_min(lo, q); hi = simd_max(hi, q); any = true }
        for layer in layers {
            for item in layer.items {
                switch item {
                case let .polygon(points, _, _, _): points.forEach(add)
                case let .polyline(points, _, _): points.forEach(add)
                case let .text(s, at, size, anchor, rotation, _, bold):
                    let w = textWidth(s, size: size, bold: bold)
                    let x0 = anchor == .start ? 0 : anchor == .middle ? -w / 2 : -w
                    let c = cos(rotation * .pi / 180), sn = sin(rotation * .pi / 180)
                    for (x, y) in [(x0, -0.75 * size), (x0 + w, -0.75 * size), (x0 + w, 0.22 * size), (x0, 0.22 * size)] {
                        add(V2(at.x + x * c - y * sn, at.y + x * sn + y * c))
                    }
                }
            }
        }
        return any ? (lo, hi) : nil
    }

    private static func centroid(_ pts: [P2]) -> V2 {
        var a = 0.0, cx = 0.0, cy = 0.0
        for i in pts.indices {
            let p = pts[i].v, q = pts[(i + 1) % pts.count].v
            let cr = p.x * q.y - q.x * p.y
            a += cr; cx += (p.x + q.x) * cr; cy += (p.y + q.y) * cr
        }
        if abs(a) < 1e-9 {
            let sum = pts.reduce(V2(0, 0)) { $0 + $1.v }
            return sum / Double(max(pts.count, 1))
        }
        return V2(cx / (3 * a), cy / (3 * a))
    }

    // MARK: SVG

    enum SVGWriter {
        static func num(_ v: Double) -> String {
            var s = String(format: "%.4f", v)
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
            return s == "-0" ? "0" : s
        }

        static func escape(_ s: String) -> String {
            var r = ""
            for ch in s {
                switch ch {
                case "&": r += "&amp;"
                case "<": r += "&lt;"
                case ">": r += "&gt;"
                case "\"": r += "&quot;"
                case "'": r += "&apos;"
                default: r.append(ch)
                }
            }
            return r
        }

        static func paint(_ c: Color?, _ attr: String) -> String {
            guard let c else { return " \(attr)=\"none\"" }
            var s = " \(attr)=\"\(c.hex)\""
            if c.a < 1 { s += " \(attr)-opacity=\"\(num(c.a))\"" }
            return s
        }

        static func write(_ d: Drawing, title: String) -> String {
            var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
            out += "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(num(d.width))mm\" height=\"\(num(d.height))mm\" viewBox=\"0 0 \(num(d.width)) \(num(d.height))\">\n"
            out += "<title>\(escape(title))</title>\n"
            out += "<rect x=\"0\" y=\"0\" width=\"\(num(d.width))\" height=\"\(num(d.height))\" fill=\"#FFFFFF\"/>\n"
            for layer in d.layers where !layer.items.isEmpty {
                out += "<g id=\"\(layer.name)\">\n"
                for item in layer.items {
                    switch item {
                    case let .polygon(points, fill, stroke, width):
                        let pts = points.map { "\(num($0.x)),\(num($0.y))" }.joined(separator: " ")
                        out += "<polygon points=\"\(pts)\"\(paint(fill, "fill"))\(paint(stroke, "stroke"))"
                        if stroke != nil { out += " stroke-width=\"\(num(width))\" stroke-linejoin=\"miter\"" }
                        out += "/>\n"
                    case let .polyline(points, stroke, width):
                        let pts = points.map { "\(num($0.x)),\(num($0.y))" }.joined(separator: " ")
                        out += "<polyline points=\"\(pts)\" fill=\"none\"\(paint(stroke, "stroke")) stroke-width=\"\(num(width))\"/>\n"
                    case let .text(s, at, size, anchor, rotation, color, bold):
                        let a = anchor == .start ? "start" : anchor == .middle ? "middle" : "end"
                        out += "<text x=\"\(num(at.x))\" y=\"\(num(at.y))\" font-family=\"Helvetica, Arial, sans-serif\" font-size=\"\(num(size))\" text-anchor=\"\(a)\""
                        if bold { out += " font-weight=\"bold\"" }
                        if rotation != 0 { out += " transform=\"rotate(\(num(rotation)) \(num(at.x)) \(num(at.y)))\"" }
                        out += "\(paint(color, "fill"))>\(escape(s))</text>\n"
                    }
                }
                out += "</g>\n"
            }
            out += "</svg>\n"
            return out
        }
    }

    // MARK: PDF

    enum PDFWriter {
        static let ptPerMM = 72.0 / 25.4

        static func write(_ d: Drawing) -> Data {
            let data = NSMutableData()
            guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return Data() }
            var box = CGRect(x: 0, y: 0, width: d.width * ptPerMM, height: d.height * ptPerMM)
            guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(box)
            func pt(_ v: V2) -> CGPoint { CGPoint(x: v.x * ptPerMM, y: (d.height - v.y) * ptPerMM) }
            func cg(_ c: Color) -> CGColor { CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a) }
            for layer in d.layers {
                for item in layer.items {
                    switch item {
                    case let .polygon(points, fill, stroke, width):
                        guard let first = points.first else { continue }
                        ctx.beginPath()
                        ctx.move(to: pt(first))
                        for q in points.dropFirst() { ctx.addLine(to: pt(q)) }
                        ctx.closePath()
                        if let fill { ctx.setFillColor(cg(fill)); ctx.fillPath() }
                        if let stroke {
                            ctx.beginPath()
                            ctx.move(to: pt(first))
                            for q in points.dropFirst() { ctx.addLine(to: pt(q)) }
                            ctx.closePath()
                            ctx.setStrokeColor(cg(stroke)); ctx.setLineWidth(width * ptPerMM); ctx.setLineJoin(.miter)
                            ctx.strokePath()
                        }
                    case let .polyline(points, stroke, width):
                        guard let first = points.first else { continue }
                        ctx.beginPath()
                        ctx.move(to: pt(first))
                        for q in points.dropFirst() { ctx.addLine(to: pt(q)) }
                        ctx.setStrokeColor(cg(stroke)); ctx.setLineWidth(width * ptPerMM)
                        ctx.strokePath()
                    case let .text(s, at, size, anchor, rotation, color, bold):
                        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size * ptPerMM, nil)
                        let attrs: [NSAttributedString.Key: Any] = [
                            NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font,
                            NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String): cg(color),
                        ]
                        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
                        let w = CTLineGetTypographicBounds(line, nil, nil, nil)
                        let dx = anchor == .start ? 0 : anchor == .middle ? -w / 2 : -w
                        ctx.saveGState()
                        let origin = pt(at)
                        ctx.translateBy(x: origin.x, y: origin.y)
                        ctx.rotate(by: -rotation * .pi / 180)
                        ctx.textPosition = CGPoint(x: dx, y: 0)
                        CTLineDraw(line, ctx)
                        ctx.restoreGState()
                    }
                }
            }
            ctx.endPDFPage()
            ctx.closePDF()
            return data as Data
        }
    }
}
