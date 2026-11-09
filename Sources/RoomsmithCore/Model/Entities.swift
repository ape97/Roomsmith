import Foundation

// MARK: - Basic value types

/// sRGB colour, 0…255 per channel plus opacity 0…1.
public struct RGBColor: Codable, Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }

    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        r = UInt8((v >> 16) & 0xFF); g = UInt8((v >> 8) & 0xFF); b = UInt8(v & 0xFF)
    }

    public var hex: String { String(format: "#%02X%02X%02X", r, g, b) }

    // Stored as "#RRGGBB" so project files stay readable.
    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let c = RGBColor(hex: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad colour \(s)"))
        }
        self = c
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hex)
    }
}

public enum ObjectKind: String, Codable, Sendable, CaseIterable {
    case level, wall, room, opening, dimension, furniture, group, material, definition, product, asset, camera, background
}

// MARK: - Levels, walls, rooms, openings, dimensions

public struct Level: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Floor elevation of this level in mm (world Z of its floor).
    public var elevation: MM
    /// Default wall/ceiling height of the level.
    public var height: MM
    public var visible: Bool = true
    public var locked: Bool = false
    public var rev: Int64 = 0
    public init(id: UUID = UUID(), name: String, elevation: MM = 0, height: MM = 2500) {
        self.id = id; self.name = name; self.elevation = elevation; self.height = height
    }
}

public struct Wall: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var levelId: UUID
    /// Axis start and end points (centre line of the wall).
    public var start: P2
    public var end: P2
    public var thickness: MM
    public var height: MM
    /// Material of the left/right face seen from start → end. nil = default wall material.
    public var leftMaterialId: UUID?
    public var rightMaterialId: UUID?
    public var locked: Bool = false
    public var rev: Int64 = 0
    public init(id: UUID = UUID(), levelId: UUID, start: P2, end: P2, thickness: MM = 115, height: MM = 2500) {
        self.id = id; self.levelId = levelId; self.start = start; self.end = end
        self.thickness = thickness; self.height = height
    }
}

public struct Room: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var levelId: UUID
    public var name: String
    /// Closed polygon, counter-clockwise or clockwise, without repeating the first point.
    public var points: [P2]
    public var floorMaterialId: UUID?
    public var ceilingMaterialId: UUID?
    public var showFloor: Bool = true
    public var showCeiling: Bool = false
    public var rev: Int64 = 0
    public init(id: UUID = UUID(), levelId: UUID, name: String, points: [P2]) {
        self.id = id; self.levelId = levelId; self.name = name; self.points = points
    }
}

public enum OpeningKind: String, Codable, Sendable, CaseIterable { case door, window, opening }

/// Look of a door leaf or window sash. Door styles apply to doors, window styles to windows; a plain opening has none.
public enum OpeningStyle: String, Codable, Sendable, CaseIterable {
    case smooth, panel2, panel4, glass, sliding
    case tiltTurn1, tiltTurn2, fixed, balconyDoor
    /// Two-sash, floor-length balcony door (added after schema 4 without a bump; older builds reject files that use it).
    case balconyDoor2

    public static let doorStyles: [OpeningStyle] = [.smooth, .panel2, .panel4, .glass, .sliding]
    public static let windowStyles: [OpeningStyle] = [.tiltTurn1, .tiltTurn2, .fixed, .balconyDoor, .balconyDoor2]

    /// Styles that can be chosen for `kind` (empty for a plain opening).
    public static func styles(for kind: OpeningKind) -> [OpeningStyle] {
        switch kind { case .door: doorStyles; case .window: windowStyles; case .opening: [] }
    }

    /// Style a new opening of `kind` starts with (the plain look the app always had).
    public static func defaultStyle(for kind: OpeningKind) -> OpeningStyle { kind == .window ? .fixed : .smooth }

    public func isValid(for kind: OpeningKind) -> Bool { Self.styles(for: kind).contains(self) }
}

public enum OpeningHandle: String, Codable, Sendable, CaseIterable { case lever, knob, bar, none }

public enum OpeningGlass: String, Codable, Sendable, CaseIterable { case clear, frosted, tinted }

