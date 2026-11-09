import Foundation
import simd

/// Room schedule: pure geometry per room. "Floor area" is the exact polygon area of the room as drawn; no
/// living-area factors (balconies, sloped ceilings, ...) are applied, because those rules vary by country and are
/// not verified here.
///
/// Wall areas: rooms and walls are independent entities, so a wall is attributed to a room edge only when it runs
/// parallel to that edge and the edge lies within half the wall thickness (+1 mm) of the wall axis. Each wall
/// counts with its own height, capped at the level's clear height when that is known. Per room edge the covered
/// stretches of all matching walls are merged: every elementary stretch is counted once, with the tallest covering
/// wall (the first one on a tie) as owner; only the owner's door/window/opening cut-outs (clipped to the stretch and
/// to the owner's height) are subtracted. Length covered by more than one wall is reported in
/// `overlappingWallLengthMM` (sum of (wall count - 1) x stretch length). Edges without a matching wall are not
/// counted (`unmatchedEdgeLengthMM`); when no edge matches, the wall areas are nil.
public struct RoomReportRow: Codable, Sendable, Equatable {
    public var roomId: UUID
    public var name: String
    /// Twice the polygon area in mm² (exact integer; the area may end in .5).
    public var twiceFloorAreaMM2: Int64
    public var floorAreaMM2: Double { Double(twiceFloorAreaMM2) / 2 }
    public var perimeterMM: Double
    /// Clear height of the level (nil when the level is unknown).
    public var clearHeightMM: MM?
    /// Twice the volume in mm³ (exact: twice the area × clear height); nil without a clear height.
    public var twiceVolumeMM3: Int128?
    public var volumeMM3: Double? { twiceVolumeMM3.map { Double($0) / 2 } }
    public var wallAreaGrossMM2: Double?
    public var wallAreaNetMM2: Double?
    public var wallMatchedLengthMM: Double
    public var unmatchedEdgeLengthMM: Double
    /// Edge length covered by more than one wall, counted (wall count - 1) times; these walls are merged in the areas.
    public var overlappingWallLengthMM: Double
    /// Furniture instances whose position lies inside (or on the boundary of) the room polygon.
    public var furnitureCount: Int
    public var floorAreaSquareMetres: String { ReportFormat.squareMetres(twiceAreaMM2: twiceFloorAreaMM2) }
    /// Volume in m³ with 3 decimals (exact integer arithmetic); "" without a clear height.
    public var volumeCubicMetres: String { twiceVolumeMM3.map { ReportFormat.scaled($0, divisor: 2_000_000_000, places: 3) } ?? "" }
}

public struct RoomReportLevel: Codable, Sendable, Equatable {
    public var levelId: UUID
    public var name: String
    public var clearHeightMM: MM?
    public var rooms: [RoomReportRow]
    /// Furniture on this level whose position is in no room.
    public var furnitureOutsideRooms: Int
    /// All furniture instances on this level (each counted once).
    public var furnitureTotal: Int
    public var twiceFloorAreaMM2: Int64 { rooms.reduce(0) { $0 &+ $1.twiceFloorAreaMM2 } }
    public var perimeterMM: Double { rooms.reduce(0) { $0 + $1.perimeterMM } }
    /// Twice the volume in mm³; nil when any room has no volume.
    public var twiceVolumeMM3: Int128? {
        var sum: Int128 = 0
        for r in rooms { guard let v = r.twiceVolumeMM3 else { return nil }; sum += v }
        return sum
    }
    public var volumeMM3: Double? { twiceVolumeMM3.map { Double($0) / 2 } }
    /// Sums over the rooms that have wall areas.
    public var wallAreaGrossMM2: Double { rooms.reduce(0) { $0 + ($1.wallAreaGrossMM2 ?? 0) } }
    public var wallAreaNetMM2: Double { rooms.reduce(0) { $0 + ($1.wallAreaNetMM2 ?? 0) } }
    /// Rooms without matching walls (not part of the wall-area sums).
    public var roomsWithoutWalls: Int { rooms.filter { $0.wallAreaGrossMM2 == nil }.count }
    public var overlappingWallLengthMM: Double { rooms.reduce(0) { $0 + $1.overlappingWallLengthMM } }
    /// Sum over rooms (a piece inside two overlapping rooms counts twice).
    public var furnitureCount: Int { rooms.reduce(0) { $0 + $1.furnitureCount } }
}

public struct RoomReport: Codable, Sendable, Equatable {
    public var projectName: String
    public var levels: [RoomReportLevel]

