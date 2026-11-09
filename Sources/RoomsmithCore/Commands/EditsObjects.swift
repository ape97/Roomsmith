import Foundation

/// Where a material is applied.
public enum MaterialSlot: Sendable, Hashable {
    case wallLeft, wallRight, wallBoth, roomFloor, roomCeiling, openingFrame, allComponents
    case component(UUID)

    /// Parses "wallLeft", "wall_left", "component:<uuid>" etc.
    public init?(string: String) {
        let s = string.replacingOccurrences(of: "_", with: "").lowercased()
        switch s {
        case "wallleft", "left": self = .wallLeft
        case "wallright", "right": self = .wallRight
        case "wallboth", "wall", "both": self = .wallBoth
        case "roomfloor", "floor": self = .roomFloor
        case "roomceiling", "ceiling": self = .roomCeiling
        case "openingframe", "frame": self = .openingFrame
        case "allcomponents", "all", "furniture": self = .allComponents
        default:
            if s.hasPrefix("component:"), let colon = string.firstIndex(of: ":"),
               let id = UUID(uuidString: String(string[string.index(after: colon)...])) {
                self = .component(id)
            } else { return nil }
        }
    }
}

public extension Project {
    // MARK: Reference points

    /// Points that describe an object's position in the plan (used for pivots and bounding boxes).
    func referencePoints(_ id: UUID) -> [P2] {
        if let i = instance(id) { return [i.position.xy] }
        if let w = wall(id) { return [w.start, w.end] }
        if let r = room(id) { return r.points }
        if let d = dimension(id) { return [d.a, d.b] }
        if let g = group(id) { return g.memberIds.compactMap { instance($0)?.position.xy } }
        if let o = opening(id), let w = wall(o.wallId) {
            let ax = Geo.axis(w.start, w.end)
            return [P2(rounding: w.start.v + ax.dir * Double(o.offset))]
        }
        if let b = background(id) { return [b.origin] }
        return []
    }

    /// Centre of the bounding box of the reference points of several objects.
    func boundsCenter(_ ids: [UUID]) -> P2? {
        let pts = ids.flatMap(referencePoints)
        guard let f = pts.first else { return nil }
        var lo = f, hi = f
        for p in pts { lo = P2(min(lo.x, p.x), min(lo.y, p.y)); hi = P2(max(hi.x, p.x), max(hi.y, p.y)) }
        return P2(rounding: (lo.v + hi.v) / 2)
    }

    /// Selected ids plus members of selected groups, without duplicates.
    private func expandGroups(_ ids: [UUID]) -> [UUID] {
        var out: [UUID] = []
        var seen = Set<UUID>()
        for id in ids {
            if seen.insert(id).inserted { out.append(id) }
            if let g = group(id) { for m in g.memberIds where seen.insert(m).inserted { out.append(m) } }
        }
        return out
    }

    // MARK: Move

    /// Moves objects by a delta (mm). Walls carry their openings; a lone opening slides along its wall.
    mutating func moveObjects(_ ids: [UUID], by d: P3) throws {
        let all = expandGroups(ids)
        for id in all { try ensureEditable(id) }
        let set = Set(all)
        for id in all {
            switch kind(of: id) {
            case .furniture:
                try modify(\.instances, id, "Furniture") { $0.position = $0.position + d }
            case .group:
                try modify(\.groups, id, "Group") { $0.origin = $0.origin + d }
            case .wall:
                try modify(\.walls, id, "Wall") { $0.start = $0.start + d.xy; $0.end = $0.end + d.xy }
            case .room:
                try modify(\.rooms, id, "Room") { $0.points = $0.points.map { $0 + d.xy } }
            case .dimension:
                try modify(\.dimensions, id, "Dimension") { $0.a = $0.a + d.xy; $0.b = $0.b + d.xy }
            case .background:
                try modify(\.backgrounds, id, "Background image") { $0.origin = $0.origin + d.xy }
            case .opening:
                guard let o = opening(id), !set.contains(o.wallId), let w = wall(o.wallId) else { continue }
                let ax = Geo.axis(w.start, w.end)
                let along = (d.xy.v * ax.dir).sum()
                try modify(\.openings, id, "Opening") { $0.offset += MM(along.rounded(.toNearestOrAwayFromZero)) }
            case .level:
                try modify(\.levels, id, "Level") { $0.elevation += d.z }
            default:
                throw CommandError.invalid("\(displayName(of: id)) cannot be moved", ids: [id])
            }
        }
    }

