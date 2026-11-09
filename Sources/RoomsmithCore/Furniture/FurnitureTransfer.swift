import CryptoKit
import Foundation

/// Furniture packed up to travel between two open projects: the instances, their designs, the materials and products
/// they use and the bytes of every referenced asset. Codable, so it can also sit on a pasteboard or in a file.
public struct FurnitureTransfer: Codable, Sendable, Equatable {
    public struct AssetPayload: Codable, Sendable, Equatable {
        public var asset: ProjectAsset
        public var data: Data
        public init(asset: ProjectAsset, data: Data) { self.asset = asset; self.data = data }
    }

    /// Placement and per-instance properties; `definitionId` points into `definitions` of the source project.
    public struct InstanceProps: Codable, Sendable, Equatable {
        public var definitionId: UUID
        public var name: String
        public var position: P3
        public var rotationDeg: Double
        public var size: Size3?
        public var materialOverrides: [UUID: UUID]
        public var stateId: UUID?
        public var productId: UUID?
        public var visible: Bool
        public var locked: Bool
        public var lightOn: Bool = true
        public var allowsOverlap: Bool = false
        /// Option group id → chosen choice id, in the ids of the source project.
        public var optionSelection: [UUID: UUID] = [:]

        init(definitionId: UUID, name: String, position: P3, rotationDeg: Double, size: Size3?, materialOverrides: [UUID: UUID],
             stateId: UUID?, productId: UUID?, visible: Bool, locked: Bool, lightOn: Bool = true, allowsOverlap: Bool = false,
             optionSelection: [UUID: UUID] = [:]) {
            self.optionSelection = optionSelection
            self.definitionId = definitionId; self.name = name; self.position = position; self.rotationDeg = rotationDeg
            self.size = size; self.materialOverrides = materialOverrides; self.stateId = stateId; self.productId = productId
            self.visible = visible; self.locked = locked; self.lightOn = lightOn; self.allowsOverlap = allowsOverlap
        }