/// A door, window or plain opening that lives inside a wall. Position is relative to the wall, so it moves with it.
public struct Opening: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var wallId: UUID
    public var kind: OpeningKind
    public var name: String
    /// Distance from the wall's start point to the centre of the opening, along the wall axis.
    public var offset: MM
    public var width: MM
    public var height: MM
    /// Height of the lower edge above the floor (0 for doors).
    public var sill: MM
    /// Door swing / window hinge mirrored.
    public var flipped: Bool = false
    /// Door/window opens to the other side of the wall.
    public var inward: Bool = true
    public var frameMaterialId: UUID?
    /// Leaf / sash design; must be valid for `kind` (see `OpeningStyle.styles(for:)`).
    public var style: OpeningStyle
    public var handle: OpeningHandle = .none
    /// Width of the frame members (jambs, head, sill) in mm.
    public var frameWidth: MM = 50
    /// Number of vertical / horizontal glazing bars dividing the glass (0 = none). Only glass parts get bars.
    public var mullionCols: Int = 0
    public var mullionRows: Int = 0
    public var glassType: OpeningGlass = .clear
    public var rev: Int64 = 0
    public init(id: UUID = UUID(), wallId: UUID, kind: OpeningKind, name: String = "", offset: MM, width: MM, height: MM, sill: MM) {
        self.id = id; self.wallId = wallId; self.kind = kind; self.name = name
        self.offset = offset; self.width = width; self.height = height; self.sill = sill
        self.style = OpeningStyle.defaultStyle(for: kind)
    }
}

public struct Dimension: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var levelId: UUID
    public var a: P2
    public var b: P2
    /// Perpendicular offset of the dimension line from the measured segment (positive = left of a→b).
    public var offset: MM
    public var rev: Int64 = 0
    public init(id: UUID = UUID(), levelId: UUID, a: P2, b: P2, offset: MM = 300) {
        self.id = id; self.levelId = levelId; self.a = a; self.b = b; self.offset = offset
    }
}

// MARK: - Materials and assets

public struct Material: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var color: RGBColor
    /// 0 = mirror, 1 = matte.
    public var roughness: Double = 0.7
    public var metallic: Double = 0
    public var opacity: Double = 1
    public var textureAssetId: UUID?
    /// Real-world size of one texture tile.
    public var textureTile: MM = 1000
    /// Name of the preset this material was made from (informational; the parameters below are what renders).
    public var preset: String?
    public var finish: MaterialFinish = .matte
    /// Procedural pattern generated from the parameters below; an imported `textureAssetId` takes precedence.
    public var pattern: MaterialPattern = .none
    /// Second pattern colour (stripe, tile, grain, thread); nil = a darkened `color`.
    public var color2: RGBColor?
    /// Size of one pattern cell (stripe pair, tile, plank width, weave cell) in mm.
    public var patternSize: MM = 100
    /// Rotation of the pattern / grain direction in degrees.
    public var patternAngleDeg: Double = 0
    /// Joint width between tiles / planks in mm.
    public var grout: MM = 3
    /// Clear lacquer layer 0...1.
    public var clearcoat: Double = 0
    /// Specular strength 0...1 (0.5 = neutral).
    public var specular: Double = 0.5
    public var rev: Int64 = 0
    public init(id: UUID = UUID(), name: String, color: RGBColor, roughness: Double = 0.7, metallic: Double = 0, opacity: Double = 1) {
        self.id = id; self.name = name; self.color = color
        self.roughness = roughness; self.metallic = metallic; self.opacity = opacity
    }
    /// True when both materials render the same apart from identity, revision and the texture asset (which lives in a
    /// project-specific asset table, so callers compare it by content hash). Compares every other field, so a field
    /// added later is covered automatically.
    public func sameLook(as other: Material) -> Bool {
        var a = self
        a.id = other.id; a.rev = other.rev; a.textureAssetId = other.textureAssetId
        return a == other
    }
}

public enum MaterialFinish: String, Codable, Sendable, CaseIterable { case matte, satin, brushed, polished }

public enum MaterialPattern: String, Codable, Sendable, CaseIterable { case none, stripes, grid, tiles, wood, fabric, leather }

public enum AssetKind: String, Codable, Sendable { case mesh, texture, image, background, file }

