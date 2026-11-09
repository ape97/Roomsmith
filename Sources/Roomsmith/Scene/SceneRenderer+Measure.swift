import AppKit
import Foundation
import RealityKit
import RoomsmithCore
import simd

// Measure tool of the 3D view: two clicks on surfaces give a straight distance with dx/dy/dz. The points are kept in
// document coordinates (mm), so the line and its label stay on the world points while the camera moves. The drawing is
// a transparent AppKit overlay above the ARView that is re-projected from the camera every frame.

/// What the overlay draws, in view points with the origin at the bottom left. Equatable so a frame without change
/// does not redraw.
struct MeasureShape: Equatable {
    /// Where the two points are drawn (nil: behind the camera).
    var a: CGPoint?
    var b: CGPoint?
    /// Ends of the line, clipped at the camera's near plane when one point is behind it.
    var lineA: CGPoint?
    var lineB: CGPoint?
    /// The second point follows the pointer (not clicked yet): dashed line.
    var preview = false
    var lines: [String] = []
}

extension SceneRenderer {
    /// The measure tool takes the clicks of this view (not in first person, not while Space makes it a Hand).
    var measureActive: Bool { model.tool == .measure && camera.rig.mode != .firstPerson }

    // MARK: Points

    /// The surface point under a view point: the nearest picked surface, else the ground plane of the active level.
    func measurePoint(at p: SIMD2<Double>) -> P3? {
        let r = ray(at: p)
        var world: D3?
        if let hit = pickNearest(origin: r.origin, dir: r.dir) {
            world = r.origin + r.dir * hit.t
        } else if abs(r.dir.z) > 1e-6 {
            let t = (activeElevation - r.origin.z) / r.dir.z
            if t > 0 { world = r.origin + r.dir * t }
        }
        guard let w = world, w.x.isFinite, w.y.isFinite, w.z.isFinite else { return nil }
        let q = P3(MM(w.x.rounded()), MM(w.y.rounded()), MM(w.z.rounded()))
        return q.isInRange ? q : nil
    }

    /// A click of the measure tool: first A, then B, then a new measurement.
    func measureClick(at point: SIMD2<Double>) {
        guard let p = measurePoint(at: point) else { return }
        measure.click(p)
        measurePreview = nil
        refreshMeasureOverlay()
    }

    /// Pointer moved while A waits for B: the line follows the cursor.
    func measureHover(at point: SIMD2<Double>) {
        guard measure.isPending else { return }
        let p = measurePoint(at: point)
        if p != measurePreview { measurePreview = p; refreshMeasureOverlay() }
    }

    func clearMeasurement() {
        guard !measure.isEmpty || measurePreview != nil else { return }
        measure.clear()
        measurePreview = nil
        refreshMeasureOverlay()
    }

    /// The tool was switched on or off (toolbar, shortcut, plan): drop hover and gizmo, set the cursor, forget a leftover.
    func measureToolDidChange() {
        lastMeasureActive = measureActive
        if !measureActive { clearMeasurement() }
        guard interactive, !stopped else { return }
        if measureActive {
            gizmo.highlight(nil)
            if model.hoveredId != nil { model.hoveredId = nil }
        }
        updateGizmo()
        if let v = arView { v.window?.invalidateCursorRects(for: v) }
    }

    // MARK: Overlay

    func installMeasureOverlay(in view: ARView) {
        guard interactive, measureOverlay == nil else { return }
        let overlay = SceneMeasureOverlay(frame: view.bounds)
        overlay.autoresizingMask = [.width, .height]
        view.addSubview(overlay)
        measureOverlay = overlay
    }

