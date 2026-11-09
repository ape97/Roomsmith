import Foundation

public extension Project {
    /// Adds a dimension chain: one dimension per pair of neighbouring points on a shared line, plus (when
    /// `includeTotal` and there are at least three points) one total dimension from the first to the last point
    /// whose line sits `DimensionChains.totalGap` (400 mm) further out. With only two points the single part already
    /// is the total, so no second dimension is added.
    ///
    /// `points` are ordered and snapped to the line first-to-last as described at `DimensionChains.pointsChain`
    /// (duplicates are an error). `offset` is the signed distance of the part lines (positive = left of the
    /// direction of the chain, like `addDimension`). Returns the ids of the parts in order, the total last (if any).
    /// Nothing is added when it throws. Through `DocumentStore.run`/`apply` the whole chain is one undo step.
    @discardableResult
    mutating func addDimensionChain(levelId: UUID, points: [P2], offset: MM = 500, includeTotal: Bool = true) throws -> [UUID] {
        try ensureLevel(levelId)
        guard offset.magnitude <= coordinateLimit.magnitude else {
            throw CommandError.range("The dimension offset must lie within +-100 km")
        }
        let totalOffset = DimensionChains.totalOffset(for: offset)
        guard totalOffset.magnitude <= coordinateLimit.magnitude else {
            throw CommandError.range("The dimension offset must lie within +-100 km")
        }
        let line = try DimensionChains.pointsChain(points)
        var ids: [UUID] = []
        for i in 0..<(line.count - 1) {
            ids.append(try addDimension(levelId: levelId, a: line[i], b: line[i + 1], offset: offset))
        }
        if includeTotal && line.count > 2 {
            ids.append(try addDimension(levelId: levelId, a: line[0], b: line[line.count - 1], offset: totalOffset))
        }
        return ids
    }
}