/// A file stored inside the project package under `assets/<storedName>`.
public struct ProjectAsset: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: AssetKind
    /// File name inside `assets/` (content hash + extension).
    public var storedName: String
    public var originalName: String
    public var sha256: String
    public var byteCount: Int64
    /// For meshes: measured bounding box in mm after import scale.
    public var measuredSize: Size3?
    /// Scale applied to the source units to get metres (e.g. 0.01 for centimetre models).
    public var importScale: Double = 1
    public var notes: String = ""
    public var rev: Int64 = 0
    public init(id: UUID = UUID(), kind: AssetKind, storedName: String, originalName: String, sha256: String, byteCount: Int64) {
        self.id = id; self.kind = kind; self.storedName = storedName; self.originalName = originalName
        self.sha256 = sha256; self.byteCount = byteCount
    }
}

/// A scanned plan or sketch under a level, calibrated with a reference distance.
public struct BackgroundImage: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var levelId: UUID
    public var assetId: UUID
    /// Two pixel positions on the image and the real distance between them.
    public var calibrationA: P2
    public var calibrationB: P2
    public var calibrationLength: MM
    /// World position of the image's top-left pixel.
    public var origin: P2
    public var opacity: Double = 0.5
    public var visible: Bool = true
    public var rev: Int64 = 0
    public init(id: UUID = UUID(), levelId: UUID, assetId: UUID, calibrationA: P2, calibrationB: P2, calibrationLength: MM, origin: P2) {
        self.id = id; self.levelId = levelId; self.assetId = assetId
        self.calibrationA = calibrationA; self.calibrationB = calibrationB
        self.calibrationLength = calibrationLength; self.origin = origin
    }
    /// Millimetres per image pixel.
    public var mmPerPixel: Double {
        let dx = Double(calibrationB.x - calibrationA.x), dy = Double(calibrationB.y - calibrationA.y)
        let px = (dx * dx + dy * dy).squareRoot()
        return px > 0 ? Double(calibrationLength) / px : 1
    }
}

// MARK: - Furniture

public enum PrimitiveShape: String, Codable, Sendable, CaseIterable {
    /// Box with the given size.
    case box
    /// Box with rounded edges (upholstery). The unit mesh rounds by 1/4 of its edge, so after scaling every edge is
    /// rounded by 1/4 of the part's size along that axis (elliptical, not one radius for all axes).
    case cushion
    /// Cylinder standing on Z: an ellipse of width × depth (unit mesh of radius 0.5, scaled), not a circle of min(width, depth).
    case cylinder
    /// Sphere/ellipsoid in the size box.
    case sphere
    /// Thin panel/plate (same as box, kept separate for the editor).
    case panel
    /// Box with softly eased edges: one real radius in mm for every edge (min(12 mm, 30 % of the thinnest side)), so a
    /// worktop, a cabinet front or a leg catches a highlight on its edges at any size. The unit mesh depends on the size.
    case rounded
    /// Frustum standing on Z: the bottom is the full width × depth ellipse, the top is `Meshes.taperTop` of it. Upright it is
    /// a lamp shade or a tapered leg; turned upside down (rotation x 180) it is a flower pot that widens upwards.
    case taper
    /// Imported mesh asset scaled into the size box.
    case mesh
}

/// One part of a furniture definition. Positions are local to the furniture origin, which is the
/// centre of the footprint at floor height. `position` is the centre of the part's bounding box.
public struct Component: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var shape: PrimitiveShape
    public var position: P3
    public var size: Size3
    public var rotation: R3 = .zero
    /// Local point the rotation is applied around (defaults to the part's centre when nil).
    public var pivot: P3?
    public var materialId: UUID?
    public var meshAssetId: UUID?
    public var visible: Bool = true
    public init(id: UUID = UUID(), name: String, shape: PrimitiveShape, position: P3, size: Size3, rotation: R3 = .zero, pivot: P3? = nil, materialId: UUID? = nil) {
        self.id = id; self.name = name; self.shape = shape; self.position = position; self.size = size
        self.rotation = rotation; self.pivot = pivot; self.materialId = materialId
    }
}

/// Overrides of a component in a state. nil fields keep the component's base value.
public struct ComponentPose: Codable, Hashable, Sendable {
    public var position: P3?
    public var rotation: R3?
    public var size: Size3?
    public var visible: Bool?
    public init(position: P3? = nil, rotation: R3? = nil, size: Size3? = nil, visible: Bool? = nil) {
        self.position = position; self.rotation = rotation; self.size = size; self.visible = visible
    }
}

public enum Easing: String, Codable, Sendable, CaseIterable { case linear, easeIn, easeOut, easeInOut }

