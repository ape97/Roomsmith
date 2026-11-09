import AppKit
import Foundation
import RealityKit
import RoomsmithCore

/// Highlight state of an object. Priority when several apply: selected > hover > collision.
enum SceneTint: Hashable {
    case none, hover, selected, collision

    static func resolve(selected: Bool, hovered: Bool, colliding: Bool) -> SceneTint {
        if selected { return .selected }
        if hovered { return .hover }
        if colliding { return .collision }
        return .none
    }
}

/// Which document material (or built-in default) a mesh slot uses.
enum MatKey: Hashable {
    case doc(UUID)
    case wallDefault, floorDefault, ceilingDefault, frameDefault, glass, glassFrosted, glassTinted, hardware, componentDefault

    static func of(_ id: UUID?, _ fallback: MatKey) -> MatKey { id.map { MatKey.doc($0) } ?? fallback }
}

/// Builds and caches RealityKit materials from document materials. Defaults mirror the OBJ/USDZ export
/// (`SceneExport`): neutral grey surfaces, warm white door and window frames, glass with 30 % opacity.
@MainActor
final class SceneMaterials {
    private struct CacheKey: Hashable {
        var key: MatKey
        var tint: SceneTint
        var rev: Int64
        var textured: Bool
        var scale: Int
        var metricUV: Bool
        /// Lamp glow in 1/1000 steps (nil = no glow), so equal glows share one material.
        var glow: SIMD3<Int>?
    }

    /// A procedural pattern with the relief maps derived from it (nil for flat patterns).
    private struct ProceduralSet {
        var color: TextureResource
        var normal: TextureResource?
        var roughness: TextureResource?
    }

    private var cache: [CacheKey: RealityKit.Material] = [:]
    /// Pattern parameters behind the cached materials that carry a procedural texture, so evicting the texture also drops them
    /// (a cached material keeps its texture alive).
    private var cacheProcedural: [CacheKey: ProceduralTexture.Params] = [:]
    private var textures: [UUID: TextureResource] = [:]
    /// Procedural pattern textures by parameters; rendering is deterministic, so equal parameters share one resource.
    private var proceduralTextures: [ProceduralTexture.Params: ProceduralSet] = [:]
    /// Least recently used first; keeps at most `proceduralLimit` textures (dragging a size slider makes many variants).
    private var proceduralOrder: [ProceduralTexture.Params] = []
    private static let proceduralLimit = 32
    private var loading: Set<UUID> = []
    private var failed: Set<UUID> = []
    /// Pattern textures being rendered in the background, and those that could not be made (not retried until the next reset).
    private var proceduralPending: Set<ProceduralTexture.Params> = []
    private var proceduralFailed: Set<ProceduralTexture.Params> = []
    /// Bumped by `invalidateTextures`; a load or render that started before it must not store its result (it belongs to
    /// the old project or package). `assetEpoch` does the same for one replaced or removed asset.
    private var epoch = 0
    private var assetEpoch: [UUID: Int] = [:]
    /// Textures that arrived since the scene last refreshed; reported in one batch (`onTexturesReady`).
    private var readyAssets: Set<UUID> = []
    private var readyParams: Set<ProceduralTexture.Params> = []
    private var flushScheduled = false

    /// Reads textures from the project package; nil until the project has a file.
    var packageURL: URL?
    /// Called (on the main actor, at most once per short interval) after textures finished loading or rendering, so the
    /// scene can re-skin what uses them. `takeReady()` says which ones.
    var onTexturesReady: (() -> Void)?

    /// True while textures are loading or rendering (or their refresh is about to run); snapshots wait for it.
    var isBusy: Bool { !loading.isEmpty || !proceduralPending.isEmpty || flushScheduled }

    private static let accent = SIMD3<Double>(0.25, 0.55, 1.0)

    func reset() {
        cache.removeAll(); cacheProcedural.removeAll()
        proceduralFailed.removeAll()  // a failed render gets another try after a reset
    }

