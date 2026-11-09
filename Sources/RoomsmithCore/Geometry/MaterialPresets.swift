import Foundation

/// A named bundle of material parameters. Applying it overwrites the look parameters and keeps name, id and
/// (for presets without own colours, such as paints and glass) the colour.
public struct MaterialPreset: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var group: String
    var color: RGBColor?
    var color2: RGBColor?
    var roughness: Double
    var metallic: Double = 0
    var opacity: Double = 1
    var finish: MaterialFinish = .matte
    var pattern: MaterialPattern = .none
    var patternSize: MM = 100
    var grout: MM = 3
    var textureTile: MM = 1000
    var clearcoat: Double = 0
    var specular: Double = 0.5
}

public enum MaterialPresets {
    private static func c(_ hex: String) -> RGBColor { RGBColor(hex: hex) ?? RGBColor(200, 200, 200) }

    public static let all: [MaterialPreset] = [
        MaterialPreset(id: "paint-matt", name: "Wall paint, matt", group: "Paint", roughness: 0.95, finish: .matte, specular: 0.3),
        MaterialPreset(id: "paint-satin", name: "Wall paint, satin", group: "Paint", roughness: 0.55, finish: .satin, specular: 0.5),
        MaterialPreset(id: "wallpaper-stripes", name: "Wallpaper, stripes", group: "Wallpaper", color: c("#E9E1D0"), color2: c("#CFC2A6"),
                       roughness: 0.9, pattern: .stripes, patternSize: 100, specular: 0.3),
        MaterialPreset(id: "wallpaper-grid", name: "Wallpaper, grid", group: "Wallpaper", color: c("#EDEAE2"), color2: c("#B9B4A6"),
                       roughness: 0.9, pattern: .grid, patternSize: 125, grout: 4, specular: 0.3),
        MaterialPreset(id: "tiles-white", name: "Tiles, white", group: "Tiles", color: c("#F2F2EE"), color2: c("#A8A8A4"),
                       roughness: 0.25, finish: .polished, pattern: .tiles, patternSize: 250, grout: 3, clearcoat: 0.4, specular: 0.6),
        MaterialPreset(id: "tiles-anthracite", name: "Tiles, anthracite", group: "Tiles", color: c("#4A4C50"), color2: c("#8C8E90"),
                       roughness: 0.4, finish: .satin, pattern: .tiles, patternSize: 500, grout: 4, specular: 0.5),
        MaterialPreset(id: "wood-oak", name: "Wood, oak", group: "Wood", color: c("#D8B787"), color2: c("#9C7442"),
                       roughness: 0.55, finish: .satin, pattern: .wood, patternSize: 140, grout: 2, clearcoat: 0.15),
        MaterialPreset(id: "wood-walnut", name: "Wood, walnut", group: "Wood", color: c("#7A5232"), color2: c("#3E2614"),
                       roughness: 0.5, finish: .satin, pattern: .wood, patternSize: 160, grout: 2, clearcoat: 0.2),
        MaterialPreset(id: "wood-ash", name: "Wood, ash", group: "Wood", color: c("#EAD9B8"), color2: c("#BFA77C"),
                       roughness: 0.6, finish: .satin, pattern: .wood, patternSize: 120, grout: 2, clearcoat: 0.1),
        MaterialPreset(id: "fabric", name: "Fabric, woven", group: "Textile", color: c("#8C93A0"), color2: c("#767D8A"),
                       roughness: 0.95, pattern: .fabric, patternSize: 12, textureTile: 200, specular: 0.2),
        MaterialPreset(id: "leather", name: "Leather", group: "Textile", color: c("#6B3F25"),
                       roughness: 0.5, pattern: .leather, patternSize: 12, textureTile: 300, clearcoat: 0.1, specular: 0.55),
        MaterialPreset(id: "metal-brushed", name: "Metal, brushed", group: "Metal", color: c("#BFC3C8"),
                       roughness: 0.35, metallic: 1, finish: .brushed, specular: 0.6),
        MaterialPreset(id: "metal-polished", name: "Metal, polished", group: "Metal", color: c("#D6D8DC"),
                       roughness: 0.1, metallic: 1, finish: .polished, clearcoat: 0.3, specular: 0.7),
        MaterialPreset(id: "glass-clear", name: "Glass, clear", group: "Glass", color: c("#AAC8E6"),
                       roughness: 0.05, opacity: 0.25, finish: .polished, specular: 0.7),
        MaterialPreset(id: "glass-frosted", name: "Glass, frosted", group: "Glass", color: c("#E4EEF4"),
                       roughness: 0.85, opacity: 0.6, finish: .matte, specular: 0.3),
        MaterialPreset(id: "glass-tinted", name: "Glass, tinted", group: "Glass", color: c("#56707F"),
                       roughness: 0.1, opacity: 0.45, finish: .polished, specular: 0.6),
        MaterialPreset(id: "plastic-matt", name: "Plastic, matt", group: "Plastic", roughness: 0.8, finish: .matte, specular: 0.4),
        MaterialPreset(id: "plastic-glossy", name: "Plastic, glossy", group: "Plastic", roughness: 0.2, finish: .polished, clearcoat: 0.5, specular: 0.6),
    ]

    public static func preset(_ id: String) -> MaterialPreset? {
        let key = id.lowercased()
        return all.first { $0.id == key } ?? all.first { $0.name.lowercased() == key }
    }

    /// Writes the preset's look into `m`. Colours stay when the preset has none; an imported image texture is dropped
    /// (it would hide the preset). Name, id and revision are untouched.
    public static func apply(_ p: MaterialPreset, to m: inout Material) {
        if let c = p.color { m.color = c }
        m.color2 = p.color2
        m.roughness = p.roughness; m.metallic = p.metallic; m.opacity = p.opacity
        m.finish = p.finish; m.pattern = p.pattern
        m.patternSize = p.patternSize; m.patternAngleDeg = 0; m.grout = p.grout
        m.textureTile = p.textureTile
        m.clearcoat = p.clearcoat; m.specular = p.specular
        m.textureAssetId = nil
        m.preset = p.id
    }
}

/// Shading values a renderer uses for a material: the stored parameters with the finish applied.
public struct MaterialShading: Sendable, Equatable {
    public var roughness: Double
    public var metallic: Double
    public var clearcoat: Double
    public var specular: Double
    /// 0 = isotropic; brushed metal stretches highlights along `anisotropyAngleDeg`.
    public var anisotropy: Double
    public var anisotropyAngleDeg: Double

    public static func resolve(_ m: Material) -> MaterialShading {
        func unit(_ v: Double) -> Double { v.isFinite ? min(max(v, 0), 1) : 0 }
        var rough = unit(m.roughness), coat = unit(m.clearcoat), aniso = 0.0
        switch m.finish {
        case .matte: break
        case .satin: rough *= 0.8
        case .brushed: aniso = 0.8
        case .polished: rough *= 0.5; coat = max(coat, 0.3)
        }
        return MaterialShading(roughness: rough, metallic: unit(m.metallic), clearcoat: coat, specular: unit(m.specular),
                               anisotropy: aniso, anisotropyAngleDeg: m.patternAngleDeg)
    }
}
