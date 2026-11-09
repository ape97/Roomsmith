import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Presenter mode: which address the Apple TV can reach, and swapping it into the stream URL.

public struct PresenterNetworkInterface: Sendable, Equatable {
    public var name: String
    /// Dotted IPv4 address.
    public var address: String
    public var isUp: Bool
    public var isLoopback: Bool
    public var isPointToPoint: Bool

    public init(name: String, address: String, isUp: Bool = true, isLoopback: Bool = false, isPointToPoint: Bool = false) {
        self.name = name
        self.address = address
        self.isUp = isUp
        self.isLoopback = isLoopback
        self.isPointToPoint = isPointToPoint
    }
}

public enum PresenterLANAddress {
    public static let loopbackHost = "127.0.0.1"

    /// IPv4 interfaces of this Mac (getifaddrs).
    public static func currentInterfaces() -> [PresenterNetworkInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var out: [PresenterNetworkInterface] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cursor {
            defer { cursor = p.pointee.ifa_next }
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(buffer.count)) != nil else { continue }
            let flags = Int32(p.pointee.ifa_flags)
            out.append(PresenterNetworkInterface(
                name: String(cString: p.pointee.ifa_name),
                address: String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self),
                isUp: flags & IFF_UP != 0 && flags & IFF_RUNNING != 0,
                isLoopback: flags & IFF_LOOPBACK != 0,
                isPointToPoint: flags & IFF_POINTOPOINT != 0))
        }
        return out
    }

    /// Picks the interface an Apple TV on the same network is most likely to reach: up, not loopback, not a tunnel,
    /// not link-local, preferably a private address on an `en*` interface. `preferred` (e.g. the interface of the
    /// system's active network path) wins if it is usable. Nothing is hard-coded to `en0`.
    public static func select(from interfaces: [PresenterNetworkInterface], preferred: String? = nil) -> PresenterNetworkInterface? {
        let usable = interfaces.filter { i in
            i.isUp && !i.isLoopback && !i.isPointToPoint && isUsableIPv4(i.address) && !isLinkLocal(i.address)
        }
        if let preferred, let match = usable.first(where: { $0.name == preferred }) { return match }
        func rank(_ i: PresenterNetworkInterface) -> Int {
            var r = 0
            if isPrivate(i.address) { r += 10 }
            if i.name.hasPrefix("en") { r += 5 }
            if ["awdl", "llw", "utun", "anpi", "ap", "gif", "stf", "bridge", "vmenet", "feth"].contains(where: { i.name.hasPrefix($0) }) { r -= 20 }
            return r
        }
        return usable.enumerated().max { a, b in
            let ra = rank(a.element), rb = rank(b.element)
            return ra != rb ? ra < rb : a.offset > b.offset   // ties: first listed wins
        }?.element
    }

    /// The LAN interface to use now, or nil if there is none.
    public static func current(preferred: String? = nil) -> PresenterNetworkInterface? {
        select(from: currentInterfaces(), preferred: preferred)
    }

    /// Address of the named interface (for `HLSServer.Bind.lan`).
    public static func address(ofInterface name: String, in interfaces: [PresenterNetworkInterface] = currentInterfaces()) -> String? {
        interfaces.first { $0.name == name && $0.isUp && !$0.isLoopback }?.address
    }

    // MARK: URL host

    public static func isLoopbackHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host == "::1" || host == "[::1]" || host.hasPrefix("127.")
    }

    /// The same URL with another host (port, path and query stay).
    public static func replacingHost(in url: URL, with host: String) -> URL? {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        c.host = host
        return c.url
    }

    /// `http://host:port/token/live.m3u8`.
    public static func streamURL(host: String, port: UInt16, token: String) -> URL? {
        URL(string: "http://\(host):\(port)/\(token)/\(HLSPlaylist.playlistName)")
    }

    // MARK: Address classes

    static func octets(_ address: String) -> [Int]? {
        let p = address.split(separator: ".", omittingEmptySubsequences: false).compactMap { Int($0) }
        return p.count == 4 && p.allSatisfy { (0 ... 255).contains($0) } && address.split(separator: ".").count == 4 ? p : nil
    }

    static func isUsableIPv4(_ address: String) -> Bool {
        guard let o = octets(address) else { return false }
        return o[0] != 0 && o[0] < 224
    }

    static func isLinkLocal(_ address: String) -> Bool {
        guard let o = octets(address) else { return false }
        return o[0] == 169 && o[1] == 254
    }

    static func isPrivate(_ address: String) -> Bool {
        guard let o = octets(address) else { return false }
        return o[0] == 10 || (o[0] == 172 && (16 ... 31).contains(o[1])) || (o[0] == 192 && o[1] == 168)
    }
}
