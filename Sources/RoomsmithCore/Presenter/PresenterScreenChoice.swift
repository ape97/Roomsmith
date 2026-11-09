import Foundation

/// Picks the display for the live presenter window. Pure: the app maps `NSScreen` to `Candidate`.
public enum PresenterScreenChoice {
    public struct Candidate: Sendable, Equatable {
        public var id: UInt32
        public var name: String
        public var isMain: Bool
        public init(id: UInt32, name: String, isMain: Bool) { self.id = id; self.name = name; self.isMain = isMain }
    }

    /// True when the display name suggests an AirPlay receiver (best effort, names are not guaranteed).
    public static func looksLikeAirPlay(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("apple tv") || n.contains("airplay")
    }

    /// Chooses an external (non-main) display: one named like AirPlay / Apple TV first, otherwise the one that
    /// appeared last (not in `known`), otherwise the last in the list. nil when there is no external display.
    public static func choose(_ candidates: [Candidate], known: Set<UInt32> = []) -> Candidate? {
        let external = candidates.filter { !$0.isMain }
        if let tv = external.last(where: { looksLikeAirPlay($0.name) }) { return tv }
        if let added = external.last(where: { !known.contains($0.id) }) { return added }
        return external.last
    }

    /// The external display that is new since `known`, preferring AirPlay-named ones; nil when nothing was added.
    public static func added(_ candidates: [Candidate], known: Set<UInt32>) -> Candidate? {
        let fresh = candidates.filter { !$0.isMain && !known.contains($0.id) }
        return fresh.last(where: { looksLikeAirPlay($0.name) }) ?? fresh.last
    }
}