    func invalidateTextures() {
        epoch += 1
        textures.removeAll(); loading.removeAll(); failed.removeAll(); cache.removeAll(); cacheProcedural.removeAll(); proceduralTextures.removeAll(); proceduralOrder.removeAll()
        proceduralPending.removeAll(); proceduralFailed.removeAll(); readyAssets.removeAll(); readyParams.removeAll()
    }

    /// Forgets only these assets (a replaced or removed texture); results of loads still running for them are discarded.
    /// The caller re-skins the materials that use them.
    func invalidate(assets ids: Set<UUID>) {
        for id in ids {
            textures[id] = nil; loading.remove(id); failed.remove(id); readyAssets.remove(id)
            assetEpoch[id, default: 0] += 1
        }
    }

    /// Drops the cached RealityKit materials built from these document materials (all tints), so the next request rebuilds them.
    func drop(materials ids: Set<UUID>) {
        for k in Array(cache.keys) {
            guard case .doc(let id) = k.key, ids.contains(id) else { continue }
            cache[k] = nil; cacheProcedural[k] = nil
        }
    }

    /// The textures that arrived since the last call.
    func takeReady() -> (assets: Set<UUID>, params: Set<ProceduralTexture.Params>) {
        defer { readyAssets.removeAll(); readyParams.removeAll() }
        return (readyAssets, readyParams)
    }