        /// Transfers written before `lightOn`, `allowsOverlap` and `optionSelection` existed carry none of these keys; they get the defaults.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            definitionId = try c.decode(UUID.self, forKey: .definitionId)
            name = try c.decode(String.self, forKey: .name)
            position = try c.decode(P3.self, forKey: .position)
            rotationDeg = try c.decode(Double.self, forKey: .rotationDeg)
            size = try c.decodeIfPresent(Size3.self, forKey: .size)
            materialOverrides = try c.decode([UUID: UUID].self, forKey: .materialOverrides)
            stateId = try c.decodeIfPresent(UUID.self, forKey: .stateId)
            productId = try c.decodeIfPresent(UUID.self, forKey: .productId)
            visible = try c.decode(Bool.self, forKey: .visible)
            locked = try c.decode(Bool.self, forKey: .locked)
            lightOn = try c.decodeIfPresent(Bool.self, forKey: .lightOn) ?? true
            allowsOverlap = try c.decodeIfPresent(Bool.self, forKey: .allowsOverlap) ?? false
            optionSelection = try c.decodeIfPresent([UUID: UUID].self, forKey: .optionSelection) ?? [:]
        }
    }

    public var sourceProjectName: String
    public var definitions: [FurnitureDefinition]
    public var materials: [Material]
    public var products: [CatalogProduct]
    public var assets: [AssetPayload]
    public var instances: [InstanceProps]

    public var isEmpty: Bool { instances.isEmpty }

    /// Middle of the packed furniture in the plan (mm); drops use it to put the group under the pointer.
    public var center: P2? {
        guard !instances.isEmpty else { return nil }
        let xs = instances.map(\.position.x), ys = instances.map(\.position.y)
        return P2((xs.min()! + xs.max()!) / 2, (ys.min()! + ys.max()!) / 2)
    }

    // MARK: Export

    /// Packs the furniture `ids` (instances, or groups which stand for their members) of `project`.
    /// `packageURL` is the project's package; it is needed only when assets (meshes, textures, product files) are involved.
    public static func make(from project: Project, ids: [UUID], packageURL: URL?) throws -> FurnitureTransfer {
        var instanceIds: [UUID] = []
        for id in ids {
            if project.instance(id) != nil { instanceIds.append(id) }
            else if let g = project.group(id) { instanceIds.append(contentsOf: g.memberIds.filter { project.instance($0) != nil }) }
            else { throw CommandError.invalid("Only furniture and groups can be transferred", ids: [id]) }
        }
        var seen = Set<UUID>()
        instanceIds = instanceIds.filter { seen.insert($0).inserted }
        guard !instanceIds.isEmpty else { throw CommandError.invalid("Nothing to transfer: no furniture in the given ids") }

        var t = FurnitureTransfer(sourceProjectName: project.name, definitions: [], materials: [], products: [], assets: [], instances: [])
        var materialIds: [UUID] = [], productIds: [UUID] = [], assetIds: [UUID] = []
        func noteUnique(_ id: UUID?, _ list: inout [UUID]) { if let id, !list.contains(id) { list.append(id) } }

        for iid in instanceIds {
            guard let inst = project.instance(iid) else { continue }
            guard let def = project.definition(inst.definitionId) else { throw CommandError.notFound("Definition", inst.definitionId) }
            if !t.definitions.contains(where: { $0.id == def.id }) {
                t.definitions.append(def)
                for c in def.components { noteUnique(c.materialId, &materialIds); noteUnique(c.meshAssetId, &assetIds) }
                for g in def.optionGroups { for ch in g.choices { for e in ch.effects.values { noteUnique(e.materialId, &materialIds) } } }
                noteUnique(def.productId, &productIds)
            }
            for m in inst.materialOverrides.values { noteUnique(m, &materialIds) }
            noteUnique(inst.productId, &productIds)
            t.instances.append(InstanceProps(definitionId: def.id, name: inst.name, position: inst.position, rotationDeg: inst.rotationDeg,
                                             size: inst.size, materialOverrides: inst.materialOverrides, stateId: inst.stateId,
                                             productId: inst.productId, visible: inst.visible, locked: inst.locked,
                                             lightOn: inst.lightOn, allowsOverlap: inst.allowsOverlap,
                                             optionSelection: inst.optionSelection))
        }
        for mid in materialIds {
            guard let m = project.material(mid) else { continue }  // built-in palette entries are not project materials
            t.materials.append(m)
            noteUnique(m.textureAssetId, &assetIds)
        }
        for pid in productIds {
            guard let p = project.product(pid) else { continue }
            t.products.append(p)
            for a in p.fileAssetIds + p.imageAssetIds { noteUnique(a, &assetIds) }
        }
        for aid in assetIds {
            guard let a = project.asset(aid) else { continue }
            guard let packageURL else {
                throw CommandError.invalid("Save the source project first: its models and textures are stored in the project file")
            }
            let url = ProjectPackage.assetURL(a, in: packageURL)
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                throw CommandError.invalid("The file of asset \"\(a.originalName)\" is missing in the source project")
            }
            t.assets.append(AssetPayload(asset: a, data: data))
        }
        return t
    }

    // MARK: Import

    /// What an import created.
    public struct ImportResult: Sendable {
        public var instanceIds: [UUID]
        /// Designs the import added. A design the project already had (built-in by key, or an identical own one) is not
        /// listed and not added again.
        public var definitionIds: [UUID]
    }

    /// Writes the asset bytes into the target package and returns the stored assets by source asset id plus the files created.
    static func stageAssets(_ payloads: [AssetPayload], into packageURL: URL) throws -> (stored: [UUID: ProjectAsset], created: [URL]) {
        var stored: [UUID: ProjectAsset] = [:]
        var created: [URL] = []
        let fm = FileManager.default
        do {
            for p in payloads {
                let hex = SHA256.hash(data: p.data).map { String(format: "%02x", $0) }.joined()
                guard hex == p.asset.sha256 else {
                    throw CommandError.invalid("Asset \"\(p.asset.originalName)\" is damaged (checksum mismatch)")
                }
                var a = p.asset
                a.id = UUID()
                try fm.createDirectory(at: ProjectPackage.assetsDir(packageURL), withIntermediateDirectories: true)
                let dest = ProjectPackage.assetURL(a, in: packageURL)
                if !fm.fileExists(atPath: dest.path) {
                    try p.data.write(to: dest, options: .atomic)
                    created.append(dest)
                }
                stored[p.asset.id] = a
            }
        } catch {
            for u in created { try? fm.removeItem(at: u) }
            throw error
        }
        return (stored, created)
    }

    /// Adds the transferred furniture to `p` with fresh ids everywhere, except that a design the project already has is
    /// reused instead of copied: a built-in one by catalog key, an own one when it is the same design under other ids
    /// (`FurnitureDefinition.isSameDesign`, no product link). So placing or pasting the same piece again adds no design.
    /// `stored` maps source asset ids to the assets staged in the target package. Instances land on `levelId`, shifted by
    /// `offset` (mm) in the plan. With `restOnFurniture` a transfer of exactly one piece stands on the furniture under its new
    /// position (`RestingSurface`); it keeps its own height elsewhere.
    mutating func importInto(_ p: inout Project, stored: [UUID: ProjectAsset], levelId: UUID, offset: P2,
                             restOnFurniture: Bool = false) throws -> ImportResult {
        // Assets: addAsset de-duplicates by content, so the returned id may be an existing one.
        var assetMap: [UUID: UUID] = [:]
        var assetSha: [UUID: String] = [:]
        for payload in assets {
            guard let s = stored[payload.asset.id] else { throw CommandError.invalid("Asset \"\(payload.asset.originalName)\" was not staged") }
            assetMap[payload.asset.id] = p.addAsset(s)
            assetSha[payload.asset.id] = payload.asset.sha256
        }
        func mapAsset(_ id: UUID?) throws -> UUID? {
            guard let id else { return nil }
            guard let m = assetMap[id] else { throw CommandError.invalid("Transfer is incomplete: asset \(id.uuidString.lowercased()) is missing") }
            return m
        }

        // Materials: reuse an equal material of the target (texture compared by content hash), else add a copy.
        var materialMap: [UUID: UUID] = [:]
        func mapMaterial(_ id: UUID?) throws -> UUID? {
            guard let id else { return nil }
            if let m = materialMap[id] { return m }
            guard var m = materials.first(where: { $0.id == id }) else { return nil }
            let sourceSha = m.textureAssetId.flatMap { assetSha[$0] }
            if let same = p.materials.first(where: { c in
                c.sameLook(as: m) && c.textureAssetId.flatMap({ p.asset($0)?.sha256 }) == sourceSha
            }) {
                materialMap[id] = same.id
                return same.id
            }
            m.id = UUID()
            m.textureAssetId = try mapAsset(m.textureAssetId)
            m.rev = 0
            materialMap[id] = p.addMaterial(m)
            return m.id
        }

        // Products: copied once per source product; files and images travel along, rooms do not.
        var productMap: [UUID: UUID?] = [:]
        var defMap: [UUID: UUID] = [:]
        func mapProduct(_ id: UUID?) throws -> UUID? {
            guard let id else { return nil }
            if let m = productMap[id] { return m }
            guard var prod = products.first(where: { $0.id == id }) else { return nil }
            prod.id = UUID()
            prod.fileAssetIds = try prod.fileAssetIds.compactMap { try mapAsset($0) }
            prod.imageAssetIds = try prod.imageAssetIds.compactMap { try mapAsset($0) }
            prod.definitionId = prod.definitionId.flatMap { defMap[$0] }
            prod.roomIds = []
            prod.rev = 0
            productMap[id] = p.addProduct(prod)
            return prod.id
        }

        // Definitions: a built-in design of the target with the same key and identical component/state ids is reused.
        var reused = Set<UUID>()
        var compMaps: [UUID: [UUID: UUID]] = [:]
        var stateMaps: [UUID: [UUID: UUID]] = [:]
        var optionMaps: [UUID: [UUID: UUID]] = [:]   // option group and choice ids of the source → fresh ids
        var created: [UUID] = []
        for src in definitions {
            if let key = src.catalogKey,
               let existing = p.definitions.first(where: {
                   $0.catalogKey == key && Set($0.components.map(\.id)) == Set(src.components.map(\.id))
                       && Set($0.states.map(\.id)) == Set(src.states.map(\.id))
               }) {
                defMap[src.id] = existing.id
                reused.insert(src.id)
                productMap[src.productId ?? UUID()] = existing.productId
                continue
            }
            let newId = UUID()
            defMap[src.id] = newId
            var comp: [UUID: UUID] = [:]
            for c in src.components { comp[c.id] = UUID() }
            var state: [UUID: UUID] = [:]
            for s in src.states { state[s.id] = UUID() }
            var option: [UUID: UUID] = [:]
            for g in src.optionGroups { option[g.id] = UUID(); for ch in g.choices { option[ch.id] = UUID() } }
            compMaps[src.id] = comp
            stateMaps[src.id] = state
            optionMaps[src.id] = option
        }
        func remapPoses(_ poses: [UUID: ComponentPose], _ comp: [UUID: UUID]) -> [UUID: ComponentPose] {
            var out: [UUID: ComponentPose] = [:]
            for (k, v) in poses { if let n = comp[k] { out[n] = v } }
            return out
        }
        for src in definitions where !reused.contains(src.id) {
            guard let newId = defMap[src.id], let comp = compMaps[src.id], let state = stateMaps[src.id],
                  let option = optionMaps[src.id] else { continue }
            var d = src
            d.id = newId
            d.rev = 0
            d.builtin = false
            d.catalogKey = nil
            d.components = try src.components.map { c in
                var n = c
                n.id = comp[c.id] ?? c.id
                n.materialId = try mapMaterial(c.materialId)
                n.meshAssetId = try mapAsset(c.meshAssetId)
                return n
            }
            d.states = src.states.map { s in
                var n = s
                n.id = state[s.id] ?? s.id
                n.poses = remapPoses(s.poses, comp)
                return n
            }
            d.defaultStateId = src.defaultStateId.flatMap { state[$0] }
            d.tracks = src.tracks.map { tr in
                var n = tr
                n.id = UUID()
                n.fromStateId = tr.fromStateId.flatMap { state[$0] }
                n.toStateId = state[tr.toStateId] ?? tr.toStateId
                n.keyframes = tr.keyframes.map { AnimationTrack.Keyframe(t: $0.t, poses: remapPoses($0.poses, comp)) }
                return n
            }
            d.optionGroups = try src.optionGroups.map { g in
                var ng = g
                ng.id = option[g.id] ?? g.id
                ng.defaultChoiceId = g.defaultChoiceId.flatMap { option[$0] }
                ng.choices = try g.choices.map { ch in
                    var nc = ch
                    nc.id = option[ch.id] ?? ch.id
                    nc.effects = [:]
                    for (k, e) in ch.effects {
                        guard let nk = comp[k] else { continue }
                        nc.effects[nk] = OptionEffect(materialId: try mapMaterial(e.materialId), visible: e.visible)
                    }
                    return nc
                }
                return ng
            }
            // An identical own design (same parts, states, options; ids ignored) is used instead of a second copy. A design
            // with a product link is always copied, because the link would have to be copied too.
            if src.productId == nil, let twin = p.ownTwin(of: d) {
                func byIndex<T>(_ a: [T], _ b: [T], _ id: (T) -> UUID) -> [UUID: UUID] {
                    Dictionary(zip(a, b).map { (id($0), id($1)) }, uniquingKeysWith: { x, _ in x })
                }
                defMap[src.id] = twin.id
                compMaps[src.id] = byIndex(src.components, twin.components) { $0.id }
                stateMaps[src.id] = byIndex(src.states, twin.states) { $0.id }
                var twinOptions = byIndex(src.optionGroups, twin.optionGroups) { $0.id }
                for (g, tg) in zip(src.optionGroups, twin.optionGroups) {
                    twinOptions.merge(byIndex(g.choices, tg.choices) { $0.id }, uniquingKeysWith: { x, _ in x })
                }
                optionMaps[src.id] = twinOptions
                continue
            }
            d.productId = try mapProduct(src.productId)
            p.addDefinition(d)
            created.append(newId)
        }
        var newInstances: [UUID] = []
        for props in instances {
            guard let targetDef = defMap[props.definitionId] else { throw CommandError.notFound("Definition", props.definitionId) }
            let isReused = reused.contains(props.definitionId)
            let comp = compMaps[props.definitionId] ?? [:]
            let state = stateMaps[props.definitionId] ?? [:]
            let option = optionMaps[props.definitionId] ?? [:]
            var pos = props.position
            pos.x += offset.x; pos.y += offset.y
            let id = try p.addInstance(definitionId: targetDef, levelId: levelId, position: pos, rotationDeg: props.rotationDeg,
                                       name: props.name, size: props.size)
            guard let idx = p.instances.firstIndex(where: { $0.id == id }) else { continue }
            var overrides: [UUID: UUID] = [:]
            for (k, v) in props.materialOverrides {
                guard let key = isReused ? k : comp[k], let value = try mapMaterial(v) else { continue }
                overrides[key] = value
            }
            p.instances[idx].materialOverrides = overrides
            // Always set from the source (also nil): addInstance would otherwise fill in the default state and the
            // definition's product.
            p.instances[idx].stateId = props.stateId.flatMap { isReused ? $0 : state[$0] }
            p.instances[idx].groupId = nil
            p.instances[idx].productId = try props.productId.flatMap { try mapProduct($0) }
            p.instances[idx].visible = props.visible
            p.instances[idx].locked = props.locked
            p.instances[idx].lightOn = props.lightOn
            p.instances[idx].allowsOverlap = props.allowsOverlap
            // A reused built-in design keeps its ids; keep only the choices it really has.
            var selection: [UUID: UUID] = [:]
            for (g, c) in props.optionSelection {
                if isReused {
                    if p.definition(targetDef)?.optionGroups.first(where: { $0.id == g })?.choices.contains(where: { $0.id == c }) == true { selection[g] = c }
                } else if let ng = option[g], let nc = option[c] {
                    selection[ng] = nc
                }
            }
            p.instances[idx].optionSelection = selection
            if restOnFurniture, instances.count == 1 {
                let inst = p.instances[idx]
                p.instances[idx].position.z = RestingSurface.z(for: inst, at: inst.position.xy, in: p, wasResting: false)
            }
            newInstances.append(id)
        }
        return ImportResult(instanceIds: newInstances, definitionIds: created)
    }
}