    /// Moves one object so that its reference point (furniture/group: position/origin; others: first point) lands on `to`.
    mutating func moveObject(_ id: UUID, to: P3) throws {
        let from: P3
        if let i = instance(id) { from = i.position }
        else if let g = group(id) { from = g.origin }
        else if let p = referencePoints(id).first { from = P3(p.x, p.y, to.z) }
        else { throw CommandError(.notFound, "Object \(id.uuidString.lowercased()) does not exist", ids: [id]) }
        try moveObjects([id], by: to - from)
    }

    // MARK: Rotate

    /// Rotates objects counter-clockwise by `deg` around `pivot` (default: the object itself, or the
    /// bounding-box centre of several objects).
    mutating func rotateObjects(_ ids: [UUID], by deg: Double, pivot: P2? = nil) throws {
        let all = expandGroups(ids)
        for id in all { try ensureEditable(id) }
        let pv: P2
        if let pivot { pv = pivot }
        else if ids.count == 1, let g = group(ids[0]) { pv = g.origin.xy }
        else if let c = boundsCenter(ids) { pv = c }
        else { throw CommandError.invalid("Nothing to rotate") }
        func rot(_ p: P2) -> P2 { Geo.rotate(p, around: pv, deg: deg) }
        for id in all {
            switch kind(of: id) {
            case .furniture:
                try modify(\.instances, id, "Furniture") { i in
                    let xy = rot(i.position.xy)
                    i.position = P3(xy.x, xy.y, i.position.z)
                    i.rotationDeg = Angle.normalized(i.rotationDeg + deg)
                }
            case .group:
                try modify(\.groups, id, "Group") { g in
                    let xy = rot(g.origin.xy)
                    g.origin = P3(xy.x, xy.y, g.origin.z)
                    g.rotationDeg = Angle.normalized(g.rotationDeg + deg)
                }
            case .wall: try modify(\.walls, id, "Wall") { $0.start = rot($0.start); $0.end = rot($0.end) }
            case .room: try modify(\.rooms, id, "Room") { $0.points = $0.points.map(rot) }
            case .dimension: try modify(\.dimensions, id, "Dimension") { $0.a = rot($0.a); $0.b = rot($0.b) }
            case .opening: continue // follows its wall
            default: throw CommandError.invalid("\(displayName(of: id)) cannot be rotated", ids: [id])
            }
        }
    }

    // MARK: Delete

