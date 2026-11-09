import Foundation
import CoreGraphics

/// Deterministic procedural textures generated from material parameters (no files, nothing stored in the project).
/// One image covers exactly one repeat (`Material.textureTile` mm) and tiles seamlessly; the renderer rotates it by
/// `patternAngleDeg` through the texture-coordinate transform, so the generator itself ignores the angle.
public enum ProceduralTexture {
    public struct Params: Hashable, Sendable {
        public var pattern: MaterialPattern
        public var color1: RGBColor
        public var color2: RGBColor
        /// Real-world size of the whole image in mm (the material's texture tile).
        public var tileMM: Int64
        public var cellMM: Int64
        public var groutMM: Int64

        public init(pattern: MaterialPattern, color1: RGBColor, color2: RGBColor, tileMM: Int64, cellMM: Int64, groutMM: Int64) {
            self.pattern = pattern; self.color1 = color1; self.color2 = color2
            self.tileMM = tileMM; self.cellMM = cellMM; self.groutMM = groutMM
        }

        /// Cells per side: `tile / cell` rounded, so the pattern repeats without a seam.
        public var cells: Int {
            let t = Double(max(tileMM, 1)), c = Double(max(cellMM, 1))
            return min(max(Int((t / c).rounded()), 1), 64)
        }

        /// Image side in pixels.
        public var side: Int {
            switch pattern {
            case .stripes, .grid, .tiles: 1024
            default: 512
            }
        }
    }

    public struct Pixels: Sendable, Equatable {
        public var width: Int
        public var height: Int
        /// RGBA, 8 bit, straight alpha (always 255), row 0 at the top.
        public var rgba: [UInt8]

        public func pixel(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
            let i = (y * width + x) * 4
            return (rgba[i], rgba[i + 1], rgba[i + 2])
        }
    }

    /// Parameters for a material; nil when it has no procedural pattern.
    public static func params(for m: Material) -> Params? {
        guard m.pattern != .none else { return nil }
        return Params(pattern: m.pattern, color1: m.color, color2: m.color2 ?? defaultSecondColor(m.color), tileMM: max(m.textureTile, 1),
                      cellMM: max(m.patternSize, 1), groutMM: max(m.grout, 0))
    }

    /// The second colour used while a material has none of its own: a darker shade of the main colour.
    public static func defaultSecondColor(_ c: RGBColor) -> RGBColor {
        RGBColor(UInt8(Double(c.r) * 0.55), UInt8(Double(c.g) * 0.55), UInt8(Double(c.b) * 0.55))
    }

    // MARK: - Rendering

    /// Renders one repeat; `side` overrides the pixel size (small previews), the layout scales with it.
    public static func render(_ p: Params, side override: Int? = nil) -> Pixels {
        let side = max(override ?? p.side, 16)
        var buf = [UInt8](repeating: 255, count: side * side * 4)
        let n = p.cells
        let c1 = lin(p.color1), c2 = lin(p.color2)
        let groutPx = p.groutMM == 0 ? 0 : max(1, Int((Double(p.groutMM) / Double(max(p.tileMM, 1)) * Double(side)).rounded()))
        for y in 0..<side {
            for x in 0..<side {
                let col: (Double, Double, Double)
                switch p.pattern {
                case .none: col = c1
                case .stripes: col = stripes(x, side, n, c1, c2)
                case .grid: col = grid(x, y, side, n, max(groutPx, 1), c1, c2)
                case .tiles: col = tiles(x, y, side, n, groutPx, c1, c2)
                case .wood: col = wood(x, y, side, n, groutPx, c1, c2)
                case .fabric: col = fabric(x, y, side, n, c1, c2)
                case .leather: col = leather(x, y, side, n, c1)
                }
                let i = (y * side + x) * 4
                buf[i] = byte(col.0); buf[i + 1] = byte(col.1); buf[i + 2] = byte(col.2)
            }
        }
        return Pixels(width: side, height: side, rgba: buf)
    }

