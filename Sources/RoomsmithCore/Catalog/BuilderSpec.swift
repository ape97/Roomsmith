import Foundation

/// Templates offered by the furniture builder; each maps to one `ParametricBuilder` generator.
public enum BuilderTemplate: String, CaseIterable, Identifiable, Codable, Sendable {
    case cabinet, table, shelf, sofa, box
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }

    public var defaultSize: Size3 {
        switch self {
        case .cabinet: Size3(800, 500, 900)
        case .table: Size3(1400, 800, 740)
        case .shelf: Size3(800, 300, 1800)
        case .sofa: Size3(2000, 900, 850)
        case .box: Size3(500, 500, 500)
        }
    }
}

/// Parameters of all templates; each template reads the ones it needs.
public struct BuilderParams: Codable, Sendable, Equatable {
    public var width: MM = 800
    public var depth: MM = 500
    public var height: MM = 900
    public var shelves = 2
    public var doors = 2
    public var plinth: MM = 60
    public var legInset: MM = 40
    public var topThickness: MM = 30
    public var boards = 4
    public var armWidth: MM = 150
    public var seatHeight: MM = 420
    public var materialId: UUID? = BuiltinCatalog.materials.first { $0.name == "Oak" }?.id

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case width, depth, height, shelves, doors, plinth, legInset, topThickness, boards, armWidth, seatHeight, materialId
    }

    /// Missing keys keep their defaults, so specs written by other versions still load.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = try c.decodeIfPresent(MM.self, forKey: .width) ?? width
        depth = try c.decodeIfPresent(MM.self, forKey: .depth) ?? depth
        height = try c.decodeIfPresent(MM.self, forKey: .height) ?? height
        shelves = try c.decodeIfPresent(Int.self, forKey: .shelves) ?? shelves
        doors = try c.decodeIfPresent(Int.self, forKey: .doors) ?? doors
        plinth = try c.decodeIfPresent(MM.self, forKey: .plinth) ?? plinth
        legInset = try c.decodeIfPresent(MM.self, forKey: .legInset) ?? legInset
        topThickness = try c.decodeIfPresent(MM.self, forKey: .topThickness) ?? topThickness
        boards = try c.decodeIfPresent(Int.self, forKey: .boards) ?? boards
        armWidth = try c.decodeIfPresent(MM.self, forKey: .armWidth) ?? armWidth
        seatHeight = try c.decodeIfPresent(MM.self, forKey: .seatHeight) ?? seatHeight
        if c.contains(.materialId) { materialId = try c.decodeIfPresent(UUID.self, forKey: .materialId) }
    }

    /// `materialId` is written as an explicit null when it is nil: the synthesized encoder would omit the key, and the
    /// decoder reads a missing key as "default material (Oak)", so "no material" would turn into Oak on the next load.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(width, forKey: .width)
        try c.encode(depth, forKey: .depth)
        try c.encode(height, forKey: .height)
        try c.encode(shelves, forKey: .shelves)
        try c.encode(doors, forKey: .doors)
        try c.encode(plinth, forKey: .plinth)
        try c.encode(legInset, forKey: .legInset)
        try c.encode(topThickness, forKey: .topThickness)
        try c.encode(boards, forKey: .boards)
        try c.encode(armWidth, forKey: .armWidth)
        try c.encode(seatHeight, forKey: .seatHeight)
        try c.encode(materialId, forKey: .materialId)
    }

    public mutating func apply(defaultsOf t: BuilderTemplate) {
        let s = t.defaultSize
        width = s.width; depth = s.depth; height = s.height
    }

    public var size: Size3 { Size3(width, depth, height) }

    public func generate(_ t: BuilderTemplate, name: String) -> FurnitureDefinition {
        switch t {
        case .cabinet: ParametricBuilder.cabinet(name: name, size: size, shelves: shelves, doors: doors, plinth: plinth, materialId: materialId)
        case .table: ParametricBuilder.table(name: name, size: size, legInset: legInset, topThickness: topThickness, materialId: materialId)
        case .shelf: ParametricBuilder.shelf(name: name, size: size, boards: boards, materialId: materialId)
        case .sofa: ParametricBuilder.sofa(name: name, size: size, armWidth: armWidth, seatHeight: seatHeight, materialId: materialId)
        case .box: ParametricBuilder.box(name: name, size: size, materialId: materialId)
        }
    }
}

/// A parametric design: template plus parameters. Stored with library entries so an entry can be rebuilt and edited later.
public struct ParametricSpec: Codable, Sendable, Equatable {
    public var template: BuilderTemplate
    public var params: BuilderParams
    public init(template: BuilderTemplate, params: BuilderParams) { self.template = template; self.params = params }

    public func generate(name: String) -> FurnitureDefinition { params.generate(template, name: name) }
}