    /// Deletes objects with their dependants. Returns all removed ids.
    @discardableResult
    mutating func deleteObjects(_ ids: [UUID]) throws -> [UUID] {
        var removed = Set<UUID>()
        var queue = ids
        let doomed = deletionSet(ids)
        while let id = queue.popLast() {
            if removed.contains(id) { continue }
            guard let k = kind(of: id) else { throw CommandError(.notFound, "Object \(id.uuidString.lowercased()) does not exist", ids: [id]) }
            switch k {
            case .level:
                if levels.count - levels.filter({ removed.contains($0.id) }).count <= 1 {
                    throw CommandError.invalid("The last level cannot be deleted", ids: [id])
                }
                if level(id)?.locked == true { throw CommandError.locked(id) }
                queue += walls.filter { $0.levelId == id }.map(\.id) + rooms.filter { $0.levelId == id }.map(\.id)
                    + instances.filter { $0.levelId == id }.map(\.id) + groups.filter { $0.levelId == id }.map(\.id)
                    + dimensions.filter { $0.levelId == id }.map(\.id) + backgrounds.filter { $0.levelId == id }.map(\.id)
                // Children first, the level itself last.
                queue.insert(id, at: 0)
                if queue.count > 1 && queue.dropFirst().contains(where: { !removed.contains($0) && kind(of: $0) != nil }) {
                    // Process children; the level is removed when it comes up again with no children left.
                    if walls.contains(where: { $0.levelId == id }) || rooms.contains(where: { $0.levelId == id })
                        || instances.contains(where: { $0.levelId == id }) || groups.contains(where: { $0.levelId == id })
                        || dimensions.contains(where: { $0.levelId == id }) || backgrounds.contains(where: { $0.levelId == id }) {
                        continue
                    }
                }
                levels.removeAll { $0.id == id }
            case .wall:
                try ensureEditable(id)
                let ops = openings.filter { $0.wallId == id }.map(\.id)
                openings.removeAll { $0.wallId == id }
                removed.formUnion(ops)
                walls.removeAll { $0.id == id }
            case .opening:
                try ensureEditable(id); openings.removeAll { $0.id == id }
            case .room:
                try ensureEditable(id); rooms.removeAll { $0.id == id }
            case .dimension:
                try ensureEditable(id); dimensions.removeAll { $0.id == id }
            case .background:
                try ensureEditable(id); backgrounds.removeAll { $0.id == id }
            case .furniture:
                try ensureEditable(id)
                if let gid = instance(id)?.groupId, let gi = groups.firstIndex(where: { $0.id == gid }) {
                    groups[gi].memberIds.removeAll { $0 == id }
                    for c in groups[gi].configurations.indices { groups[gi].configurations[c].poses[id] = nil }
                    if groups[gi].memberIds.isEmpty { removed.insert(gid); groups.remove(at: gi) }
                }
                instances.removeAll { $0.id == id }
            case .group:
                try ensureEditable(id)
                let members = group(id)?.memberIds ?? []
                for m in members where isLocked(m) { throw CommandError.locked(m) }
                instances.removeAll { members.contains($0.id) }
                removed.formUnion(members)
                groups.removeAll { $0.id == id }
            case .material:
                for i in walls.indices {
                    if walls[i].leftMaterialId == id { walls[i].leftMaterialId = nil }
                    if walls[i].rightMaterialId == id { walls[i].rightMaterialId = nil }
                }
                for i in rooms.indices {
                    if rooms[i].floorMaterialId == id { rooms[i].floorMaterialId = nil }
                    if rooms[i].ceilingMaterialId == id { rooms[i].ceilingMaterialId = nil }
                }
                for i in openings.indices where openings[i].frameMaterialId == id { openings[i].frameMaterialId = nil }
                for i in instances.indices { instances[i].materialOverrides = instances[i].materialOverrides.filter { $0.value != id } }
                for g in groups.indices {
                    for c in groups[g].configurations.indices {
                        for (mid, var pose) in groups[g].configurations[c].poses {
                            guard let ov = pose.materialOverrides, ov.values.contains(id) else { continue }
                            pose.materialOverrides = ov.filter { $0.value != id }
                            groups[g].configurations[c].poses[mid] = pose
                        }
                    }
                }
                for d in definitions.indices {
                    for c in definitions[d].components.indices where definitions[d].components[c].materialId == id {
                        definitions[d].components[c].materialId = nil
                    }
                }
                pruneOptionMaterial(id)
                materials.removeAll { $0.id == id }
            case .definition:
                let users = instances.filter { $0.definitionId == id && !doomed.contains($0.id) }.count // users deleted in the same call (incl. group members, level contents) do not block
                if users > 0 { throw CommandError.invalid("This furniture definition is used by \(users) placed object(s)", ids: [id]) }
                for i in products.indices where products[i].definitionId == id { products[i].definitionId = nil }
                definitions.removeAll { $0.id == id }
            case .product:
                for i in instances.indices where instances[i].productId == id { instances[i].productId = nil }
                for i in groups.indices where groups[i].productId == id { groups[i].productId = nil }
                for i in definitions.indices where definitions[i].productId == id { definitions[i].productId = nil }
                products.removeAll { $0.id == id }
            case .asset:
                let usedByMesh = definitions.contains { $0.components.contains { $0.meshAssetId == id } }
                if usedByMesh || backgrounds.contains(where: { $0.assetId == id }) {
                    throw CommandError.invalid("This asset is still in use", ids: [id])
                }
                for i in materials.indices where materials[i].textureAssetId == id { materials[i].textureAssetId = nil }
                for i in products.indices {
                    products[i].fileAssetIds.removeAll { $0 == id }
                    products[i].imageAssetIds.removeAll { $0 == id }
                }
                assets.removeAll { $0.id == id }
            case .camera:
                cameras.removeAll { $0.id == id }
            }
            removed.insert(id)
        }
        return Array(removed)
    }

