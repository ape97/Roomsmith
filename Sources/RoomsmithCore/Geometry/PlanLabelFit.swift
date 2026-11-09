import Foundation

/// Decisions about plan labels on screen (pixels): which dimension texts fit and how a furniture name is fitted.
/// Pure, so the rules are tested without drawing.
public enum PlanLabelFit {
    /// Axis-aligned box of a label on screen.
    public struct Box: Sendable, Equatable {
        public var centerX: Double, centerY: Double, halfWidth: Double, halfHeight: Double
        public init(centerX: Double, centerY: Double, halfWidth: Double, halfHeight: Double) {
            self.centerX = centerX; self.centerY = centerY; self.halfWidth = halfWidth; self.halfHeight = halfHeight
        }

        /// Bounding box of a text of `width` x `height` centred at the point and rotated by `angle` (radians).
        public init(centerX: Double, centerY: Double, width: Double, height: Double, angle: Double) {
            let c = abs(cos(angle)), s = abs(sin(angle))
            self.init(centerX: centerX, centerY: centerY,
                      halfWidth: (width * c + height * s) / 2, halfHeight: (width * s + height * c) / 2)
        }
    }

    /// Space kept between a dimension text and the ends of its segment (both sides together).
    public static let dimensionMargin = 8.0
    /// Space kept between two dimension texts.
    public static let dimensionGap = 3.0

    /// True when a dimension text of `textWidth` px fits into a segment of `segmentPixels` px.
    public static func dimensionTextFits(textWidth: Double, segmentPixels: Double) -> Bool {
        segmentPixels >= textWidth + dimensionMargin
    }

    public static func overlaps(_ a: Box, _ b: Box, gap: Double = dimensionGap) -> Bool {
        abs(a.centerX - b.centerX) < a.halfWidth + b.halfWidth + gap
            && abs(a.centerY - b.centerY) < a.halfHeight + b.halfHeight + gap
    }

    /// Whether a dimension label is drawn: its text fits the segment and no label drawn before touches it.
    public static func shouldDrawDimension(textWidth: Double, segmentPixels: Double, box: Box, placed: [Box]) -> Bool {
        dimensionTextFits(textWidth: textWidth, segmentPixels: segmentPixels) && !placed.contains { overlaps($0, box) }
    }

    /// Width in px a furniture name may use. A piece whose screen box equals its own extent (turned by a multiple of
    /// 90 degrees) offers its full box; a slanted piece keeps the short side plus a little overhang.
    public static func furnitureNameWidth(boxPixels: Double, longSidePixels: Double, shortSidePixels: Double) -> Double {
        let aligned = abs(boxPixels - longSidePixels) < 1.5 || abs(boxPixels - shortSidePixels) < 1.5
        return aligned ? boxPixels - 4 : min(shortSidePixels + 20, boxPixels - 4)
    }

    public struct NameFit: Sendable, Equatable {
        public var fontSize: Double
        /// True when even the smallest size needs an ellipsis.
        public var truncated: Bool
    }

    /// Full name at `maxSize` when it fits, else the largest smaller size down to `minSize`, only then an ellipsis.
    /// `widthAtMax` is the text width measured at `maxSize`; width grows linearly with the size.
    public static func furnitureNameFit(widthAtMax: Double, available: Double, maxSize: Double = 10, minSize: Double = 8) -> NameFit {
        guard widthAtMax > available, widthAtMax > 0 else { return NameFit(fontSize: maxSize, truncated: false) }
        let size = maxSize * available / widthAtMax
        if size >= minSize { return NameFit(fontSize: (size * 4).rounded(.down) / 4, truncated: false) }
        return NameFit(fontSize: minSize, truncated: true)
    }
}
