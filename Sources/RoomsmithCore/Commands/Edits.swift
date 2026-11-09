import Foundation

/// Document edits. Each is a pure mutation of a `Project` used inside `DocumentStore.apply`; invariants are
/// checked afterwards by `Validator`, lock rules here.
public extension Project {
    // MARK: Generic helpers

    mutating func modify<T: Identifiable>(_ kp: WritableKeyPath<Project, [T]>, _ id: UUID, _ what: String,
                                          _ body: (inout T) throws -> Void) throws where T.ID == UUID {
        guard let i = self[keyPath: kp].firstIndex(where: { $0.id == id }) else { throw CommandError.notFound(what, id) }
        try body(&self[keyPath: kp][i])
    }

    /// True if the object, its group or its level is locked.
    func isLocked(_ id: UUID) -> Bool {
        if let lid = levelId(of: id), level(lid)?.locked == true { return true }
        if let w = wall(id) { return w.locked }
        if let o = opening(id) { return wall(o.wallId)?.locked ?? false }
        if let i = instance(id) { return i.locked || (i.groupId.flatMap { group($0)?.locked } ?? false) }
        if let g = group(id) { return g.locked }
        return false
    }

    func ensureEditable(_ id: UUID) throws {
        if kind(of: id) == nil { throw CommandError(.notFound, "Object \(id.uuidString.lowercased()) does not exist", ids: [id]) }
        if isLocked(id) { throw CommandError.locked(id) }
    }

    func ensureLevel(_ id: UUID) throws {
        guard let l = level(id) else { throw CommandError.notFound("Level", id) }
        if l.locked { throw CommandError.locked(id) }
    }

    // MARK: Levels

    @discardableResult
    mutating func addLevel(name: String, elevation: MM? = nil, height: MM = 2500, id: UUID = UUID()) -> UUID {
        let top = levels.map { $0.elevation + $0.height }.max() ?? 0
        levels.append(Level(id: id, name: name, elevation: elevation ?? top, height: height))
        return id
    }

    mutating func updateLevel(_ id: UUID, name: String? = nil, elevation: MM? = nil, height: MM? = nil,
                              visible: Bool? = nil, locked: Bool? = nil) throws {
        try modify(\.levels, id, "Level") { l in
            if let name { l.name = name }
            if let elevation { l.elevation = elevation }
            if let height { l.height = height }
            if let visible { l.visible = visible }
            if let locked { l.locked = locked }
        }
    }

    // MARK: Walls

    @discardableResult
    mutating func addWall(levelId: UUID, start: P2, end: P2, thickness: MM? = nil, height: MM? = nil, id: UUID = UUID()) throws -> UUID {
        try ensureLevel(levelId)
        walls.append(Wall(id: id, levelId: levelId, start: start, end: end,
                          thickness: thickness ?? settings.defaultWallThickness, height: height ?? settings.defaultWallHeight))
        return id
    }

    /// Walls along a polyline; `closed` adds the segment from the last point back to the first.
    @discardableResult
    mutating func addWalls(levelId: UUID, points: [P2], closed: Bool, thickness: MM? = nil, height: MM? = nil) throws -> [UUID] {
        guard points.count >= 2 else { throw CommandError.invalid("A wall polyline needs at least 2 points") }
        if closed && points.count < 3 { throw CommandError.invalid("A closed wall outline needs at least 3 points") }
        var ids: [UUID] = []
        for i in 0..<(points.count - 1) {
            ids.append(try addWall(levelId: levelId, start: points[i], end: points[i + 1], thickness: thickness, height: height))
        }
        if closed { ids.append(try addWall(levelId: levelId, start: points[points.count - 1], end: points[0], thickness: thickness, height: height)) }
        return ids
    }

