import Foundation

// MARK: - geometry.*

enum GeometryTools {
    private static func optionalMaterial(_ p: inout Project, _ a: Args, _ key: String) throws -> UUID?? {
        guard a.present(key) else { return nil }
        if a.isNull(key) { return .some(nil) }
        return .some(try p.resolveMaterial(a.raw(key)!, field: key))
    }

    private static func requireAny(_ a: Args, _ keys: [String]) throws {
        guard keys.contains(where: a.present) else {
            throw ToolError.invalid(nil, "Give at least one of: \(keys.joined(separator: ", "))")
        }
    }

    private static let detailProps: [String: JSONValue] = [
        "style": S.str("Look. Doors: \(OpeningStyle.doorStyles.map(\.rawValue).joined(separator: ", ")); windows: \(OpeningStyle.windowStyles.map(\.rawValue).joined(separator: ", ")). Must suit the type (default: smooth door, fixed window). Sliding doors stay closed in walk mode.",
                       values: OpeningStyle.allCases.map(\.rawValue)),
        "handle": S.str("Handle on doors and openable windows (default none).", values: OpeningHandle.allCases.map(\.rawValue)),
        "frameWidthMm": S.int("Frame width 20...150 mm (default 50)."),
        "mullionCols": S.int("Vertical glazing bars 0...6 (glass door, windows, sliding door)."),
        "mullionRows": S.int("Horizontal glazing bars 0...6."),
        "glass": S.str("Glass type (default clear).", values: OpeningGlass.allCases.map(\.rawValue)),
    ]

    private static func mullion(_ a: Args, _ key: String) throws -> Int? {
        guard let v = try a.int(key) else { return nil }
        guard (0...6).contains(v) else { throw ToolError.invalid(key, "must be 0 to 6") }
        return Int(v)
    }

    private static let materialDoc = "Material id or exact name; null removes it."
    private static func matSchema(_ d: String) -> JSONValue { .object(["description": .string(d + materialDoc)]) }