// MARK: - Copy and move between two stores

/// Runs transfers between two open documents. Each side gets its own command and so its own undo step.
@MainActor
public enum FurnitureTransferService {
    public struct Outcome: Sendable {
        public var newIds: [UUID]
        /// Move only: the originals are gone from the source. False when the copy stands but deleting failed.
        public var sourceRemoved: Bool
        /// Move only: why deleting failed.
        public var deleteError: String?
    }

    /// Imports `transfer` into `target` as one command. `targetPackage` is the target's package URL (nil while unsaved).
    @discardableResult
    public static func importTransfer(_ transfer: FurnitureTransfer, into target: DocumentStore, targetPackage: URL?, levelId: UUID,
                                      offset: P2 = P2(0, 0), options: CommandOptions = .user,
                                      undoName: String = "Paste furniture", restOnFurniture: Bool = false) throws -> [UUID] {
        var staged: (stored: [UUID: ProjectAsset], created: [URL]) = ([:], [])
        if !transfer.assets.isEmpty {
            guard let targetPackage else {
                throw CommandError.invalid("Save the target project first: its models and textures are stored in the project file")
            }
            staged = try FurnitureTransfer.stageAssets(transfer.assets, into: targetPackage)
        }
        var copy = transfer
        do {
            let result = try target.apply(undoName, options: options) { p in
                try copy.importInto(&p, stored: staged.stored, levelId: levelId, offset: offset, restOnFurniture: restOnFurniture)
            }
            return result.value.instanceIds
        } catch {
            // Only files this call created; same content that was there before stays.
            for u in staged.created { try? FileManager.default.removeItem(at: u) }
            throw error
        }
    }