    public var twiceFloorAreaMM2: Int64 { levels.reduce(0) { $0 &+ $1.twiceFloorAreaMM2 } }
    public var perimeterMM: Double { levels.reduce(0) { $0 + $1.perimeterMM } }
    /// Twice the volume in mm³; nil when any level has a room without volume.
    public var twiceVolumeMM3: Int128? {
        var sum: Int128 = 0
        for l in levels { guard let v = l.twiceVolumeMM3 else { return nil }; sum += v }
        return sum
    }
    public var volumeMM3: Double? { twiceVolumeMM3.map { Double($0) / 2 } }
    public var wallAreaGrossMM2: Double { levels.reduce(0) { $0 + $1.wallAreaGrossMM2 } }
    public var wallAreaNetMM2: Double { levels.reduce(0) { $0 + $1.wallAreaNetMM2 } }
    public var roomsWithoutWalls: Int { levels.reduce(0) { $0 + $1.roomsWithoutWalls } }
    public var overlappingWallLengthMM: Double { levels.reduce(0) { $0 + $1.overlappingWallLengthMM } }
    public var furnitureCount: Int { levels.reduce(0) { $0 + $1.furnitureCount } }
    public var furnitureTotal: Int { levels.reduce(0) { $0 + $1.furnitureTotal } }
    public var furnitureOutsideRooms: Int { levels.reduce(0) { $0 + $1.furnitureOutsideRooms } }

    public static func make(_ p: Project) -> RoomReport {
        var out: [RoomReportLevel] = []
        let known = Set(p.levels.map(\.id))
        var groups: [(id: UUID, name: String, height: MM?)] = p.levels.sorted { $0.elevation < $1.elevation }
            .map { ($0.id, $0.name, $0.height) }
        for r in p.rooms where !known.contains(r.levelId) && !groups.contains(where: { $0.id == r.levelId }) {
            groups.append((r.levelId, "(unknown level)", nil))
        }
        for g in groups {
            let rooms = p.rooms.filter { $0.levelId == g.id }
            let walls = p.walls.filter { $0.levelId == g.id }
            let wallIds = Set(walls.map(\.id))
            let openings = p.openings.filter { wallIds.contains($0.wallId) }
            let furniture = p.instances.filter { $0.levelId == g.id }
            var rows: [RoomReportRow] = []
            for r in rooms {
                let twice = Geo.twiceSignedArea(r.points).magnitude
                let twice64 = twice > UInt128(Int64.max) ? Int64.max : Int64(twice)
                let perim = Geo.perimeter(r.points)
                let wallInfo = wallAreas(room: r, walls: walls, openings: openings, levelHeight: g.height)
                let matched = wallInfo.matched
                rows.append(RoomReportRow(
                    roomId: r.id, name: r.name, twiceFloorAreaMM2: twice64, perimeterMM: perim,
                    clearHeightMM: g.height,
                    twiceVolumeMM3: g.height.map { Int128(twice64) * Int128($0) },
                    wallAreaGrossMM2: matched > 0 ? wallInfo.gross : nil,
                    wallAreaNetMM2: matched > 0 ? wallInfo.net : nil,
                    wallMatchedLengthMM: matched,
                    unmatchedEdgeLengthMM: max(0, perim - matched),
                    overlappingWallLengthMM: wallInfo.overlap,
                    furnitureCount: furniture.filter { Geo.contains(r.points, $0.position.xy) }.count))
            }
            let outside = furniture.filter { f in !rooms.contains { Geo.contains($0.points, f.position.xy) } }.count
            out.append(RoomReportLevel(levelId: g.id, name: g.name, clearHeightMM: g.height, rooms: rows,
                                       furnitureOutsideRooms: outside, furnitureTotal: furniture.count))
        }
        return RoomReport(projectName: p.name, levels: out)
    }

    /// One wall stretch along a room edge (edge coordinates, mm) with its effective height and cut-outs.
    private struct Stretch {
        var o0: Double, o1: Double
        var height: Double
        var cuts: [(u0: Double, u1: Double, bottom: Double, top: Double)]
    }

    private static func wallAreas(room: Room, walls: [Wall], openings: [Opening], levelHeight: MM?)
        -> (gross: Double, net: Double, matched: Double, overlap: Double) {
        let pts = room.points
        guard pts.count >= 3 else { return (0, 0, 0, 0) }
        var matched = 0.0, overlap = 0.0, gross = 0.0, cutArea = 0.0
        for i in pts.indices {
            let a = pts[i].v, b = pts[(i + 1) % pts.count].v
            let ed = b - a
            let len = simd_length(ed)
            guard len > 0 else { continue }
            let dir = ed / len, nrm = V2(-dir.y, dir.x)
            var stretches: [Stretch] = []
            for w in walls {
                let ws = w.start.v, we = w.end.v
                let wd = we - ws
                let wlen = simd_length(wd)
                guard wlen > 0 else { continue }
                let wdir = wd / wlen
                guard abs(dir.x * wdir.y - dir.y * wdir.x) < 1e-6 else { continue }
                let tol = Double(w.thickness) / 2 + 1
                guard abs(simd_dot(ws - a, nrm)) <= tol, abs(simd_dot(we - a, nrm)) <= tol else { continue }
                let t0 = simd_dot(ws - a, dir), t1 = simd_dot(we - a, dir)
                let o0 = max(0, min(t0, t1)), o1 = min(len, max(t0, t1))
                guard o1 - o0 > 0 else { continue }
                let h = Double(min(w.height, levelHeight ?? w.height))
                let sameDir = t1 >= t0
                var cuts: [(u0: Double, u1: Double, bottom: Double, top: Double)] = []
                for o in openings where o.wallId == w.id {
                    let s0 = Double(o.offset) - Double(o.width) / 2, s1 = Double(o.offset) + Double(o.width) / 2
                    let u0 = sameDir ? t0 + s0 : t0 - s1, u1 = sameDir ? t0 + s1 : t0 - s0
                    cuts.append((u0, u1, max(0, Double(o.sill)), min(Double(o.sill + o.height), h)))
                }
                stretches.append(Stretch(o0: o0, o1: o1, height: h, cuts: cuts))
            }
            let cuts = Set(stretches.flatMap { [$0.o0, $0.o1] }).sorted()
            guard cuts.count >= 2 else { continue }
            for k in 0..<(cuts.count - 1) {
                let p = cuts[k], q = cuts[k + 1]
                let covering = stretches.filter { $0.o0 <= p && $0.o1 >= q }
                guard var owner = covering.first else { continue }
                for s in covering.dropFirst() where s.height > owner.height { owner = s }
                matched += q - p
                overlap += Double(covering.count - 1) * (q - p)
                gross += (q - p) * owner.height
                for c in owner.cuts {
                    let c0 = max(p, c.u0), c1 = min(q, c.u1)
                    guard c1 > c0 else { continue }
                    cutArea += (c1 - c0) * max(0, c.top - c.bottom)
                }
            }
        }
        return (gross, max(0, gross - cutArea), matched, overlap)
    }

