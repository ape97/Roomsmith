import Foundation

/// Limits audit entries for failed logins: at most one per client id and interval. Suppressed attempts are
/// counted and reported with the next admitted entry. The reported count mixes this client's own suppressed
/// attempts with the global ones (flood limit, and clients forgotten to bound memory); it is not split. Not thread safe; the owner serialises access.
public struct AuthFailureThrottle: Sendable {
    public static let maxFieldLength = 100
    public static let maxTrackedClients = 256

    public let interval: TimeInterval
    private struct Entry { var lastLogged: Date; var suppressed: Int }
    private var entries: [String: Entry] = [:]

    /// Global token bucket against floods of changing client ids.
    public let globalRate: Double
    public let globalBurst: Double
    private var tokens: Double
    private var lastRefill: Date?
    private var globalSuppressed = 0

    public init(interval: TimeInterval = 1, globalRate: Double = 10, globalBurst: Double = 10) {
        self.interval = interval
        self.globalRate = globalRate
        self.globalBurst = globalBurst
        self.tokens = globalBurst
    }

    /// Client-controlled text cut to `maxFieldLength` characters.
    /// Counted in unicode scalars so a base character with endless combining marks cannot blow the limit.
    public static func clip(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        out.append(contentsOf: s.unicodeScalars.prefix(maxFieldLength))
        return String(out)
    }

    /// nil: suppress this attempt (counted). Otherwise write an entry; the value is the number of attempts
    /// suppressed for this client since the last entry.
    public mutating func admit(clientId: String, at now: Date = Date()) -> Int? {
        let key = Self.clip(clientId)
        if var e = entries[key], now.timeIntervalSince(e.lastLogged) < interval, now >= e.lastLogged {
            e.suppressed += 1
            entries[key] = e
            return nil
        }
        if let last = lastRefill, now >= last {
            tokens = min(globalBurst, tokens + now.timeIntervalSince(last) * globalRate)
        } else if lastRefill != nil {
            tokens = min(tokens, globalBurst)  // clock went backwards: no refill
        }
        lastRefill = now
        guard tokens >= 1 else {
            globalSuppressed += 1
            return nil
        }
        tokens -= 1
        if entries[key] == nil && entries.count >= Self.maxTrackedClients {
            // Bounded memory against floods of random client ids: forget the expired ones, else the oldest.
            for (_, e) in entries where now.timeIntervalSince(e.lastLogged) >= interval { globalSuppressed += e.suppressed }
            entries = entries.filter { now.timeIntervalSince($0.value.lastLogged) < interval }
            if entries.count >= Self.maxTrackedClients, let oldest = entries.min(by: { $0.value.lastLogged < $1.value.lastLogged })?.key {
                globalSuppressed += entries[oldest]?.suppressed ?? 0  // keep the count of the forgotten client
                entries[oldest] = nil
            }
        }
        let suppressed = (entries[key]?.suppressed ?? 0) + globalSuppressed
        globalSuppressed = 0
        entries[key] = Entry(lastLogged: now, suppressed: 0)
        return suppressed
    }
}