    /// 64-bit FNV-1a over the pixel bytes: equal parameters give an equal fingerprint.
    public static func fingerprint(_ px: Pixels) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in px.rgba { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    public enum ImageSpace: Sendable { case sRGB, linear }

    /// `linear` tags data maps (normal, roughness) so nothing gamma-converts their values.
    public static func cgImage(_ px: Pixels, colorSpace: ImageSpace = .sRGB) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(px.rgba) as CFData) else { return nil }
        let name = colorSpace == .sRGB ? CGColorSpace.sRGB : CGColorSpace.linearSRGB
        return CGImage(width: px.width, height: px.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: px.width * 4,
                       space: CGColorSpace(name: name) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: - Surface relief

    /// Tangent-space normal map and roughness map for a rendered pattern, or nil for flat patterns (none, stripes, grid).
    public struct SurfaceMaps: Sendable, Equatable {
        /// RGB = (n * 0.5 + 0.5) * 255 with +x right and +y up in the image (row 0 is the top), z out of the surface.
        public var normal: Pixels
        /// Grey multiplier for the material roughness: 255 = the full roughness, darker = a little smoother.
        public var roughness: Pixels
    }

    /// Relief strength per pattern (height steps per unit of luminance); flat patterns have none.
    public static func reliefStrength(_ pattern: MaterialPattern) -> Double? {
        switch pattern {
        case .none, .stripes, .grid: nil
        case .wood: 1.5
        case .fabric: 2.5
        case .leather: 3
        case .tiles: 2
        }
    }

    /// Derives relief from the pattern's own brightness: darker reads as deeper (grout, creases, thread gaps, pores). The
    /// central differences wrap around, so the maps tile exactly like the colour image. Raised, bright areas are a little
    /// smoother (worn leather, polished grain), recesses keep the full roughness.
    public static func surfaceMaps(_ px: Pixels, pattern: MaterialPattern) -> SurfaceMaps? {
        guard let strength = reliefStrength(pattern), px.width > 1, px.height > 1 else { return nil }
        let w = px.width, h = px.height
        var height = [Double](repeating: 0, count: w * h)
        var lo = Double.infinity, hi = -Double.infinity
        for i in 0..<(w * h) {
            let l = (0.2126 * Double(px.rgba[i * 4]) + 0.7152 * Double(px.rgba[i * 4 + 1]) + 0.0722 * Double(px.rgba[i * 4 + 2])) / 255
            height[i] = l; lo = min(lo, l); hi = max(hi, l)
        }
        let range = hi - lo
        var normal = [UInt8](repeating: 255, count: w * h * 4)
        var rough = [UInt8](repeating: 255, count: w * h * 4)
        // Scale so a full black-to-white step across one pixel tilts by about `strength`, independent of the image size.
        let k = strength * Double(w) / 512
        for y in 0..<h {
            for x in 0..<w {
                let l = height[y * w + wrap(x - 1, w)], r = height[y * w + wrap(x + 1, w)]
                let up = height[wrap(y - 1, h) * w + x], down = height[wrap(y + 1, h) * w + x]
                // Image rows grow downwards, the normal's +y points up the image.
                var n = (-(r - l) * 0.5 * k, (down - up) * 0.5 * k, 1.0)
                let len = (n.0 * n.0 + n.1 * n.1 + n.2 * n.2).squareRoot()
                n = (n.0 / len, n.1 / len, n.2 / len)
                let i = (y * w + x) * 4
                normal[i] = byte(n.0 * 0.5 + 0.5); normal[i + 1] = byte(n.1 * 0.5 + 0.5); normal[i + 2] = byte(n.2 * 0.5 + 0.5)
                let t = range > 1e-9 ? (height[y * w + x] - lo) / range : 0
                let g = byte(1 - 0.2 * t)
                rough[i] = g; rough[i + 1] = g; rough[i + 2] = g
            }
        }
        return SurfaceMaps(normal: Pixels(width: w, height: h, rgba: normal), roughness: Pixels(width: w, height: h, rgba: rough))
    }

    // MARK: - Patterns (colours are 0...1 sRGB triples)

    private typealias C3 = (Double, Double, Double)

    private static func lin(_ c: RGBColor) -> C3 { (Double(c.r) / 255, Double(c.g) / 255, Double(c.b) / 255) }
    private static func byte(_ v: Double) -> UInt8 { UInt8(min(max(v, 0), 1) * 255 + 0.5) }
    private static func mix(_ a: C3, _ b: C3, _ t: Double) -> C3 { (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t) }
    private static func scale(_ a: C3, _ k: Double) -> C3 { (a.0 * k, a.1 * k, a.2 * k) }

    /// Integer hash to 0...1, stable across runs.
    private static func hash(_ x: Int, _ y: Int, _ seed: Int) -> Double {
        var h = UInt64(truncatingIfNeeded: x) &* 0x9E3779B97F4A7C15
        h ^= UInt64(truncatingIfNeeded: y) &* 0xC2B2AE3D27D4EB4F
        h ^= UInt64(truncatingIfNeeded: seed) &* 0x165667B19E3779F9
        h ^= h >> 29; h = h &* 0xBF58476D1CE4E5B9; h ^= h >> 32
        return Double(h & 0xFFFFFF) / Double(0x1000000)
    }

    private static func wrap(_ v: Int, _ period: Int) -> Int { ((v % period) + period) % period }

    /// Value noise that repeats every `periodX` / `periodY` lattice cells.
    private static func noise(_ x: Double, _ y: Double, periodX: Int, periodY: Int, seed: Int) -> Double {
        let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
        let fx = x - Double(x0), fy = y - Double(y0)
        let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
        func h(_ a: Int, _ b: Int) -> Double { hash(wrap(a, periodX), wrap(b, periodY), seed) }
        let top = h(x0, y0) * (1 - sx) + h(x0 + 1, y0) * sx
        let bottom = h(x0, y0 + 1) * (1 - sx) + h(x0 + 1, y0 + 1) * sx
        return top * (1 - sy) + bottom * sy
    }

    private static func stripes(_ x: Int, _ side: Int, _ n: Int, _ c1: C3, _ c2: C3) -> C3 {
        // n pairs of (colour 1, colour 2): 2n bands across the width.
        (x * 2 * n / side) % 2 == 0 ? c1 : c2
    }

    private static func grid(_ x: Int, _ y: Int, _ side: Int, _ n: Int, _ line: Int, _ c1: C3, _ c2: C3) -> C3 {
        let cell = Double(side) / Double(n)
        let fx = Double(x).truncatingRemainder(dividingBy: cell), fy = Double(y).truncatingRemainder(dividingBy: cell)
        let half = Double(line) / 2
        let onLine = fx < half || fx >= cell - half || fy < half || fy >= cell - half
        return onLine ? c2 : c1
    }

    private static func tiles(_ x: Int, _ y: Int, _ side: Int, _ n: Int, _ grout: Int, _ c1: C3, _ c2: C3) -> C3 {
        let cell = Double(side) / Double(n)
        let tx = Int(Double(x) / cell), ty = Int(Double(y) / cell)
        let fx = Double(x) - Double(tx) * cell, fy = Double(y) - Double(ty) * cell
        let g = Double(grout) / 2
        if grout > 0, fx < g || fx >= cell - g || fy < g || fy >= cell - g { return c2 }
        // Slight per-tile brightness variation and a faint surface grain keep large floors from looking flat.
        let tileTone = 0.94 + 0.12 * hash(tx, ty, 11)
        let grain = 0.985 + 0.03 * hash(x, y, 12)
        return scale(c1, tileTone * grain)
    }

    private static func wood(_ x: Int, _ y: Int, _ side: Int, _ n: Int, _ grout: Int, _ c1: C3, _ c2: C3) -> C3 {
        let plank = Double(side) / Double(n)
        let px = Int(Double(x) / plank)
        let fx = Double(x) - Double(px) * plank
        if grout > 0, fx < Double(grout) / 2 || fx >= plank - Double(grout) / 2 { return scale(c2, 0.5) }
        // Grain runs along y. Everything is periodic so planks and the whole image repeat without a seam.
        let u = Double(x) / Double(side), v = Double(y) / Double(side)
        let tone = hash(px, 0, 21)
        let warp = noise(u * 6, v * 3, periodX: 6, periodY: 3, seed: 22) * 1.6
        let rings = noise(u * Double(n) * 5 + warp, v * 2, periodX: n * 5, periodY: 2, seed: 23 + px)
        let fibre = noise(u * Double(n) * 40, v * 6, periodX: n * 40, periodY: 6, seed: 24)
        let pores = hash(x, y, 25) > 0.985 ? 0.8 : 1.0
        var t = 0.35 + 0.5 * rings + 0.25 * (fibre - 0.5)
        t = t * (0.75 + 0.5 * tone)
        return scale(mix(c1, c2, min(max(t, 0), 1)), pores)
    }

    private static func fabric(_ x: Int, _ y: Int, _ side: Int, _ n: Int, _ c1: C3, _ c2: C3) -> C3 {
        // Plain weave with `n` threads per direction; each thread has a rounded brightness profile.
        let thread = Double(side) / Double(max(n, 1))
        let tx = Int(Double(x) / thread), ty = Int(Double(y) / thread)
        let fx = Double(x) / thread - Double(tx), fy = Double(y) / thread - Double(ty)
        let warpOver = (tx + ty) % 2 == 0
        let along = warpOver ? fx : fy   // position across the visible thread
        let profile = 0.72 + 0.28 * sin(along * .pi)
        let base = warpOver ? c1 : c2
        let fuzz = 0.97 + 0.06 * hash(x, y, 31)
        return scale(base, profile * fuzz)
    }

    private static func leather(_ x: Int, _ y: Int, _ side: Int, _ n: Int, _ c1: C3) -> C3 {
        // Pebbled grain: darker creases where two neighbouring Voronoi cells meet, periodic over the image.
        let cells = min(max(n, 4), 64)
        let u = Double(x) / Double(side) * Double(cells), v = Double(y) / Double(side) * Double(cells)
        let cx = Int(u.rounded(.down)), cy = Int(v.rounded(.down))
        var f1 = Double.infinity, f2 = Double.infinity
        for dy in -1...1 {
            for dx in -1...1 {
                let gx = cx + dx, gy = cy + dy
                let wx = wrap(gx, cells), wy = wrap(gy, cells)
                let px = Double(gx) + hash(wx, wy, 41), py = Double(gy) + hash(wx, wy, 42)
                let d = ((px - u) * (px - u) + (py - v) * (py - v)).squareRoot()
                if d < f1 { f2 = f1; f1 = d } else if d < f2 { f2 = d }
            }
        }
        let crease = min(max((f2 - f1) * 3.2, 0), 1)
        let tone = 0.55 + 0.45 * crease
        let fine = 0.97 + 0.06 * hash(x, y, 43)
        return scale(c1, tone * fine)
    }
}
