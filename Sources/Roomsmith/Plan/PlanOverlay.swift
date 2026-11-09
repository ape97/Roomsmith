import AppKit
import simd
import RoomsmithCore

// Interactive overlay: selection, hover, handles, snap feedback and tool previews.

extension PlanNSView {
    func drawOverlay(_ ctx: CGContext, _ sc: PlanScene) {
        dimLabelBoxes.removeAll(keepingCapacity: true)   // the live labels of a drag are judged on their own
        // Hover (not while dragging)
        if moveDrag?.started != true, handleDrag?.started != true, let h = model.hoveredId, !model.selection.contains(h) {
            highlight(ctx, h, sc, color: PlanColors.accent.withAlphaComponent(0.7), width: 1.5, fill: 0.06)
        }
        // Selection
        for id in model.selection { highlight(ctx, id, sc, color: PlanColors.accent, width: 2, fill: 0.1) }

        if model.tool == .select {
            drawHandles(ctx, sc)
            drawGuides(ctx, (moveDrag?.guides ?? []) + (handleDrag?.guides ?? []))
            if let mq = marquee, hypot(Double(mq.current.x - mq.start.x), Double(mq.current.y - mq.start.y)) > 3 {
                let r = NSRect(x: min(mq.start.x, mq.current.x), y: min(mq.start.y, mq.current.y),
                               width: abs(mq.current.x - mq.start.x), height: abs(mq.current.y - mq.start.y))
                ctx.setFillColor(PlanColors.accent.withAlphaComponent(0.1).cgColor)
                ctx.setStrokeColor(PlanColors.accent.cgColor)
                ctx.setLineWidth(1)
                ctx.fill(r); ctx.stroke(r)
            }
            drawDragReadout(ctx)
        } else {
            drawToolOverlay(ctx, sc)
        }
    }

    // MARK: Highlight

