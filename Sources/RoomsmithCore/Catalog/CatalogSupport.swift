import CryptoKit
import Foundation

/// Deterministic identifiers so built-in designs keep the same ids in every run, project and test.
enum StableID {
    static func uuid(_ text: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return bytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }
}

/// The shared colour palette of the built-in catalog. Original colours, stable ids.
enum Palette {
    private static func make(_ name: String, _ hex: String, roughness: Double = 0.7, metallic: Double = 0, opacity: Double = 1) -> Material {
        Material(id: StableID.uuid("material/\(name)"), name: name, color: RGBColor(hex: hex) ?? RGBColor(128, 128, 128),
                 roughness: roughness, metallic: metallic, opacity: opacity)
    }

    static let oak = make("Oak", "#C9A271", roughness: 0.65)
    static let walnut = make("Walnut", "#6B4A32", roughness: 0.6)
    static let birch = make("Birch", "#E2CBA0", roughness: 0.65)
    static let whiteLacquer = make("White lacquer", "#F2F2EE", roughness: 0.35)
    static let greyFabric = make("Grey fabric", "#8A8D91", roughness: 0.95)
    static let beigeFabric = make("Beige fabric", "#D5C8B0", roughness: 0.95)
    static let leather = make("Brown leather", "#7A4B2C", roughness: 0.5)
    static let blackMetal = make("Black metal", "#222427", roughness: 0.45, metallic: 0.6)
    static let chrome = make("Chrome", "#C9CED3", roughness: 0.15, metallic: 1)
    static let stainless = make("Stainless steel", "#A8ADB2", roughness: 0.3, metallic: 0.9)
    static let glass = make("Glass", "#CFE6EC", roughness: 0.05, opacity: 0.3)
    static let ceramic = make("White ceramic", "#F7F7F5", roughness: 0.15)
    static let leaf = make("Leaf green", "#4F7A3A", roughness: 0.85)
    static let soil = make("Soil", "#4A3A2C", roughness: 1)
    static let screen = make("Screen black", "#0E0F11", roughness: 0.1)
    static let blackPlastic = make("Black plastic", "#2B2C2E", roughness: 0.6)
    static let rug = make("Sand wool", "#C8B79A", roughness: 1)
    static let stone = make("Dark stone", "#4B4E52", roughness: 0.4)
    static let lampshade = make("Lampshade", "#F1E7D0", roughness: 0.9)
    static let linen = make("White linen", "#EEEBE3", roughness: 0.95)

    static let all: [Material] = [oak, walnut, birch, whiteLacquer, greyFabric, beigeFabric, leather, blackMetal, chrome,
                                  stainless, glass, ceramic, leaf, soil, screen, blackPlastic, rug, stone, lampshade, linen]
}

/// Collects the parts of one definition. Parts are given as closed ranges per axis (min…max, mm) in the
/// definition space (origin = footprint centre at the floor, front = −Y, back = +Y, Z up), which keeps joints flush.
struct PartBuilder {
    let key: String
    let size: Size3
    var hw: MM { size.width / 2 }
    var hd: MM { size.depth / 2 }
    var h: MM { size.height }

    private(set) var components: [Component] = []
    private var poses: [String: [UUID: ComponentPose]] = [:]
    private var stateNames: [String] = []
    private var stateSizes: [String: Size3] = [:]
    private var defaultStateName: String?
    var durationMs = 800

    init(key: String, size: Size3) { self.key = key; self.size = size }

    @discardableResult
    mutating func add(_ name: String, _ shape: PrimitiveShape = .box, x: ClosedRange<MM>, y: ClosedRange<MM>, z: ClosedRange<MM>,
                      _ material: UUID?, pivot: P3? = nil) -> UUID {
        let id = StableID.uuid("\(key)/part/\(name)")
        let sz = Size3(max(x.upperBound - x.lowerBound, 1), max(y.upperBound - y.lowerBound, 1), max(z.upperBound - z.lowerBound, 1))
        let pos = P3((x.lowerBound + x.upperBound) / 2, (y.lowerBound + y.upperBound) / 2, (z.lowerBound + z.upperBound) / 2)
        components.append(Component(id: id, name: name, shape: shape, position: pos, size: sz, pivot: pivot, materialId: material))
        return id
    }

    @discardableResult
    mutating func add(_ name: String, _ shape: PrimitiveShape = .box, x: ClosedRange<MM>, y: ClosedRange<MM>, z: ClosedRange<MM>,
                      _ material: Material, pivot: P3? = nil) -> UUID {
        add(name, shape, x: x, y: y, z: z, material.id, pivot: pivot)
    }

    func position(of id: UUID) -> P3 { components.first { $0.id == id }?.position ?? .zero }

    /// Declares a state; the first declared one is the default unless `asDefault` is set.
    mutating func state(_ name: String, size: Size3? = nil, asDefault: Bool = false) {
        if !stateNames.contains(name) { stateNames.append(name) }
        if let size { stateSizes[name] = size }
        if asDefault { defaultStateName = name }
    }

    mutating func pose(_ state: String, _ id: UUID, position: P3? = nil, rotation: R3? = nil, size: Size3? = nil, visible: Bool? = nil) {
        if !stateNames.contains(state) { stateNames.append(state) }
        poses[state, default: [:]][id] = ComponentPose(position: position, rotation: rotation, size: size, visible: visible)
    }

    func finish(name: String, category: String, tags: [String] = []) -> FurnitureDefinition {
        var def = FurnitureDefinition(id: StableID.uuid("\(key)/definition"), name: name, category: category, size: size, components: components)
        def.tags = tags
        let states = stateNames.map {
            FurnitureState(id: StableID.uuid("\(key)/state/\($0)"), name: $0, poses: poses[$0] ?? [:], size: stateSizes[$0])
        }
        def.states = states
        def.defaultStateId = (defaultStateName.flatMap { n in states.first { $0.name == n } } ?? states.first)?.id
        for a in states {
            for b in states where a.id != b.id {
                def.tracks.append(AnimationTrack(id: StableID.uuid("\(key)/track/\(a.name)>\(b.name)"), fromStateId: a.id, toStateId: b.id,
                                                 durationMs: durationMs, easing: .easeInOut))
            }
        }
        return def
    }
}
