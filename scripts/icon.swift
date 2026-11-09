// Draws the Roomsmith app icon: macOS squircle with a deep blue blueprint grid, a white isometric room (cube)
// and a small orange dimension arrow along one edge.
// Usage: swift scripts/icon.swift [output.png] [output.icns]
//   Defaults: docs/images/icon.png (1024 px) and Resources/AppIcon.icns (all sizes 16...1024 incl. @2x, built with iconutil).
// Run it from the repository root.
import AppKit

let pngPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/images/icon.png"
let icnsPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "Resources/AppIcon.icns"

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

/// Superellipse like the Apple icon shape (continuous corners).
func squircle(_ rect: CGRect, n: Double = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2, cx = rect.midX, cy = rect.midY
    for i in 0...720 {
        let t = Double(i) / 720 * 2 * .pi
        let c = cos(t), s = sin(t)
        let p = CGPoint(x: cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n), y: cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n))
        i == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    path.closeSubpath()
    return path
}

func render() -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    func linear(_ colors: [CGColor], _ from: CGPoint, _ to: CGPoint, locations: [CGFloat]? = nil) {
        let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
        cg.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    func poly(_ pts: [CGPoint]) -> CGPath {
        let p = CGMutablePath(); p.addLines(between: pts); p.closeSubpath(); return p
    }

    let shape = squircle(CGRect(x: 100, y: 100, width: 824, height: 824))

    // Shadow below the shape
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: color(0, 0, 0, 0.35))
    cg.addPath(shape); cg.setFillColor(color(0.02, 0.10, 0.28)); cg.fillPath()
    cg.restoreGState()

    // Blueprint background
    cg.saveGState()
    cg.addPath(shape); cg.clip()
    linear([color(0.13, 0.36, 0.78), color(0.06, 0.20, 0.52), color(0.02, 0.09, 0.28)],
           CGPoint(x: 512, y: 924), CGPoint(x: 512, y: 100), locations: [0, 0.5, 1])
    let glow = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, 0.22), color(1, 1, 1, 0)] as CFArray, locations: nil)!
    cg.drawRadialGradient(glow, startCenter: CGPoint(x: 340, y: 880), startRadius: 0, endCenter: CGPoint(x: 340, y: 880), endRadius: 560, options: [])

    // Grid: fine lines every 64 px, stronger every 4th
    cg.setLineCap(.butt)
    for i in 0...16 {
        let v = 100 + CGFloat(i) * 51.5
        cg.setStrokeColor(color(0.7, 0.85, 1, i % 4 == 0 ? 0.20 : 0.09))
        cg.setLineWidth(i % 4 == 0 ? 3 : 2)
        cg.move(to: CGPoint(x: v, y: 100)); cg.addLine(to: CGPoint(x: v, y: 924)); cg.strokePath()
        cg.move(to: CGPoint(x: 100, y: v)); cg.addLine(to: CGPoint(x: 924, y: v)); cg.strokePath()
    }

    // Isometric room (cube): hexagon of radius 235 around (512, 540)
    let cx: CGFloat = 512, cy: CGFloat = 548, r: CGFloat = 235, h = r * 0.866, half = r * 0.5
    let top = CGPoint(x: cx, y: cy + r), upR = CGPoint(x: cx + h, y: cy + half), loR = CGPoint(x: cx + h, y: cy - half)
    let bottom = CGPoint(x: cx, y: cy - r), loL = CGPoint(x: cx - h, y: cy - half), upL = CGPoint(x: cx - h, y: cy + half)
    let centre = CGPoint(x: cx, y: cy)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 26, color: color(0, 0.04, 0.16, 0.45))
    cg.addPath(poly([top, upR, loR, bottom, loL, upL])); cg.setFillColor(color(1, 1, 1)); cg.fillPath()
    cg.restoreGState()
    // Faces: floor plan seen from above (top, bright), left wall, right wall (shaded)
    cg.addPath(poly([top, upR, centre, upL])); cg.setFillColor(color(1, 1, 1)); cg.fillPath()
    cg.addPath(poly([upL, centre, bottom, loL])); cg.setFillColor(color(0.78, 0.88, 1)); cg.fillPath()
    cg.addPath(poly([centre, upR, loR, bottom])); cg.setFillColor(color(0.55, 0.72, 0.97)); cg.fillPath()
    // Seams between the faces
    cg.setStrokeColor(color(0.06, 0.20, 0.52, 0.9)); cg.setLineWidth(10); cg.setLineJoin(.round); cg.setLineCap(.round)
    cg.move(to: upL); cg.addLine(to: centre); cg.addLine(to: upR); cg.strokePath()
    cg.move(to: centre); cg.addLine(to: bottom); cg.strokePath()
    // Room opening in the top face: an inset floor diamond in blueprint blue
    let k: CGFloat = 0.5
    func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
    let mid = lerp(top, centre, 0.5)
    let floor = [lerp(mid, top, k), lerp(mid, upR, k), lerp(mid, centre, k), lerp(mid, upL, k)]
    cg.addPath(poly(floor)); cg.setFillColor(color(0.13, 0.36, 0.78, 0.9)); cg.fillPath()

    // Orange dimension arrow parallel to the lower left edge, offset outwards
    let orange = color(1.0, 0.58, 0.10), nx: CGFloat = -0.5, ny: CGFloat = -0.866, off: CGFloat = 92
    let a = CGPoint(x: loL.x + nx * off, y: loL.y + ny * off), b = CGPoint(x: bottom.x + nx * off, y: bottom.y + ny * off)
    let dx = (b.x - a.x), dy = (b.y - a.y), len = (dx * dx + dy * dy).squareRoot(), ux = dx / len, uy = dy / len
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -5), blur: 10, color: color(0, 0.03, 0.12, 0.5))
    cg.setStrokeColor(orange); cg.setLineWidth(22); cg.setLineCap(.round)
    cg.move(to: a); cg.addLine(to: b); cg.strokePath()
    for (p, s) in [(a, CGFloat(1)), (b, CGFloat(-1))] {   // arrow heads pointing outwards
        let tip = CGPoint(x: p.x - ux * s * 16, y: p.y - uy * s * 16)
        let w: CGFloat = 36, l: CGFloat = 62
        let base = CGPoint(x: tip.x + ux * s * l, y: tip.y + uy * s * l)
        cg.addPath(poly([tip, CGPoint(x: base.x - uy * w, y: base.y + ux * w), CGPoint(x: base.x + uy * w, y: base.y - ux * w)]))
        cg.setFillColor(orange); cg.fillPath()
    }
    // End ticks across the arrow, at the tips
    cg.setLineWidth(16)
    for (p, s) in [(a, CGFloat(1)), (b, CGFloat(-1))] {
        let tip = CGPoint(x: p.x - ux * s * 16, y: p.y - uy * s * 16)
        cg.move(to: CGPoint(x: tip.x - nx * 46, y: tip.y - ny * 46))
        cg.addLine(to: CGPoint(x: tip.x + nx * 46, y: tip.y + ny * 46)); cg.strokePath()
    }
    cg.restoreGState()
    cg.restoreGState()

    // Glass edge
    cg.saveGState()
    cg.addPath(shape); cg.setLineWidth(6); cg.replacePathWithStrokedPath(); cg.clip()
    linear([color(1, 1, 1, 0.55), color(1, 1, 1, 0.08), color(0, 0, 0, 0.15)], CGPoint(x: 512, y: 924), CGPoint(x: 512, y: 100),
           locations: [0, 0.5, 1])
    cg.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func png(_ rep: NSBitmapImageRep) -> Data { rep.representation(using: .png, properties: [:])! }

/// Scales the 1024 px master down with high-quality interpolation.
func scaled(_ master: CGImage, to px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.cgContext.interpolationQuality = .high
    ctx.cgContext.draw(master, in: CGRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    return png(rep)
}

let fm = FileManager.default
let master = render()
try fm.createDirectory(atPath: (pngPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
try png(master).write(to: URL(fileURLWithPath: pngPath))

let iconset = NSTemporaryDirectory() + "Roomsmith-\(getpid()).iconset"
try? fm.removeItem(atPath: iconset)
try fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try scaled(master.cgImage!, to: base * scale).write(to: URL(fileURLWithPath: "\(iconset)/\(name)"))
    }
}
try fm.createDirectory(atPath: (icnsPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset, "-o", icnsPath]
try task.run(); task.waitUntilExit()
try? fm.removeItem(atPath: iconset)
guard task.terminationStatus == 0 else { FileHandle.standardError.write(Data("iconutil failed\n".utf8)); exit(1) }
print(pngPath); print(icnsPath)
