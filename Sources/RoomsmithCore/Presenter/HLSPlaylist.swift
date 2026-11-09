import Foundation

// Presenter mode: live HLS playlist (fMP4) and the in-memory segment store behind the HTTP server.

public struct HLSSegment: Sendable, Equatable {
    /// Running number; also the media sequence number of the playlist when this is its first entry.
    public var index: Int
    /// Seconds.
    public var duration: Double

    public init(index: Int, duration: Double) {
        self.index = index
        self.duration = duration
    }

    public var fileName: String { HLSPlaylist.segmentName(index) }
}

public enum HLSPlaylist {
    public static let playlistName = "live.m3u8"
    public static let initName = "init.mp4"

    public static func segmentName(_ index: Int) -> String { "seg\(index).m4s" }

    /// Index of a segment file name (`seg12.m4s` -> 12); nil for anything else.
    public static func segmentIndex(fromName name: String) -> Int? {
        guard name.hasPrefix("seg"), name.hasSuffix(".m4s") else { return nil }
        let digits = name.dropFirst(3).dropLast(4)
        guard !digits.isEmpty, digits.count <= 9, digits.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
        return Int(digits)
    }

    /// Renders a media playlist for the last `window` segments.
    /// - Parameters:
    ///   - startOffset: `EXT-X-START:TIME-OFFSET`; negative values start that many seconds before the live edge.
    ///     Zero or positive values are ignored.
    ///   - ended: adds `EXT-X-ENDLIST` (stream stopped).
    public static func render(segments: [HLSSegment], window: Int = 6, startOffset: Double? = nil, ended: Bool = false) -> String {
        let visible = Array(segments.suffix(max(1, window)))
        let target = max(1, Int((visible.map(\.duration).max() ?? 1).rounded(.up)))
        var out = "#EXTM3U\n"
        out += "#EXT-X-VERSION:7\n"
        out += "#EXT-X-TARGETDURATION:\(target)\n"
        out += "#EXT-X-MEDIA-SEQUENCE:\(visible.first?.index ?? 0)\n"
        out += "#EXT-X-INDEPENDENT-SEGMENTS\n"
        if let offset = startOffset, offset < 0 {
            out += "#EXT-X-START:TIME-OFFSET=\(format(offset))\n"
        }
        out += "#EXT-X-MAP:URI=\"\(initName)\"\n"
        for s in visible {
            out += "#EXTINF:\(format(s.duration)),\n\(s.fileName)\n"
        }
        if ended { out += "#EXT-X-ENDLIST\n" }
        return out
    }

    static func format(_ value: Double) -> String { String(format: "%.3f", value) }
}

/// A servable file.
public struct HLSResource: Sendable, Equatable {
    public var contentType: String
    public var data: Data

    public init(contentType: String, data: Data) {
        self.contentType = contentType
        self.data = data
    }

    public static let playlistType = "application/vnd.apple.mpegurl"
    public static let mp4Type = "video/mp4"
}

/// Thread-safe ring buffer of the newest segments plus the init segment. Producer: the encoder delegate (any queue);
/// consumer: the HTTP server (its own queue).
public final class HLSSegmentStore: Sendable {
    private struct State {
        var initSegment: Data?
        var segments: [(info: HLSSegment, data: Data)] = []
        var nextIndex = 0
        var ended = false
        var totalAppended = 0
    }

    public let capacity: Int
    /// Segments listed in the playlist (the window is smaller than the capacity so listed files are never evicted).
    public let window: Int
    /// `EXT-X-START:TIME-OFFSET` (negative: seconds before the live edge).
    public let startOffset: Double?
    private let state = Locked(State())

    public init(capacity: Int = 8, window: Int = 6, startOffset: Double? = -1.0) {
        self.capacity = max(2, capacity)
        self.window = min(max(1, window), self.capacity)
        self.startOffset = startOffset
    }

    public func setInit(_ data: Data) {
        state.withLock { $0.initSegment = data }
    }

    /// Appends a segment and returns its index.
    @discardableResult
    public func append(duration: Double, data: Data) -> Int {
        state.withLock { s in
            let index = s.nextIndex
            s.nextIndex += 1
            s.totalAppended += 1
            s.segments.append((HLSSegment(index: index, duration: duration), data))
            if s.segments.count > capacity { s.segments.removeFirst(s.segments.count - capacity) }
            return index
        }
    }

    public func markEnded() { state.withLock { $0.ended = true } }

    /// Forgets everything (new stream): the next segment index continues so stale client caches never match.
    public func reset() {
        state.withLock { s in
            s.initSegment = nil
            s.segments.removeAll()
            s.ended = false
            s.totalAppended = 0
        }
    }

    public var hasInit: Bool { state.withLock { $0.initSegment != nil } }
    public var totalAppended: Int { state.withLock { $0.totalAppended } }
    public var isEnded: Bool { state.withLock { $0.ended } }
    public var segments: [HLSSegment] { state.withLock { $0.segments.map(\.info) } }
    public var bufferedCount: Int { state.withLock { $0.segments.count } }

    /// Playlist text; nil until the init segment and one segment exist.
    public func playlist() -> String? {
        state.withLock { s in
            guard s.initSegment != nil, !s.segments.isEmpty else { return nil }
            return HLSPlaylist.render(segments: s.segments.map(\.info), window: window, startOffset: startOffset, ended: s.ended)
        }
    }

    /// The file for a name from the URL (`live.m3u8`, `init.mp4`, `seg<N>.m4s`); nil if unknown or evicted.
    public func resource(named name: String) -> HLSResource? {
        switch name {
        case HLSPlaylist.playlistName:
            guard let text = playlist() else { return nil }
            return HLSResource(contentType: HLSResource.playlistType, data: Data(text.utf8))
        case HLSPlaylist.initName:
            guard let d = state.withLock({ $0.initSegment }) else { return nil }
            return HLSResource(contentType: HLSResource.mp4Type, data: d)
        default:
            guard let index = HLSPlaylist.segmentIndex(fromName: name) else { return nil }
            let data = state.withLock { s in s.segments.first { $0.info.index == index }?.data }
            return data.map { HLSResource(contentType: HLSResource.mp4Type, data: $0) }
        }
    }
}

/// Minimal lock box around a value.
final class Locked<Value>: @unchecked Sendable {
    // Safe: `value` is only touched while `lock` is held.
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