    private func markReady(asset: UUID? = nil, params: ProceduralTexture.Params? = nil) {
        if let asset { readyAssets.insert(asset) }
        if let params { readyParams.insert(params) }
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            // Textures that finish within one frame share a single refresh of the scene.
            try? await Task.sleep(for: .milliseconds(16))
            guard let self else { return }
            self.flushScheduled = false
            if !self.readyAssets.isEmpty || !self.readyParams.isEmpty { self.onTexturesReady?() }
        }
    }

    /// `opacityScale` multiplies the material's own opacity (wall transparency); 1 leaves it unchanged. `metricUV` is for
    /// meshes whose UVs are millimetres (merged furniture): the material then scales them by its texture tile. `glow` is the
    /// emissive colour of a switched-on lamp part (linear 0...1, already scaled to its strength).
    func material(_ key: MatKey, tint: SceneTint, project: Project, opacityScale: Double = 1, metricUV: Bool = false,
                  glow: SIMD3<Double>? = nil) -> RealityKit.Material {
        var spec = SceneMaterials.spec(for: key, project: project)
        var texture: TextureResource?
        var relief: ProceduralSet?
        if let tid = spec.textureAssetId {
            if let t = textures[tid] { texture = t } else { requestTexture(tid, project: project) }
        } else if let params = spec.procedural {
            relief = proceduralTexture(params)
            texture = relief?.color
        }
        // A pattern still rendering in the background shows the material's base colour (like the material editor preview).
        if spec.procedural != nil, texture == nil, let base = spec.baseColor { spec.color = base }
        let scale = Int((min(max(opacityScale, 0), 1) * 100).rounded())
        let glowKey = glow.map { SIMD3<Int>(($0 * 1000).rounded(.toNearestOrEven)) }
        let ck = CacheKey(key: key, tint: tint, rev: spec.rev, textured: texture != nil, scale: scale, metricUV: metricUV, glow: glowKey)
        if let m = cache[ck] { return m }
        spec.texture = texture
        spec.normalMap = relief?.normal
        spec.roughnessMap = relief?.roughness
        spec.uvPerMM = metricUV ? 1 / Double(max(spec.tileMM, 1)) : nil
        spec.glow = glow
        spec.opacity *= Double(scale) / 100
        let m = SceneMaterials.build(spec, tint: tint)
        cache[ck] = m
        if texture != nil, let params = spec.procedural { cacheProcedural[ck] = params }
        return m
    }

    /// Own opacity of the material a component uses, without any highlight tint (nil or a missing material: opaque grey).
    /// Decides whether a piece of furniture draws the component merged (opaque) or as its own entity (transparent).
    static func baseOpacity(ofMaterial id: UUID?, project: Project) -> Double {
        id.flatMap { project.material($0)?.opacity } ?? 1
    }

    /// Same threshold as `build`: below it the material blends.
    static func isTransparent(opacity: Double) -> Bool { opacity < 0.999 }

    // MARK: - Specs

    private struct Spec {
        var color: SIMD3<Double>
        var roughness: Double
        var metallic: Double
        var opacity: Double
        var textureAssetId: UUID?
        var texture: TextureResource?
        var rev: Int64
        var clearcoat = 0.0
        var specular = 0.5
        var anisotropy = 0.0
        var anisotropyAngle = 0.0
        var procedural: ProceduralTexture.Params?
        var uvAngleDeg = 0.0
        /// The material's own colour when `color` is white because a pattern texture supplies it.
        var baseColor: SIMD3<Double>?
        var tileMM: Int64 = 1000
        var normalMap: TextureResource?
        var roughnessMap: TextureResource?
        /// UV scale for millimetre UVs (1 / texture tile); nil when the mesh brings its own tiling.
        var uvPerMM: Double?
        var glow: SIMD3<Double>?
    }

    private static func spec(for key: MatKey, project: Project) -> Spec {
        func grey() -> Spec { Spec(color: SIMD3(204, 204, 204) / 255, roughness: 0.8, metallic: 0, opacity: 1, textureAssetId: nil, rev: -1) }
        switch key {
        case .doc(let id):
            guard let m = project.material(id) else { return grey() }
            let shading = MaterialShading.resolve(m)
            let procedural = m.textureAssetId == nil ? ProceduralTexture.params(for: m) : nil
            return Spec(color: procedural == nil ? SIMD3(Double(m.color.r), Double(m.color.g), Double(m.color.b)) / 255 : SIMD3(repeating: 1),
                        roughness: shading.roughness, metallic: shading.metallic, opacity: m.opacity,
                        textureAssetId: m.textureAssetId, rev: m.rev, clearcoat: shading.clearcoat, specular: shading.specular,
                        anisotropy: shading.anisotropy, anisotropyAngle: shading.anisotropyAngleDeg, procedural: procedural,
                        uvAngleDeg: m.patternAngleDeg,
                        baseColor: procedural == nil ? nil : SIMD3(Double(m.color.r), Double(m.color.g), Double(m.color.b)) / 255,
                        tileMM: m.textureTile)
        case .glass:
            return Spec(color: SIMD3(170, 200, 230) / 255, roughness: 0.1, metallic: 0, opacity: 0.3, textureAssetId: nil, rev: -2)
        case .glassFrosted:
            return Spec(color: SIMD3(225, 232, 238) / 255, roughness: 0.7, metallic: 0, opacity: 0.75, textureAssetId: nil, rev: -3)
        case .glassTinted:
            return Spec(color: SIMD3(70, 85, 95) / 255, roughness: 0.1, metallic: 0, opacity: 0.5, textureAssetId: nil, rev: -4)
        case .hardware:
            return Spec(color: SIMD3(176, 178, 182) / 255, roughness: 0.3, metallic: 1, opacity: 1, textureAssetId: nil, rev: -5,
                        specular: 0.8)
        case .frameDefault:
            // Painted joinery: a warm white satin lacquer so doors and frames read against the grey default wall.
            return Spec(color: SIMD3(240, 237, 230) / 255, roughness: 0.35, metallic: 0, opacity: 1, textureAssetId: nil, rev: -6,
                        clearcoat: 0.3, specular: 0.6)
        case .wallDefault, .floorDefault, .ceilingDefault, .componentDefault:
            return grey()
        }
    }

    /// Highlight look of one colour: the colour pulled towards the tint and an emissive glow. A tint never changes the
    /// opacity or the blending mode (switching opaque to transparent and back left pink remnants on screen).
    private static func tinted(color: SIMD3<Double>, tint: SceneTint) -> (SIMD3<Double>, SIMD3<Double>?) {
        var c = color
        var emissive: SIMD3<Double>?
        switch tint {
        case .none: break
        case .hover:
            c = c * 0.85 + SIMD3(repeating: 1) * 0.15
        case .selected:
            c = c * 0.65 + accent * 0.35
            emissive = accent * 0.25
        case .collision:
            c = c * 0.45 + SIMD3(1.0, 0.1, 0.1) * 0.55
            emissive = SIMD3(0.45, 0.02, 0.02)
        }
        return (c, emissive)
    }

    /// A loaded model's own material with the highlight applied, keeping its textures and every other property.
    /// Each material keeps its own colour, so a multi-material model stays recognisable while highlighted.
    static func highlighted(_ material: any RealityKit.Material, tint: SceneTint) -> any RealityKit.Material {
        guard tint != .none, var pbr = material as? PhysicallyBasedMaterial else { return material }
        let base = pbr.baseColor.tint.usingColorSpace(.sRGB) ?? .white
        let color = SIMD3(Double(base.redComponent), Double(base.greenComponent), Double(base.blueComponent))
        let (c, glow) = tinted(color: color, tint: tint)
        // A white-tinted textured material would barely change, so hovering adds a soft glow.
        let emissive = tint == .hover ? SIMD3(repeating: 0.4) : glow
        pbr.baseColor.tint = NSColor(srgbRed: c.x, green: c.y, blue: c.z, alpha: base.alphaComponent)
        if let e = emissive {
            pbr.emissiveColor = .init(color: NSColor(srgbRed: e.x, green: e.y, blue: e.z, alpha: 1))
            pbr.emissiveIntensity = 1
        }
        return pbr
    }

    private static func build(_ s: Spec, tint: SceneTint) -> RealityKit.Material {
        let (c, emissive) = tinted(color: s.color, tint: tint)
        var m = PhysicallyBasedMaterial()
        let color = NSColor(srgbRed: c.x, green: c.y, blue: c.z, alpha: 1)
        m.baseColor = .init(tint: color, texture: s.texture.map { .init($0) })
        let roughness = Float(min(max(s.roughness, 0.02), 1))
        if let r = s.roughnessMap {
            m.roughness = .init(scale: roughness, texture: .init(r))
        } else {
            m.roughness = .init(floatLiteral: roughness)
        }
        if let n = s.normalMap { m.normal = .init(texture: .init(n)) }
        m.metallic = .init(floatLiteral: Float(min(max(s.metallic, 0), 1)))
        m.clearcoat = .init(floatLiteral: Float(min(max(s.clearcoat, 0), 1)))
        m.specular = .init(floatLiteral: Float(min(max(s.specular, 0), 1)))
        if s.anisotropy > 0 {
            m.anisotropyLevel = .init(floatLiteral: Float(s.anisotropy))
            m.anisotropyAngle = .init(floatLiteral: Float(s.anisotropyAngle * .pi / 180))
        }
        let uvScale = Float(s.uvPerMM ?? 1)
        if s.uvAngleDeg != 0 || uvScale != 1 {
            m.textureCoordinateTransform = .init(offset: .zero, scale: SIMD2(uvScale, uvScale), rotation: Float(s.uvAngleDeg * .pi / 180))
        }
        if SceneMaterials.isTransparent(opacity: s.opacity) { m.blending = .transparent(opacity: .init(floatLiteral: Float(max(s.opacity, 0.02)))) }
        if let e = emissive {
            m.emissiveColor = .init(color: NSColor(srgbRed: e.x, green: e.y, blue: e.z, alpha: 1))
            m.emissiveIntensity = 1
        } else if let g = s.glow {
            // A lit lamp part: its own colour lit from inside, so the shade reads as glowing even in daylight.
            let k = max(g.x, g.y, g.z, 1)
            m.emissiveColor = .init(color: NSColor(srgbRed: min(g.x * c.x / k * 1.2, 1), green: min(g.y * c.y / k * 1.2, 1),
                                                   blue: min(g.z * c.z / k * 1.2, 1), alpha: 1))
            m.emissiveIntensity = Float(k)
        }
        return m
    }

    /// Unlit colour used by outlines and the gizmo.
    static func unlit(_ color: NSColor) -> UnlitMaterial {
        UnlitMaterial(color: color)
    }

    // MARK: - Textures

    /// The pattern texture if it is ready; otherwise starts rendering it in the background (up to 1024 px, too slow for
    /// the main thread) and returns nil until `onTexturesReady` reports it.
    private func proceduralTexture(_ params: ProceduralTexture.Params) -> ProceduralSet? {
        if let t = proceduralTextures[params] {
            if let i = proceduralOrder.firstIndex(of: params) { proceduralOrder.remove(at: i) }
            proceduralOrder.append(params)
            return t
        }
        requestProcedural(params)
        return nil
    }

    private func requestProcedural(_ params: ProceduralTexture.Params) {
        guard !proceduralFailed.contains(params), proceduralPending.insert(params).inserted else { return }
        let stamp = epoch
        Task { @MainActor [weak self] in
            let (pixels, maps) = await Task.detached(priority: .userInitiated) {
                let px = ProceduralTexture.render(params)
                return (px, ProceduralTexture.surfaceMaps(px, pattern: params.pattern))
            }.value
            guard let self, self.epoch == stamp else { return }   // invalidated meanwhile: the result is stale
            let image = ProceduralTexture.cgImage(pixels)
            let t = if let image { try? await TextureResource(image: image, options: .init(semantic: .color)) } else { TextureResource?.none }
            // Relief is optional: without it the pattern still shows, just flat.
            var normal: TextureResource?, rough: TextureResource?
            if let maps, let n = ProceduralTexture.cgImage(maps.normal, colorSpace: .linear), let r = ProceduralTexture.cgImage(maps.roughness, colorSpace: .linear) {
                normal = try? await TextureResource(image: n, options: .init(semantic: .normal))
                rough = try? await TextureResource(image: r, options: .init(semantic: .raw))
            }
            guard self.epoch == stamp else { return }
            self.proceduralPending.remove(params)
            guard let t else {
                self.proceduralFailed.insert(params)
                return
            }
            self.storeProcedural(params, ProceduralSet(color: t, normal: normal, roughness: rough))
            self.markReady(params: params)
        }
    }

    private func storeProcedural(_ params: ProceduralTexture.Params, _ t: ProceduralSet) {
        proceduralTextures[params] = t
        proceduralOrder.append(params)
        var evicted = Set<ProceduralTexture.Params>()
        while proceduralOrder.count > Self.proceduralLimit {
            let old = proceduralOrder.removeFirst()
            proceduralTextures[old] = nil
            evicted.insert(old)
        }
        if !evicted.isEmpty { dropCachedMaterials(using: evicted) }
    }

    /// Removes cached materials built with an evicted pattern texture; without this the cache would keep every texture a
    /// slider drag ever produced, whatever the LRU limit.
    private func dropCachedMaterials(using evicted: Set<ProceduralTexture.Params>) {
        for (k, params) in cacheProcedural where evicted.contains(params) {
            cache[k] = nil
            cacheProcedural[k] = nil
        }
    }

    private func requestTexture(_ assetId: UUID, project: Project) {
        guard !loading.contains(assetId), !failed.contains(assetId),
              let package = packageURL, let asset = project.asset(assetId) else { return }
        loading.insert(assetId)
        let url = ProjectPackage.assetURL(asset, in: package)
        let stamp = (epoch, assetEpoch[assetId] ?? 0)
        Task { @MainActor [weak self] in
            do {
                let t = try await TextureResource(contentsOf: url)
                // Invalidated while loading (other package, replaced or removed asset): drop the result.
                guard let self, self.epoch == stamp.0, (self.assetEpoch[assetId] ?? 0) == stamp.1 else { return }
                self.textures[assetId] = t
                self.loading.remove(assetId)
                self.markReady(asset: assetId)
            } catch {
                guard let self, self.epoch == stamp.0, (self.assetEpoch[assetId] ?? 0) == stamp.1 else { return }
                self.loading.remove(assetId)
                self.failed.insert(assetId)
            }
        }
    }
}
