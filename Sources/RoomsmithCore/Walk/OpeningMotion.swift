import Foundation

/// Everything about an opening that decides whether a stored open pose is still right. When it changes, the entry is
/// dropped and the opening is shown closed.
public struct OpeningSignature: Hashable, Sendable {
    public var wallId: UUID
    public var wallThickness: MM
    public var kind: OpeningKind
    public var style: OpeningStyle
    public var flipped: Bool
    public var inward: Bool
    public var width: MM
    public var height: MM
    public var sill: MM
    public var frameWidth: MM
    /// Doors are movable (turn only); windows follow `WindowProfile.effectiveMotion`.
    public var movable: Bool
    public var sashCount: Int

    public init?(_ o: Opening, wall: Wall?) {
        guard let wall, o.kind != .opening else { return nil }
        wallId = wall.id; wallThickness = wall.thickness; kind = o.kind; style = o.style; flipped = o.flipped; inward = o.inward
        width = o.width; height = o.height; sill = o.sill; frameWidth = o.frameWidth
        if o.kind == .door {
            movable = true; sashCount = 1
        } else {
            let m = Meshes.windowMotion(o, wall: wall)
            movable = m?.movable ?? false; sashCount = m?.sashCount ?? 0
        }
    }

    /// Signatures of all openings of all walls and levels.
    public static func map(_ p: Project) -> [UUID: OpeningSignature] {
        let walls = Dictionary(p.walls.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [UUID: OpeningSignature] = [:]
        for o in p.openings { if let s = OpeningSignature(o, wall: walls[o.wallId]) { out[o.id] = s } }
        return out
    }
}

/// Open/close state of doors and windows in one view: view state, not in the document. Pure and testable; the walk
/// controller holds one instance and forwards.
///
/// An opening is `closed`, turned or tilted. Asking for the other mode while one is open first closes it, then opens the
/// other (`pending`), so the pose never jumps.
public struct OpeningMotion: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        /// Mode of the pose being shown (turn or tilt).
        public var mode: OpeningMode
        public var progress: Double
        /// True while opening or open; false while closing.
        public var opening: Bool
        /// Mode to open as soon as the closing sash is shut.
        public var pending: OpeningMode?
        public var signature: OpeningSignature
    }

    public private(set) var entries: [UUID: Entry] = [:]

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    /// Asks for `mode` on opening `id`. `open` true / false / nil (toggle). Doors only turn, non-movable openings are
    /// ignored. Returns the mode the opening is heading to (`.closed` when it ends up shut or nothing happened).
    @discardableResult
    public mutating func request(_ id: UUID, mode: OpeningMode, open: Bool? = nil, signature: OpeningSignature) -> OpeningMode {
        guard signature.movable, mode != .closed, !(signature.kind == .door && mode == .tilt) else { return target(id) }
        guard var e = entries[id] else {
            if open != false { entries[id] = Entry(mode: mode, progress: 0, opening: true, pending: nil, signature: signature) }
            return target(id)
        }
        e.signature = signature
        let heading = target(id)
        let want: Bool = open ?? (heading != mode)   // toggle: same mode again closes
        if !want {
            e.opening = false; e.pending = nil
        } else if e.mode == mode {
            e.opening = true; e.pending = nil
        } else {
            // Other mode: shut first, then open the requested one.
            e.opening = false; e.pending = mode
        }
        entries[id] = e
        return target(id)
    }

    /// Puts an opening straight into a pose (progress 0...1, open) without animation: for still pictures and tests.
    public mutating func setPose(_ id: UUID, mode: OpeningMode, progress: Double, signature: OpeningSignature) {
        guard signature.movable, mode != .closed, !(signature.kind == .door && mode == .tilt) else { return }
        entries[id] = Entry(mode: mode, progress: min(max(progress, 0), 1), opening: true, pending: nil, signature: signature)
    }

    /// Mode the opening is heading to: pending mode, its current mode while opening, else closed.
    public func target(_ id: UUID) -> OpeningMode {
        guard let e = entries[id] else { return .closed }
        if let p = e.pending { return p }
        return e.opening ? e.mode : .closed
    }

    /// Pose to show: mode and progress 0...1 (closed and 0 without an entry).
    public func pose(_ id: UUID) -> (mode: OpeningMode, progress: Double) {
        guard let e = entries[id] else { return (.closed, 0) }
        return (e.mode, e.progress)
    }

    /// Moves every entry by `dt` seconds; `seconds` is the time from closed to fully open.
    public mutating func advance(dt: Double, seconds: Double) {
        guard !entries.isEmpty, dt > 0, seconds > 0 else { return }
        for (id, var e) in entries {
            if e.opening { e.progress = min(1, e.progress + dt / seconds) }
            else { e.progress = max(0, e.progress - dt / seconds) }
            if e.progress == 0, !e.opening {
                if let p = e.pending { e.mode = p; e.pending = nil; e.opening = true } else { entries[id] = nil; continue }
            }
            entries[id] = e
        }
    }

    /// Drops entries whose opening is gone, changed its signature or is no longer movable.
    public mutating func prune(current: [UUID: OpeningSignature]) {
        for (id, e) in entries {
            if let s = current[id], s == e.signature, s.movable { continue }
            entries[id] = nil
        }
    }

    /// Openings that are turned open (or opening); the walk collider treats these like open doors. Tilted ones stay solid.
    public var turnedIds: Set<UUID> {
        Set(entries.filter { $0.value.mode == .turn && $0.value.opening }.map(\.key))
    }

    /// Openings heading to an open pose, with their mode, sorted by id.
    public var openList: [(id: UUID, mode: OpeningMode)] {
        entries.keys.sorted { $0.uuidString < $1.uuidString }.compactMap { id in
            let t = target(id)
            return t == .closed ? nil : (id, t)
        }
    }
}