    public static func copy(ids: [UUID], from source: DocumentStore, sourcePackage: URL?, to target: DocumentStore, targetPackage: URL?,
                            levelId: UUID, offset: P2 = P2(0, 0), options: CommandOptions = .user,
                            prebuilt: FurnitureTransfer? = nil) throws -> Outcome {
        let t = try prebuilt ?? FurnitureTransfer.make(from: source.project, ids: ids, packageURL: sourcePackage)
        let new = try importTransfer(t, into: target, targetPackage: targetPackage, levelId: levelId, offset: offset, options: options)
        return Outcome(newIds: new, sourceRemoved: false, deleteError: nil)
    }

    /// Copy into the target first (own undo step), then delete in the source (own undo step). If the delete fails the
    /// copy stays and the outcome says why.
    public static func move(ids: [UUID], from source: DocumentStore, sourcePackage: URL?, to target: DocumentStore, targetPackage: URL?,
                            levelId: UUID, offset: P2 = P2(0, 0), options: CommandOptions = .user,
                            prebuilt: FurnitureTransfer? = nil) throws -> Outcome {
        var out = try copy(ids: ids, from: source, sourcePackage: sourcePackage, to: target, targetPackage: targetPackage,
                           levelId: levelId, offset: offset, options: options, prebuilt: prebuilt)
        do {
            try source.run("Move furniture to another project", options: options) { p in _ = try p.deleteObjects(ids) }
            out.sourceRemoved = true
        } catch {
            out.deleteError = (error as? CommandError)?.message ?? "\(error)"
        }
        return out
    }
}
