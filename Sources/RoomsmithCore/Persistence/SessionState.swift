import Foundation

/// Which projects were open when Roomsmith last quit, so the next launch can open them again: the ordered tabs (file
/// paths), the active tab, and the compare split. View state only, never part of a project. Stored as JSON in the
/// support folder; a missing, broken or newer file reads as the empty state, never as an error.
public struct SessionState: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let fileName = "session.json"

    public enum Axis: String, Codable, Sendable { case sideBySide, stacked }
    public enum Pane: String, Codable, Sendable { case plan, scene }
    public enum Side: String, Codable, Sendable { case left, right }

    /// The compare split. The left pane is the active tab; `rightIndex` is the tab shown next to it.
    public struct Split: Codable, Equatable, Sendable {
        public var rightIndex: Int
        public var axis: Axis
        public var leftContent: Pane
        public var rightContent: Pane
        public var focus: Side

        public init(rightIndex: Int, axis: Axis = .sideBySide, leftContent: Pane = .plan, rightContent: Pane = .plan, focus: Side = .left) {
            self.rightIndex = rightIndex; self.axis = axis
            self.leftContent = leftContent; self.rightContent = rightContent; self.focus = focus
        }

        /// Field by field: a value this version does not know (e.g. a pane added later) falls back to its default
        /// instead of throwing the whole split away. Only `rightIndex` is essential.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            rightIndex = try c.decode(Int.self, forKey: .rightIndex)
            axis = (try? c.decodeIfPresent(Axis.self, forKey: .axis)) ?? .sideBySide
            leftContent = (try? c.decodeIfPresent(Pane.self, forKey: .leftContent)) ?? .plan
            rightContent = (try? c.decodeIfPresent(Pane.self, forKey: .rightContent)) ?? .plan
            focus = (try? c.decodeIfPresent(Side.self, forKey: .focus)) ?? .left
        }
    }

    public var version: Int
    /// File paths of the saved projects, in tab order. Projects that were never saved are not part of a session.
    public var tabs: [String]
    public var activeIndex: Int
    public var split: Split?

    public static let empty = SessionState(tabs: [], activeIndex: 0, split: nil)

    public init(tabs: [String], activeIndex: Int, split: Split? = nil) {
        self.version = Self.currentVersion
        self.tabs = tabs
        self.activeIndex = activeIndex
        self.split = split
    }

    /// Tolerant like the library index: one damaged field or element costs only itself, never the whole session.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        tabs = ((try? c.decodeIfPresent([Failable<String>].self, forKey: .tabs)) ?? nil)?.compactMap(\.value) ?? []
        activeIndex = (try? c.decodeIfPresent(Int.self, forKey: .activeIndex)) ?? 0
        split = (try? c.decodeIfPresent(Split.self, forKey: .split)) ?? nil
    }

    public var isEmpty: Bool { tabs.isEmpty }

    /// Standardized path of a file URL (the form stored here and compared everywhere).
    public static func path(for url: URL) -> String { url.standardizedFileURL.path }

    /// Clamps the active index into the tab range and drops a split whose right tab does not exist or is the active tab.
    public func sanitized() -> SessionState {
        var s = self
        s.tabs = tabs.filter { !$0.isEmpty }
        s.activeIndex = s.tabs.isEmpty ? 0 : min(max(activeIndex, 0), s.tabs.count - 1)
        if let sp = split, !(s.tabs.indices.contains(sp.rightIndex) && sp.rightIndex != s.activeIndex) { s.split = nil }
        return s
    }

    /// Builds the state from the live tab list (`nil` = untitled tab). Untitled tabs are left out and the indices move
    /// with the remaining tabs; an active untitled tab becomes the next saved one (else the last). A split that
    /// involves an untitled tab, or whose right index is out of range, is dropped.
    public static func make(tabs: [String?], active: Int, split: Split?) -> SessionState {
        var newIndex: [Int: Int] = [:]
        var paths: [String] = []
        for (i, p) in tabs.enumerated() {
            guard let p, !p.isEmpty else { continue }
            newIndex[i] = paths.count
            paths.append(p)
        }
        guard !paths.isEmpty else { return .empty }
        var activeNew = paths.count - 1
        if tabs.indices.contains(active) {
            activeNew = (active..<tabs.count).lazy.compactMap { newIndex[$0] }.first ?? paths.count - 1
        }
        var splitNew: Split?
        if var sp = split, let r = newIndex[sp.rightIndex], let a = newIndex[active], a != r {
            sp.rightIndex = r
            splitNew = sp
        }
        return SessionState(tabs: paths, activeIndex: activeNew, split: splitNew).sanitized()
    }

    // MARK: Storage

    public static var defaultURL: URL { AgentPaths.supportDirectory.appendingPathComponent(fileName) }

    /// The stored state; the empty state when the file is missing, unreadable, malformed or from a newer version.
    public static func load(from url: URL = defaultURL) -> SessionState {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(SessionState.self, from: data),
              s.version == currentVersion else { return .empty }
        return s.sanitized()
    }

    /// Writes the state atomically (a crash never leaves half a file), creating the folder when needed.
    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }
}

/// The "Open Recent" list: newest first, no duplicates (by standardized path), at most `limit` entries.
public struct RecentProjects: Codable, Equatable, Sendable {
    public static let limit = 10
    public static let currentVersion = 1
    public static let fileName = "recent.json"

    public private(set) var version = RecentProjects.currentVersion
    public private(set) var entries: [String]

    public init(entries: [String] = []) {
        self.entries = []
        for e in entries where !e.isEmpty {
            let p = Self.key(e)
            if !self.entries.contains(p) { self.entries.append(p) }
        }
        if self.entries.count > Self.limit { self.entries.removeLast(self.entries.count - Self.limit) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .version)
        let raw = ((try? c.decodeIfPresent([Failable<String>].self, forKey: .entries)) ?? nil)?.compactMap(\.value) ?? []
        self.init(entries: raw)
        self.version = version
    }

    public var isEmpty: Bool { entries.isEmpty }

    private static func key(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }

    /// Moves (or adds) a project to the front.
    public mutating func note(_ path: String) {
        let p = Self.key(path)
        entries.removeAll { $0 == p }
        entries.insert(p, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    public mutating func remove(_ path: String) {
        let p = Self.key(path)
        entries.removeAll { $0 == p }
    }

    public mutating func clear() { entries.removeAll() }

    /// One menu row. The title is the file name; two entries with the same file name also show the parent folder.
    public struct Item: Equatable, Sendable {
        public var path: String
        public var title: String
    }

    public func items() -> [Item] {
        let names = entries.map { URL(fileURLWithPath: $0).lastPathComponent }
        return zip(entries, names).map { path, name in
            guard names.filter({ $0 == name }).count > 1 else { return Item(path: path, title: name) }
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
            return Item(path: path, title: "\(name) — \(parent)")
        }
    }

    // MARK: Storage

    public static var defaultURL: URL { AgentPaths.supportDirectory.appendingPathComponent(fileName) }

    /// The stored list without the files that no longer exist; empty when the file is missing, malformed or newer.
    public static func load(from url: URL = defaultURL, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> RecentProjects {
        guard let data = try? Data(contentsOf: url),
              let r = try? JSONDecoder().decode(RecentProjects.self, from: data),
              r.version == currentVersion else { return RecentProjects() }
        return RecentProjects(entries: r.entries.filter(fileExists))
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }
}