    @MainActor
    static func specs() -> [ToolSpec] {
        [
            .write("geometry.create_wall",
                   "Creates a wall from `start` to `end`, or a chain of walls through `points` (closed: also from the last point back to the first). Millimetres; thickness and height default to the project settings.",
                   ["levelId": S.uuid("Level; default the active level."),
                    "start": S.p2("Start point of a single wall."), "end": S.p2("End point of a single wall."),
                    "points": S.arr("Points of a wall chain (at least 2).", items: S.p2("Point.")),
                    "closed": S.bool("Chain only: close the loop."),
                    "thicknessMm": S.int("Wall thickness."), "heightMm": S.int("Wall height."),
                    "id": S.uuid("Optional id of a single wall.")]) { p, env, a in
                let level = try env.level(a, in: p)
                let thickness = try a.mm("thicknessMm"), height = try a.mm("heightMm")
                if let pts = try a.p2List("points") {
                    guard !a.has("start"), !a.has("end"), !a.has("id") else {
                        throw ToolError.invalid("points", "cannot be combined with start, end or id")
                    }
                    guard pts.count >= 2 else { throw ToolError.invalid("points", "needs at least 2 points") }
                    let ids = try p.addWalls(levelId: level, points: pts, closed: try a.bool("closed") ?? false,
                                             thickness: thickness, height: height)
                    return .object(["ids": J.ids(ids)])
                }
                let id = try p.addWall(levelId: level, start: try a.requireP2("start"), end: try a.requireP2("end"),
                                       thickness: thickness, height: height, id: try a.uuid("id") ?? UUID())
                return .object(["id": J.id(id), "ids": J.ids([id])])
            },
            .write("geometry.update_wall",
                   "Changes a wall. Moving an end point also moves walls that share it unless moveJoined is false.",
                   ["id": S.uuid("Wall id."), "start": S.p2("New start point."), "end": S.p2("New end point."),
                    "thicknessMm": S.int("Thickness."), "heightMm": S.int("Height."),
                    "leftMaterial": matSchema("Left side (seen from start to end). "),
                    "rightMaterial": matSchema("Right side. "),
                    "moveJoined": S.bool("Default true.")], required: ["id"]) { p, _, a in
                try requireAny(a, ["start", "end", "thicknessMm", "heightMm", "leftMaterial", "rightMaterial"])
                let id = try a.requireUUID("id")
                guard p.wall(id) != nil else { throw ToolError.notFound("Wall", id) }
                let left = try optionalMaterial(&p, a, "leftMaterial"), right = try optionalMaterial(&p, a, "rightMaterial")
                try p.updateWall(id, start: try a.p2("start"), end: try a.p2("end"), thickness: try a.mm("thicknessMm"),
                                 height: try a.mm("heightMm"), leftMaterialId: left, rightMaterialId: right,
                                 moveJoined: try a.bool("moveJoined") ?? true)
                return .object([:])
            },
            .write("geometry.split_wall", "Splits a wall in two at a point on it. Openings stay with the part they belong to. Returns both new wall ids.",
                   ["id": S.uuid("Wall id."), "at": S.p2("Point on the wall (projected onto its axis).")], required: ["id", "at"]) { p, _, a in
                let id = try a.requireUUID("id")
                guard p.wall(id) != nil else { throw ToolError.notFound("Wall", id) }
                let (first, second) = try p.splitWall(id, at: try a.requireP2("at"))
                return .object(["ids": J.ids([first, second]), "first": J.id(first), "second": J.id(second)])
            },
            .write("geometry.create_room", "Creates a room from a closed polygon (corner points in order, at least 3, not self-intersecting).",
                   ["levelId": S.uuid("Level; default the active level."), "name": S.str("Room name."),
                    "points": S.arr("Corner points.", items: S.p2("Corner.")), "id": S.uuid("Optional id.")],
                   required: ["name", "points"]) { p, env, a in
                let level = try env.level(a, in: p)
                guard let pts = try a.p2List("points"), pts.count >= 3 else { throw ToolError.invalid("points", "needs at least 3 points") }
                let id = try p.addRoom(levelId: level, name: try a.requireNonEmptyString("name"), points: pts, id: try a.uuid("id") ?? UUID())
                return .object(["id": J.id(id)])
            },
            .write("geometry.update_room", "Changes a room's name, outline, floor/ceiling material or visibility.",
                   ["id": S.uuid("Room id."), "name": S.str("New name."), "points": S.arr("New outline.", items: S.p2("Corner.")),
                    "floorMaterial": matSchema("Floor. "),
                    "ceilingMaterial": matSchema("Ceiling. "),
                    "showFloor": S.bool("Draw the floor."), "showCeiling": S.bool("Draw the ceiling.")], required: ["id"]) { p, _, a in
                try requireAny(a, ["name", "points", "floorMaterial", "ceilingMaterial", "showFloor", "showCeiling"])
                let id = try a.requireUUID("id")
                guard p.room(id) != nil else { throw ToolError.notFound("Room", id) }
                let floor = try optionalMaterial(&p, a, "floorMaterial"), ceiling = try optionalMaterial(&p, a, "ceilingMaterial")
                try p.updateRoom(id, name: try a.nonEmptyString("name"), points: try a.p2List("points"), floorMaterialId: floor,
                                 ceilingMaterialId: ceiling, showFloor: try a.bool("showFloor"), showCeiling: try a.bool("showCeiling"))
                return .object([:])
            },
            .write("geometry.add_opening",
                   "Adds a door, window or open passage to a wall. `offsetMm` is the distance of the opening's centre from the wall start (default: wall centre). Defaults: door 900x2100, window 1200x1200 with sill 900, opening 1000x2100.",
                   ["wallId": S.uuid("Wall."), "type": S.str("Kind of opening (default door).", values: OpeningKind.allCases.map(\.rawValue)),
                    "offsetMm": S.int("Centre position along the wall from its start."), "widthMm": S.int("Width."),
                    "heightMm": S.int("Height."), "sillMm": S.int("Height of the lower edge above the floor."),
                    "name": S.str("Optional name."), "id": S.uuid("Optional id.")].merging(detailProps) { a, _ in a },
                   required: ["wallId"]) { p, _, a in
                let wall = try a.requireUUID("wallId")
                guard p.wall(wall) != nil else { throw ToolError.notFound("Wall", wall) }
                let type = try a.enumValue("type", OpeningKind.self) ?? .door
                let defaults: (MM, MM) = switch type { case .door: (900, 2100); case .window: (1200, 1200); case .opening: (1000, 2100) }
                let id = try p.addOpening(wallId: wall, kind: type, offset: try a.mm("offsetMm"), width: try a.mm("widthMm") ?? defaults.0,
                                          height: try a.mm("heightMm") ?? defaults.1, sill: try a.mm("sillMm"),
                                          name: try a.string("name") ?? "", style: try a.enumValue("style", OpeningStyle.self),
                                          handle: try a.enumValue("handle", OpeningHandle.self), frameWidth: try a.mm("frameWidthMm"),
                                          mullionCols: try mullion(a, "mullionCols"), mullionRows: try mullion(a, "mullionRows"),
                                          glassType: try a.enumValue("glass", OpeningGlass.self), id: try a.uuid("id") ?? UUID())
                return .object(["id": J.id(id)])
            },
            .write("geometry.update_opening", "Changes an opening: type, size, position, swing, frame material or the wall it sits in.",
                   ["id": S.uuid("Opening id."), "type": S.str("Kind.", values: OpeningKind.allCases.map(\.rawValue)),
                    "name": S.str("Name."), "offsetMm": S.int("Centre position along the wall."), "widthMm": S.int("Width."),
                    "heightMm": S.int("Height."), "sillMm": S.int("Sill height."), "flipped": S.bool("Mirror along the wall."),
                    "inward": S.bool("Opens to the left side of the wall."), "frameMaterial": matSchema("Frame. "),
                    "wallId": S.uuid("Move the opening to another wall.")].merging(detailProps) { a, _ in a },
                   required: ["id"]) { p, _, a in
                try requireAny(a, ["type", "name", "offsetMm", "widthMm", "heightMm", "sillMm", "flipped", "inward", "frameMaterial", "wallId",
                                   "style", "handle", "frameWidthMm", "mullionCols", "mullionRows", "glass"])
                let id = try a.requireUUID("id")
                guard p.opening(id) != nil else { throw ToolError.notFound("Opening", id) }
                let frame = try optionalMaterial(&p, a, "frameMaterial")
                try p.updateOpening(id, kind: try a.enumValue("type", OpeningKind.self), name: try a.string("name"), offset: try a.mm("offsetMm"),
                                    width: try a.mm("widthMm"), height: try a.mm("heightMm"), sill: try a.mm("sillMm"),
                                    flipped: try a.bool("flipped"), inward: try a.bool("inward"), frameMaterialId: frame, wallId: try a.uuid("wallId"),
                                    style: try a.enumValue("style", OpeningStyle.self), handle: try a.enumValue("handle", OpeningHandle.self),
                                    frameWidth: try a.mm("frameWidthMm"), mullionCols: try mullion(a, "mullionCols"),
                                    mullionRows: try mullion(a, "mullionRows"), glassType: try a.enumValue("glass", OpeningGlass.self))
                return .object([:])
            },
            .write("geometry.create_dimension", "Adds a dimension line between two points; the label shows the distance.",
                   ["levelId": S.uuid("Level; default the active level."), "a": S.p2("First point."), "b": S.p2("Second point."),
                    "offsetMm": S.int("Distance of the dimension line from the measured line (default 300)."),
                    "id": S.uuid("Optional id.")], required: ["a", "b"]) { p, env, a in
                let level = try env.level(a, in: p)
                let id = try p.addDimension(levelId: level, a: try a.requireP2("a"), b: try a.requireP2("b"),
                                            offset: try a.mm("offsetMm") ?? 300, id: try a.uuid("id") ?? UUID())
                return .object(["id": J.id(id)])
            },
            .write("geometry.create_level", "Adds a storey. Elevation defaults to the top of the highest level.",
                   ["name": S.str("Level name."), "elevationMm": S.int("Floor height above the ground level."),
                    "heightMm": S.int("Storey height (default 2500)."), "id": S.uuid("Optional id.")], required: ["name"]) { p, _, a in
                let id = p.addLevel(name: try a.requireNonEmptyString("name"), elevation: try a.mm("elevationMm"),
                                    height: try a.mm("heightMm") ?? 2500, id: try a.uuid("id") ?? UUID())
                return .object(["id": J.id(id)])
            },
            .write("geometry.update_level", "Changes a storey: name, floor elevation, height, visibility or lock. Only the given keys change.",
                   ["id": S.uuid("Level id."), "name": S.str("New name."), "elevationMm": S.int("Floor height above the ground level."),
                    "heightMm": S.int("Storey height."), "visible": S.bool("Show the level."), "locked": S.bool("Lock the level against edits.")],
                   required: ["id"]) { p, _, a in
                try requireAny(a, ["name", "elevationMm", "heightMm", "visible", "locked"])
                let id = try a.requireUUID("id")
                guard p.level(id) != nil else { throw ToolError.notFound("Level", id) }
                try p.updateLevel(id, name: try a.nonEmptyString("name"), elevation: try a.mm("elevationMm"),
                                  height: try a.mm("heightMm"), visible: try a.bool("visible"), locked: try a.bool("locked"))
                return .object([:])
            },
            .write("geometry.update_dimension", "Changes a dimension line: end points and/or the offset of the line. Only the given keys change.",
                   ["id": S.uuid("Dimension id."), "a": S.p2("First point."), "b": S.p2("Second point."),
                    "offsetMm": S.int("Distance of the dimension line from the measured line.")], required: ["id"]) { p, _, a in
                try requireAny(a, ["a", "b", "offsetMm"])
                let id = try a.requireUUID("id")
                guard p.dimension(id) != nil else { throw ToolError.notFound("Dimension", id) }
                try p.updateDimension(id, a: try a.p2("a"), b: try a.p2("b"), offset: try a.mm("offsetMm"))
                return .object([:])
            },
            .write("geometry.create_room_from_walls",
                   "Creates a room from the closed wall loop around a point (walls must meet at their end points; the outline is inset by half the wall thickness, like the UI's room tool). Fails with INVALID_ARGUMENT when no closed loop surrounds the point.",
                   ["levelId": S.uuid("Level; default the active level."), "point": S.p2("A point inside the enclosed area."),
                    "name": S.str("Room name (default \"Room N\")."), "id": S.uuid("Optional id.")], required: ["point"]) { p, env, a in
                let level = try env.level(a, in: p)
                let pt = try a.requireP2("point")
                let walls = p.walls.filter { $0.levelId == level && $0.start != $0.end }
                guard !walls.isEmpty else { throw ToolError.invalid("point", "the level has no walls; create walls first or use geometry.create_room") }
                guard let poly = RoomFinder.face(containing: pt.v, walls: walls) else {
                    throw ToolError.invalid("point", "no closed wall loop surrounds this point; close the walls or use geometry.create_room")
                }
                let name = try a.nonEmptyString("name") ?? "Room \(p.rooms.filter { $0.levelId == level }.count + 1)"
                let id = try p.addRoom(levelId: level, name: name, points: poly, id: try a.uuid("id") ?? UUID())
                return .object(["id": J.id(id), "points": .array(poly.map { J.p2($0) })])
            },
            .read("geometry.measure_distance",
                  "Shortest distance between two targets, each either {\"id\": uuid} (furniture, wall, room, opening, dimension, group) or a point {\"x\",\"y\"}. Walls are measured by their outline, furniture by its rotated footprint. overlap=true (distance 0) when they touch or one contains the other.",
                  ["from": S.obj("First target: {id} or {x,y}."), "to": S.obj("Second target: {id} or {x,y}.")],
                  required: ["from", "to"]) { env, a in
                let p = env.project
                let from = try Measure.target(p, a.raw("from")!, "from"), to = try Measure.target(p, a.raw("to")!, "to")
                let r = Measure.distance(from.prims, to.prims)
                return .object([
                    "distanceMm": J.mm(r.distance), "exactMm": .number((r.distance * 1000).rounded() / 1000),
                    "overlap": .bool(r.overlap), "from": J.v2(r.from), "to": J.v2(r.to),
                    "fromLabel": .string(from.label), "toLabel": .string(to.label),
                ])
            },
        ]
    }
}