    func highlight(_ ctx: CGContext, _ id: UUID, _ sc: PlanScene, color: NSColor, width: CGFloat, fill: CGFloat) {
        guard let r = sc.byId[id] else { return }
        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.withAlphaComponent(fill).cgColor)
        ctx.setLineWidth(width)
        func poly(_ pts: [V2]) {
            let p = screenPath(pts)
            ctx.addPath(p); ctx.fillPath()
            ctx.addPath(p); ctx.strokePath()
        }
        switch r.kind {
        case .room: poly(sc.rooms[r.index].polygon)
        case .wall: for piece in sc.walls[r.index].pieces { poly(piece) }
        case .opening:
            let o = sc.openings[r.index]
            poly([o.r0, o.r1, o.l1, o.l0])
        case .foot: poly(sc.feet[r.index].corners)
        case .group:
            let g = sc.groups[r.index]
            poly(g.corners)
            for m in g.group.memberIds { if let mr = sc.byId[m], mr.kind == .foot { poly(sc.feet[mr.index].corners) } }
        case .dim:
            let d = sc.dims[r.index]
            ctx.beginPath()
            ctx.move(to: vp.screen(d.a)); ctx.addLine(to: vp.screen(d.a2)); ctx.addLine(to: vp.screen(d.b2)); ctx.addLine(to: vp.screen(d.b))
            ctx.strokePath()
        }
    }

    // MARK: Handles

    func drawHandles(_ ctx: CGContext, _ sc: PlanScene) {
        guard model.selection.count == 1, let id = model.selection.first else { return }
        for (h, p) in handles(for: id, in: sc) {
            let s = vp.screen(p)
            let active = hoverHandle == h || handleDrag?.handle == h
            if case .rotate = h {
                if let ref = sc.byId[id] {
                    let base: V2
                    switch ref.kind {
                    case .foot: base = sc.feet[ref.index].rect.center
                    case .group: base = sc.groups[ref.index].rect.center
                    default: base = p
                    }
                    ctx.setStrokeColor(PlanColors.accent.withAlphaComponent(0.6).cgColor)
                    ctx.setLineWidth(1)
                    line(ctx, base, p)
                }
                ctx.setFillColor((active ? PlanColors.accent : NSColor.textBackgroundColor).cgColor)
                ctx.setStrokeColor(PlanColors.accent.cgColor)
                ctx.setLineWidth(1.5)
                let r = CGRect(x: s.x - 6, y: s.y - 6, width: 12, height: 12)
                ctx.fillEllipse(in: r); ctx.strokeEllipse(in: r)
                // small arrow glyph
                ctx.setStrokeColor((active ? NSColor.white : PlanColors.accent).cgColor)
                ctx.setLineWidth(1.2)
                ctx.beginPath()
                ctx.addArc(center: s, radius: 2.8, startAngle: 0.4, endAngle: 4.6, clockwise: false)
                ctx.strokePath()
                continue
            }
            let size: CGFloat = active ? 10 : 8
            let r = CGRect(x: s.x - size / 2, y: s.y - size / 2, width: size, height: size)
            ctx.setFillColor((active ? PlanColors.accent : NSColor.textBackgroundColor).cgColor)
            ctx.setStrokeColor(PlanColors.accent.cgColor)
            ctx.setLineWidth(1.5)
            if case .dimOffset = h {
                ctx.fillEllipse(in: r); ctx.strokeEllipse(in: r)
            } else {
                ctx.fill(r); ctx.stroke(r)
            }
        }
    }

    func drawGuides(_ ctx: CGContext, _ guides: [SnapGuide]) {
        guard !guides.isEmpty else { return }
        ctx.setStrokeColor(NSColor.systemPink.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.beginPath()
        for g in guides { ctx.move(to: vp.screen(g.from)); ctx.addLine(to: vp.screen(g.to)) }
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
    }

    /// Small tag with the move distance or rotation angle while dragging.
    func drawDragReadout(_ ctx: CGContext) {
        var text: String?
        if let d = moveDrag, d.started {
            let u = project.settings.displayUnit
            text = "Δ \(u.format(d.delta.x, withUnit: false)), \(u.format(d.delta.y, withUnit: false)) \(u.rawValue)"
        } else if let h = handleDrag, h.started {
            switch h.handle {
            case .rotate:
                if h.ids.count > 1 {
                    text = String(format: "%+.1f°", PlanGesture.signedDisplayAngle(h.rotationDelta))
                } else {
                    let deg = Angle.normalized(((h.startRotation + h.rotationDelta) * 10).rounded() / 10)
                    text = String(format: "%.1f°", deg == 0 ? 0 : deg) // avoids "-0.0°"
                }
            case .wallStart(let id), .wallEnd(let id):
                if let w = displayScene.walls.first(where: { $0.wall.id == id })?.wall {
                    text = project.settings.displayUnit.format(MM(simd_length(w.end.v - w.start.v).rounded()))
                }
            default: break
            }
        }
        if let text, let m = mouse { drawTag(text, near: m) }
    }

    func drawTag(_ text: String, near m: CGPoint) {
        let s = attributed(text, size: 11, weight: .medium, color: .labelColor, mono: true)
        let sz = s.size()
        let r = NSRect(x: min(m.x + 14, bounds.width - sz.width - 16), y: min(m.y + 16, bounds.height - 26), width: sz.width + 12, height: 20)
        let pill = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
        NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
        pill.fill()
        NSColor.separatorColor.setStroke()
        pill.lineWidth = 1
        pill.stroke()
        s.draw(at: NSPoint(x: r.minX + 6, y: r.minY + 3))
    }

    // MARK: Snap marker

    func drawSnapMarker(_ ctx: CGContext, _ r: SnapResult) {
        drawGuides(ctx, r.guides)
        let s = vp.screen(r.point)
        let color: NSColor
        switch r.kind {
        case .none: return
        case .grid: color = .systemGray
        default: color = .systemOrange
        }
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(1.5)
        if r.kind == .grid {
            ctx.beginPath()
            ctx.move(to: CGPoint(x: s.x - 4, y: s.y)); ctx.addLine(to: CGPoint(x: s.x + 4, y: s.y))
            ctx.move(to: CGPoint(x: s.x, y: s.y - 4)); ctx.addLine(to: CGPoint(x: s.x, y: s.y + 4))
            ctx.strokePath()
        } else {
            ctx.stroke(CGRect(x: s.x - 5, y: s.y - 5, width: 10, height: 10))
        }
    }

    // MARK: Tool overlays

    func drawToolOverlay(_ ctx: CGContext, _ sc: PlanScene) {
        let unit = project.settings.displayUnit
        switch model.tool {
        case .wall:
            let thickness = Double(project.settings.defaultWallThickness)
            let candidate = wallCandidate()
            var pts = wallPoints
            if let c = candidate, c != pts.last { pts.append(c) }
            if pts.count >= 2 {
                ctx.setLineCap(.round)
                ctx.setStrokeColor(PlanColors.accent.withAlphaComponent(0.35).cgColor)
                ctx.setLineWidth(max(2, CGFloat(thickness * vp.scale)))
                ctx.addPath(screenPath(pts.map(\.v), closed: false)); ctx.strokePath()
                ctx.setLineCap(.butt)
                ctx.setStrokeColor(PlanColors.accent.cgColor)
                ctx.setLineWidth(1.5)
                ctx.addPath(screenPath(pts.map(\.v), closed: false)); ctx.strokePath()
            }
            for p in wallPoints { dot(ctx, p) }
            if wallPoints.count >= 3, let f = wallPoints.first, let c = candidate {
                let s = vp.screen(f), t = vp.screen(c)
                if hypot(Double(s.x - t.x), Double(s.y - t.y)) <= 10 {
                    ctx.setStrokeColor(NSColor.systemGreen.cgColor); ctx.setLineWidth(2)
                    ctx.strokeEllipse(in: CGRect(x: s.x - 8, y: s.y - 8, width: 16, height: 16))
                }
            }
            if let r = snapResult { drawSnapMarker(ctx, r) }
            if let last = wallPoints.last, let c = candidate, c != last {
                let len = MM(simd_length(c.v - last.v).rounded())
                let ang = atan2(Double(c.y - last.y), Double(c.x - last.x)) * 180 / .pi
                var text = "\(unit.format(len))  \(String(format: "%.1f°", ang < 0 ? ang + 360 : ang))"
                if !wallInput.isEmpty { text = "\(wallInput)  →  \(text)" }
                if let m = mouse { drawTag(text, near: m) }
            } else if !wallInput.isEmpty, let m = mouse {
                drawTag(wallInput, near: m)
            }
        case .room:
            var pts = roomPoints
            if let c = snapResult?.point, !pts.isEmpty, c != pts.last { pts.append(c) }
            if pts.count >= 2 {
                let path = screenPath(pts.map(\.v), closed: pts.count >= 3)
                if pts.count >= 3 { ctx.setFillColor(NSColor.systemTeal.withAlphaComponent(0.15).cgColor); ctx.addPath(path); ctx.fillPath() }
                ctx.setStrokeColor(NSColor.systemTeal.cgColor); ctx.setLineWidth(1.5)
                ctx.addPath(screenPath(pts.map(\.v), closed: false)); ctx.strokePath()
            }
            for p in roomPoints { dot(ctx, p) }
            if let r = snapResult { drawSnapMarker(ctx, r) }
            if roomPoints.count >= 3 {
                let a = Geo.area(roomPoints) / 1_000_000
                if let m = mouse { drawTag(String(format: "%.2f m²", a), near: m) }
            }
        case .door, .window, .opening:
            if let pr = proposal {
                ctx.saveGState()
                // Ghost: paper-coloured gap plus the opening symbol.
                PlanColors.paper.withAlphaComponent(0.9).setFill()
                ctx.addPath(screenPath([pr.item.r0, pr.item.r1, pr.item.l1, pr.item.l0])); ctx.fillPath()
                drawOpening(ctx, pr.item, ghost: true)
                ctx.setStrokeColor(PlanColors.accent.cgColor); ctx.setLineWidth(1.5)
                ctx.addPath(screenPath([pr.item.r0, pr.item.r1, pr.item.l1, pr.item.l0])); ctx.strokePath()
                ctx.restoreGState()
                if let m = mouse {
                    drawTag("\(unit.format(pr.opening.width)) × \(unit.format(pr.opening.height))  @ \(unit.format(pr.opening.offset))", near: m)
                }
            }
        case .dimension:
            if let r = snapResult, dimB == nil { drawSnapMarker(ctx, r) }
            if let a = dimA {
                dot(ctx, a)
                if let b = dimB {
                    dot(ctx, b)
                    let ax = Geo.axis(a, b)
                    let off = ax.normal * Double(dimOffset)
                    let d = PlanDimItem(dimension: RoomsmithCore.Dimension(id: UUID(), levelId: levelId, a: a, b: b, offset: dimOffset),
                                        a: a.v, b: b.v, a2: a.v + off, b2: b.v + off,
                                        length: MM(ax.length.rounded()), lo: a.v, hi: b.v)
                    drawDimension(ctx, d, color: PlanColors.accent)
                } else if let c = snapResult?.point {
                    ctx.setStrokeColor(PlanColors.accent.cgColor); ctx.setLineWidth(1)
                    ctx.setLineDash(phase: 0, lengths: [4, 3])
                    line(ctx, a.v, c.v)
                    ctx.setLineDash(phase: 0, lengths: [])
                    drawDimLabel(ctx, a.v, c.v, text: unit.format(MM(simd_length(c.v - a.v).rounded())), color: PlanColors.accent, ticks: false)
                }
            }
        case .measure:
            let b = measureB ?? (measureA != nil ? snapResult?.point : nil)
            if measureB == nil, let r = snapResult { drawSnapMarker(ctx, r) }
            if let a = measureA {
                dot(ctx, a)
                if let b, b != a {
                    dot(ctx, b)
                    ctx.setStrokeColor(NSColor.systemOrange.cgColor); ctx.setLineWidth(1.5)
                    line(ctx, a.v, b.v)
                    let mid = vp.screen((a.v + b.v) / 2)
                    drawTag(distanceText(a, b), near: CGPoint(x: mid.x - 20, y: mid.y - 36))
                }
            }
        case .calibrate:
            if let bg = calibrationTarget(), let ext = backgroundExtent(bg) {
                let tl = vp.screen(V2(ext.lo.x, ext.hi.y)), br = vp.screen(V2(ext.hi.x, ext.lo.y))
                ctx.setStrokeColor(NSColor.systemOrange.cgColor); ctx.setLineWidth(1.5)
                ctx.setLineDash(phase: 0, lengths: [6, 4])
                ctx.stroke(CGRect(x: tl.x, y: tl.y, width: br.x - tl.x, height: br.y - tl.y))
                ctx.setLineDash(phase: 0, lengths: [])
            }
            if calB == nil, let r = snapResult { drawSnapMarker(ctx, r) }
            if let a = calA {
                dot(ctx, a)
                let b = calB ?? snapResult?.point
                if let b, b != a {
                    if calB != nil { dot(ctx, b) }
                    ctx.setStrokeColor(NSColor.systemOrange.cgColor); ctx.setLineWidth(1.5)
                    line(ctx, a.v, b.v)
                    if let m = mouse { drawTag(unit.format(MM(simd_length(b.v - a.v).rounded())), near: m) }
                }
            }
        case .select, .hand: break
        }
    }

    func dot(_ ctx: CGContext, _ p: P2) {
        let s = vp.screen(p)
        ctx.setFillColor(NSColor.textBackgroundColor.cgColor)
        ctx.setStrokeColor(PlanColors.accent.cgColor)
        ctx.setLineWidth(1.5)
        let r = CGRect(x: s.x - 3.5, y: s.y - 3.5, width: 7, height: 7)
        ctx.fillEllipse(in: r); ctx.strokeEllipse(in: r)
    }
}