    /// Updates a wall. With `moveJoined`, walls sharing a moved end point follow it.
    mutating func updateWall(_ id: UUID, start: P2? = nil, end: P2? = nil, thickness: MM? = nil, height: MM? = nil,
                             leftMaterialId: UUID?? = nil, rightMaterialId: UUID?? = nil, moveJoined: Bool = true) throws {
        try ensureEditable(id)
        guard let old = wall(id) else { throw CommandError.notFound("Wall", id) }
        try modify(\.walls, id, "Wall") { w in
            if let start { w.start = start }
            if let end { w.end = end }
            if let thickness { w.thickness = thickness }
            if let height { w.height = height }
            if let leftMaterialId { w.leftMaterialId = leftMaterialId }
            if let rightMaterialId { w.rightMaterialId = rightMaterialId }
        }
        guard moveJoined else { return }
        var moves: [(P2, P2)] = []
        if let start, start != old.start { moves.append((old.start, start)) }
        if let end, end != old.end { moves.append((old.end, end)) }
        for (from, to) in moves {
            for i in walls.indices where walls[i].id != id && walls[i].levelId == old.levelId {
                let touches = walls[i].start == from || walls[i].end == from
                if !touches { continue }
                if isLocked(walls[i].id) { throw CommandError(.locked, "A joined wall is locked", ids: [walls[i].id]) }
                if walls[i].start == from { walls[i].start = to }
                if walls[i].end == from { walls[i].end = to }
            }
        }
    }

    /// Splits a wall at the point nearest to `at`. Openings go to the part they lie in.
    @discardableResult
    mutating func splitWall(_ id: UUID, at p: P2) throws -> (UUID, UUID) {
        try ensureEditable(id)
        guard let w = wall(id) else { throw CommandError.notFound("Wall", id) }
        let r = Geo.pointSegment(p.v, w.start.v, w.end.v)
        let len = wallLength(w)
        let splitAt = r.t * len
        guard splitAt >= 1, splitAt <= len - 1 else { throw CommandError.invalid("The split point must lie inside the wall", ids: [id]) }
        let sp = P2(rounding: r.closest)
        let cut = Double(Geo.distance(w.start, sp))
        for o in openings where o.wallId == id {
            let a = Double(o.offset) - Double(o.width) / 2, b = Double(o.offset) + Double(o.width) / 2
            if a < cut && b > cut { throw CommandError.invalid("Cannot split a wall through an opening", ids: [id, o.id]) }
        }
        var second = w
        second.id = UUID()
        second.start = sp
        try modify(\.walls, id, "Wall") { $0.end = sp }
        walls.append(second)
        let cutMM = MM(cut.rounded(.toNearestOrAwayFromZero))
        for i in openings.indices where openings[i].wallId == id && Double(openings[i].offset) > cut {
            openings[i].wallId = second.id
            openings[i].offset -= cutMM
        }
        return (id, second.id)
    }

    // MARK: Rooms

    @discardableResult
    mutating func addRoom(levelId: UUID, name: String, points: [P2], id: UUID = UUID()) throws -> UUID {
        try ensureLevel(levelId)
        rooms.append(Room(id: id, levelId: levelId, name: name, points: points))
        return id
    }

    mutating func updateRoom(_ id: UUID, name: String? = nil, points: [P2]? = nil, floorMaterialId: UUID?? = nil,
                             ceilingMaterialId: UUID?? = nil, showFloor: Bool? = nil, showCeiling: Bool? = nil) throws {
        try ensureEditable(id)
        try modify(\.rooms, id, "Room") { r in
            if let name { r.name = name }
            if let points { r.points = points }
            if let floorMaterialId { r.floorMaterialId = floorMaterialId }
            if let ceilingMaterialId { r.ceilingMaterialId = ceilingMaterialId }
            if let showFloor { r.showFloor = showFloor }
            if let showCeiling { r.showCeiling = showCeiling }
        }
    }

    // MARK: Openings

    /// Adds a door, window or plain opening. `offset` is the centre along the wall from its start; nil centres it.
    @discardableResult
    mutating func addOpening(wallId: UUID, kind: OpeningKind, offset: MM? = nil, width: MM, height: MM, sill: MM? = nil,
                             name: String = "", style: OpeningStyle? = nil, handle: OpeningHandle? = nil, frameWidth: MM? = nil,
                             mullionCols: Int? = nil, mullionRows: Int? = nil, glassType: OpeningGlass? = nil,
                             id: UUID = UUID()) throws -> UUID {
        try ensureEditable(wallId)
        guard let w = wall(wallId) else { throw CommandError.notFound("Wall", wallId) }
        let off = offset ?? MM((wallLength(w) / 2).rounded(.toNearestOrAwayFromZero))
        let s = sill ?? (kind == .window ? 900 : 0)
        var o = Opening(id: id, wallId: wallId, kind: kind, name: name, offset: off, width: width, height: height, sill: s)
        try Self.applyDetail(&o, style: style, handle: handle, frameWidth: frameWidth, mullionCols: mullionCols,
                             mullionRows: mullionRows, glassType: glassType)
        if style != nil, handle == nil { giveOpenableHandle(&o) }
        openings.append(o)
        return id
    }

