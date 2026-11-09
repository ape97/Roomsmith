import Foundation

/// Bill of materials: furniture instances grouped by definition, effective size, product and material, plus walls
/// and openings. Prices come from the linked `CatalogProduct.priceMinor` (instance product, else definition product);
/// they are shown with 2 decimals, which assumes a currency with 100 minor units.
public struct BOMFurnitureLine: Codable, Sendable, Equatable {
    public var definitionId: UUID
    public var name: String
    public var count: Int
    public var width: MM
    public var depth: MM
    public var height: MM
    public var material: String
    public var productId: UUID?
    public var unitPriceMinor: Int64?
    public var currency: String?
    /// count × unit price (saturating); nil without a price.
    public var totalPriceMinor: Int64? {
        guard let u = unitPriceMinor else { return nil }
        let (v, o) = u.multipliedReportingOverflow(by: Int64(count))
        return o ? (u < 0 ? Int64.min : Int64.max) : v
    }
}

public struct BOMWallSummary: Codable, Sendable, Equatable {
    public var count: Int
    /// Sum of axis lengths.
    public var totalLengthMM: Double
    /// Sum of length × height of one face per wall; the height is capped at the level's clear height.
    public var areaMM2: Double
}

public struct BOMOpeningLine: Codable, Sendable, Equatable {
    public var kind: OpeningKind
    public var width: MM
    public var height: MM
    public var count: Int
}

public struct BillOfMaterials: Codable, Sendable, Equatable {
    public var projectName: String
    public var furniture: [BOMFurnitureLine]
    public var walls: BOMWallSummary
    public var openings: [BOMOpeningLine]
    /// Instances whose definition does not exist (not listed).
    public var instancesWithoutDefinition: Int

    public var furnitureCount: Int { furniture.reduce(0) { $0 + $1.count } }
    /// Pieces per currency over priced lines.
    public var pricedCounts: [String: Int] {
        var t: [String: Int] = [:]
        for l in furniture where l.totalPriceMinor != nil { t[l.currency ?? "", default: 0] += l.count }
        return t
    }
    /// Sum per currency over priced lines.
    public var totalsMinor: [String: Int64] {
        var t: [String: Int64] = [:]
        for l in furniture { if let v = l.totalPriceMinor { t[l.currency ?? "", default: 0] = t[l.currency ?? "", default: 0] &+ v } }
        return t
    }
    /// Pieces without a price (not part of the totals).
    public var unpricedCount: Int { furniture.filter { $0.unitPriceMinor == nil }.reduce(0) { $0 + $1.count } }
    public func openingCount(_ kind: OpeningKind) -> Int { openings.filter { $0.kind == kind }.reduce(0) { $0 + $1.count } }

    /// Total order for reproducible output (Swift compares tuples only up to six elements).
    static func lineOrder(_ a: BOMFurnitureLine, _ b: BOMFurnitureLine) -> Bool {
        if (a.name, a.width, a.depth, a.height, a.material) != (b.name, b.width, b.depth, b.height, b.material) {
            return (a.name, a.width, a.depth, a.height, a.material) < (b.name, b.width, b.depth, b.height, b.material)
        }
        return (a.definitionId.uuidString, a.productId?.uuidString ?? "") < (b.definitionId.uuidString, b.productId?.uuidString ?? "")
    }

