import Foundation

// MARK: - geometry.dimension_chain

/// Dimension chains: a row of adjacent dimensions on one line (+ optional total), from free points or along a wall face.
enum DimensionTools {
    private static func dimensionJSON(_ d: Dimension) -> JSONValue {
        .object(["id": J.id(d.id), "a": J.p2(d.a), "b": J.p2(d.b), "offsetMm": .int(d.offset),
                 "lengthMm": .int(DimensionChains.length(d.a, d.b))])
    }

    @MainActor
    static func specs() -> [ToolSpec] {
        [
            .write("geometry.dimension_chain",
                   "Adds a dimension chain (Maßkette): one dimension between each pair of neighbouring points on a shared line, plus an optional total dimension from the first to the last point, drawn 400 mm further out. Give either `points` (+ `levelId`) or a `wallId`. With `points`, the line runs through the first and the last point; the other points are always projected onto it (a sideways offset never enters a dimension), sorted along it, and points with the same projected position are an error. With `wallId`, the points lie on the visible wall face as the plan draws it: the ends are the mitred face corners (so `outer` measures the outer size, e.g. 4240 for a 4000 room with 240 walls, `inner` the inner size, 3760), then both edges of every door/window/opening on that face; openings reaching beyond the face ends are clamped, openings outside it ignored. All lengths are whole millimetres: the distance of the stored points, rounded half away from zero (exactly the number the plan shows); on slanted walls a single part can deviate by 1 mm from the ideal value (e.g. 899 or 901 instead of 900). With only two points there is just one dimension and no separate total. One undo step.",
                   ["levelId": S.uuid("Level for `points`; default the active level. With `wallId` it must be the wall's level if given."),
                    "points": S.arr("Chain points (at least 2) in millimetres.", items: S.p2("Point.")),
                    "wallId": S.uuid("Wall to dimension along one face."),
                    "side": S.str("Wall face (with `wallId`): `auto` (default) = outer face, else left; `outer`, `inner`, or `left` / `right` seen from the wall start to its end.",
                                  values: ChainSide.allCases.map(\.rawValue)),
                    "includeOpenings": S.bool("With `wallId`: split the chain at door/window/opening edges (default true)."),
                    "offsetMm": S.int("Distance of the dimension line from the measured line, default 500. With `wallId` it is the distance from the wall face (not negative); with `points` it is signed, positive = left of the first-to-last direction."),
                    "includeTotal": S.bool("Add the total dimension (default true; skipped when the chain has a single dimension)."),
                   ]) { p, env, a in
                let hasPoints = a.has("points"), hasWall = a.has("wallId")
                guard hasPoints != hasWall else {
                    throw ToolError.invalid(nil, "Give exactly one of `points` or `wallId`")
                }
                let includeTotal = try a.bool("includeTotal") ?? true
                let offset = try a.mm("offsetMm") ?? 500

                let level: UUID
                let points: [P2]
                let signedOffset: MM
                var wallInfo: [String: JSONValue] = [:]
                if hasWall {
                    let wallId = try a.requireUUID("wallId")
                    guard let wall = p.wall(wallId) else { throw ToolError.notFound("Wall", wallId) }
                    if let given = try a.uuid("levelId"), given != wall.levelId {
                        throw ToolError.invalid("levelId", "is not the level of the wall")
                    }
                    guard offset >= 0 else { throw ToolError.invalid("offsetMm", "must not be negative with `wallId`") }
                    let side = try a.enumValue("side", ChainSide.self) ?? .auto
                    let chain = try DimensionChains.wallChain(p, wallId: wallId, side: side, offset: offset,
                                                              includeOpenings: try a.bool("includeOpenings") ?? true)
                    level = wall.levelId; points = chain.points; signedOffset = chain.offset
                    wallInfo = ["wallId": J.id(wallId), "side": .string(chain.side.rawValue), "outerSide": .bool(chain.isOuter)]
                } else {
                    guard !a.has("side") && !a.has("includeOpenings") else {
                        throw ToolError.invalid(a.has("side") ? "side" : "includeOpenings", "only applies with `wallId`")
                    }
                    level = try env.level(a, in: p)
                    points = try a.p2List("points") ?? []
                    signedOffset = offset
                }

                let ids = try p.addDimensionChain(levelId: level, points: points, offset: signedOffset, includeTotal: includeTotal)
                let dims = ids.compactMap { p.dimension($0) }
                let hasTotal = includeTotal && dims.count > 2 && ids.count == dims.count
                let parts = hasTotal ? Array(dims.dropLast()) : dims
                let partLengths = parts.map { DimensionChains.length($0.a, $0.b) }
                var out: [String: JSONValue] = wallInfo
                out["ids"] = J.ids(ids)
                out["dimensions"] = .array(dims.map(dimensionJSON))
                out["partsMm"] = .array(partLengths.map { .int($0) })
                out["sumOfPartsMm"] = .int(partLengths.reduce(0, +))
                if let first = parts.first, let last = parts.last {
                    out["totalLengthMm"] = .int(DimensionChains.length(first.a, last.b))
                }
                out["totalId"] = hasTotal ? J.id(ids[ids.count - 1]) : .null
                out["note"] = .string("sumOfPartsMm can differ from totalLengthMm by rounding on slanted lines, and a single part can be off by 1 mm there; both are exact distances of the stored points rounded to whole mm. On axis-parallel lines they are equal.")
                return .object(out)
            },
        ]
    }
}