    // MARK: Duplicate

    /// Copies objects (walls with their openings, groups with their members) shifted by `offset`.
    /// Returns old id → new id.
    @discardableResult
    mutating func duplicateObjects(_ ids: [UUID], offset: P3 = P3(500, 500, 0)) throws -> [UUID: UUID] {
        var map: [UUID: UUID] = [:]
        var done = Set<UUID>()
        for id in ids where !done.contains(id) {
            done.insert(id)
            switch kind(of: id) {
            case .furniture:
                guard var c = instance(id) else { continue }
                if let g = c.groupId, ids.contains(g) { continue } // copied with its group
                c.id = UUID(); c.groupId = nil; c.position = c.position + offset; c.locked = false
                instances.append(c); map[id] = c.id
            case .wall:
                guard var c = wall(id) else { continue }
                c.id = UUID(); c.start = c.start + offset.xy; c.end = c.end + offset.xy; c.locked = false
                walls.append(c); map[id] = c.id
                for o in openings where o.wallId == id {
                    var oc = o; oc.id = UUID(); oc.wallId = c.id
                    openings.append(oc); map[o.id] = oc.id
                }
            case .room:
                guard var c = room(id) else { continue }
                c.id = UUID(); c.points = c.points.map { $0 + offset.xy }; c.name += " copy"
                rooms.append(c); map[id] = c.id
            case .dimension:
                guard var c = dimension(id) else { continue }
                c.id = UUID(); c.a = c.a + offset.xy; c.b = c.b + offset.xy
                dimensions.append(c); map[id] = c.id
            case .group:
                guard var g = group(id) else { continue }
                let ng = UUID()
                var memberMap: [UUID: UUID] = [:]
                for m in g.memberIds {
                    guard var c = instance(m) else { continue }
                    c.id = UUID(); c.groupId = ng; c.position = c.position + offset; c.locked = false
                    instances.append(c); memberMap[m] = c.id; map[m] = c.id
                }
                g.id = ng; g.origin = g.origin + offset; g.name += " copy"; g.locked = false
                g.memberIds = g.memberIds.compactMap { memberMap[$0] }
                g.configurations = g.configurations.map { cfg in
                    var n = cfg; n.id = UUID()
                    n.poses = Dictionary(uniqueKeysWithValues: cfg.poses.compactMap { k, v in memberMap[k].map { ($0, v) } })
                    if g.activeConfigurationId == cfg.id { g.activeConfigurationId = n.id }
                    return n
                }
                groups.append(g); map[id] = ng
            case .opening, .level, .material, .definition, .product, .asset, .camera, .background:
                throw CommandError.invalid("\(displayName(of: id)) cannot be duplicated", ids: [id])
            case nil:
                throw CommandError(.notFound, "Object \(id.uuidString.lowercased()) does not exist", ids: [id])
            }
        }
        return map
    }

    // MARK: Materials, lock, visibility

