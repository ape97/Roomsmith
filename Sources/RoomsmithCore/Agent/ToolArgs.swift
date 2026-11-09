import Foundation

// MARK: - JSON output helpers

/// Helpers that turn model values into the API's JSON conventions (lowercase UUIDs, integer mm, {x,y} points).
enum J {
    static func id(_ u: UUID) -> JSONValue { .string(u.uuidString.lowercased()) }
    static func ids(_ list: [UUID]) -> JSONValue { .array(list.map(id)) }
    static func p2(_ p: P2) -> JSONValue { .object(["x": .int(p.x), "y": .int(p.y)]) }
    static func p3(_ p: P3) -> JSONValue { .object(["x": .int(p.x), "y": .int(p.y), "z": .int(p.z)]) }
    static func v2(_ v: V2) -> JSONValue { .object(["x": mm(v.x), "y": mm(v.y)]) }

    /// Computed double to whole mm for output. Never capped: lengths up to ~2.83e8 mm are reported as they are.
    /// A value that is not finite or does not fit Int64 becomes JSON null (never a made-up number).
    static func mm(_ d: Double) -> JSONValue {
        guard d.isFinite, let i = Int64(exactly: d.rounded(.toNearestOrAwayFromZero)) else { return .null }
        return .int(i)
    }
    static func size(_ s: Size3) -> JSONValue { .object(["width": .int(s.width), "depth": .int(s.depth), "height": .int(s.height)]) }
    static func r3(_ r: R3) -> JSONValue { .object(["x": .number(r.x), "y": .number(r.y), "z": .number(r.z)]) }

    /// Lowercases every string that is a UUID (Codable encodes UUIDs in upper case).
    static func normalizeIds(_ v: JSONValue) -> JSONValue {
        switch v {
        case .string(let s):
            if s.count == 36, UUID(uuidString: s) != nil { return .string(s.lowercased()) }
            return v
        case .array(let a): return .array(a.map(normalizeIds))
        case .object(let o): return .object(o.mapValues(normalizeIds))
        default: return v
        }
    }

    /// Codable value as API JSON with lowercase ids.
    static func encode(_ value: some Encodable) -> JSONValue {
        guard let v = try? JSONValue(encoding: value) else { return .null }
        return normalizeIds(v)
    }

    static func optional(_ v: JSONValue?) -> JSONValue { v ?? .null }
}

// MARK: - Errors

enum ToolError {
    static func invalid(_ field: String?, _ message: String) -> AgentError {
        AgentError(code: AgentError.invalidArgument,
                   message: field.map { "Argument '\($0)': \(message)" } ?? message,
                   details: field.map { .object(["field": .string($0)]) })
    }

    static func missing(_ field: String) -> AgentError { invalid(field, "is required") }

    static func notFound(_ what: String, _ id: UUID) -> AgentError {
        AgentError(code: AgentError.notFound, message: "\(what) \(id.uuidString.lowercased()) does not exist",
                   details: .object(["ids": J.ids([id])]))
    }

    static func notFoundText(_ message: String) -> AgentError { AgentError(code: AgentError.notFound, message: message) }
}

extension AgentError {
    /// Maps a document command error to the API error with the same code. Ids and details go into `details`.
    init(_ e: CommandError) {
        var d: [String: JSONValue] = [:]
        if !e.ids.isEmpty { d["ids"] = J.ids(e.ids) }
        var current: [String: JSONValue] = [:]
        for (k, v) in e.details {
            let value: JSONValue = Int64(v).map { .int($0) } ?? .string(v)
            if UUID(uuidString: k) != nil { current[k.lowercased()] = value } else { d[k] = value }
        }
        if !current.isEmpty { d["currentRevisions"] = .object(current) }
        self.init(code: e.code.rawValue, message: e.message, details: d.isEmpty ? nil : .object(d))
    }
}

// MARK: - Arguments

/// Typed reader for the arguments of one tool call. Every failure is an INVALID_ARGUMENT naming the field.
struct Args {
    let values: [String: JSONValue]

    init(values: [String: JSONValue] = [:]) { self.values = values }

