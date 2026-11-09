import Foundation

/// Dimension derivation from a photo's proportions, parameter suggestions per template, clamping and colour-to-material.
public enum PhotoDimensioning {
    public struct Result: Sendable, Equatable {
        public var size: Size3
        /// Dimensions the user did not give ("width", "depth", "height").
        public var derived: [String]
    }

    /// Needs at least one user dimension. Missing ones come from the photo's proportions (front view: width / height;
    /// side view: depth / height) and otherwise from the template's default proportions, scaled to the known dimensions.
    public static func derive(template: BuilderTemplate, analysis: PhotoAnalysis, user: PhotoDimensions) throws -> Result {
        guard !user.isEmpty else { throw PhotoAnalysisError("Give at least one dimension (width, depth or height in mm)") }
        for (name, v) in [("width", user.width), ("depth", user.depth), ("height", user.height)] {
            if let v, !sizeLimit.contains(v) { throw PhotoAnalysisError("\(name) must be between \(sizeLimit.lowerBound) and \(sizeLimit.upperBound) mm") }
        }
        let def = template.defaultSize
        // Scale of the user's dimensions against the template defaults (geometric mean), used for whatever has no other source.
        var ratios: [Double] = []
        if let w = user.width { ratios.append(Double(w) / Double(def.width)) }
        if let d = user.depth { ratios.append(Double(d) / Double(def.depth)) }
        if let h = user.height { ratios.append(Double(h) / Double(def.height)) }
        let scale = exp(ratios.map(log).reduce(0, +) / Double(ratios.count))

        let awh = analysis.aspectWH.flatMap { $0 > 0.05 && $0 < 20 ? $0 : nil }
        let adh = analysis.aspectDH.flatMap { $0 > 0.05 && $0 < 20 ? $0 : nil }
        var w = user.width.map(Double.init), d = user.depth.map(Double.init), h = user.height.map(Double.init)

        // Photo proportions first, as long as one of the two related sides is known.
        if let awh {
            if w == nil, let h { w = h * awh }
            else if h == nil, let w { h = w / awh }
        }
        if let adh {
            if d == nil, let h { d = h * adh }
            else if h == nil, let d { h = d / adh }
        }
        if let awh, w == nil, let hh = h { w = hh * awh }
        if let awh, h == nil, let ww = w { h = ww / awh }
        // Template proportions for the rest.
        if w == nil { w = Double(def.width) * scale }
        if d == nil { d = Double(def.depth) * scale }
        if h == nil { h = Double(def.height) * scale }

        func c(_ v: Double) -> MM { min(max(MM(v.rounded()), sizeLimit.lowerBound), sizeLimit.upperBound) }
        var derived: [String] = []
        if user.width == nil { derived.append("width") }
        if user.depth == nil { derived.append("depth") }
        if user.height == nil { derived.append("height") }
        return Result(size: Size3(user.width ?? c(w!), user.depth ?? c(d!), user.height ?? c(h!)), derived: derived)
    }

    /// Parameters for a template: size plus counts and thicknesses that follow from the size. Always inside valid ranges.
    public static func params(template: BuilderTemplate, size: Size3, materialId: UUID?) -> BuilderParams {
        var p = BuilderParams()
        p.width = size.width; p.depth = size.depth; p.height = size.height
        p.materialId = materialId
        p.doors = min(4, max(1, Int((Double(size.width) / 450).rounded())))
        p.shelves = min(8, max(0, Int((Double(size.height) / 400).rounded())))
        p.boards = min(12, max(2, Int((Double(size.height) / 450).rounded())))
        p.armWidth = min(size.width / 4, max(40, size.width * 3 / 40))
        p.seatHeight = min(size.height * 3 / 5, max(150, size.height / 2))
        p.plinth = min(size.height / 4, 60)
        return clamp(p)
    }

    /// Keeps every parameter inside what the generators accept.
    public static func clamp(_ p: BuilderParams) -> BuilderParams {
        var q = p
        func lim(_ v: MM) -> MM { min(max(v, sizeLimit.lowerBound), sizeLimit.upperBound) }
        q.width = lim(p.width); q.depth = lim(p.depth); q.height = lim(p.height)
        q.shelves = min(max(p.shelves, 0), 20)
        q.doors = min(max(p.doors, 0), 6)
        q.boards = min(max(p.boards, 2), 20)
        q.plinth = min(max(p.plinth, 0), max(0, q.height / 4))
        q.legInset = min(max(p.legInset, 0), max(0, min(q.width, q.depth) / 4))
        q.topThickness = min(max(p.topThickness, 4), max(4, q.height / 4))
        q.armWidth = min(max(p.armWidth, 0), q.width / 4)
        q.seatHeight = min(max(p.seatHeight, 1), max(1, q.height))
        return q
    }

    // MARK: Colour

    /// Palette entries that make sense as furniture surface (no glass, soil, screens or lampshades).
    static let furnitureMaterials: [Material] = BuiltinCatalog.materials.filter {
        $0.opacity >= 1 && !["Soil", "Leaf green", "Screen black", "Lampshade"].contains($0.name)
    }

    /// The built-in material whose colour is closest to `c` (weighted RGB distance, which is close to perception).
    public static func nearestMaterial(to c: RGBColor) -> Material? {
        func dist(_ m: Material) -> Double {
            let rm = (Double(c.r) + Double(m.color.r)) / 2
            let dr = Double(c.r) - Double(m.color.r), dg = Double(c.g) - Double(m.color.g), db = Double(c.b) - Double(m.color.b)
            return (2 + rm / 256) * dr * dr + 4 * dg * dg + (2 + (255 - rm) / 256) * db * db
        }
        return furnitureMaterials.min { dist($0) < dist($1) }
    }

    public static func material(for colors: [PhotoColor]) -> Material? {
        guard let top = colors.max(by: { $0.weight < $1.weight }) else { return nil }
        return nearestMaterial(to: top.color)
    }
}