    // MARK: Output

    private static let header = ["Level", "Room", "Floor area (m²)", "Perimeter (m)", "Clear height (mm)", "Volume (m³)",
                                 "Wall area gross (m²)", "Wall area net (m²)", "Furniture"]

    private static func volumeText(_ twice: Int128?) -> String {
        twice.map { ReportFormat.scaled($0, divisor: 2_000_000_000, places: 3) } ?? ""
    }

    private func cells(level: String, row r: RoomReportRow) -> [String] {
        [level, r.name, r.floorAreaSquareMetres, ReportFormat.metres(r.perimeterMM),
         r.clearHeightMM.map { "\($0)" } ?? "", r.volumeCubicMetres,
         r.wallAreaGrossMM2.map(ReportFormat.squareMetres) ?? "", r.wallAreaNetMM2.map(ReportFormat.squareMetres) ?? "",
         "\(r.furnitureCount)"]
    }

    private func totalCells(label: String, name: String, twice: Int64, perimeter: Double, twiceVolume: Int128?, gross: Double, net: Double, furniture: Int) -> [String] {
        [label, name, ReportFormat.squareMetres(twiceAreaMM2: twice), ReportFormat.metres(perimeter), "",
         Self.volumeText(twiceVolume), ReportFormat.squareMetres(gross), ReportFormat.squareMetres(net), "\(furniture)"]
    }

    private var tableRows: [[String]] {
        var rows: [[String]] = []
        for l in levels {
            for r in l.rooms { rows.append(cells(level: l.name, row: r)) }
            if l.furnitureOutsideRooms > 0 {
                rows.append([l.name, "(outside rooms)", "", "", "", "", "", "", "\(l.furnitureOutsideRooms)"])
            }
            rows.append(totalCells(label: l.name, name: "Level total", twice: l.twiceFloorAreaMM2, perimeter: l.perimeterMM,
                                   twiceVolume: l.twiceVolumeMM3, gross: l.wallAreaGrossMM2, net: l.wallAreaNetMM2, furniture: l.furnitureTotal))
        }
        rows.append(totalCells(label: "", name: "Project total", twice: twiceFloorAreaMM2, perimeter: perimeterMM,
                               twiceVolume: twiceVolumeMM3, gross: wallAreaGrossMM2, net: wallAreaNetMM2, furniture: furnitureTotal))
        return rows
    }

    /// CSV, comma separated, "." decimals, RFC 4180 quoting. Level totals and the project total are rows too.
    public func csv() -> String { ReportFormat.csv(header: Self.header, rows: tableRows) }

    public func markdown() -> String {
        var s = "# Room report: \(ReportFormat.mdCell(projectName))\n\n" +
        ReportFormat.markdownTable(header: Self.header, rows: tableRows, rightAligned: [2, 3, 4, 5, 6, 7, 8]) +
        "\nFloor area is the plain polygon area of each room; no living-area factors are applied. " +
        "Wall areas appear only where walls run along room edges."
        if roomsWithoutWalls > 0 {
            s += "\n\n\(roomsWithoutWalls) \(roomsWithoutWalls == 1 ? "room" : "rooms") without matching walls \(roomsWithoutWalls == 1 ? "is" : "are") not included in wall-area totals."
        }
        if twiceVolumeMM3 == nil {
            s += "\n\nVolume totals are empty because at least one room has no known clear height."
        }
        if overlappingWallLengthMM > 0 {
            s += "\n\nWarning: \(ReportFormat.metres(overlappingWallLengthMM)) m of room edges are covered by more than one wall; " +
                "each stretch is counted once, with the tallest wall."
        }
        return s + "\n"
    }
}
