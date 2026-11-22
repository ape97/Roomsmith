import Foundation

/// Fine move while Space is held during a furniture drag (plan, 3D free drag, 3D axis arrows): the pointer travel counts
/// only a fraction, and nothing snaps or stops at walls and furniture (the same switch-off as Option). The views feed
/// the raw cursor offset since the press; this type turns it into the effective offset.
///
/// The conversion works on the travel between two updates, not on the absolute offset. On every switch of `fine` the
/// offset is re-based on the offset the view really showed last (`show`, after snapping and contact stops), so pressing
/// or releasing Space in the middle of a drag never makes the piece jump, even from a snapped or stopped position.
public struct FineMotion: Sendable, Equatable {
    /// Share of the pointer travel that moves the piece while Space is held (1 px of travel moves 1/10 px).
    public static let scale = 0.1

    private var lastRaw = V2(0, 0)
    private var effective = V2(0, 0)
    private var lastFine = false
    private var shown: V2?

    public init() {}

    /// Effective offset for the raw offset `raw` (mm since the press). `fine` scales the travel since the last call.
    public mutating func advance(raw: V2, fine: Bool) -> V2 {
        if fine != lastFine {
            lastFine = fine
            if let shown { effective = shown }
        }
        let step = raw - lastRaw
        lastRaw = raw
        effective += fine ? step * Self.scale : step
        return effective
    }

    /// Tells the offset the view displays after snapping and stops; the next switch of `fine` continues from it.
    public mutating func show(_ offset: V2) { shown = offset }

    /// One-dimensional variant for an axis drag: the offset along the axis.
    public mutating func advance(raw: Double, fine: Bool) -> Double {
        advance(raw: V2(raw, 0), fine: fine).x
    }

    public mutating func show(_ offset: Double) { show(V2(offset, 0)) }
}