    /// A window that can be opened but has no handle gets a lever, so a new tilt-and-turn window or balcony door has
    /// something to grip. Only runs when the caller set the style and left the handle alone: an explicit `none` stays.
    private func giveOpenableHandle(_ o: inout Opening) {
        guard o.kind == .window, o.handle == .none, WindowProfile.isMovableStyle(o.style),
              let w = wall(o.wallId), Meshes.windowMotion(o, wall: w)?.movable == true else { return }
        o.handle = .lever
    }

    mutating func updateOpening(_ id: UUID, kind: OpeningKind? = nil, name: String? = nil, offset: MM? = nil, width: MM? = nil,
                                height: MM? = nil, sill: MM? = nil, flipped: Bool? = nil, inward: Bool? = nil,
                                frameMaterialId: UUID?? = nil, wallId: UUID? = nil, style: OpeningStyle? = nil,
                                handle: OpeningHandle? = nil, frameWidth: MM? = nil, mullionCols: Int? = nil,
                                mullionRows: Int? = nil, glassType: OpeningGlass? = nil) throws {
        try ensureEditable(id)
        if let wallId { try ensureEditable(wallId) }
        try modify(\.openings, id, "Opening") { o in
            if let kind {
                o.kind = kind
                // A style of the old kind falls back to the new kind's default unless the caller names one.
                if style == nil, !o.style.isValid(for: kind) { o.style = OpeningStyle.defaultStyle(for: kind) }
            }
            try Self.applyDetail(&o, style: style, handle: handle, frameWidth: frameWidth, mullionCols: mullionCols,
                                 mullionRows: mullionRows, glassType: glassType)
            if let name { o.name = name }
            if let offset { o.offset = offset }
            if let width { o.width = width }
            if let height { o.height = height }
            if let sill { o.sill = sill }
            if let flipped { o.flipped = flipped }
            if let inward { o.inward = inward }
            if let frameMaterialId { o.frameMaterialId = frameMaterialId }
            if let wallId { o.wallId = wallId }
        }
        if style != nil, handle == nil, let i = openings.firstIndex(where: { $0.id == id }) {
            var o = openings[i]
            giveOpenableHandle(&o)
            openings[i] = o
        }
    }

    static let frameWidthRange: ClosedRange<MM> = 20 ... 150
    static let mullionRange: ClosedRange<Int> = 0 ... 6

    /// Applies and validates the detail fields of an opening (style must suit its kind).
    private static func applyDetail(_ o: inout Opening, style: OpeningStyle?, handle: OpeningHandle?, frameWidth: MM?,
                                    mullionCols: Int?, mullionRows: Int?, glassType: OpeningGlass?) throws {
        if let style {
            guard style.isValid(for: o.kind) else {
                let ok = OpeningStyle.styles(for: o.kind).map(\.rawValue).joined(separator: ", ")
                throw CommandError.invalid("Style \(style.rawValue) does not fit a \(o.kind.rawValue); use one of: \(ok)", ids: [o.id])
            }
            o.style = style
        }
        if let handle { o.handle = handle }
        if let frameWidth {
            guard frameWidthRange.contains(frameWidth) else {
                throw CommandError.range("Frame width must be \(frameWidthRange.lowerBound) to \(frameWidthRange.upperBound) mm", ids: [o.id])
            }
            o.frameWidth = frameWidth
        }
        if let mullionCols {
            guard mullionRange.contains(mullionCols) else { throw CommandError.range("Mullion columns must be 0 to 6", ids: [o.id]) }
            o.mullionCols = mullionCols
        }
        if let mullionRows {
            guard mullionRange.contains(mullionRows) else { throw CommandError.range("Mullion rows must be 0 to 6", ids: [o.id]) }
            o.mullionRows = mullionRows
        }
        if let glassType { o.glassType = glassType }
    }

