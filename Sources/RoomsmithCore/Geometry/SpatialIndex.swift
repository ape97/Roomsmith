import Foundation
import simd

/// Uniform grid over the floor plane (default cell 1000 mm) for broad-phase queries on footprints and walls.
/// Items are small integers chosen by the caller (array indices). Queries return a sorted, de-duplicated
/// candidate list that may contain false positives from the same cell.
public struct SpatialIndex: Sendable {
    private struct Cell: Hashable { var x: Int32; var y: Int32 }

    public let cellSize: Double
    private var cells: [Cell: [Int]] = [:]
    /// Items that would cover too many cells (very long walls) – returned by every query.
    private var oversized: [Int] = []
    private static let maxSpan = 64

    public init(cellSize: Double = 1000) { self.cellSize = max(cellSize, 1) }

    private func cellRange(_ lo: V2, _ hi: V2) -> (x0: Int, x1: Int, y0: Int, y1: Int) {
        func c(_ v: Double) -> Int { Int(max(-1e9, min(1e9, (v / cellSize).rounded(.down)))) }
        return (c(lo.x), c(hi.x), c(lo.y), c(hi.y))
    }

    public mutating func insert(_ id: Int, min lo: V2, max hi: V2) {
        let r = cellRange(lo, hi)
        if r.x1 - r.x0 >= Self.maxSpan || r.y1 - r.y0 >= Self.maxSpan { oversized.append(id); return }
        for x in r.x0...r.x1 {
            for y in r.y0...r.y1 { cells[Cell(x: Int32(x), y: Int32(y)), default: []].append(id) }
        }
    }

    public func query(min lo: V2, max hi: V2) -> [Int] {
        let r = cellRange(lo, hi)
        var out = oversized
        if r.x1 - r.x0 >= Self.maxSpan || r.y1 - r.y0 >= Self.maxSpan {
            for list in cells.values { out.append(contentsOf: list) }
        } else {
            for x in r.x0...r.x1 {
                for y in r.y0...r.y1 {
                    if let list = cells[Cell(x: Int32(x), y: Int32(y))] { out.append(contentsOf: list) }
                }
            }
        }
        guard out.count > 1 else { return out }
        out.sort()
        var w = 1
        for i in 1..<out.count where out[i] != out[w - 1] { out[w] = out[i]; w += 1 }
        out.removeLast(out.count - w)
        return out
    }
}
