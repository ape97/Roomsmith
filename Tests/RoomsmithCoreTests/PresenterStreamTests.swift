import Testing
import Foundation
import CoreGraphics
import CoreVideo
@testable import RoomsmithCore

/// Minimal ISO-BMFF reader, just enough to look at fragment sample flags.
private enum MP4 {
    struct Box { let type: String; let body: Range<Int> }

    static func boxes(_ d: Data, in range: Range<Int>) -> [Box] {
        var out: [Box] = []
        var p = range.lowerBound
        while p + 8 <= range.upperBound {
            let size = Int(be32(d, p))
            let type = String(decoding: d[p + 4 ..< p + 8], as: UTF8.self)
            guard size >= 8, p + size <= range.upperBound else { break }
            out.append(Box(type: type, body: p + 8 ..< p + size))
            p += size
        }
        return out
    }

    static func be32(_ d: Data, _ o: Int) -> UInt32 {
        let i = d.startIndex + o
        return UInt32(d[i]) << 24 | UInt32(d[i + 1]) << 16 | UInt32(d[i + 2]) << 8 | UInt32(d[i + 3])
    }

    /// Flags of the first sample of the first fragment, or nil if the structure is unexpected.
    static func firstSampleFlags(_ d: Data) -> UInt32? {
        let top = boxes(d, in: 0 ..< d.count)
        guard let moof = top.first(where: { $0.type == "moof" }) else { return nil }
        guard let traf = boxes(d, in: moof.body).first(where: { $0.type == "traf" }) else { return nil }
        let kids = boxes(d, in: traf.body)
        var defaultFlags: UInt32?
        if let tfhd = kids.first(where: { $0.type == "tfhd" }) {
            let flags = be32(d, tfhd.body.lowerBound) & 0xFFFFFF
            var o = tfhd.body.lowerBound + 8   // version/flags + track id
            if flags & 0x1 != 0 { o += 8 }
            if flags & 0x2 != 0 { o += 4 }
            if flags & 0x8 != 0 { o += 4 }
            if flags & 0x10 != 0 { o += 4 }
            if flags & 0x20 != 0 { defaultFlags = be32(d, o) }
        }
        guard let trun = kids.first(where: { $0.type == "trun" }) else { return nil }
        let f = be32(d, trun.body.lowerBound) & 0xFFFFFF
        var o = trun.body.lowerBound + 8       // version/flags + sample count
        if f & 0x1 != 0 { o += 4 }
        if f & 0x4 != 0 { return be32(d, o) }   // first_sample_flags
        if f & 0x400 != 0 {                     // per-sample flags: skip the fields before it
            if f & 0x100 != 0 { o += 4 }
            if f & 0x200 != 0 { o += 4 }
            return be32(d, o)
        }
        return defaultFlags
    }

    static func hasBox(_ d: Data, _ type: String) -> Bool { boxes(d, in: 0 ..< d.count).contains { $0.type == type } }
}

@Suite("Presenter encoder", .serialized)
struct PresenterEncoderTests {
    @Test func producesInitAndIndependentSegments() async throws {
        let store = HLSSegmentStore(capacity: 16, window: 6, startOffset: -1)
        let encoder = HLSEncoder(configuration: .init(width: 640, height: 360, frameRate: 30, segmentInterval: 0.5), store: store)
        let compositor = PresenterCompositor(composition: PresenterComposition(layout: .plan, canvas: CGSize(width: 640, height: 360)))
        let failure = Locked<String?>(nil)
        try encoder.start(onFailure: { msg in failure.withLock { $0 = msg } })

        // About 2.6 s of moving content; the frame clock and the segmenter run in real time.
        let begin = Date()
        var i = 0
        while Date().timeIntervalSince(begin) < 2.6 {
            let level = UInt8((i * 9) % 256)
            if let img = PresenterPlaylistTests.solidImage(width: 320, height: 180, r: level, g: UInt8(255 - Int(level)), b: 90),
               let buf = compositor.compose(plan: .cgImage(img), scene: nil) {
                encoder.submit(PresenterFrame(buf))
            }
            i += 1
            try await Task.sleep(nanoseconds: 33_000_000)
        }
        await encoder.stop()

        #expect(failure.withLock { $0 } == nil)
        #expect(store.hasInit)
        let initData = try #require(store.resource(named: "init.mp4")?.data)
        #expect(MP4.hasBox(initData, "ftyp") && MP4.hasBox(initData, "moov"))
        #expect(store.totalAppended >= 3)
        #expect(store.isEnded)
        #expect(encoder.statistics.framesAppended > 20)

        var checked = 0
        for segment in store.segments {
            let data = try #require(store.resource(named: segment.fileName)?.data)
            let flags = try #require(MP4.firstSampleFlags(data), "no sample flags in \(segment.fileName)")
            #expect(flags & 0x10000 == 0, "segment \(segment.index) does not start with a sync sample (flags \(String(flags, radix: 16)))")
            checked += 1
        }
        #expect(checked >= 3)
        // All but the last (partial) segment are close to the requested interval.
        for segment in store.segments.dropLast() {
            #expect(abs(segment.duration - 0.5) <= 0.05, "segment \(segment.index) lasts \(segment.duration) s")
        }
        let list = try #require(store.playlist())
        #expect(list.contains("#EXT-X-ENDLIST") && list.contains("#EXT-X-MAP"))
    }
}