    // MARK: Dimensions

    @discardableResult
    mutating func addDimension(levelId: UUID, a: P2, b: P2, offset: MM = 300, id: UUID = UUID()) throws -> UUID {
        try ensureLevel(levelId)
        dimensions.append(Dimension(id: id, levelId: levelId, a: a, b: b, offset: offset))
        return id
    }

    mutating func updateDimension(_ id: UUID, a: P2? = nil, b: P2? = nil, offset: MM? = nil) throws {
        try ensureEditable(id)
        try modify(\.dimensions, id, "Dimension") { d in
            if let a { d.a = a }
            if let b { d.b = b }
            if let offset { d.offset = offset }
        }
    }

    // MARK: Materials, definitions, products, assets, backgrounds

    @discardableResult
    mutating func addMaterial(_ m: Material) -> UUID { materials.append(m); return m.id }
    mutating func updateMaterial(_ id: UUID, _ body: (inout Material) throws -> Void) throws {
        try modify(\.materials, id, "Material") { m in let keep = m.id; try body(&m); m.id = keep }
    }

    /// Applies a built-in material preset (see `MaterialPresets`) to a material; keeps its name and colour unless the preset sets one.
    mutating func applyMaterialPreset(_ materialId: UUID, preset presetId: String) throws {
        guard let preset = MaterialPresets.preset(presetId) else {
            throw CommandError.invalid("Unknown material preset \(presetId); see material.list_presets", ids: [materialId])
        }
        try updateMaterial(materialId) { m in MaterialPresets.apply(preset, to: &m) }
    }

    @discardableResult
    mutating func addDefinition(_ d: FurnitureDefinition) -> UUID { definitions.append(d); return d.id }
    mutating func updateDefinition(_ id: UUID, _ body: (inout FurnitureDefinition) throws -> Void) throws {
        try modify(\.definitions, id, "Definition") { d in let keep = d.id; try body(&d); d.id = keep }
        // Instances in a state that no longer exists fall back to the base pose.
        guard let d = definition(id) else { return }
        let sids = Set(d.states.map(\.id))
        let cids = Set(d.components.map(\.id))
        for i in instances.indices where instances[i].definitionId == id {
            if let s = instances[i].stateId, !sids.contains(s) { instances[i].stateId = d.defaultStateId }
            instances[i].materialOverrides = instances[i].materialOverrides.filter { cids.contains($0.key) }
        }
        // Option effects on removed parts or materials go; so do selections of removed groups or choices.
        pruneOptionGroups(definitionId: id)
    }

    /// Places an instance of a definition. The position is the footprint centre; z is the bottom.
    @discardableResult
    mutating func addInstance(definitionId: UUID, levelId: UUID, position: P3, rotationDeg: Double = 0, name: String? = nil,
                              size: Size3? = nil, id: UUID = UUID()) throws -> UUID {
        try ensureLevel(levelId)
        guard let def = definition(definitionId) else { throw CommandError.notFound("Definition", definitionId) }
        var inst = FurnitureInstance(id: id, definitionId: definitionId, levelId: levelId, name: name ?? def.name,
                                     position: position, rotationDeg: Angle.normalized(rotationDeg))
        inst.size = size
        inst.stateId = def.defaultStateId
        inst.productId = def.productId
        instances.append(inst)
        return id
    }

    mutating func updateInstance(_ id: UUID, _ body: (inout FurnitureInstance) throws -> Void) throws {
        try ensureEditable(id)
        try modify(\.instances, id, "Furniture") { i in
            let keep = (i.id, i.groupId)
            try body(&i)
            i.id = keep.0; i.groupId = keep.1
            i.rotationDeg = Angle.normalized(i.rotationDeg)
        }
    }

    @discardableResult
    mutating func addProduct(_ p: CatalogProduct) -> UUID { products.append(p); return p.id }
    mutating func updateProduct(_ id: UUID, _ body: (inout CatalogProduct) throws -> Void) throws {
        try modify(\.products, id, "Product") { p in let keep = p.id; try body(&p); p.id = keep }
    }

