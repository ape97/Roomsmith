import CoreGraphics
import Foundation

// Presenter mode: what is shown and where. Pure geometry, no rendering.

/// What the presenter output shows.
public enum PresenterLayout: String, CaseIterable, Sendable, Identifiable {
    case plan
    case scene3D
    case sideBySide

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .plan: "Plan"
        case .scene3D: "3D"
        case .sideBySide: "Side by side"
        }
    }
}

/// Output canvas size (pixels).
public enum PresenterResolution: String, CaseIterable, Sendable, Identifiable {
    case hd720
    case hd1080

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .hd720: "1280 × 720"
        case .hd1080: "1920 × 1080"
        }
    }

    public var width: Int { self == .hd720 ? 1280 : 1920 }
    public var height: Int { self == .hd720 ? 720 : 1080 }
    public var size: CGSize { CGSize(width: width, height: height) }
}

/// Which source fills a pane.
public enum PresenterPaneKind: Sendable, Equatable {
    case plan
    case scene3D
}

/// One cell of the output canvas. Rectangles use image space: origin top left, y grows downwards, whole pixels.
public struct PresenterPane: Sendable, Equatable {
    public var kind: PresenterPaneKind
    /// The area reserved for this source.
    public var cell: CGRect
}

/// Layout of the canvas: pane cells and the letterboxed placement of source images inside them.
public struct PresenterComposition: Sendable, Equatable {
    public var layout: PresenterLayout
    public var canvas: CGSize
    /// Space between the two panes of the side-by-side layout (pixels).
    public var gap: Int

    public init(layout: PresenterLayout, resolution: PresenterResolution = .hd1080, gap: Int = 16) {
        self.init(layout: layout, canvas: resolution.size, gap: gap)
    }

    public init(layout: PresenterLayout, canvas: CGSize, gap: Int = 16) {
        self.layout = layout
        self.canvas = CGSize(width: max(2, canvas.width.rounded()), height: max(2, canvas.height.rounded()))
        self.gap = max(0, gap)
    }

    public var panes: [PresenterPane] {
        let full = CGRect(origin: .zero, size: canvas)
        switch layout {
        case .plan:
            return [PresenterPane(kind: .plan, cell: full)]
        case .scene3D:
            return [PresenterPane(kind: .scene3D, cell: full)]
        case .sideBySide:
            let w = canvas.width, g = CGFloat(min(gap, Int(w) - 2))
            let cellW = ((w - g) / 2).rounded(.down)
            let left = CGRect(x: 0, y: 0, width: cellW, height: canvas.height)
            let right = CGRect(x: w - cellW, y: 0, width: cellW, height: canvas.height)
            return [PresenterPane(kind: .plan, cell: left), PresenterPane(kind: .scene3D, cell: right)]
        }
    }

    /// Size in pixels a source should render at for `kind`; nil if the layout does not show it.
    public func sourceSize(for kind: PresenterPaneKind) -> CGSize? {
        panes.first { $0.kind == kind }?.cell.size
    }

    /// Largest rectangle with the aspect ratio of `content` that fits `cell`, centred, whole pixels.
    /// Empty or non-finite sizes give the cell itself.
    public static func aspectFit(content: CGSize, in cell: CGRect) -> CGRect {
        guard content.width > 0, content.height > 0, content.width.isFinite, content.height.isFinite,
              cell.width > 0, cell.height > 0 else { return cell }
        let scale = min(cell.width / content.width, cell.height / content.height)
        let w = min(cell.width, (content.width * scale).rounded())
        let h = min(cell.height, (content.height * scale).rounded())
        let x = cell.minX + ((cell.width - w) / 2).rounded(.down)
        let y = cell.minY + ((cell.height - h) / 2).rounded(.down)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