    public static func make(_ p: Project) -> BillOfMaterials {
        let defs = Dictionary(p.definitions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let prods = Dictionary(p.products.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let mats = Dictionary(p.materials.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        struct Key: Hashable { var def: UUID; var w: MM; var d: MM; var h: MM; var product: UUID?; var material: String }
        var counts: [Key: Int] = [:]
        var missing = 0
        for inst in p.instances {
            guard let def = defs[inst.definitionId] else { missing += 1; continue }
            let s = FurnitureResolver.size(of: inst, definition: def)
            let pid = inst.productId ?? def.productId
            var material = pid.flatMap { prods[$0] }?.materialText ?? ""
            if material.isEmpty {
                var names = Set<String>()
                let options = FurnitureResolver.optionOutcome(of: inst, definition: def)
                for c in def.components where !options.hidden.contains(c.id) {
                    if let id = FurnitureResolver.materialId(of: c, inst: inst, options: options), let n = mats[id] { names.insert(n) }
                }
                material = names.sorted().joined(separator: " / ")
            }
            counts[Key(def: def.id, w: s.width, d: s.depth, h: s.height, product: pid, material: material), default: 0] += 1
        }
        let lines: [BOMFurnitureLine] = counts.map { k, n in
            let prod = k.product.flatMap { prods[$0] }
            return BOMFurnitureLine(definitionId: k.def, name: defs[k.def]?.name ?? "", count: n, width: k.w, depth: k.d, height: k.h,
                                    material: k.material, productId: k.product, unitPriceMinor: prod?.priceMinor,
                                    currency: prod?.priceMinor == nil ? nil : prod?.currency)
        }.sorted(by: Self.lineOrder)

        // Same height rule as the room report: a wall counts up to its level's clear height.
        let levelHeights = Dictionary(p.levels.map { ($0.id, $0.height) }, uniquingKeysWith: { a, _ in a })
        var length = 0.0, area = 0.0
        for w in p.walls {
            let l = Geo.distance(w.start, w.end)
            let h = min(w.height, levelHeights[w.levelId] ?? w.height)
            length += l; area += l * Double(h)
        }
        var oc: [OpeningKind: [MM: [MM: Int]]] = [:]
        for o in p.openings { oc[o.kind, default: [:]][o.width, default: [:]][o.height, default: 0] += 1 }
        var ol: [BOMOpeningLine] = []
        for (k, byW) in oc { for (w, byH) in byW { for (h, n) in byH { ol.append(BOMOpeningLine(kind: k, width: w, height: h, count: n)) } } }
        let order = OpeningKind.allCases
        ol.sort { (order.firstIndex(of: $0.kind)!, $0.width, $0.height) < (order.firstIndex(of: $1.kind)!, $1.width, $1.height) }
        return BillOfMaterials(projectName: p.name, furniture: lines,
                               walls: BOMWallSummary(count: p.walls.count, totalLengthMM: length, areaMM2: area),
                               openings: ol, instancesWithoutDefinition: missing)
    }

    // MARK: Output

    private static let header = ["Section", "Name", "Quantity", "Width (mm)", "Depth (mm)", "Height (mm)", "Material",
                                 "Currency", "Unit price", "Total price", "Length (m)", "Area (m²)"]

    private var tableRows: [[String]] {
        var rows: [[String]] = []
        for l in furniture {
            rows.append(["furniture", l.name, "\(l.count)", "\(l.width)", "\(l.depth)", "\(l.height)", l.material,
                         l.currency ?? "", l.unitPriceMinor.map(ReportFormat.price) ?? "", l.totalPriceMinor.map(ReportFormat.price) ?? "", "", ""])
        }
        for (cur, total) in totalsMinor.sorted(by: { $0.key < $1.key }) {
            rows.append(["furniture total", "", "\(pricedCounts[cur] ?? 0)", "", "", "", "", cur, "", ReportFormat.price(minor: total), "", ""])
        }
        rows.append(["walls", "Walls", "\(walls.count)", "", "", "", "", "", "", "",
                     ReportFormat.metres(walls.totalLengthMM), ReportFormat.squareMetres(walls.areaMM2)])
        for o in openings {
            rows.append(["openings", o.kind.rawValue, "\(o.count)", "\(o.width)", "", "\(o.height)", "", "", "", "", "", ""])
        }
        return rows
    }

    public func csv() -> String { ReportFormat.csv(header: Self.header, rows: tableRows) }

    public func markdown() -> String {
        var s = "# Bill of materials: \(ReportFormat.mdCell(projectName))\n\n"
        s += ReportFormat.markdownTable(header: Self.header, rows: tableRows, rightAligned: [2, 3, 4, 5, 8, 9, 10, 11])
        s += "\nWall area is one face per wall (axis length × height, capped at the level's clear height). Totals count priced pieces per currency. Unpriced pieces: \(unpricedCount)."
        if instancesWithoutDefinition > 0 { s += " Instances without definition (not listed): \(instancesWithoutDefinition)." }
        return s + "\n"
    }
}