extension PresenterPlaylistTests {
    static func solidImage(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) -> CGImage? {
        PresenterCompositionTests.solid(width: width, height: height, r: r, g: g, b: b)
    }
}

@Suite("Presenter server", .serialized)
struct PresenterServerTests {
    private func fetch(_ url: URL, method: String = "GET") async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 5
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]      // never route loopback through a proxy
        // Close the connection afterwards: idle keep-alive sockets count against the per-address limit.
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }
        let (data, resp) = try await session.data(for: req)
        return (data, try #require(resp as? HTTPURLResponse))
    }

    @Test func servesPlaylistInitAndSegmentOnLoopback() async throws {
        let store = HLSSegmentStore()
        store.setInit(Data("INIT".utf8))
        store.append(duration: 0.5, data: Data("SEGMENT-0".utf8))
        let server = HLSServer(bind: .loopback) { name in store.resource(named: name) }
        let port = try await server.start()
        defer { server.stop() }
        #expect(port > 0)
        let base = "http://127.0.0.1:\(port)/\(server.token)/"

        let (list, listResp) = try await fetch(try #require(URL(string: base + "live.m3u8")))
        #expect(listResp.statusCode == 200)
        #expect(listResp.value(forHTTPHeaderField: "Content-Type") == "application/vnd.apple.mpegurl")
        #expect(listResp.value(forHTTPHeaderField: "Cache-Control")?.contains("no-cache") == true)
        #expect(String(decoding: list, as: UTF8.self).contains("seg0.m4s"))

        let (initData, initResp) = try await fetch(try #require(URL(string: base + "init.mp4")))
        #expect(initResp.statusCode == 200 && initResp.value(forHTTPHeaderField: "Content-Type") == "video/mp4")
        #expect(initData == Data("INIT".utf8))

        let (seg, segResp) = try await fetch(try #require(URL(string: base + "seg0.m4s")))
        #expect(segResp.statusCode == 200 && segResp.value(forHTTPHeaderField: "Content-Type") == "video/mp4")
        #expect(seg == Data("SEGMENT-0".utf8))

        let (head, headResp) = try await fetch(try #require(URL(string: base + "seg0.m4s")), method: "HEAD")
        #expect(headResp.statusCode == 200 && head.isEmpty)
        #expect(headResp.value(forHTTPHeaderField: "Content-Length") == "9")

        let (_, missing) = try await fetch(try #require(URL(string: base + "seg9.m4s")))
        #expect(missing.statusCode == 404)
        let (_, wrong) = try await fetch(try #require(URL(string: "http://127.0.0.1:\(port)/\(String(repeating: "0", count: 32))/live.m3u8")))
        #expect(wrong.statusCode == 404)
        let (_, noToken) = try await fetch(try #require(URL(string: "http://127.0.0.1:\(port)/live.m3u8")))
        #expect(noToken.statusCode == 404)
    }

    @Test func stopsCleanly() async throws {
        let server = HLSServer(bind: .loopback) { _ in nil }
        let port = try await server.start()
        server.stop()
        try await Task.sleep(nanoseconds: 150_000_000)
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/\(server.token)/live.m3u8"))
        await #expect(throws: (any Error).self) { _ = try await fetch(url) }
        server.stop()   // a second stop is harmless
    }

    @Test func lanBindToUnknownInterfaceFails() async {
        let server = HLSServer(bind: .lan(interfaceName: "nonexistent9")) { _ in nil }
        await #expect(throws: (any Error).self) { _ = try await server.start() }
    }

    // MARK: Raw loopback sockets (limits, deadlines, stop before ready)

    private func rawConnect(_ port: UInt16, receiveTimeout: Int = 2) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        try #require(fd >= 0)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: receiveTimeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = UInt32(0x7F000001).bigEndian
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try #require(rc == 0)
        return fd
    }

    /// Reads until EOF, reset or timeout. `closed` is false when the read timed out with the peer still open.
    private func rawRead(_ fd: Int32) -> (text: String, closed: Bool) {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n > 0 { out.append(contentsOf: buf[0 ..< n]); continue }
            if n == 0 { return (String(decoding: out, as: UTF8.self), true) }
            return (String(decoding: out, as: UTF8.self), errno != EAGAIN && errno != EWOULDBLOCK)
        }
    }

    @Test func dribblingConnectionIsClosedAtTheHardDeadline() async throws {
        let server = HLSServer(bind: .loopback, limits: .init(headerDeadline: 0.3)) { _ in nil }
        let port = try await server.start()
        defer { server.stop() }
        let fd = try rawConnect(port)
        defer { close(fd) }
        // One byte every 100 ms would keep a per-byte idle timer alive forever.
        let started = Date()
        var sendFailed = false
        for _ in 0 ..< 15 {
            if send(fd, "G", 1, 0) < 0 { sendFailed = true; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let result = rawRead(fd)
        #expect(sendFailed || result.closed)
        #expect(Date().timeIntervalSince(started) < 1.9)
    }

    @Test func connectionOverPerAddressLimitIsRejected() async throws {
        let server = HLSServer(bind: .loopback, limits: .init(headerDeadline: 5)) { _ in nil }
        let port = try await server.start()
        defer { server.stop() }
        var held: [Int32] = []
        defer { held.forEach { close($0) } }
        for _ in 0 ..< HLSServer.Limits().maxConnectionsPerAddress { held.append(try rawConnect(port)) }
        try await Task.sleep(nanoseconds: 300_000_000)   // let the server accept all of them
        let extra = try rawConnect(port, receiveTimeout: 1)
        defer { close(extra) }
        #expect(rawRead(extra).closed)
        // The held ones stay open (their read just times out).
        #expect(rawRead(try #require(held.first)).closed == false)
    }

    @Test func oversizedHeaderGets431() async throws {
        let server = HLSServer(bind: .loopback, limits: .init(headerDeadline: 5)) { _ in nil }
        let port = try await server.start()
        defer { server.stop() }
        let fd = try rawConnect(port)
        defer { close(fd) }
        let junk = [UInt8](repeating: UInt8(ascii: "A"), count: 20 * 1024)
        _ = send(fd, "GET /", 5, 0)
        _ = send(fd, junk, junk.count, 0)
        let result = rawRead(fd)
        #expect(result.text.hasPrefix("HTTP/1.1 431") || result.closed)
        #expect(result.closed)
    }

    @Test func stopBeforeReadyEndsStartWithCancellation() async throws {
        let server = HLSServer(bind: .loopback) { _ in nil }
        let task = Task { try await server.start() }
        server.stop()
        let outcome = await task.result
        // Either stop ran first (start refused) or start was pending (cancelled); never a hang, never a live listener.
        if case .success = outcome { Issue.record("start must not succeed after stop") }
        await #expect(throws: (any Error).self) { _ = try await server.start() }
    }

    @Test func secondStartDoesNotReplaceTheListener() async throws {
        let server = HLSServer(bind: .loopback) { _ in nil }
        let port = try await server.start()
        defer { server.stop() }
        await #expect(throws: HLSServer.ServerError.self) { _ = try await server.start() }
        #expect(server.port == port)
    }
}
