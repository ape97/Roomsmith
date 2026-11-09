import AppKit
import simd
import RoomsmithCore

// Background images (scanned plans) under the drawing. The asset file only exists inside a saved project package.

extension PlanNSView {
    func backgroundImage(_ bg: BackgroundImage) -> NSImage? {
        if imagesFor != model.fileURL { images.removeAll(); imagesFor = model.fileURL }
        if let cachedImage = images[bg.assetId] { return cachedImage }
        // Without a package file or an asset record nothing is cached: either may appear with the next change.
        guard let pkg = model.fileURL, let asset = project.asset(bg.assetId) else { return nil }
        let image = NSImage(contentsOf: ProjectPackage.assetURL(asset, in: pkg))
        // A failed read is remembered only until the next document change (not on every redraw, and not for good).
        images[bg.assetId] = .some(image)
        return image
    }

    /// Called when the document changed: forgets pictures of backgrounds that are gone and failed reads (the file may be there now).
    func pruneBackgroundImages() {
        let live = Set(project.backgrounds.map(\.assetId))
        images = images.filter { live.contains($0.key) && $0.value != nil }
    }

    /// Pixel size of the image (not the point size, which depends on the file's DPI).
    func pixelSize(_ image: NSImage) -> CGSize {
        var best = CGSize.zero
        for rep in image.representations where rep.pixelsWide > 0 && rep.pixelsHigh > 0 {
            let s = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            if s.width * s.height > best.width * best.height { best = s }
        }
        return best == .zero ? image.size : best
    }

    /// World rectangle covered by the image: origin is the top-left pixel; the image grows +x and -y.
    func backgroundExtent(_ bg: BackgroundImage) -> (lo: V2, hi: V2)? {
        guard let img = backgroundImage(bg) else { return nil }
        let px = pixelSize(img)
        let mmpp = bg.mmPerPixel
        let o = bg.origin.v
        return (V2(o.x, o.y - Double(px.height) * mmpp), V2(o.x + Double(px.width) * mmpp, o.y))
    }

    func drawBackgrounds(_ ctx: CGContext, visible: (lo: V2, hi: V2)) {
        let level = levelId
        let all = project.backgrounds.filter { $0.levelId == level && $0.visible }
        guard !all.isEmpty else { return }
        if model.fileURL == nil {
            drawCornerNote("Save the project to show its background images")
        }
        for bg in all {
            guard let img = backgroundImage(bg), let ext = backgroundExtent(bg) else { continue }
            guard ext.hi.x >= visible.lo.x, ext.lo.x <= visible.hi.x, ext.hi.y >= visible.lo.y, ext.lo.y <= visible.hi.y else { continue }
            let tl = vp.screen(V2(ext.lo.x, ext.hi.y)), br = vp.screen(V2(ext.hi.x, ext.lo.y))
            let rect = NSRect(x: tl.x, y: tl.y, width: br.x - tl.x, height: br.y - tl.y)
            img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: CGFloat(max(0, min(1, bg.opacity))),
                     respectFlipped: true, hints: [.interpolation: NSImageInterpolation.medium.rawValue])
            if model.selection.contains(bg.id) {
                ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
                ctx.setLineWidth(1.5)
                ctx.setLineDash(phase: 0, lengths: [6, 4])
                ctx.stroke(rect)
                ctx.setLineDash(phase: 0, lengths: [])
            }
        }
    }

    func drawCornerNote(_ text: String) {
        let s = attributed(text, size: 11, color: .secondaryLabelColor)
        let sz = s.size()
        s.draw(at: NSPoint(x: bounds.maxX - sz.width - 14, y: bounds.maxY - sz.height - 10))
    }
}