/// A state of one object, e.g. a bed "folded" / "unfolded". Exact end poses per component.
public struct FurnitureState: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var poses: [UUID: ComponentPose]
    /// Nominal size of the object in this state (height for collisions; footprint when the state has no poses). A state that
    /// moves components gets its footprint from the hull of the visible components. nil = definition size.
    public var size: Size3?
    public init(id: UUID = UUID(), name: String, poses: [UUID: ComponentPose] = [:], size: Size3? = nil) {
        self.id = id; self.name = name; self.poses = poses; self.size = size
    }
}

/// Keyframes for a transition between two states. Without a track the renderer interpolates linearly.
public struct AnimationTrack: Codable, Hashable, Identifiable, Sendable {
    public struct Keyframe: Codable, Hashable, Sendable {
        /// 0…1 along the transition.
        public var t: Double
        public var poses: [UUID: ComponentPose]
        public init(t: Double, poses: [UUID: ComponentPose]) { self.t = t; self.poses = poses }
    }
    public var id: UUID
    public var fromStateId: UUID?
    public var toStateId: UUID
    public var durationMs: Int = 800
    public var easing: Easing = .easeInOut
    public var keyframes: [Keyframe] = []
    public init(id: UUID = UUID(), fromStateId: UUID?, toStateId: UUID, durationMs: Int = 800, easing: Easing = .easeInOut) {
        self.id = id; self.fromStateId = fromStateId; self.toStateId = toStateId
        self.durationMs = durationMs; self.easing = easing
    }
}

/// A reusable furniture design (the "product definition"), separate from placed instances.
public struct FurnitureDefinition: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var category: String
    /// Nominal bounding size of the design (origin at footprint centre, floor height).
    public var size: Size3
    public var components: [Component]
    public var states: [FurnitureState] = []
    public var defaultStateId: UUID?
    public var tracks: [AnimationTrack] = []
    public var productId: UUID?
    /// Shipped with the app (built-in catalog) vs. created/imported by the user.
    public var builtin: Bool = false
    /// Stable key for built-in designs ("sofa-3", "bed-fold" …).
    public var catalogKey: String?
    public var tags: [String] = []
    /// Lamps that belong to this design (at most `LightEmitter.maxPerDefinition`).
    public var lights: [LightEmitter] = []
    /// Switchable aspects (colour, front, handle); each placed piece selects one choice per group.
    public var optionGroups: [OptionGroup] = []
    public var rev: Int64 = 0
    public init(id: UUID = UUID(), name: String, category: String, size: Size3, components: [Component]) {
        self.id = id; self.name = name; self.category = category; self.size = size; self.components = components
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, category, size, components, states, defaultStateId, tracks, productId, builtin, catalogKey, tags, lights, optionGroups, rev
    }

    // Written by hand so that data saved before a field existed (library files, pasteboard, transfers) still decodes.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        category = try c.decode(String.self, forKey: .category)
        size = try c.decode(Size3.self, forKey: .size)
        components = try c.decode([Component].self, forKey: .components)
        states = try c.decodeIfPresent([FurnitureState].self, forKey: .states) ?? []
        defaultStateId = try c.decodeIfPresent(UUID.self, forKey: .defaultStateId)
        tracks = try c.decodeIfPresent([AnimationTrack].self, forKey: .tracks) ?? []
        productId = try c.decodeIfPresent(UUID.self, forKey: .productId)
        builtin = try c.decodeIfPresent(Bool.self, forKey: .builtin) ?? false
        catalogKey = try c.decodeIfPresent(String.self, forKey: .catalogKey)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        lights = try c.decodeIfPresent([LightEmitter].self, forKey: .lights) ?? []
        optionGroups = try c.decodeIfPresent([OptionGroup].self, forKey: .optionGroups) ?? []
        rev = try c.decodeIfPresent(Int64.self, forKey: .rev) ?? 0
    }
}

