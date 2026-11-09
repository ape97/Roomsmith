import Foundation

/// A sheet size in mm.
public struct PaperSize: Sendable, Equatable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
    public var area: Double { width * height }
}

/// Standard sheets offered by the plan export.
public enum PaperFormat: String, CaseIterable, Sendable, Identifiable {
    case a4 = "A4", a3 = "A3", a2 = "A2", a1 = "A1", a0 = "A0", letter = "Letter"
    public var id: String { rawValue }

    /// Portrait size in mm (ISO 216; US Letter is 8.5 × 11 in).
    public var portrait: PaperSize {
        switch self {
        case .a4: PaperSize(width: 210, height: 297)
        case .a3: PaperSize(width: 297, height: 420)
        case .a2: PaperSize(width: 420, height: 594)
        case .a1: PaperSize(width: 594, height: 841)
        case .a0: PaperSize(width: 841, height: 1189)
        case .letter: PaperSize(width: 215.9, height: 279.4)
        }
    }

    public func size(landscape: Bool) -> PaperSize {
        let p = portrait
        return landscape ? PaperSize(width: p.height, height: p.width) : p
    }
}

public enum PaperOrientation: String, CaseIterable, Sendable, Identifiable {
    case auto = "Automatic", landscape = "Landscape", portrait = "Portrait"
    public var id: String { rawValue }
}

public enum ScaleChoice: Hashable, Sendable, Identifiable {
    case ratio(Int), fit
    public var id: Self { self }
    public var title: String {
        switch self { case .ratio(let r): "1:\(r)"; case .fit: "Fit to paper" }
    }
    /// Fixed ratios offered in the export dialog.
    public static let all: [ScaleChoice] = [.ratio(10), .ratio(20), .ratio(25), .ratio(50), .ratio(75), .ratio(100), .ratio(200), .fit]
}

/// Result of laying the plan out on a sheet.
public struct PlanLayout: Sendable, Equatable {
    public var scale: Int
    public var landscape: Bool
    public var sheet: PaperSize
    /// The drawing (margin, legend, scale bar included) fits on `sheet` at `scale`.
    public var fits: Bool
    /// What the drawing needs at `scale`.
    public var required: PaperSize
}

/// Whether a drawing fits a sheet, and which scale, paper and orientation make it fit. Pure functions, no drawing.
public enum PlanFit {
    /// Slack for floating-point rounding (paper mm).
    public static let tolerance = 1e-6

    /// Scales tried by "Fit to paper", largest drawing first.
    public static let fitScales = [10, 20, 25, 50, 75, 100, 150, 200, 250, 500, 1000]

    public static func fits(_ required: PaperSize, on sheet: PaperSize) -> Bool {
        required.width <= sheet.width + tolerance && required.height <= sheet.height + tolerance
    }

    /// The orientation in which `required` fits `paper` (true = landscape), preferring the requested one;
    /// nil if it fits neither way.
    public static func orientation(for required: PaperSize, on paper: PaperFormat, preferred: PaperOrientation) -> Bool? {
        let order: [Bool]
        switch preferred {
        case .landscape: order = [true]
        case .portrait: order = [false]
        case .auto: order = required.width >= required.height ? [true, false] : [false, true]
        }
        return order.first { fits(required, on: paper.size(landscape: $0)) }
    }

    /// Smallest sheet (by area) larger than `current` on which every size in `required` fits, in some allowed orientation.
    public static func smallestPaper(fitting required: [PaperSize], preferred: PaperOrientation, larger current: PaperFormat? = nil,
                                     among formats: [PaperFormat]? = nil) -> PaperFormat? {
        let floor = current?.portrait.area ?? 0
        let allowed = formats ?? (current == .letter ? PaperFormat.allCases : PaperFormat.allCases.filter { $0 != .letter })
        return allowed.filter { $0.portrait.area > floor }
            .sorted { $0.portrait.area < $1.portrait.area }
            .first { f in required.allSatisfy { orientation(for: $0, on: f, preferred: preferred) != nil } }
    }

    /// Upper bound for the total pixel count of a PNG export.
    public static let maxPixels = 100_000_000

    /// Pixel size of a sheet rendered at `dpi` (`ceil(mm / 25.4 * dpi)`), lowering the dpi so width * height stays
    /// within `maxPixels`. Returns the dpi actually used.
    public static func pixelSize(widthMM: Double, heightMM: Double, dpi: Double, maxPixels: Int = PlanFit.maxPixels)
        -> (width: Int, height: Int, dpi: Double) {
        func px(_ mm: Double, _ d: Double) -> Int { max(1, Int((mm / 25.4 * d).rounded(.up))) }
        var d = dpi
        var w = px(widthMM, d), h = px(heightMM, d)
        if Double(w) * Double(h) > Double(maxPixels) {
            d = dpi * (Double(maxPixels) / (Double(w) * Double(h))).squareRoot()
            w = px(widthMM, d); h = px(heightMM, d)
            while Double(w) * Double(h) > Double(maxPixels), d > 1 {
                d *= 0.999; w = px(widthMM, d); h = px(heightMM, d)
            }
        }
        return (w, h, d)
    }

    /// Lays a drawing out on `paper`. `required(scale)` is the size the drawing needs at that scale.
    /// A fixed ratio keeps its scale even when it does not fit (`fits == false`; the caller decides what to do).
    /// `.fit` takes the first of `fitScales` that fits; if none does, the last one with `fits == false`.
    public static func layout(scale: ScaleChoice, paper: PaperFormat, orientation: PaperOrientation,
                              required: (Int) -> PaperSize) -> PlanLayout {
        func attempt(_ s: Int) -> PlanLayout {
            let need = required(s)
            if let land = Self.orientation(for: need, on: paper, preferred: orientation) {
                return PlanLayout(scale: s, landscape: land, sheet: paper.size(landscape: land), fits: true, required: need)
            }
            let land: Bool
            switch orientation {
            case .landscape: land = true
            case .portrait: land = false
            case .auto: land = need.width >= need.height
            }
            return PlanLayout(scale: s, landscape: land, sheet: paper.size(landscape: land), fits: false, required: need)
        }
        switch scale {
        case .ratio(let r): return attempt(max(1, r))
        case .fit:
            var last = attempt(fitScales[0])
            for s in fitScales {
                last = attempt(s)
                if last.fits { return last }
            }
            return last
        }
    }
}

extension PlanExport {
    /// Lays out one level on `paper`; the returned layout carries the page to pass in `Options.page`.
    public static func layout(_ p: Project, levelId: UUID, unit: LengthUnit, scale: ScaleChoice, paper: PaperFormat,
                              orientation: PaperOrientation) -> PlanLayout {
        PlanFit.layout(scale: scale, paper: paper, orientation: orientation) { s in
            requiredSize(p, options: Options(levelId: levelId, scale: s, unit: unit))
        }
    }

    /// Export options for a laid-out level: a fixed sheet when the plan fits, otherwise a custom page of exactly the
    /// required size (the caller must have asked the user first).
    public static func options(for layout: PlanLayout, paper: PaperFormat, levelId: UUID, unit: LengthUnit) -> Options {
        let page = layout.fits
            ? Page(name: paper.rawValue, width: layout.sheet.width, height: layout.sheet.height)
            : Page(name: nil, width: layout.required.width, height: layout.required.height)
        return Options(levelId: levelId, scale: layout.scale, unit: unit, page: page)
    }
}
