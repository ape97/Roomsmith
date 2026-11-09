import Foundation

/// Decides when the player has drifted too far behind the live edge and should jump forward.
/// Pure and clock-free: the caller passes the measured distance and the current time.
public struct PresenterLiveEdge: Sendable {
    public enum Decision: Sendable, Equatable { case none, seek }

    /// Distance behind the live edge (seconds) above which a sample counts as "too far behind". Default, not measured.
    public static let defaultThreshold = 2.5
    /// Consecutive samples above the threshold needed before a seek. Default, not measured.
    public static let defaultRequiredSamples = 2
    /// Minimum seconds between two seeks. Default, not measured.
    public static let defaultMinInterval = 5.0

    public let threshold: Double
    public let requiredSamples: Int
    public let minInterval: Double
    private var consecutive = 0
    private var lastSeek: Double?

    public init(threshold: Double = defaultThreshold, requiredSamples: Int = defaultRequiredSamples,
                minInterval: Double = defaultMinInterval) {
        self.threshold = threshold
        self.requiredSamples = max(1, requiredSamples)
        self.minInterval = minInterval
    }

    /// Feeds one sample. `behind` is seekable end minus current time, `now` any monotonic time in seconds.
    /// A sample strictly above the threshold counts; a seek needs `requiredSamples` in a row and `minInterval`
    /// since the last seek. Non-finite samples reset the streak.
    public mutating func evaluate(behind: Double, now: Double) -> Decision {
        guard behind.isFinite, behind > threshold else { consecutive = 0; return .none }
        consecutive += 1
        guard consecutive >= requiredSamples else { return .none }
        if let last = lastSeek, now - last < minInterval { return .none }
        lastSeek = now
        consecutive = 0
        return .seek
    }
}