/// A placed piece of furniture.
public struct FurnitureInstance: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var definitionId: UUID
    public var levelId: UUID
    public var name: String
    /// World position of the footprint centre; z = elevation above the level floor.
    public var position: P3
    /// Rotation around the vertical axis, degrees counter-clockwise seen from above, [0, 360).
    public var rotationDeg: Double = 0
    /// Actual size. nil = definition size. Scaling is always expressed as an exact mm size.
    public var size: Size3?
    /// Component id → material id.
    public var materialOverrides: [UUID: UUID] = [:]
    public var stateId: UUID?
    /// Option group id → selected choice id. Groups without an entry use their default choice.
    public var optionSelection: [UUID: UUID] = [:]
    public var groupId: UUID?
    public var productId: UUID?
    public var visible: Bool = true
    public var locked: Bool = false
    /// Whether the design's lamps are switched on for this piece.
    public var lightOn: Bool = true
    /// The piece never reports or receives collision warnings and is not a contact obstacle while dragging.
    /// Flat floor pieces (rugs) behave the same without the flag, see `CollisionChecker.isFree`.
    public var allowsOverlap: Bool = false
    public var rev: Int64 = 0
    public init(id: UUID = UUID(), definitionId: UUID, levelId: UUID, name: String, position: P3, rotationDeg: Double = 0) {
        self.id = id; self.definitionId = definitionId; self.levelId = levelId; self.name = name
        self.position = position; self.rotationDeg = rotationDeg
    }

    private enum CodingKeys: String, CodingKey {
        case id, definitionId, levelId, name, position, rotationDeg, size, materialOverrides, stateId, optionSelection
        case groupId, productId, visible, locked, lightOn, allowsOverlap, rev
    }

    // Written by hand so that data saved before a field existed (library files, pasteboard, transfers) still decodes.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        definitionId = try c.decode(UUID.self, forKey: .definitionId)
        levelId = try c.decode(UUID.self, forKey: .levelId)
        name = try c.decode(String.self, forKey: .name)
        position = try c.decode(P3.self, forKey: .position)
        rotationDeg = try c.decodeIfPresent(Double.self, forKey: .rotationDeg) ?? 0
        size = try c.decodeIfPresent(Size3.self, forKey: .size)
        materialOverrides = try c.decodeIfPresent([UUID: UUID].self, forKey: .materialOverrides) ?? [:]
        stateId = try c.decodeIfPresent(UUID.self, forKey: .stateId)
        optionSelection = try c.decodeIfPresent([UUID: UUID].self, forKey: .optionSelection) ?? [:]
        groupId = try c.decodeIfPresent(UUID.self, forKey: .groupId)
        productId = try c.decodeIfPresent(UUID.self, forKey: .productId)
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        lightOn = try c.decodeIfPresent(Bool.self, forKey: .lightOn) ?? true
        allowsOverlap = try c.decodeIfPresent(Bool.self, forKey: .allowsOverlap) ?? false
        rev = try c.decodeIfPresent(Int64.self, forKey: .rev) ?? 0
    }
}

/// Pose of one member inside a group configuration, relative to the group origin.
public struct MemberPose: Codable, Hashable, Sendable {
    public var local: P3
    public var rotationDeg: Double
    public var visible: Bool = true
    public var stateId: UUID?
    public var materialOverrides: [UUID: UUID]?
    public init(local: P3, rotationDeg: Double, visible: Bool = true, stateId: UUID? = nil, materialOverrides: [UUID: UUID]? = nil) {
        self.local = local; self.rotationDeg = rotationDeg; self.visible = visible
        self.stateId = stateId; self.materialOverrides = materialOverrides
    }
}

public struct GroupConfiguration: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var poses: [UUID: MemberPose]
    public init(id: UUID = UUID(), name: String, poses: [UUID: MemberPose]) { self.id = id; self.name = name; self.poses = poses }
}

/// A group of furniture instances. Members keep their world transforms; the group stores an origin so that
/// configurations can be expressed in local coordinates and the whole group can be moved/rotated.
public struct FurnitureGroup: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var levelId: UUID
    public var origin: P3
    public var rotationDeg: Double = 0
    public var memberIds: [UUID]
    public var configurations: [GroupConfiguration] = []
    public var activeConfigurationId: UUID?
    public var productId: UUID?
    public var locked: Bool = false
    public var rev: Int64 = 0
    public init(id: UUID = UUID(), name: String, levelId: UUID, origin: P3, memberIds: [UUID]) {
        self.id = id; self.name = name; self.levelId = levelId; self.origin = origin; self.memberIds = memberIds
    }
}

// MARK: - Catalog / products

public enum PurchaseStatus: String, Codable, Sendable, CaseIterable { case idea, shortlisted, ordered, purchased, returned, owned }

public struct ProductLink: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var url: String
    public init(id: UUID = UUID(), title: String, url: String) { self.id = id; self.title = title; self.url = url }
    /// Only http(s) links with a host are accepted.
    public var isValid: Bool {
        guard let u = URL(string: url), let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme), u.host != nil else { return false }
        return true
    }
}