    init(_ json: JSONValue) throws {
        switch json {
        case .null: values = [:]
        case .object(let o): values = o
        default: throw ToolError.invalid(nil, "Arguments must be a JSON object")
        }
    }

    /// The value if present and not null.
    func raw(_ key: String) -> JSONValue? {
        guard let v = values[key], !v.isNull else { return nil }
        return v
    }
    func has(_ key: String) -> Bool { raw(key) != nil }
    /// True if the key is present with an explicit `null` (used to clear optional fields).
    func isNull(_ key: String) -> Bool { values[key]?.isNull == true }
    func present(_ key: String) -> Bool { values[key] != nil }

    // Scalars

    func string(_ key: String) throws -> String? {
        guard let v = raw(key) else { return nil }
        guard let s = v.stringValue else { throw ToolError.invalid(key, "must be a string") }
        return s
    }
    func requireString(_ key: String) throws -> String {
        guard let s = try string(key) else { throw ToolError.missing(key) }
        return s
    }
    func nonEmptyString(_ key: String) throws -> String? {
        guard let s = try string(key) else { return nil }
        if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ToolError.invalid(key, "must not be empty") }
        return s
    }
    func requireNonEmptyString(_ key: String) throws -> String {
        guard let s = try nonEmptyString(key) else { throw ToolError.missing(key) }
        return s
    }

    func int(_ key: String) throws -> Int64? {
        guard let v = raw(key) else { return nil }
        guard let i = v.int64Value else { throw ToolError.invalid(key, "must be a whole number (integer millimetres or count)") }
        return i
    }
    /// Integer millimetres (length, height, offset, elevation): whole number within ±`coordinateLimit`.
    func mm(_ key: String) throws -> MM? {
        guard let v = raw(key) else { return nil }
        return try Args.coordinate(v, key)
    }

    func requireInt(_ key: String) throws -> Int64 {
        guard let i = try int(key) else { throw ToolError.missing(key) }
        return i
    }

    func double(_ key: String) throws -> Double? {
        guard let v = raw(key) else { return nil }
        guard let d = v.doubleValue, d.isFinite else { throw ToolError.invalid(key, "must be a finite number") }
        return d
    }
    func requireDouble(_ key: String) throws -> Double {
        guard let d = try double(key) else { throw ToolError.missing(key) }
        return d
    }

    func bool(_ key: String) throws -> Bool? {
        guard let v = raw(key) else { return nil }
        guard let b = v.boolValue else { throw ToolError.invalid(key, "must be true or false") }
        return b
    }
    func requireBool(_ key: String) throws -> Bool {
        guard let b = try bool(key) else { throw ToolError.missing(key) }
        return b
    }

    func uuid(_ key: String) throws -> UUID? {
        guard let v = raw(key) else { return nil }
        return try Args.parseUUID(v, key)
    }
    func requireUUID(_ key: String) throws -> UUID {
        guard let u = try uuid(key) else { throw ToolError.missing(key) }
        return u
    }

    func uuidList(_ key: String) throws -> [UUID]? {
        guard let v = raw(key) else { return nil }
        guard let a = v.arrayValue else { throw ToolError.invalid(key, "must be an array of UUID strings") }
        var out: [UUID] = []
        var seen = Set<UUID>()
        for (i, item) in a.enumerated() {
            let u = try Args.parseUUID(item, "\(key)[\(i)]")
            if seen.insert(u).inserted { out.append(u) }
        }
        return out
    }
    func requireUUIDList(_ key: String, allowEmpty: Bool = false) throws -> [UUID] {
        guard let l = try uuidList(key) else { throw ToolError.missing(key) }
        if l.isEmpty && !allowEmpty { throw ToolError.invalid(key, "must contain at least one id") }
        return l
    }

    static func parseUUID(_ v: JSONValue, _ field: String) throws -> UUID {
        guard let s = v.stringValue, let u = UUID(uuidString: s.trimmingCharacters(in: .whitespaces)) else {
            throw ToolError.invalid(field, "must be a UUID string")
        }
        return u
    }

    // Geometry

    func p2(_ key: String) throws -> P2? {
        guard let v = raw(key) else { return nil }
        return try Args.parseP2(v, key)
    }
    func requireP2(_ key: String) throws -> P2 {
        guard let p = try p2(key) else { throw ToolError.missing(key) }
        return p
    }
    func p2List(_ key: String) throws -> [P2]? {
        guard let v = raw(key) else { return nil }
        guard let a = v.arrayValue else { throw ToolError.invalid(key, "must be an array of {x,y} points") }
        return try a.enumerated().map { try Args.parseP2($0.element, "\(key)[\($0.offset)]") }
    }

    /// Point with optional z (default `defaultZ`).
    func p3(_ key: String, defaultZ: MM = 0) throws -> P3? {
        guard let v = raw(key) else { return nil }
        return try Args.parseP3(v, key, defaultZ: defaultZ)
    }
    func requireP3(_ key: String, defaultZ: MM = 0) throws -> P3 {
        guard let p = try p3(key, defaultZ: defaultZ) else { throw ToolError.missing(key) }
        return p
    }

    func size3(_ key: String) throws -> Size3? {
        guard let v = raw(key) else { return nil }
        return try Args.parseSize3(v, key)
    }
    func requireSize3(_ key: String) throws -> Size3 {
        guard let s = try size3(key) else { throw ToolError.missing(key) }
        return s
    }

    static func coordinate(_ v: JSONValue?, _ field: String) throws -> MM {
        guard let v, let i = v.int64Value else {
            throw ToolError.invalid(field, "must be a whole number of millimetres (got \(v?.jsonString() ?? "nothing"))")
        }
        return try checkedMM(i, field)
    }

    /// API boundary check for every length, coordinate, delta, height and offset: within ±`coordinateLimit`
    /// (OUT_OF_RANGE), so no later sum, difference or product of two values can overflow Int64.
    static func checkedMM(_ i: MM, _ field: String) throws -> MM {
        guard i.magnitude <= coordinateLimit.magnitude else {
            throw AgentError(code: AgentError.outOfRange,
                             message: "Argument '\(field)': \(i) mm is outside the allowed range of ±\(coordinateLimit) mm",
                             details: .object(["field": .string(field), "limitMm": .int(coordinateLimit)]))
        }
        return i
    }

    static func parseP2(_ v: JSONValue, _ field: String) throws -> P2 {
        switch v {
        case .object:
            return P2(try coordinate(v["x"], "\(field).x"), try coordinate(v["y"], "\(field).y"))
        case .array(let a) where a.count == 2:
            return P2(try coordinate(a[0], "\(field)[0]"), try coordinate(a[1], "\(field)[1]"))
        default:
            throw ToolError.invalid(field, "must be a point {\"x\": mm, \"y\": mm}")
        }
    }

    static func parseP3(_ v: JSONValue, _ field: String, defaultZ: MM = 0) throws -> P3 {
        switch v {
        case .object:
            let z: MM = try v["z"].map { $0.isNull ? defaultZ : try coordinate($0, "\(field).z") } ?? defaultZ
            return P3(try coordinate(v["x"], "\(field).x"), try coordinate(v["y"], "\(field).y"), z)
        case .array(let a) where a.count == 2 || a.count == 3:
            return P3(try coordinate(a[0], "\(field)[0]"), try coordinate(a[1], "\(field)[1]"),
                      a.count == 3 ? try coordinate(a[2], "\(field)[2]") : defaultZ)
        default:
            throw ToolError.invalid(field, "must be a point {\"x\": mm, \"y\": mm, \"z\": mm}")
        }
    }

    static func parseSize3(_ v: JSONValue, _ field: String) throws -> Size3 {
        guard case .object = v else { throw ToolError.invalid(field, "must be {\"width\": mm, \"depth\": mm, \"height\": mm}") }
        return Size3(try coordinate(v["width"], "\(field).width"), try coordinate(v["depth"], "\(field).depth"),
                     try coordinate(v["height"], "\(field).height"))
    }

    static func parseR3(_ v: JSONValue, _ field: String) throws -> R3 {
        guard case .object = v else { throw ToolError.invalid(field, "must be {\"x\": deg, \"y\": deg, \"z\": deg}") }
        func axis(_ k: String) throws -> Double {
            guard let x = v[k], !x.isNull else { return 0 }
            guard let d = x.doubleValue, d.isFinite else { throw ToolError.invalid("\(field).\(k)", "must be a finite number of degrees") }
            return d
        }
        return R3(try axis("x"), try axis("y"), try axis("z"))
    }

    // Containers

    func object(_ key: String) throws -> Args? {
        guard let v = raw(key) else { return nil }
        guard let o = v.objectValue else { throw ToolError.invalid(key, "must be an object") }
        return Args(values: o)
    }
    func array(_ key: String) throws -> [JSONValue]? {
        guard let v = raw(key) else { return nil }
        guard let a = v.arrayValue else { throw ToolError.invalid(key, "must be an array") }
        return a
    }
    func requireArray(_ key: String) throws -> [JSONValue] {
        guard let a = try array(key) else { throw ToolError.missing(key) }
        return a
    }
    func stringList(_ key: String) throws -> [String]? {
        guard let a = try array(key) else { return nil }
        return try a.enumerated().map {
            guard let s = $0.element.stringValue else { throw ToolError.invalid("\(key)[\($0.offset)]", "must be a string") }
            return s
        }
    }

    func enumValue<E: RawRepresentable & CaseIterable>(_ key: String, _ type: E.Type) throws -> E? where E.RawValue == String {
        guard let s = try string(key) else { return nil }
        guard let e = E(rawValue: s) ?? E.allCases.first(where: { $0.rawValue.lowercased() == s.lowercased() }) else {
            throw ToolError.invalid(key, "must be one of: \(E.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return e
    }

    /// `{uuid: int}` map used for optimistic concurrency.
    func revisionMap(_ key: String) throws -> [UUID: Int64] {
        guard let v = raw(key) else { return [:] }
        guard let o = v.objectValue else { throw ToolError.invalid(key, "must be an object {\"<uuid>\": revision}") }
        var out: [UUID: Int64] = [:]
        for (k, rv) in o {
            guard let u = UUID(uuidString: k) else { throw ToolError.invalid(key, "key '\(k)' is not a UUID") }
            guard let r = rv.int64Value else { throw ToolError.invalid(key, "revision of \(k) must be an integer") }
            out[u] = r
        }
        return out
    }
}

// MARK: - Pagination

struct PageRequest {
    var limit: Int
    var offset: Int

    static let defaultLimit = 50
    static let maxLimit = 500

    init(_ a: Args, defaultLimit: Int = PageRequest.defaultLimit) throws {
        let l = try a.int("limit").map(Int.init) ?? defaultLimit
        guard (1...PageRequest.maxLimit).contains(l) else { throw ToolError.invalid("limit", "must be between 1 and \(PageRequest.maxLimit)") }
        limit = l
        if let c = try a.string("cursor") {
            guard let o = Int(c), o >= 0, o <= Int(Int32.max) else { throw ToolError.invalid("cursor", "is not a cursor returned by this tool") }
            offset = o
        } else { offset = 0 }
    }

    /// `{items, total, nextCursor?, revision}`; the closure builds the rows of the requested page only.
    func result<T>(_ all: [T], revision: Int64, _ row: (T) -> JSONValue, extra: [String: JSONValue] = [:]) -> JSONValue {
        let end = min(all.count, offset + limit)  // offset <= Int32.max and limit <= maxLimit: cannot overflow
        let slice = offset < all.count ? all[offset..<end] : []
        var o = extra
        o["items"] = .array(slice.map(row))
        o["total"] = .int(Int64(all.count))
        o["revision"] = .int(revision)
        if end < all.count { o["nextCursor"] = .string(String(end)) }
        return .object(o)
    }
}

// MARK: - Schema builders

enum S {
    static func str(_ d: String, values: [String]? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": "string", "description": .string(d)]
        if let values { o["enum"] = .array(values.map { .string($0) }) }
        return .object(o)
    }
    static func int(_ d: String) -> JSONValue { .object(["type": "integer", "description": .string(d)]) }
    static func num(_ d: String) -> JSONValue { .object(["type": "number", "description": .string(d)]) }
    static func bool(_ d: String) -> JSONValue { .object(["type": "boolean", "description": .string(d)]) }
    static func uuid(_ d: String) -> JSONValue {
        .object(["type": "string", "format": "uuid", "description": .string(d + " (lowercase UUID)")])
    }
    static func uuids(_ d: String) -> JSONValue {
        .object(["type": "array", "items": ["type": "string", "format": "uuid"], "minItems": 1, "description": .string(d)])
    }
    static func p2(_ d: String) -> JSONValue {
        .object(["type": "object", "description": .string(d + " Millimetres."),
                 "properties": ["x": ["type": "integer"], "y": ["type": "integer"]], "required": ["x", "y"]])
    }
    static func p3(_ d: String) -> JSONValue {
        .object(["type": "object", "description": .string(d + " Millimetres; z optional."),
                 "properties": ["x": ["type": "integer"], "y": ["type": "integer"], "z": ["type": "integer"]], "required": ["x", "y"]])
    }
    static func size(_ d: String) -> JSONValue {
        .object(["type": "object", "description": .string(d + " Millimetres."),
                 "properties": ["width": ["type": "integer"], "depth": ["type": "integer"], "height": ["type": "integer"]],
                 "required": ["width", "depth", "height"]])
    }
    static func arr(_ d: String, items: JSONValue = .object([:])) -> JSONValue {
        .object(["type": "array", "items": items, "description": .string(d)])
    }
    static func obj(_ d: String, _ props: [String: JSONValue] = [:], required: [String] = []) -> JSONValue {
        var o: [String: JSONValue] = ["type": "object", "description": .string(d), "properties": .object(props)]
        if !required.isEmpty { o["required"] = .array(required.map { .string($0) }) }
        return .object(o)
    }

    static let limit = int("Page size, default 50, maximum 500.")
    static let cursor = str("`nextCursor` of the previous page.")
}

// MARK: - Tool specification

/// Everything a handler needs besides the arguments.
@MainActor
struct ToolEnv {
    let store: DocumentStore
    let context: AgentAppContext
    let clientId: String
    unowned let registry: ToolRegistry
    /// True while the surrounding write (a single tool or a whole `app.batch`) is a dry run. Tools with side
    /// effects outside the project (files) must check this, not their own `dryRun` argument, which batch steps never get.
    var dryRun = false

    var project: Project { store.project }

    /// Level for create tools: the `levelId` argument, else the active level, else the first level.
    func level(_ a: Args, in p: Project) throws -> UUID {
        if let id = try a.uuid("levelId") {
            guard p.level(id) != nil else { throw ToolError.notFound("Level", id) }
            return id
        }
        if p.level(context.activeLevelId) != nil { return context.activeLevelId }
        guard let first = p.levels.first else { throw ToolError.invalid(nil, "The project has no level") }
        return first.id
    }
}

@MainActor
struct ToolSpec {
    typealias ReadHandler = @MainActor (ToolEnv, Args) throws -> JSONValue
    typealias AsyncHandler = @MainActor (ToolEnv, Args) async throws -> JSONValue
    typealias WriteHandler = @MainActor (inout Project, ToolEnv, Args) throws -> JSONValue

    enum Handler {
        /// Reads the document; never changes anything.
        case read(ReadHandler)
        case asyncRead(AsyncHandler)
        /// Edit of the project, wrapped by the registry in exactly one `store.apply`.
        case write(WriteHandler)
        /// Mutates outside `apply` (undo/redo, saving). The store or the handler enforces the write lock.
        case action(ReadHandler)
    }

    var name: String
    var description: String
    var properties: [String: JSONValue]
    var required: [String]
    var readOnly: Bool
    var handler: Handler
    /// Extra arguments are passed on to another tool (scene.create_object).
    var openArguments = false
    /// Records an undo step (false for transient changes such as the camera).
    var recordUndo = true
    /// May appear as a step of `app.batch`.
    var batchable: Bool {
        if case .write = handler { return recordUndo && name != "app.batch" }
        return false
    }
    var isWrite: Bool { if case .write = handler { return true } else { return false } }

    static func read(_ name: String, _ description: String, _ properties: [String: JSONValue] = [:], required: [String] = [],
                     _ body: @escaping ReadHandler) -> ToolSpec {
        ToolSpec(name: name, description: description, properties: properties, required: required, readOnly: true, handler: .read(body))
    }
    static func asyncRead(_ name: String, _ description: String, _ properties: [String: JSONValue] = [:], required: [String] = [],
                          _ body: @escaping AsyncHandler) -> ToolSpec {
        ToolSpec(name: name, description: description, properties: properties, required: required, readOnly: true, handler: .asyncRead(body))
    }
    static func write(_ name: String, _ description: String, _ properties: [String: JSONValue] = [:], required: [String] = [],
                      _ body: @escaping WriteHandler) -> ToolSpec {
        ToolSpec(name: name, description: description, properties: properties, required: required, readOnly: false, handler: .write(body))
    }
    static func action(_ name: String, _ description: String, _ properties: [String: JSONValue] = [:], required: [String] = [],
                       readOnly: Bool = false, _ body: @escaping ReadHandler) -> ToolSpec {
        ToolSpec(name: name, description: description, properties: properties, required: required, readOnly: readOnly, handler: .action(body))
    }

    /// Properties added to every mutating tool.
    static let commonProperties: [String: JSONValue] = [
        "dryRun": S.bool("Validate and report the changes without committing anything."),
        "expectedRevision": S.int("Fail with CONFLICT if document content changed since this revision (camera moves do not count)."),
        "expectedObjectRevisions": .object(["type": "object", "additionalProperties": ["type": "integer"],
                                            "description": "{\"<uuid>\": rev}: fail with CONFLICT if any of these objects changed since you read it."]),
    ]
    static let commonKeys = Set(commonProperties.keys)

    var descriptor: ToolDescriptor {
        var props = properties
        if isWrite { for (k, v) in ToolSpec.commonProperties { props[k] = v } }
        var schema: [String: JSONValue] = ["type": "object", "properties": .object(props),
                                           "additionalProperties": .bool(openArguments)]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return ToolDescriptor(name: name, description: description, inputSchema: .object(schema), readOnly: readOnly)
    }
}

// MARK: - Project lookups with API errors

extension Project {
    /// Kind of an existing object or NOT_FOUND.
    func requireKind(_ id: UUID) throws -> ObjectKind {
        guard let k = kind(of: id) else {
            throw AgentError(code: AgentError.notFound, message: "Object \(id.uuidString.lowercased()) does not exist",
                             details: .object(["ids": J.ids([id])]))
        }
        return k
    }

    func requireAll(_ ids: [UUID]) throws {
        let missing = ids.filter { kind(of: $0) == nil }
        if !missing.isEmpty {
            throw AgentError(code: AgentError.notFound,
                             message: "Object(s) not found: \(missing.map { $0.uuidString.lowercased() }.joined(separator: ", "))",
                             details: .object(["ids": J.ids(missing)]))
        }
    }

    /// The room that contains a point on a level (first match), for readable furniture rows.
    func roomName(at p: P2, level: UUID) -> String? {
        rooms.first { $0.levelId == level && Geo.contains($0.points, p) }?.name
    }

    /// Material by UUID or exact (case-insensitive) name; palette materials are added on demand.
    mutating func resolveMaterial(_ value: JSONValue, field: String) throws -> UUID {
        guard let s = value.stringValue else { throw ToolError.invalid(field, "must be a material id or name") }
        if let u = UUID(uuidString: s) {
            if material(u) != nil { return u }
            if let m = BuiltinCatalog.materials.first(where: { $0.id == u }) { materials.append(m); return u }
            throw ToolError.notFound("Material", u)
        }
        if let m = materials.first(where: { $0.name.caseInsensitiveCompare(s) == .orderedSame }) { return m.id }
        if let m = BuiltinCatalog.materials.first(where: { $0.name.caseInsensitiveCompare(s) == .orderedSame }) {
            materials.append(m)
            return m.id
        }
        throw ToolError.notFoundText("Material '\(s)' does not exist. Use scene.list_objects with kind=material to see the names.")
    }
}
