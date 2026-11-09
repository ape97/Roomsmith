import Foundation

// MARK: - report.*

/// Read-only reports for agents: room areas and volumes, bill of materials, clearance check. They use the same
/// report types as the app (`RoomReport`, `BillOfMaterials`, `ClearanceCheck`); areas and volumes are given as exact
/// decimal strings (m², m³, rounded half away from zero) next to the raw millimetre values.
public enum ReportTools {
    static let formats = ["json", "csv", "markdown"]

    static func format(_ a: Args) throws -> String {
        let f = try a.string("format")?.lowercased() ?? "json"
        guard formats.contains(f) else { throw ToolError.invalid("format", "must be json, csv or markdown") }
        return f
    }

    static func text(_ format: String, _ body: String) -> JSONValue {
        .object(["format": .string(format), "text": .string(body)])
    }

    /// Optional `levelId` filter; an unknown id is an error, never an empty report.
    static func levelFilter(_ a: Args, _ p: Project) throws -> UUID? {
        guard let id = try a.uuid("levelId") else { return nil }
        guard p.level(id) != nil else { throw ToolError.notFound("Level", id) }
        return id
    }

    static func num(_ d: Double?) -> JSONValue { d.map { J.mm($0) } ?? .null }
    static func str(_ s: String) -> JSONValue { s.isEmpty ? .null : .string(s) }

    // MARK: Room report

    static func roomJSON(_ r: RoomReportRow) -> JSONValue {
        .object([
            "id": J.id(r.roomId), "name": .string(r.name),
            "floorAreaM2": .string(r.floorAreaSquareMetres),
            "perimeterM": .string(ReportFormat.metres(r.perimeterMM)),
            "clearHeightMm": r.clearHeightMM.map { .int($0) } ?? .null,
            "volumeM3": str(r.volumeCubicMetres),
            "wallAreaGrossM2": r.wallAreaGrossMM2.map { .string(ReportFormat.squareMetres($0)) } ?? .null,
            "wallAreaNetM2": r.wallAreaNetMM2.map { .string(ReportFormat.squareMetres($0)) } ?? .null,
            "wallMatchedLengthMm": num(r.wallMatchedLengthMM),
            "unmatchedEdgeLengthMm": num(r.unmatchedEdgeLengthMM),
            "overlappingWallLengthMm": num(r.overlappingWallLengthMM),
            "furnitureCount": .int(Int64(r.furnitureCount)),
        ])
    }

    static func volume(_ twice: Int128?) -> JSONValue {
        twice.map { .string(ReportFormat.scaled($0, divisor: 2_000_000_000, places: 3)) } ?? .null
    }

    static func roomsJSON(_ r: RoomReport) -> JSONValue {
        .object([
            "projectName": .string(r.projectName),
            "levels": .array(r.levels.map { l in
                .object([
                    "id": J.id(l.levelId), "name": .string(l.name),
                    "clearHeightMm": l.clearHeightMM.map { .int($0) } ?? .null,
                    "rooms": .array(l.rooms.map(roomJSON)),
                    "floorAreaM2": .string(ReportFormat.squareMetres(twiceAreaMM2: l.twiceFloorAreaMM2)),
                    "volumeM3": volume(l.twiceVolumeMM3),
                    "wallAreaGrossM2": .string(ReportFormat.squareMetres(l.wallAreaGrossMM2)),
                    "wallAreaNetM2": .string(ReportFormat.squareMetres(l.wallAreaNetMM2)),
                    "furnitureInRooms": .int(Int64(l.furnitureCount)),
                    "furnitureOutsideRooms": .int(Int64(l.furnitureOutsideRooms)),
                    "furnitureTotal": .int(Int64(l.furnitureTotal)),
                ])
            }),
            "totals": .object([
                "floorAreaM2": .string(ReportFormat.squareMetres(twiceAreaMM2: r.twiceFloorAreaMM2)),
                "volumeM3": volume(r.twiceVolumeMM3),
                "wallAreaGrossM2": .string(ReportFormat.squareMetres(r.wallAreaGrossMM2)),
                "wallAreaNetM2": .string(ReportFormat.squareMetres(r.wallAreaNetMM2)),
                "roomsWithoutWalls": .int(Int64(r.roomsWithoutWalls)),
                "furnitureTotal": .int(Int64(r.furnitureTotal)),
            ]),
            "notes": .string("Floor area is the plain polygon area (no living-area factors). Volume and clear height are null when the level has no clear height; per-room wall areas are null when no wall lies along the room edges (level and project sums then count 0, see roomsWithoutWalls). Wall areas count only walls along room edges, capped at the level height, openings subtracted."),
        ])
    }