    /// Links a product to furniture, a group or a definition (nil product unlinks).
    mutating func linkProduct(_ productId: UUID?, to objectId: UUID) throws {
        if let productId, product(productId) == nil { throw CommandError.notFound("Product", productId) }
        switch kind(of: objectId) {
        case .furniture: try ensureEditable(objectId); try modify(\.instances, objectId, "Furniture") { $0.productId = productId }
        case .group: try ensureEditable(objectId); try modify(\.groups, objectId, "Group") { $0.productId = productId }
        case .definition:
            try modify(\.definitions, objectId, "Definition") { $0.productId = productId }
            if let productId { try modify(\.products, productId, "Product") { $0.definitionId = objectId } }
        case nil: throw CommandError(.notFound, "Object \(objectId.uuidString.lowercased()) does not exist", ids: [objectId])
        default: throw CommandError.invalid("Products can only be linked to furniture, groups or definitions", ids: [objectId])
        }
    }

    @discardableResult
    mutating func addAsset(_ a: ProjectAsset) -> UUID {
        if let existing = assets.first(where: { $0.sha256 == a.sha256 && $0.kind == a.kind }) { return existing.id }
        assets.append(a); return a.id
    }
    mutating func updateAsset(_ id: UUID, _ body: (inout ProjectAsset) throws -> Void) throws {
        try modify(\.assets, id, "Asset") { a in let keep = a.id; try body(&a); a.id = keep }
    }

    @discardableResult
    mutating func addBackground(_ b: BackgroundImage) throws -> UUID {
        try ensureLevel(b.levelId)
        guard asset(b.assetId) != nil else { throw CommandError.notFound("Asset", b.assetId) }
        backgrounds.append(b); return b.id
    }
    mutating func updateBackground(_ id: UUID, _ body: (inout BackgroundImage) throws -> Void) throws {
        try modify(\.backgrounds, id, "Background image") { b in let keep = b.id; try body(&b); b.id = keep }
    }

    // MARK: States and animation

    /// Adds or replaces (same id or same name) a state of a definition. Returns the state id.
    @discardableResult
    mutating func defineState(definitionId: UUID, _ state: FurnitureState, makeDefault: Bool = false) throws -> UUID {
        var sid = state.id
        try modify(\.definitions, definitionId, "Definition") { d in
            if let i = d.states.firstIndex(where: { $0.id == state.id || $0.name.caseInsensitiveCompare(state.name) == .orderedSame }) {
                var s = state; s.id = d.states[i].id; sid = s.id
                d.states[i] = s
            } else {
                d.states.append(state)
            }
            if makeDefault || d.defaultStateId == nil && d.states.count == 1 { d.defaultStateId = sid }
        }
        return sid
    }

    @discardableResult
    mutating func addTrack(definitionId: UUID, _ track: AnimationTrack) throws -> UUID {
        try modify(\.definitions, definitionId, "Definition") { d in
            d.tracks.removeAll { $0.id == track.id || ($0.fromStateId == track.fromStateId && $0.toStateId == track.toStateId) }
            d.tracks.append(track)
        }
        return track.id
    }

    /// Switches instances to a state (nil = base pose of the definition).
    mutating func activateState(_ instanceIds: [UUID], stateId: UUID?) throws {
        for id in instanceIds {
            try ensureEditable(id)
            guard let inst = instance(id) else { throw CommandError.notFound("Furniture", id) }
            if let stateId {
                guard let def = definition(inst.definitionId), def.states.contains(where: { $0.id == stateId }) else {
                    throw CommandError(.notFound, "State \(stateId.uuidString.lowercased()) does not exist for this furniture", ids: [id])
                }
            }
            try modify(\.instances, id, "Furniture") { $0.stateId = stateId }
        }
    }

    // MARK: Camera and settings

    mutating func setCamera(_ c: CameraState) { camera = c }

    @discardableResult
    mutating func saveCamera(name: String, state: CameraState? = nil) -> UUID {
        if let i = cameras.firstIndex(where: { $0.name == name }) { cameras[i].state = state ?? camera; return cameras[i].id }
        let c = SavedCamera(name: name, state: state ?? camera)
        cameras.append(c); return c.id
    }

    mutating func updateSettings(_ body: (inout ProjectSettings) throws -> Void) rethrows { try body(&settings) }
}