    mutating func setMaterial(_ ids: [UUID], slot: MaterialSlot, materialId: UUID?) throws {
        if let materialId, material(materialId) == nil { throw CommandError.notFound("Material", materialId) }
        for id in ids {
            try ensureEditable(id)
            switch (kind(of: id), slot) {
            case (.wall, .wallLeft): try modify(\.walls, id, "Wall") { $0.leftMaterialId = materialId }
            case (.wall, .wallRight): try modify(\.walls, id, "Wall") { $0.rightMaterialId = materialId }
            case (.wall, .wallBoth): try modify(\.walls, id, "Wall") { $0.leftMaterialId = materialId; $0.rightMaterialId = materialId }
            case (.room, .roomFloor): try modify(\.rooms, id, "Room") { $0.floorMaterialId = materialId }
            case (.room, .roomCeiling): try modify(\.rooms, id, "Room") { $0.ceilingMaterialId = materialId }
            case (.opening, .openingFrame): try modify(\.openings, id, "Opening") { $0.frameMaterialId = materialId }
            case (.furniture, .allComponents):
                guard let inst = instance(id), let def = definition(inst.definitionId) else { continue }
                try modify(\.instances, id, "Furniture") { i in
                    for c in def.components { i.materialOverrides[c.id] = materialId }
                    if materialId == nil { i.materialOverrides = [:] }
                }
            case (.furniture, .component(let cid)):
                guard let inst = instance(id), let def = definition(inst.definitionId) else { continue }
                if !def.components.contains(where: { $0.id == cid }) { throw CommandError.notFound("Component", cid) }
                try modify(\.instances, id, "Furniture") { $0.materialOverrides[cid] = materialId }
            case (.group, _):
                try setMaterial(group(id)?.memberIds ?? [], slot: slot, materialId: materialId)
            default:
                throw CommandError.invalid("Slot \(slot) does not apply to \(displayName(of: id))", ids: [id])
            }
        }
    }

    /// Locks or unlocks (allowed on locked objects).
    mutating func setLocked(_ ids: [UUID], _ locked: Bool) throws {
        for id in ids {
            switch kind(of: id) {
            case .wall: try modify(\.walls, id, "Wall") { $0.locked = locked }
            case .furniture: try modify(\.instances, id, "Furniture") { $0.locked = locked }
            case .group: try modify(\.groups, id, "Group") { $0.locked = locked }
            case .level: try modify(\.levels, id, "Level") { $0.locked = locked }
            case nil: throw CommandError(.notFound, "Object \(id.uuidString.lowercased()) does not exist", ids: [id])
            default: throw CommandError.invalid("\(displayName(of: id)) cannot be locked", ids: [id])
            }
        }
    }

    mutating func setVisible(_ ids: [UUID], _ visible: Bool) throws {
        for id in ids {
            switch kind(of: id) {
            case .furniture: try modify(\.instances, id, "Furniture") { $0.visible = visible }
            case .group: for m in group(id)?.memberIds ?? [] { try modify(\.instances, m, "Furniture") { $0.visible = visible } }
            case .level: try modify(\.levels, id, "Level") { $0.visible = visible }
            case .background: try modify(\.backgrounds, id, "Background image") { $0.visible = visible }
            case nil: throw CommandError(.notFound, "Object \(id.uuidString.lowercased()) does not exist", ids: [id])
            default: throw CommandError.invalid("\(displayName(of: id)) cannot be hidden", ids: [id])
            }
        }
    }

    // MARK: Groups and configurations

    /// Groups furniture. Origin = centre of the members' bounding box (z = lowest member), rotation 0.
    @discardableResult
    mutating func groupObjects(_ ids: [UUID], name: String, id gid: UUID = UUID()) throws -> UUID {
        var seenIds = Set<UUID>()
        let ids = ids.filter { seenIds.insert($0).inserted }
        guard ids.count >= 1 else { throw CommandError.invalid("Select at least one piece of furniture to group") }
        var levelId: UUID?
        for id in ids {
            try ensureEditable(id)
            guard let i = instance(id) else { throw CommandError.invalid("Only furniture can be grouped", ids: [id]) }
            if i.groupId != nil { throw CommandError.invalid("\(i.name) is already in a group", ids: [id]) }
            if let l = levelId, l != i.levelId { throw CommandError.invalid("Grouped furniture must be on the same level", ids: [id]) }
            levelId = i.levelId
        }
        let c = boundsCenter(ids) ?? P2(0, 0)
        let z = ids.compactMap { instance($0)?.position.z }.min() ?? 0
        groups.append(FurnitureGroup(id: gid, name: name, levelId: levelId!, origin: P3(c.x, c.y, z), memberIds: ids))
        for i in instances.indices where ids.contains(instances[i].id) { instances[i].groupId = gid }
        return gid
    }

    /// Dissolves a group; members stay where they are. Returns the former members.
    @discardableResult
    mutating func ungroup(_ gid: UUID) throws -> [UUID] {
        try ensureEditable(gid)
        guard let g = group(gid) else { throw CommandError.notFound("Group", gid) }
        for i in instances.indices where instances[i].groupId == gid { instances[i].groupId = nil }
        groups.removeAll { $0.id == gid }
        return g.memberIds
    }