    // MARK: Bill of materials

    static func bomJSON(_ b: BillOfMaterials) -> JSONValue {
        .object([
            "projectName": .string(b.projectName),
            "furniture": .array(b.furniture.map { l in
                .object([
                    "definitionId": J.id(l.definitionId), "name": .string(l.name), "count": .int(Int64(l.count)),
                    "widthMm": .int(l.width), "depthMm": .int(l.depth), "heightMm": .int(l.height),
                    "material": str(l.material), "productId": l.productId.map(J.id) ?? .null,
                    "currency": l.currency.map { .string($0) } ?? .null,
                    "unitPrice": l.unitPriceMinor.map { .string(ReportFormat.price(minor: $0)) } ?? .null,
                    "totalPrice": l.totalPriceMinor.map { .string(ReportFormat.price(minor: $0)) } ?? .null,
                ])
            }),
            "furnitureCount": .int(Int64(b.furnitureCount)),
            "totals": .array(b.totalsMinor.sorted { $0.key < $1.key }.map { cur, total in
                .object(["currency": .string(cur), "pieces": .int(Int64(b.pricedCounts[cur] ?? 0)),
                         "total": .string(ReportFormat.price(minor: total))])
            }),
            "unpricedCount": .int(Int64(b.unpricedCount)),
            "walls": .object([
                "count": .int(Int64(b.walls.count)),
                "totalLengthM": .string(ReportFormat.metres(b.walls.totalLengthMM)),
                "areaM2": .string(ReportFormat.squareMetres(b.walls.areaMM2)),
            ]),
            "openings": .array(b.openings.map {
                .object(["kind": .string($0.kind.rawValue), "widthMm": .int($0.width), "heightMm": .int($0.height),
                         "count": .int(Int64($0.count))])
            }),
            "instancesWithoutDefinition": .int(Int64(b.instancesWithoutDefinition)),
        ])
    }

    // MARK: Clearances

    /// Shared with the app's Reports sheet so both write identical clearance tables.
    public static let clearanceHeader = ["Kind", "Level", "Furniture", "Other", "Other kind", "Distance (mm)", "Limit (mm)",
                                  "Overlaps", "X (mm)", "Y (mm)"]

