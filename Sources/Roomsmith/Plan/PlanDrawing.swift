import AppKit
import simd
import RoomsmithCore

// Static drawing of the plan: paper, grid, rooms, walls, openings, furniture, groups, dimensions, HUD.

enum PlanColors {
    static let paper = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.115, alpha: 1) : NSColor(white: 0.985, alpha: 1)
    }
    static let ink = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.92, alpha: 1) : NSColor(white: 0.12, alpha: 1)
    }
    static let wallFill = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.34, alpha: 1) : NSColor(white: 0.74, alpha: 1)
    }
    static let furniture = NSColor.systemBlue
    static let collision = NSColor.systemRed
    static let accent = NSColor.controlAccentColor
}

extension PlanNSView {
    // MARK: Entry

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        vp.size = bounds.size
        let sc = displayScene
        drawPlanContent(ctx, sc)
        drawOverlay(ctx, sc)
        drawDropPreview(ctx)
        drawHUD(ctx)
    }

    /// The document content of the plan (paper, backgrounds, grid, items) in the current `vp`, without the
    /// interaction overlay and the HUD. Shared by the on-screen view and the offscreen presenter render.
    func drawPlanContent(_ ctx: CGContext, _ sc: PlanScene) {
        let vis = vp.visible
        dimLabelBoxes.removeAll(keepingCapacity: true)

        PlanColors.paper.setFill()
        ctx.fill(bounds)

        drawBackgrounds(ctx, visible: vis)
        drawGrid(ctx, vis)
        drawGhost(ctx, sc, vis)

        let indices = sc.query(lo: vis.lo, hi: vis.hi)
        let hatch = indices.count < 600
        // Room names and areas go on top of everything (as in the export, `PlanExport` labels layer): furniture never
        // hides them, and furniture names that would collide with one are left out.
        let labels = indices.compactMap { i -> RoomLabel? in
            let r = sc.refs[i]
            return r.kind == .room ? roomLabel(sc.rooms[r.index]) : nil
        }
        let labelBoxes = labels.map(\.box)
        for i in indices {
            let r = sc.refs[i]
            switch r.kind {
            case .room: drawRoom(ctx, sc.rooms[r.index])
            case .wall: drawWall(ctx, sc.walls[r.index], hatch: hatch)
            case .opening: drawOpening(ctx, sc.openings[r.index])
            case .foot: drawFoot(ctx, sc.feet[r.index], sc, avoiding: labelBoxes)
            case .group: drawGroup(ctx, sc.groups[r.index])
            case .dim: drawDimension(ctx, sc.dims[r.index])
            }
        }
        for l in labels { drawRoomLabel(ctx, l) }
    }

    /// Draws the document scene into any bitmap `CGContext` (bottom-left origin, as created by `CGContext(data:...)`)
    /// of `viewport.size` points: no interaction overlay, no tool hint. Scale bar and north arrow stay.
    /// `drawExtras` runs in the same flipped (y down) coordinate space after the content, e.g. for a pointer marker.
    /// Must be called on the main actor with an offscreen view (never the one on screen: it changes `vp`).
    func drawOffscreen(in cg: CGContext, viewport: PlanViewport, scene sc: PlanScene, drawExtras: (CGContext) -> Void = { _ in }) {
        vp = viewport
        cg.saveGState()
        cg.translateBy(x: 0, y: viewport.size.height)
        cg.scaleBy(x: 1, y: -1)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            drawPlanContent(cg, sc)
            drawScaleBarAndNorthArrow(cg)
            drawExtras(cg)
        }
        NSGraphicsContext.current = previous
        cg.restoreGState()
    }

    // MARK: Helpers

    func screenPath(_ pts: [V2], closed: Bool = true) -> CGPath {
        let p = CGMutablePath()
        guard let f = pts.first else { return p }
        p.move(to: vp.screen(f))
        for q in pts.dropFirst() { p.addLine(to: vp.screen(q)) }
        if closed { p.closeSubpath() }
        return p
    }

    func line(_ ctx: CGContext, _ a: V2, _ b: V2) {
        ctx.move(to: vp.screen(a)); ctx.addLine(to: vp.screen(b)); ctx.strokePath()
    }

    // MARK: Grid

    func drawGrid(_ ctx: CGContext, _ vis: (lo: V2, hi: V2)) {
        let g = PlanGrid.spacing(scale: vp.scale)
        func lines(_ step: Double, _ alpha: CGFloat) {
            ctx.setStrokeColor(PlanColors.ink.withAlphaComponent(alpha).cgColor)
            ctx.setLineWidth(1)
            var x = (vis.lo.x / step).rounded(.down) * step
            ctx.beginPath()
            while x <= vis.hi.x {
                let sx = (vp.screen(V2(x, 0)).x).rounded() + 0.5
                ctx.move(to: CGPoint(x: sx, y: 0)); ctx.addLine(to: CGPoint(x: sx, y: bounds.height))
                x += step
            }
            var y = (vis.lo.y / step).rounded(.down) * step
            while y <= vis.hi.y {
                let sy = (vp.screen(V2(0, y)).y).rounded() + 0.5
                ctx.move(to: CGPoint(x: 0, y: sy)); ctx.addLine(to: CGPoint(x: bounds.width, y: sy))
                y += step
            }
            ctx.strokePath()
        }
        lines(g.minor, 0.05)
        if g.major > g.minor { lines(g.major, 0.11) }
        // Origin cross
        let o = vp.screen(V2(0, 0))
        ctx.setStrokeColor(PlanColors.ink.withAlphaComponent(0.3).cgColor)
        ctx.setLineWidth(1)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: o.x - 6, y: o.y)); ctx.addLine(to: CGPoint(x: o.x + 6, y: o.y))
        ctx.move(to: CGPoint(x: o.x, y: o.y - 6)); ctx.addLine(to: CGPoint(x: o.x, y: o.y + 6))
        ctx.strokePath()
    }

    func drawGhost(_ ctx: CGContext, _ sc: PlanScene, _ vis: (lo: V2, hi: V2)) {
        guard !sc.ghostWalls.isEmpty else { return }
        ctx.setFillColor(PlanColors.ink.withAlphaComponent(0.06).cgColor)
        ctx.setStrokeColor(PlanColors.ink.withAlphaComponent(0.18).cgColor)
        ctx.setLineWidth(0.75)
        for poly in sc.ghostWalls where poly.count >= 3 {
            let (lo, hi) = PlanScene.bbox(poly)
            guard hi.x >= vis.lo.x, lo.x <= vis.hi.x, hi.y >= vis.lo.y, lo.y <= vis.hi.y else { continue }
            let p = screenPath(poly)
            ctx.addPath(p); ctx.fillPath()
            ctx.addPath(p); ctx.strokePath()
        }
    }

    // MARK: Rooms

    func drawRoom(_ ctx: CGContext, _ r: PlanRoomItem) {
        let path = screenPath(r.polygon)
        let base: NSColor = r.floor.map { NSColor(srgbRed: CGFloat($0.r) / 255, green: CGFloat($0.g) / 255, blue: CGFloat($0.b) / 255, alpha: 1) }
            ?? NSColor.systemTeal
        ctx.setFillColor(base.withAlphaComponent(r.floor == nil ? 0.09 : 0.32).cgColor)
        ctx.addPath(path); ctx.fillPath()
    }

    struct RoomLabel {
        let name: NSAttributedString, area: NSAttributedString
        let center: CGPoint, width: CGFloat
        /// Screen box of the drawn text, padded: the backdrop and the area furniture names keep clear of.
        let box: CGRect
    }

    /// Name and area of a room when the room is large enough on screen to hold them.
    func roomLabel(_ r: PlanRoomItem) -> RoomLabel? {
        let wpx = (r.hi.x - r.lo.x) * vp.scale, hpx = (r.hi.y - r.lo.y) * vp.scale
        guard wpx > 56, hpx > 28 else { return nil }
        let c = vp.screen(r.labelPoint)
        let name = attributed(r.room.name, size: 12, weight: .semibold, color: PlanColors.ink.withAlphaComponent(0.85))
        let area = attributed(String(format: "%.2f m²", r.areaM2), size: 11, color: PlanColors.ink.withAlphaComponent(0.6), mono: true)
        let w = min(CGFloat(wpx) - 8, 220)
        let textW = min(max(name.size().width, area.size().width), w)
        let box = CGRect(x: c.x - textW / 2 - 4, y: c.y - 16, width: textW + 8, height: 33)
        return RoomLabel(name: name, area: area, center: c, width: w, box: box)
    }

    func drawRoomLabel(_ ctx: CGContext, _ l: RoomLabel) {
        ctx.setFillColor(PlanColors.paper.withAlphaComponent(0.78).cgColor)
        ctx.addPath(CGPath(roundedRect: l.box, cornerWidth: 4, cornerHeight: 4, transform: nil)); ctx.fillPath()
        l.name.draw(in: NSRect(x: l.center.x - l.width / 2, y: l.center.y - 15, width: l.width, height: 16))
        l.area.draw(in: NSRect(x: l.center.x - l.width / 2, y: l.center.y + 1, width: l.width, height: 15))
    }

    // MARK: Walls

    func drawWall(_ ctx: CGContext, _ w: PlanWallItem, hatch: Bool) {
        let thick = Double(w.wall.thickness) * vp.scale
        ctx.setFillColor(PlanColors.wallFill.cgColor)
        for piece in w.pieces { ctx.addPath(screenPath(piece)); ctx.fillPath() }
        if hatch, thick >= 7 {
            ctx.saveGState()
            ctx.setStrokeColor(PlanColors.ink.withAlphaComponent(0.35).cgColor)
            ctx.setLineWidth(0.6)
            for piece in w.pieces {
                let path = screenPath(piece)
                ctx.addPath(path); ctx.clip()
                let bb = path.boundingBox.intersection(bounds)
                guard !bb.isNull, bb.width > 0, bb.height > 0 else { ctx.resetClip(); continue }
                // Lines x + y = c, phase anchored at the wall piece itself so panning does not make them crawl.
                let pb = path.boundingBox
                let c0 = pb.minX + pb.maxY
                var c = c0 + ((bb.minX + bb.minY - c0) / 5).rounded(.down) * 5
                ctx.beginPath()
                while c <= bb.maxX + bb.maxY {
                    ctx.move(to: CGPoint(x: c - bb.maxY, y: bb.maxY)); ctx.addLine(to: CGPoint(x: c - bb.minY, y: bb.minY))
                    c += 5
                }
                ctx.strokePath()
                ctx.resetClip()
            }
            ctx.restoreGState()
        }
        ctx.setStrokeColor(PlanColors.ink.cgColor)
        ctx.setLineWidth(thick < 3 ? 1 : 1.25)
        ctx.setLineCap(.butt)
        ctx.beginPath()
        for (a, b) in w.edges { ctx.move(to: vp.screen(a)); ctx.addLine(to: vp.screen(b)) }
        ctx.strokePath()
    }

    // MARK: Openings

    func drawOpening(_ ctx: CGContext, _ o: PlanOpeningItem, ghost: Bool = false) {
        let alpha: CGFloat = ghost ? 0.55 : 1
        let ink = PlanColors.ink.withAlphaComponent(alpha)
        ctx.setStrokeColor(ink.cgColor)
        ctx.setLineWidth(1.25)
        // Jambs
        ctx.beginPath()
        ctx.move(to: vp.screen(o.r0)); ctx.addLine(to: vp.screen(o.l0))
        ctx.move(to: vp.screen(o.r1)); ctx.addLine(to: vp.screen(o.l1))
        ctx.strokePath()
        switch o.opening.kind {
        case .window:
            ctx.setLineWidth(1)
            let t = o.thickness
            ctx.beginPath()
            ctx.move(to: vp.screen(o.r0)); ctx.addLine(to: vp.screen(o.r1))
            ctx.move(to: vp.screen(o.l0)); ctx.addLine(to: vp.screen(o.l1))
            let off = o.normal * (t / 6)
            ctx.move(to: vp.screen(o.a0 + off)); ctx.addLine(to: vp.screen(o.a1 + off))
            ctx.move(to: vp.screen(o.a0 - off)); ctx.addLine(to: vp.screen(o.a1 - off))
            ctx.strokePath()
        case .door:
            let flipped = o.opening.flipped
            let hinge = flipped ? o.a1 : o.a0
            let closed = flipped ? -o.dir : o.dir
            let openDir = o.normal * (o.opening.inward ? 1 : -1)
            let width = Double(o.opening.width)
            let leafEnd = hinge + openDir * width
            let sweep: Double = (closed.x * openDir.y - closed.y * openDir.x) > 0 ? 90 : -90
            // Leaf
            ctx.setLineWidth(1.5)
            line(ctx, hinge, leafEnd)
            // Swing arc
            ctx.setLineWidth(0.75)
            ctx.setStrokeColor(ink.withAlphaComponent(0.7 * alpha).cgColor)
            ctx.beginPath()
            for k in 0...24 {
                let v = Geo.rotate(closed * width, deg: sweep * Double(k) / 24)
                let pt = vp.screen(hinge + v)
                if k == 0 { ctx.move(to: pt) } else { ctx.addLine(to: pt) }
            }
            ctx.strokePath()
        case .opening:
            break
        }
    }

    // MARK: Furniture

    /// Material colour lightened for the paper background (nil material: neutral grey).
    func topFill(_ c: RoomsmithCore.RGBColor?) -> (fill: CGColor, line: CGColor) {
        let r = Double(c?.r ?? 170) / 255, g = Double(c?.g ?? 170) / 255, b = Double(c?.b ?? 170) / 255
        let k = 0.22
        let fill = NSColor(srgbRed: r + (1 - r) * k, green: g + (1 - g) * k, blue: b + (1 - b) * k, alpha: 1)
        let line = NSColor(srgbRed: r * 0.5, green: g * 0.5, blue: b * 0.5, alpha: 0.9)
        return (fill.cgColor, line.cgColor)
    }

    /// Name colour on a piece of furniture: dark on light fills, light on dark ones, whatever the app appearance
    /// (the fill colours come from the materials, not from the appearance).
    func footLabelColor(_ c: RoomsmithCore.RGBColor?) -> NSColor {
        let k = 0.22
        func lin(_ v: UInt8?) -> Double { let x = Double(v ?? 170) / 255; return x + (1 - x) * k }
        let luminance = 0.2126 * lin(c?.r) + 0.7152 * lin(c?.g) + 0.0722 * lin(c?.b)
        return luminance > 0.55 ? NSColor(white: 0.1, alpha: 0.8) : NSColor(white: 0.97, alpha: 0.9)
    }

    /// Furniture as seen from above: every visible component in its material colour, low parts first so higher
    /// ones cover them. Small on screen: only the overall outline.
    func drawFoot(_ ctx: CGContext, _ f: PlanFootItem, _ sc: PlanScene, avoiding labels: [CGRect] = []) {
        let hit = sc.colliding.contains(f.instance.id) && project.settings.collisionWarnings
        let wpx = (f.hi.x - f.lo.x) * vp.scale, hpx = (f.hi.y - f.lo.y) * vp.scale
        let outline = screenPath(f.corners)
        if f.top.shapes.isEmpty || max(wpx, hpx) < 40 {
            let c = topFill(f.top.overallColor)
            ctx.setFillColor(c.fill); ctx.addPath(outline); ctx.fillPath()
            ctx.setStrokeColor(c.line); ctx.setLineWidth(0.75); ctx.addPath(outline); ctx.strokePath()
        } else {
            ctx.setLineWidth(0.75)
            for shape in f.top.shapes {
                let c = topFill(shape.color)
                let path = screenPath(shape.points)
                ctx.setFillColor(c.fill); ctx.addPath(path); ctx.fillPath()
                ctx.setStrokeColor(c.line); ctx.addPath(path); ctx.strokePath()
            }
        }
        if hit {
            ctx.setFillColor(PlanColors.collision.withAlphaComponent(0.22).cgColor)
            ctx.addPath(outline); ctx.fillPath()
            ctx.setStrokeColor(PlanColors.collision.withAlphaComponent(0.95).cgColor)
            ctx.setLineWidth(1.75)
            ctx.setLineDash(phase: 0, lengths: [6, 3])
            ctx.addPath(outline); ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            // Diagonal hatching as well, so a collision does not rely on colour alone.
            let box = outline.boundingBoxOfPath
            ctx.saveGState()
            ctx.addPath(outline); ctx.clip()
            ctx.setStrokeColor(PlanColors.collision.withAlphaComponent(0.7).cgColor)
            ctx.setLineWidth(1)
            var x = box.minX - box.height
            while x < box.maxX {
                ctx.move(to: CGPoint(x: x, y: box.minY)); ctx.addLine(to: CGPoint(x: x + box.height, y: box.maxY))
                x += 7
            }
            ctx.strokePath()
            ctx.restoreGState()
        }
        guard wpx > 54, hpx > 16 else { return }
        let c = vp.screen(f.rect.center)
        let longPx = max(f.rect.halfSize.x, f.rect.halfSize.y) * 2 * vp.scale, shortPx = min(f.rect.halfSize.x, f.rect.halfSize.y) * 2 * vp.scale
        let w = CGFloat(PlanLabelFit.furnitureNameWidth(boxPixels: wpx, longSidePixels: longPx, shortSidePixels: shortPx))
        guard w > 0 else { return }
        let color = footLabelColor(f.top.overallColor)
        // Smaller type (down to 8 pt) before the name is cut with an ellipsis.
        let widthAtMax = Double(attributed(f.instance.name, size: 10, color: color).size().width)
        let fit = PlanLabelFit.furnitureNameFit(widthAtMax: widthAtMax, available: Double(w))
        let s = attributed(f.instance.name, size: CGFloat(fit.fontSize), color: color)
        let textW = min(s.size().width, w)
        guard !labels.contains(where: { $0.intersects(CGRect(x: c.x - textW / 2, y: c.y - 6.5, width: textW, height: 13)) }) else { return }
        s.draw(in: NSRect(x: c.x - w / 2, y: c.y - 6.5, width: w, height: 13))
    }

    func drawGroup(_ ctx: CGContext, _ g: PlanGroupItem) {
        ctx.setStrokeColor(PlanColors.furniture.withAlphaComponent(0.6).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [5, 4])
        ctx.addPath(screenPath(g.corners)); ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
    }

    // MARK: Dimensions

    func drawDimension(_ ctx: CGContext, _ d: PlanDimItem, color: NSColor = PlanColors.ink) {
        ctx.setStrokeColor(color.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(1)
        ctx.beginPath()
        ctx.move(to: vp.screen(d.a)); ctx.addLine(to: vp.screen(d.a2))
        ctx.move(to: vp.screen(d.b)); ctx.addLine(to: vp.screen(d.b2))
        ctx.move(to: vp.screen(d.a2)); ctx.addLine(to: vp.screen(d.b2))
        ctx.strokePath()
        drawDimLabel(ctx, d.a2, d.b2, text: project.settings.displayUnit.format(d.length), color: color, ticks: true)
    }

    /// Text centred on the segment, rotated along it and kept upright.
    func drawDimLabel(_ ctx: CGContext, _ a: V2, _ b: V2, text: String, color: NSColor, ticks: Bool) {
        let sa = vp.screen(a), sb = vp.screen(b)
        if ticks {
            ctx.setStrokeColor(color.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(1.25)
            let dx = Double(sb.x - sa.x), dy = Double(sb.y - sa.y)
            let len = hypot(dx, dy)
            if len > 0 {
                let ux = dx / len, uy = dy / len
                // 45 degree slash
                let tx = (ux - uy) * 0.7071 * 5, ty = (uy + ux) * 0.7071 * 5
                ctx.beginPath()
                for p in [sa, sb] {
                    ctx.move(to: CGPoint(x: p.x - tx, y: p.y - ty)); ctx.addLine(to: CGPoint(x: p.x + tx, y: p.y + ty))
                }
                ctx.strokePath()
            }
        }
        let len = hypot(Double(sb.x - sa.x), Double(sb.y - sa.y))
        var angle = atan2(Double(sb.y - sa.y), Double(sb.x - sa.x))
        if angle > .pi / 2 { angle -= .pi } else if angle <= -.pi / 2 { angle += .pi }
        let s = attributed(text, size: 11, weight: .medium, color: color, mono: true)
        let size = s.size()
        let mid = CGPoint(x: (sa.x + sb.x) / 2, y: (sa.y + sb.y) / 2)
        // Only a text that fits its segment and does not touch an earlier one is drawn.
        let box = PlanLabelFit.Box(centerX: Double(mid.x), centerY: Double(mid.y), width: Double(size.width) + 6,
                                   height: Double(size.height), angle: angle)
        guard PlanLabelFit.shouldDrawDimension(textWidth: Double(size.width), segmentPixels: len, box: box, placed: dimLabelBoxes) else { return }
        dimLabelBoxes.append(box)
        ctx.saveGState()
        ctx.translateBy(x: mid.x, y: mid.y)
        ctx.rotate(by: CGFloat(angle))
        // Paper-coloured pad so grid and walls do not cut through the number.
        let pad = NSRect(x: -size.width / 2 - 3, y: -size.height - 1, width: size.width + 6, height: size.height)
        PlanColors.paper.withAlphaComponent(0.8).setFill()
        ctx.fill(pad)
        s.draw(at: NSPoint(x: -size.width / 2, y: -size.height - 1))
        ctx.restoreGState()
    }

    // MARK: HUD

    func drawHUD(_ ctx: CGContext) {
        drawScaleBarAndNorthArrow(ctx)
        drawToolHint()
    }

    func drawScaleBarAndNorthArrow(_ ctx: CGContext) {
        // Scale bar (bottom left)
        let length = PlanGrid.scaleBarLength(scale: vp.scale)
        let px = CGFloat(length * vp.scale)
        let x0: CGFloat = 16, y0 = bounds.height - 22
        ctx.setStrokeColor(PlanColors.ink.withAlphaComponent(0.75).cgColor)
        ctx.setLineWidth(1.5)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: x0, y: y0 - 5)); ctx.addLine(to: CGPoint(x: x0, y: y0))
        ctx.addLine(to: CGPoint(x: x0 + px, y: y0)); ctx.addLine(to: CGPoint(x: x0 + px, y: y0 - 5))
        ctx.strokePath()
        let label = attributed(project.settings.displayUnit.format(MM(length)), size: 10, color: PlanColors.ink.withAlphaComponent(0.75), mono: true)
        label.draw(in: NSRect(x: x0, y: y0 - 20, width: max(px, 60), height: 14))

        // North arrow (top right); the plan is always north up.
        let c = CGPoint(x: bounds.width - 34, y: 38)
        ctx.setStrokeColor(PlanColors.ink.withAlphaComponent(0.55).cgColor)
        ctx.setFillColor(PlanColors.ink.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: CGRect(x: c.x - 15, y: c.y - 15, width: 30, height: 30))
        ctx.beginPath()
        ctx.move(to: CGPoint(x: c.x, y: c.y - 12)); ctx.addLine(to: CGPoint(x: c.x - 5, y: c.y + 6))
        ctx.addLine(to: CGPoint(x: c.x, y: c.y + 2)); ctx.addLine(to: CGPoint(x: c.x + 5, y: c.y + 6))
        ctx.closePath(); ctx.fillPath()
        attributed("N", size: 10, weight: .bold, color: PlanColors.ink.withAlphaComponent(0.7))
            .draw(in: NSRect(x: c.x - 10, y: c.y + 15, width: 20, height: 13))
    }

    func drawToolHint() {
        // Tool hint (top left)
        if let text = hintText() {
            let s = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                                  .foregroundColor: NSColor.secondaryLabelColor])
            let sz = s.size()
            let r = NSRect(x: 12, y: 10, width: min(sz.width + 16, bounds.width - 90), height: 22)
            PlanColors.paper.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            s.draw(in: NSRect(x: r.minX + 8, y: r.minY + 4, width: r.width - 12, height: 15))
        }
    }

    func hintText() -> String? {
        if spaceDown { return "Drag to pan" }
        if let hint { return hint }
        switch model.tool {
        case .select: return nil
        case .hand: return "Drag to pan · scroll or pinch to zoom · V for Select"
        case .wall:
            if !wallInput.isEmpty { return "Length: \(wallInput)  (\(project.settings.displayUnit.bareNumberHint) · Enter to apply, Backspace to edit)" }
            return wallPoints.isEmpty ? "Click to start a wall" : "Click for the next corner · type a length (\(project.settings.displayUnit.rawValue)) + Enter · double-click or Enter to finish · Esc cancels"
        case .room:
            return roomPoints.isEmpty ? "Click the corners of the room, or double-click inside walls to detect it"
                : "Click the first corner or press Enter to close · Backspace removes a corner"
        case .door, .window, .opening:
            return "Hover a wall and click to place · F or Shift flips the hinge"
        case .dimension:
            return dimA == nil ? "Click the first point" : dimB == nil ? "Click the second point" : "Move to set the offset, click to place"
        case .measure:
            return measureA == nil || measureB != nil ? "Click the first point to measure" : "Click the second point"
        case .calibrate:
            if calibrationTarget() == nil { return "Select a background image of this level first" }
            return calA == nil || calB != nil ? "Click the first reference point on the image" : "Click the second reference point"
        }
    }
}