// MARK: - Distance between shapes

enum Measure {
    struct Prim {
        var points: [V2]
        var closed: Bool
    }

    struct Target {
        var prims: [Prim]
        var label: String
    }

    static func target(_ p: Project, _ v: JSONValue, _ field: String) throws -> Target {
        guard case .object = v else { throw ToolError.invalid(field, "must be {\"id\": uuid} or {\"x\": mm, \"y\": mm}") }
        if let idv = v["id"], !idv.isNull {
            let id = try Args.parseUUID(idv, "\(field).id")
            let kind = try p.requireKind(id)
            let name = p.displayName(of: id)
            switch kind {
            case .furniture:
                guard let i = p.instance(id), let d = p.definition(i.definitionId) else { break }
                return Target(prims: [Prim(points: FurnitureResolver.footprint(of: i, definition: d).corners, closed: true)], label: name)
            case .wall:
                if let w = p.wall(id) { return Target(prims: [wallPrim(w)], label: "Wall") }
            case .room:
                if let r = p.room(id) { return Target(prims: [Prim(points: r.points.map(\.v), closed: true)], label: name) }
            case .opening:
                if let o = p.opening(id), let w = p.wall(o.wallId) {
                    let ax = Geo.axis(w.start, w.end)
                    let s = w.start.v + ax.dir * (Double(o.offset) - Double(o.width) / 2)
                    return Target(prims: [Prim(points: [s, s + ax.dir * Double(o.width)], closed: false)], label: name)
                }
            case .dimension:
                if let d = p.dimension(id) { return Target(prims: [Prim(points: [d.a.v, d.b.v], closed: false)], label: "Dimension") }
            case .group:
                if let g = p.group(id) {
                    let prims = g.memberIds.compactMap { m -> Prim? in
                        guard let i = p.instance(m), let d = p.definition(i.definitionId) else { return nil }
                        return Prim(points: FurnitureResolver.footprint(of: i, definition: d).corners, closed: true)
                    }
                    if !prims.isEmpty { return Target(prims: prims, label: name) }
                }
            default: break
            }
            throw ToolError.invalid("\(field).id", "\(kind.rawValue) '\(name)' has no measurable outline")
        }
        let pt = try Args.parseP2(v, field)
        return Target(prims: [Prim(points: [pt.v], closed: false)], label: "(\(pt.x), \(pt.y))")
    }