    public static func clearanceRows(_ list: [ClearanceFinding], _ p: Project) -> [[String]] {
        let levels = Dictionary(p.levels.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let names = Dictionary(p.instances.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        return list.map { f in
            [f.kind.rawValue, levels[f.levelId] ?? "", names[f.instanceId].flatMap { $0.isEmpty ? nil : $0 } ?? f.instanceId.uuidString.lowercased(),
             f.otherKind == .furniture ? (names[f.otherId].flatMap { $0.isEmpty ? nil : $0 } ?? f.otherId.uuidString.lowercased())
                                       : f.otherId.uuidString.lowercased(),
             f.otherKind.rawValue, ReportFormat.fixed(f.distanceMM, 0), ReportFormat.fixed(f.limitMM, 0),
             f.overlaps ? "yes" : "no", "\(f.position.x)", "\(f.position.y)"]
        }
    }

    static func clearanceRules(_ a: Args) throws -> ClearanceRules {
        var r = ClearanceRules()
        func mm(_ key: String, _ apply: (Double) -> Void) throws {
            guard let v = try a.double(key) else { return }
            guard v.isFinite, v >= 0, v <= 100_000 else { throw ToolError.invalid(key, "must be between 0 and 100000 mm") }
            apply(v)
        }
        try mm("minWalkwayMm") { r.minWalkwayMM = $0 }
        try mm("doorApproachMm") { r.doorApproachMM = $0 }
        if let s = try a.bool("checkDoorSwing") { r.checkDoorSwing = s }
        return r
    }

    // MARK: Specs

    @MainActor
    static func specs() -> [ToolSpec] {
        let fmt = S.str("Output: json (default, structured), csv (RFC 4180, header row) or markdown (table). csv/markdown return {format, text}.",
                        values: formats)
        return [
            .read("report.rooms",
                  "Room report: floor area, perimeter, clear height, volume and wall areas (gross/net) per room, with level and project totals. Areas and volumes are exact decimal strings in m² / m³ (2 / 3 decimals, half away from zero).",
                  ["format": fmt, "levelId": S.uuid("Only this level; default all levels.")]) { env, a in
                let p = env.project
                let f = try format(a)
                var r = RoomReport.make(p)
                if let id = try levelFilter(a, p) { r.levels = r.levels.filter { $0.levelId == id } }
                switch f {
                case "csv": return text(f, r.csv())
                case "markdown": return text(f, r.markdown())
                default: return roomsJSON(r)
                }
            },
            .read("report.bom",
                  "Bill of materials: furniture grouped by definition, effective size, product and material, with unit and total prices per currency; wall count, length and one-face area; openings by kind and size.",
                  ["format": fmt]) { env, a in
                let f = try format(a)
                let b = BillOfMaterials.make(env.project)
                switch f {
                case "csv": return text(f, b.csv())
                case "markdown": return text(f, b.markdown())
                default: return bomJSON(b)
                }
            },
            .read("report.clearances",
                  "Clearance check: furniture closer than the walkway width to other furniture or walls, furniture in front of doors (approach strip) and inside the door swing (quarter circle). Distances in mm. Read-only; fix findings with scene.move_objects.",
                  ["format": fmt, "levelId": S.uuid("Only this level; default all levels."),
                   "minWalkwayMm": S.num("Minimum gap between pieces / piece and wall (default 600)."),
                   "doorApproachMm": S.num("Free depth in front of doors (default 900)."),
                   "checkDoorSwing": S.bool("Report furniture inside the door swing (default true).")]) { env, a in
                let p = env.project
                let f = try format(a)
                let rules = try clearanceRules(a)
                let list = ClearanceCheck.run(p, rules: rules, levelId: try levelFilter(a, p))
                switch f {
                case "csv": return text(f, ReportFormat.csv(header: clearanceHeader, rows: clearanceRows(list, p)))
                case "markdown":
                    let body = "# Clearance check: \(ReportFormat.mdCell(p.name))\n\n"
                        + (list.isEmpty ? "No findings.\n"
                           : ReportFormat.markdownTable(header: clearanceHeader, rows: clearanceRows(list, p), rightAligned: [5, 6, 8, 9]))
                    return text(f, body)
                default:
                    return .object([
                        "count": .int(Int64(list.count)),
                        "rules": .object(["minWalkwayMm": .number(rules.minWalkwayMM), "doorApproachMm": .number(rules.doorApproachMM),
                                          "checkDoorSwing": .bool(rules.checkDoorSwing)]),
                        "findings": .array(list.map { x in
                            .object(["kind": .string(x.kind.rawValue), "levelId": J.id(x.levelId), "instanceId": J.id(x.instanceId),
                                     "otherId": J.id(x.otherId), "otherKind": .string(x.otherKind.rawValue),
                                     "distanceMm": J.mm(x.distanceMM), "limitMm": J.mm(x.limitMM), "overlaps": .bool(x.overlaps),
                                     "position": J.p2(x.position)])
                        }),
                    ])
                }
            },
        ]
    }
}