/// Product information. Exists on its own (wish list) or linked to definitions/instances.
public struct CatalogProduct: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var category: String = ""
    public var description: String = ""
    public var notes: String = ""
    public var manufacturer: String = ""
    public var model: String = ""
    public var articleNumber: String = ""
    public var links: [ProductLink] = []
    /// Price in minor currency units (cents) to stay exact.
    public var priceMinor: Int64?
    public var currency: String = "EUR"
    /// ISO date (yyyy-MM-dd) of the price.
    public var priceDate: String?
    public var dimensions: Size3?
    public var weightGrams: Int64?
    public var materialText: String = ""
    public var colorText: String = ""
    public var fileAssetIds: [UUID] = []
    public var imageAssetIds: [UUID] = []
    public var tags: [String] = []
    public var status: PurchaseStatus = .idea
    public var variants: [String] = []
    public var roomIds: [UUID] = []
    /// Free key/value fields.
    public var custom: [String: String] = [:]
    public var definitionId: UUID?
    public var rev: Int64 = 0
    public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
}

// MARK: - Cameras

public enum CameraMode: String, Codable, Sendable { case orbit, firstPerson, top, free }

public struct CameraState: Codable, Hashable, Sendable {
    public var mode: CameraMode
    /// Orbit and top: point looked at. First person and free: eye position.
    public var target: P3
    /// Orbit distance (mm).
    public var distance: MM
    /// Heading in degrees (0 = looking north / +Y), counter-clockwise.
    public var yawDeg: Double
    /// Pitch in degrees (negative = looking down).
    public var pitchDeg: Double
    public var fovDeg: Double = 60
    public init(mode: CameraMode, target: P3, distance: MM, yawDeg: Double, pitchDeg: Double, fovDeg: Double = 60) {
        self.mode = mode; self.target = target; self.distance = distance
        self.yawDeg = yawDeg; self.pitchDeg = pitchDeg; self.fovDeg = fovDeg
    }
    public static let `default` = CameraState(mode: .orbit, target: P3(0, 0, 0), distance: 9000, yawDeg: 30, pitchDeg: -35)
}

public struct SavedCamera: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var state: CameraState
    public var rev: Int64 = 0
    public init(id: UUID = UUID(), name: String, state: CameraState) { self.id = id; self.name = name; self.state = state }
}

// MARK: - Settings and project

public struct SnapSettings: Codable, Hashable, Sendable {
    public var enabled: Bool = true
    public var grid: MM = 10
    /// Distance in mm below which an object snaps to a wall/edge/object.
    public var tolerance: MM = 80
    public var toWalls: Bool = true
    public var toObjects: Bool = true
    public var toGrid: Bool = true
    /// Angle step for rotation snapping (degrees).
    public var angleStep: Double = 15
    public init() {}
}

public struct ProjectSettings: Codable, Hashable, Sendable {
    public var displayUnit: LengthUnit = .cm
    public var snap = SnapSettings()
    /// Show non-destructive collision warnings.
    public var collisionWarnings: Bool = true
    public var defaultWallThickness: MM = 115
    public var defaultWallHeight: MM = 2500
    /// Sun and sky of the 3D scene.
    public var lighting = LightingSettings()
    public init() {}
}

public struct Project: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 5

    public var schemaVersion: Int = Project.currentSchemaVersion
    public var id: UUID = UUID()
    public var name: String
    public var levels: [Level] = []
    public var walls: [Wall] = []
    public var rooms: [Room] = []
    public var openings: [Opening] = []
    public var dimensions: [Dimension] = []
    public var materials: [Material] = []
    public var definitions: [FurnitureDefinition] = []
    public var instances: [FurnitureInstance] = []
    public var groups: [FurnitureGroup] = []
    public var products: [CatalogProduct] = []
    public var assets: [ProjectAsset] = []
    public var backgrounds: [BackgroundImage] = []
    public var cameras: [SavedCamera] = []
    public var camera: CameraState = .default
    public var settings = ProjectSettings()
    /// Monotonic document revision, incremented by every successful command (also undo/redo).
    public var revision: Int64 = 0

    public init(name: String) { self.name = name }

    /// An empty project with one level.
    public static func empty(name: String = "Untitled") -> Project {
        var p = Project(name: name)
        p.levels = [Level(name: "Ground floor")]
        return p
    }
}