    /// Projects the measurement with the current camera.
    func currentMeasureShape() -> MeasureShape? {
        guard let a = measure.a else { return nil }
        let unit = model.project.settings.displayUnit
        let b = measure.b ?? measurePreview
        var shape = MeasureShape(preview: measure.b == nil)
        if let b {
            shape.lines = Measurement3D(a: a, b: b).labelLines(unit: unit)
        } else {
            shape.lines = ["Click the second point"]
        }
        let size = camera.viewSize
        guard size.width > 0, size.height > 0 else { return nil }
        let aspect = Double(size.width / size.height)
        let rig = camera.rig
        let pa = D3(Double(a.x), Double(a.y), Double(a.z))
        guard let b else {
            shape.a = Self.screenPoint(pa, rig: rig, aspect: aspect, size: size)
            return shape
        }
        let pb = D3(Double(b.x), Double(b.y), Double(b.z))
        // A point behind the camera is replaced by the place where the line crosses the near plane.
        let minDepth = 1.0
        let da = simd_dot(pa - rig.eye, rig.forward), db = simd_dot(pb - rig.eye, rig.forward)
        var ca = pa, cb = pb
        if da < minDepth, db < minDepth { return nil }
        if da < minDepth { ca = pa + (pb - pa) * ((minDepth - da) / (db - da)) }
        if db < minDepth { cb = pb + (pa - pb) * ((minDepth - db) / (da - db)) }
        shape.a = da < minDepth ? nil : Self.screenPoint(pa, rig: rig, aspect: aspect, size: size)
        shape.b = db < minDepth ? nil : Self.screenPoint(pb, rig: rig, aspect: aspect, size: size)
        shape.lineA = Self.screenPoint(ca, rig: rig, aspect: aspect, size: size)
        shape.lineB = Self.screenPoint(cb, rig: rig, aspect: aspect, size: size)
        return shape
    }

    private static func screenPoint(_ p: D3, rig: CameraRig, aspect: Double, size: CGSize) -> CGPoint? {
        guard let n = rig.project(p, aspect: aspect) else { return nil }
        return CGPoint(x: (n.x + 1) / 2 * Double(size.width), y: (n.y + 1) / 2 * Double(size.height))
    }

    func refreshMeasureOverlay() {
        guard let overlay = measureOverlay else { return }
        let shape = camera.rig.mode == .firstPerson ? nil : currentMeasureShape()
        if overlay.shape != shape { overlay.shape = shape }
    }
}

/// Transparent view above the 3D scene that draws the measuring line and its label. It never takes mouse events.
final class SceneMeasureOverlay: NSView {
    var shape: MeasureShape? { didSet { if shape != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func isAccessibilityElement() -> Bool { false }

    private static let lineColor = NSColor(calibratedRed: 1.0, green: 0.82, blue: 0.1, alpha: 1)

    override func draw(_ dirtyRect: NSRect) {
        guard let shape, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setLineCap(.round)
        if let p = shape.lineA, let q = shape.lineB {
            for (width, color) in [(5.0, NSColor.black.withAlphaComponent(0.55)), (2.5, Self.lineColor)] {
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineWidth(width)
                ctx.setLineDash(phase: 0, lengths: shape.preview ? [7, 5] : [])
                ctx.move(to: p)
                ctx.addLine(to: q)
                ctx.strokePath()
            }
            ctx.setLineDash(phase: 0, lengths: [])
        }
        for point in [shape.a, shape.b].compactMap({ $0 }) {
            let halo = CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
            ctx.fillEllipse(in: halo)
            ctx.setFillColor(Self.lineColor.cgColor)
            ctx.fillEllipse(in: halo.insetBy(dx: 2, dy: 2))
        }
        drawLabel(shape)
    }

    private func drawLabel(_ shape: MeasureShape) {
        guard !shape.lines.isEmpty else { return }
        let anchor: CGPoint
        if let p = shape.lineA, let q = shape.lineB { anchor = CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2) }
        else if let p = shape.a ?? shape.b { anchor = p }
        else { return }
        let fonts = [NSFont.systemFont(ofSize: 13, weight: .semibold), NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)]
        let strings = shape.lines.enumerated().map { i, line in
            NSAttributedString(string: line, attributes: [.font: fonts[min(i, 1)], .foregroundColor: NSColor.white])
        }
        let sizes = strings.map { $0.size() }
        let width = (sizes.map(\.width).max() ?? 0) + 16
        let height = sizes.map(\.height).reduce(0, +) + 10
        var box = CGRect(x: anchor.x - width / 2, y: anchor.y + 12, width: width, height: height)
        box.origin.x = min(max(box.origin.x, 6), max(6, bounds.width - width - 6))
        box.origin.y = min(max(box.origin.y, 6), max(6, bounds.height - height - 6))
        let pill = NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7)
        NSColor.black.withAlphaComponent(0.78).setFill()
        pill.fill()
        var y = box.maxY - 5
        for (s, size) in zip(strings, sizes) {
            y -= size.height
            s.draw(at: CGPoint(x: box.minX + (width - size.width) / 2, y: y))
        }
    }
}
