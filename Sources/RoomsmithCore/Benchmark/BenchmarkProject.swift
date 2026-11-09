import Foundation

/// Deterministic stress project for performance measurements (test P01): a grid of rooms bounded by shared walls,
/// a door in every interior wall running north–south, a window in every outer east/west wall, and `furnitureCount` small built-in pieces laid out inside the rooms, plus groups.
public enum BenchmarkProject {
    public struct Layout: Sendable {
        public var columns = 8
        public var rows = 6
        public var cellWidth: MM = 4000
        public var cellDepth: MM = 3500
        public var furnitureCount = 1000
        public var groupCount = 20
        public init() {}
    }

    public static func make(_ layout: Layout = Layout()) throws -> Project {
        var p = Project.empty(name: "Benchmark")
        p.materials = BuiltinCatalog.materials
        let level = p.levels[0].id
        let cw = layout.cellWidth, cd = layout.cellDepth
        let cols = layout.columns, rows = layout.rows

        // Horizontal wall lines (y = r·cd), split per cell so every wall has clean T/L joins.
        for r in 0...rows {
            for c in 0..<cols {
                let y = MM(r) * cd
                _ = (try p.addWall(levelId: level, start: P2(MM(c) * cw, y), end: P2(MM(c + 1) * cw, y)))
            }
        }
        // Vertical wall lines; interior ones get a door.
        for c in 0...cols {
            for r in 0..<rows {
                let x = MM(c) * cw
                let id = try p.addWall(levelId: level, start: P2(x, MM(r) * cd), end: P2(x, MM(r + 1) * cd))
                if c > 0 && c < cols { try p.addOpening(wallId: id, kind: .door, width: 900, height: 2100) }
                if c == 0 || c == cols { try p.addOpening(wallId: id, kind: .window, width: 1200, height: 1250) }
            }
        }

        // Rooms.
        var cells: [(x0: MM, y0: MM)] = []
        for r in 0..<rows {
            for c in 0..<cols {
                let x0 = MM(c) * cw, y0 = MM(r) * cd
                cells.append((x0, y0))
                try p.addRoom(levelId: level, name: "Room \(r * cols + c + 1)",
                              points: [P2(x0, y0), P2(x0 + cw, y0), P2(x0 + cw, y0 + cd), P2(x0, y0 + cd)])
            }
        }

        // Small built-in pieces laid out on a grid per room (neighbours may touch; that is fine for timing).
        let small = BuiltinCatalog.entries.compactMap { BuiltinCatalog.definition($0.key) }
            .filter { $0.size.width <= 700 && $0.size.depth <= 650 }
        let defs = small.isEmpty ? BuiltinCatalog.entries.prefix(5).compactMap { BuiltinCatalog.definition($0.key) } : small
        for d in defs { p.definitions.append(d) }

        let perRoom = max(1, Int((Double(layout.furnitureCount) / Double(max(cells.count, 1))).rounded(.up)))
        let grid = max(1, Int(Double(perRoom).squareRoot().rounded(.up)))
        var placed: [UUID] = []
        outer: for (ci, cell) in cells.enumerated() {
            let stepX = cw / MM(grid + 1), stepY = cd / MM(grid + 1)
            for k in 0..<perRoom {
                if placed.count >= layout.furnitureCount { break outer }
                let gx = MM(k % grid + 1), gy = MM(k / grid + 1)
                let def = defs[(ci * perRoom + k) % defs.count]
                let rot = Double((k % 4) * 90)
                placed.append(try p.addInstance(definitionId: def.id, levelId: level,
                                                position: P3(cell.x0 + gx * stepX, cell.y0 + gy * stepY, 0), rotationDeg: rot))
            }
        }

        // Groups of three neighbouring pieces.
        var g = 0
        var i = 0
        while g < layout.groupCount && i + 2 < placed.count {
            try p.groupObjects(Array(placed[i...(i + 2)]), name: "Group \(g + 1)")
            g += 1
            i += 50
        }
        return p
    }
}