    /// Stores the current member poses relative to the group (replaces a configuration with the same name).
    @discardableResult
    mutating func saveConfiguration(groupId: UUID, name: String) throws -> UUID {
        try ensureEditable(groupId)
        guard let g = group(groupId) else { throw CommandError.notFound("Group", groupId) }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { throw CommandError.invalid("Configuration name must not be empty", ids: [groupId]) }
        var poses: [UUID: MemberPose] = [:]
        for m in g.memberIds {
            guard let i = instance(m) else { continue }
            let rel = Geo.rotate(i.position.xy - g.origin.xy, around: P2(0, 0), deg: -g.rotationDeg)
            poses[m] = MemberPose(local: P3(rel.x, rel.y, i.position.z - g.origin.z),
                                  rotationDeg: Angle.normalized(i.rotationDeg - g.rotationDeg),
                                  visible: i.visible, stateId: i.stateId, materialOverrides: i.materialOverrides)
        }
        var cid = UUID()
        try modify(\.groups, groupId, "Group") { gr in
            if let k = gr.configurations.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                cid = gr.configurations[k].id
                gr.configurations[k].poses = poses
            } else {
                gr.configurations.append(GroupConfiguration(id: cid, name: name, poses: poses))
            }
            gr.activeConfigurationId = cid
        }
        return cid
    }

    /// Applies a stored configuration at the group's current origin and rotation.
    mutating func activateConfiguration(groupId: UUID, configurationId: UUID) throws {
        try ensureEditable(groupId)
        guard let g = group(groupId) else { throw CommandError.notFound("Group", groupId) }
        guard let cfg = g.configurations.first(where: { $0.id == configurationId }) else {
            throw CommandError(.notFound, "Configuration \(configurationId.uuidString.lowercased()) does not exist", ids: [groupId])
        }
        for (m, pose) in cfg.poses {
            guard instance(m) != nil else { continue }
            if instance(m)?.locked == true { throw CommandError.locked(m) }
            let xy = g.origin.xy + Geo.rotate(pose.local.xy, around: P2(0, 0), deg: g.rotationDeg)
            try modify(\.instances, m, "Furniture") { i in
                i.position = P3(xy.x, xy.y, g.origin.z + pose.local.z)
                i.rotationDeg = Angle.normalized(g.rotationDeg + pose.rotationDeg)
                i.visible = pose.visible
                i.stateId = pose.stateId
                if let mo = pose.materialOverrides { i.materialOverrides = mo }
            }
        }
        try modify(\.groups, groupId, "Group") { $0.activeConfigurationId = configurationId }
    }

    mutating func deleteConfiguration(groupId: UUID, configurationId: UUID) throws {
        try ensureEditable(groupId)
        try modify(\.groups, groupId, "Group") { g in
            guard g.configurations.contains(where: { $0.id == configurationId }) else {
                throw CommandError(.notFound, "Configuration does not exist", ids: [groupId])
            }
            g.configurations.removeAll { $0.id == configurationId }
            if g.activeConfigurationId == configurationId { g.activeConfigurationId = nil }
        }
    }

    /// Adds furniture to an existing group.
    mutating func addToGroup(_ gid: UUID, _ ids: [UUID]) throws {
        var seenIds = Set<UUID>()
        let ids = ids.filter { seenIds.insert($0).inserted }
        try ensureEditable(gid)
        guard let g = group(gid) else { throw CommandError.notFound("Group", gid) }
        for id in ids {
            try ensureEditable(id)
            guard let i = instance(id) else { throw CommandError.invalid("Only furniture can be grouped", ids: [id]) }
            if i.groupId != nil { throw CommandError.invalid("\(i.name) is already in a group", ids: [id]) }
            if i.levelId != g.levelId { throw CommandError.invalid("Grouped furniture must be on the same level", ids: [id]) }
        }
        try modify(\.groups, gid, "Group") { $0.memberIds += ids }
        for i in instances.indices where ids.contains(instances[i].id) { instances[i].groupId = gid }
    }
}