    static func wallPrim(_ w: Wall) -> Prim {
        let ax = Geo.axis(w.start, w.end)
        let h = ax.normal * (Double(w.thickness) / 2)
        let s = w.start.v, e = w.end.v
        return Prim(points: [s - h, e - h, e + h, s + h], closed: true)
    }

    private static func edges(_ p: Prim) -> [(V2, V2)] {
        if p.points.count == 1 { return [(p.points[0], p.points[0])] }
        var out = zip(p.points, p.points.dropFirst()).map { ($0, $1) }
        if p.closed, p.points.count > 2 { out.append((p.points[p.points.count - 1], p.points[0])) }
        return out
    }

    private static func pointSegment(_ q: V2, _ a: V2, _ b: V2) -> (d: Double, at: V2) {
        let ab = b - a
        let l2 = ab.x * ab.x + ab.y * ab.y
        guard l2 > 1e-12 else { return (hypot(q.x - a.x, q.y - a.y), a) }
        let t = max(0, min(1, ((q.x - a.x) * ab.x + (q.y - a.y) * ab.y) / l2))
        let c = a + ab * t
        return (hypot(q.x - c.x, q.y - c.y), c)
    }

    private static func segSeg(_ a1: V2, _ a2: V2, _ b1: V2, _ b2: V2) -> (d: Double, pa: V2, pb: V2) {
        let r = a2 - a1, s = b2 - b1
        let den = r.x * s.y - r.y * s.x
        if abs(den) > 1e-12 {
            let t = ((b1.x - a1.x) * s.y - (b1.y - a1.y) * s.x) / den
            let u = ((b1.x - a1.x) * r.y - (b1.y - a1.y) * r.x) / den
            if (0...1).contains(t) && (0...1).contains(u) { let x = a1 + r * t; return (0, x, x) }
        }
        var best = (d: Double.infinity, pa: a1, pb: b1)
        for (q, pa) in [(a1, true), (a2, true)] {
            let c = pointSegment(q, b1, b2)
            if c.d < best.d { best = (c.d, q, c.at) }
            _ = pa
        }
        for q in [b1, b2] {
            let c = pointSegment(q, a1, a2)
            if c.d < best.d { best = (c.d, c.at, q) }
        }
        return best
    }

    static func distance(_ a: [Prim], _ b: [Prim]) -> (distance: Double, overlap: Bool, from: V2, to: V2) {
        var best = (d: Double.infinity, pa: a[0].points[0], pb: b[0].points[0])
        for pa in a {
            for pb in b {
                // Containment of one shape in the other (closed polygons) counts as overlap.
                if pb.closed, Geo.contains(pb.points, pa.points[0]) { return (0, true, pa.points[0], pa.points[0]) }
                if pa.closed, Geo.contains(pa.points, pb.points[0]) { return (0, true, pb.points[0], pb.points[0]) }
                for ea in edges(pa) {
                    for eb in edges(pb) {
                        let r = segSeg(ea.0, ea.1, eb.0, eb.1)
                        if r.d < best.d { best = r }
                        if r.d == 0 { return (0, true, r.pa, r.pb) }
                    }
                }
            }
        }
        return (best.d, false, best.pa, best.pb)
    }
}
