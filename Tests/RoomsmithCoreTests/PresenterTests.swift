import Testing
import Foundation
import CoreGraphics
import CoreVideo
@testable import RoomsmithCore

@Suite("Presenter composition")
struct PresenterCompositionTests {
    @Test func planAndSceneFillTheCanvas() {
        let plan = PresenterComposition(layout: .plan, resolution: .hd1080)
        #expect(plan.panes == [PresenterPane(kind: .plan, cell: CGRect(x: 0, y: 0, width: 1920, height: 1080))])
        let scene = PresenterComposition(layout: .scene3D, resolution: .hd720)
        #expect(scene.panes == [PresenterPane(kind: .scene3D, cell: CGRect(x: 0, y: 0, width: 1280, height: 720))])
        #expect(plan.sourceSize(for: .scene3D) == nil)
        #expect(plan.sourceSize(for: .plan) == CGSize(width: 1920, height: 1080))
    }

    @Test func sideBySideSplitsExactly() {
        let c = PresenterComposition(layout: .sideBySide, resolution: .hd1080)
        #expect(c.panes[0] == PresenterPane(kind: .plan, cell: CGRect(x: 0, y: 0, width: 952, height: 1080)))
        #expect(c.panes[1] == PresenterPane(kind: .scene3D, cell: CGRect(x: 968, y: 0, width: 952, height: 1080)))
        let hd = PresenterComposition(layout: .sideBySide, resolution: .hd720)
        #expect(hd.panes[0].cell == CGRect(x: 0, y: 0, width: 632, height: 720))
        #expect(hd.panes[1].cell == CGRect(x: 648, y: 0, width: 632, height: 720))
        // Odd canvas: the gap grows by one pixel, the panes stay equal and inside.
        let odd = PresenterComposition(layout: .sideBySide, canvas: CGSize(width: 1281, height: 721))
        #expect(odd.panes[0].cell.width == odd.panes[1].cell.width)
        #expect(odd.panes[1].cell.maxX == 1281)
        #expect(odd.panes[0].cell.maxX <= odd.panes[1].cell.minX)
    }

    @Test func aspectFitLetterboxes() {
        let cell = CGRect(x: 968, y: 0, width: 952, height: 1080)
        // 4:3 in a tall cell: bars above and below.
        #expect(PresenterComposition.aspectFit(content: CGSize(width: 800, height: 600), in: cell)
                == CGRect(x: 968, y: 183, width: 952, height: 714))
        // 16:9 in the same cell.
        #expect(PresenterComposition.aspectFit(content: CGSize(width: 1920, height: 1080), in: cell)
                == CGRect(x: 968, y: 272, width: 952, height: 536))
        // Tall content on a wide canvas: bars left and right.
        #expect(PresenterComposition.aspectFit(content: CGSize(width: 1000, height: 2000), in: CGRect(x: 0, y: 0, width: 1920, height: 1080))
                == CGRect(x: 690, y: 0, width: 540, height: 1080))
        // Same aspect: the cell itself. Upscaling is allowed.
        #expect(PresenterComposition.aspectFit(content: CGSize(width: 960, height: 540), in: CGRect(x: 0, y: 0, width: 1920, height: 1080))
                == CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    @Test func aspectFitIgnoresDegenerateContent() {
        let cell = CGRect(x: 10, y: 20, width: 300, height: 200)
        #expect(PresenterComposition.aspectFit(content: .zero, in: cell) == cell)
        #expect(PresenterComposition.aspectFit(content: CGSize(width: Double.nan, height: 5), in: cell) == cell)
    }

    @Test func compositorPlacesPanesAndLetterboxes() throws {
        let comp = PresenterComposition(layout: .sideBySide, canvas: CGSize(width: 200, height: 100), gap: 20)
        let compositor = PresenterCompositor(composition: comp)
        // Plan: square red image in an 80x100 cell -> 80x80 centred (y 10..90). Scene absent.
        let red = try #require(Self.solid(width: 40, height: 40, r: 255, g: 0, b: 0))
        let buffer = try #require(compositor.compose(plan: .cgImage(red), scene: nil))
        func pixel(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let o = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
            return (base[o + 2], base[o + 1], base[o])   // BGRA
        }
        #expect(pixel(40, 50) == (255, 0, 0))                 // inside the plan cell, middle
        #expect(pixel(40, 3).r < 40)                          // letterbox bar above (background)
        #expect(pixel(40, 96).r < 40)                         // bar below
        #expect(pixel(150, 50).r < 40)                        // 3D cell without a source
        #expect(CVPixelBufferGetWidth(buffer) == 200 && CVPixelBufferGetHeight(buffer) == 100)
    }

    static func solid(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}

@Suite("Presenter HLS playlist and store")
struct PresenterPlaylistTests {
    private func segs(_ range: Range<Int>, duration: Double = 0.5) -> [HLSSegment] {
        range.map { HLSSegment(index: $0, duration: duration) }
    }

    @Test func slidingWindowAndMediaSequence() {
        let text = HLSPlaylist.render(segments: segs(0 ..< 10), window: 6)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.first == "#EXTM3U")
        #expect(lines.contains("#EXT-X-VERSION:7"))
        #expect(lines.contains("#EXT-X-MEDIA-SEQUENCE:4"))
        #expect(lines.contains("#EXT-X-INDEPENDENT-SEGMENTS"))
        #expect(lines.contains("#EXT-X-MAP:URI=\"init.mp4\""))
        #expect(lines.filter { $0.hasPrefix("#EXTINF") }.count == 6)
        #expect(lines.filter { $0.hasSuffix(".m4s") } == (4 ..< 10).map { "seg\($0).m4s" })
        #expect(!text.contains("#EXT-X-ENDLIST"))
        // Header order: MAP and START come before the first segment.
        #expect(text.range(of: "#EXT-X-MAP")!.lowerBound < text.range(of: "#EXTINF")!.lowerBound)
    }

    @Test func targetDurationIsTheCeilingOfTheLongestSegment() {
        func target(_ durations: [Double]) -> String {
            let s = durations.enumerated().map { HLSSegment(index: $0.offset, duration: $0.element) }
            return HLSPlaylist.render(segments: s).split(separator: "\n").first { $0.hasPrefix("#EXT-X-TARGETDURATION") }.map(String.init) ?? ""
        }
        #expect(target([0.5, 0.52]) == "#EXT-X-TARGETDURATION:1")
        #expect(target([1.0, 0.5]) == "#EXT-X-TARGETDURATION:1")
        #expect(target([1.003, 0.5]) == "#EXT-X-TARGETDURATION:2")
        #expect(target([2.4]) == "#EXT-X-TARGETDURATION:3")
        // The ceiling covers only the segments that are listed.
        let old = [HLSSegment(index: 0, duration: 4)] + segs(1 ..< 8)
        #expect(HLSPlaylist.render(segments: old, window: 6).contains("#EXT-X-TARGETDURATION:1\n"))
    }

    @Test func startOffsetAndEnd() {
        let live = HLSPlaylist.render(segments: segs(0 ..< 3), startOffset: -1.0)
        #expect(live.contains("#EXT-X-START:TIME-OFFSET=-1.000\n"))
        #expect(HLSPlaylist.render(segments: segs(0 ..< 3), startOffset: 2).contains("EXT-X-START") == false)
        #expect(HLSPlaylist.render(segments: segs(0 ..< 3), startOffset: nil).contains("EXT-X-START") == false)
        let ended = HLSPlaylist.render(segments: segs(0 ..< 3), ended: true)
        #expect(ended.hasSuffix("#EXT-X-ENDLIST\n"))
        #expect(live.contains("#EXTINF:0.500,\nseg0.m4s\n"))
    }

    @Test func segmentNameRoundTrip() {
        #expect(HLSPlaylist.segmentIndex(fromName: "seg12.m4s") == 12)
        #expect(HLSPlaylist.segmentIndex(fromName: HLSPlaylist.segmentName(0)) == 0)
        for bad in ["seg.m4s", "seg-1.m4s", "segx.m4s", "seg1.mp4", "xseg1.m4s", "seg1234567890.m4s", ""] {
            #expect(HLSPlaylist.segmentIndex(fromName: bad) == nil)
        }
    }

    @Test func storeKeepsOnlyTheNewestSegments() {
        let store = HLSSegmentStore(capacity: 8, window: 6, startOffset: -1)
        #expect(store.playlist() == nil)
        store.setInit(Data([1, 2, 3]))
        #expect(store.playlist() == nil)   // no media segment yet
        for i in 0 ..< 12 { store.append(duration: 0.5, data: Data([UInt8(i)])) }
        #expect(store.bufferedCount == 8)
        #expect(store.totalAppended == 12)
        #expect(store.resource(named: "seg3.m4s") == nil)           // evicted
        #expect(store.resource(named: "seg4.m4s")?.data == Data([4]))
        #expect(store.resource(named: "seg11.m4s")?.contentType == "video/mp4")
        #expect(store.resource(named: "seg12.m4s") == nil)
        let list = store.resource(named: "live.m3u8")
        #expect(list?.contentType == "application/vnd.apple.mpegurl")
        let text = String(decoding: list?.data ?? Data(), as: UTF8.self)
        #expect(text.contains("#EXT-X-MEDIA-SEQUENCE:6\n"))          // window of 6 of the newest 12
        #expect(store.resource(named: "init.mp4")?.data == Data([1, 2, 3]))
        #expect(store.resource(named: "other.txt") == nil)
        #expect(store.resource(named: "../init.mp4") == nil)
        store.markEnded()
        #expect(store.playlist()?.hasSuffix("#EXT-X-ENDLIST\n") == true)
    }

    @Test func storeResetKeepsIndicesIncreasing() {
        let store = HLSSegmentStore()
        store.setInit(Data([9]))
        store.append(duration: 0.5, data: Data([0]))
        store.reset()
        #expect(!store.hasInit && store.bufferedCount == 0 && !store.isEnded)
        store.setInit(Data([9]))
        #expect(store.append(duration: 0.5, data: Data([1])) == 1)
    }

    @Test func storeIsThreadSafe() async {
        let store = HLSSegmentStore()
        store.setInit(Data([0]))
        await withTaskGroup(of: Void.self) { group in
            for t in 0 ..< 4 {
                group.addTask {
                    for i in 0 ..< 200 {
                        store.append(duration: 0.5, data: Data([UInt8(t), UInt8(i % 255)]))
                        _ = store.playlist()
                        _ = store.resource(named: "seg\(i).m4s")
                    }
                }
            }
        }
        #expect(store.totalAppended == 800)
        #expect(store.bufferedCount == store.capacity)
    }
}

@Suite("Presenter HTTP")
struct PresenterHTTPTests {
    private func parse(_ text: String) -> HTTPParseResult { HTTPRequestParser.parse(Data(text.utf8)) }

    @Test func parsesGetAndHead() {
        let raw = "GET /abc/live.m3u8?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=0-9\r\n\r\n"
        guard case .request(let r, let used) = parse(raw) else { Issue.record("not parsed"); return }
        #expect(r.method == .get && r.path == "/abc/live.m3u8" && r.version == "HTTP/1.1")
        #expect(r.headers["range"] == "bytes=0-9" && r.headers["host"] == "127.0.0.1")
        #expect(used == raw.utf8.count)
        #expect(!r.wantsClose)
        guard case .request(let h, _) = parse("HEAD /a/b HTTP/1.1\r\nConnection: close\r\n\r\n") else { Issue.record("head"); return }
        #expect(h.method == .head && h.wantsClose)
        guard case .request(let old, _) = parse("GET /a/b HTTP/1.0\r\n\r\n") else { Issue.record("1.0"); return }
        #expect(old.wantsClose)
    }

    @Test func pipelinedRequestsConsumeOneAtATime() {
        let one = "GET /a/b HTTP/1.1\r\nHost: x\r\n\r\n"
        let data = Data((one + "GET /a/c HTTP/1.1\r\nHost: x\r\n\r\n").utf8)
        guard case .request(_, let used) = HTTPRequestParser.parse(data) else { Issue.record("no request"); return }
        #expect(used == one.utf8.count)
        guard case .request(let second, _) = HTTPRequestParser.parse(data.dropFirst(used)) else { Issue.record("no second"); return }
        #expect(second.path == "/a/c")
    }

    @Test func incompleteAndOversizedHeaders() {
        #expect(parse("GET /a/b HTTP/1.1\r\nHost: x\r\n") == .needMoreData)
        #expect(parse("") == .needMoreData)
        let big = "GET /a/b HTTP/1.1\r\nX: " + String(repeating: "a", count: 9000) + "\r\n\r\n"
        #expect(parse(big) == .reject(status: 431))
        // Never ending header without terminator is cut off, too.
        #expect(HTTPRequestParser.parse(Data(repeating: 65, count: 9000)) == .reject(status: 431))
        let many = "GET /a/b HTTP/1.1\r\n" + (0 ..< 100).map { "H\($0): v\r\n" }.joined() + "\r\n"
        #expect(parse(many) == .reject(status: 431))
    }

    @Test func rejectsInvalidMethodsVersionsAndBodies() {
        #expect(parse("POST /a/b HTTP/1.1\r\n\r\n") == .reject(status: 405))
        #expect(parse("DELETE /a/b HTTP/1.1\r\n\r\n") == .reject(status: 405))
        #expect(parse("FETCH /a/b HTTP/1.1\r\n\r\n") == .reject(status: 400))
        #expect(parse("GET /a/b HTTP/2.0\r\n\r\n") == .reject(status: 505))
        #expect(parse("GET /a/b\r\n\r\n") == .reject(status: 400))
        #expect(parse("GET /a/b HTTP/1.1 extra\r\n\r\n") == .reject(status: 400))
        #expect(parse("GET /a/b HTTP/1.1\r\nbroken header\r\n\r\n") == .reject(status: 400))
        #expect(parse("GET /a/b HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello") == .reject(status: 400))
        #expect(parse("GET /a/b HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n") == .reject(status: 400))
        #expect(parse("GET http://evil/a/b HTTP/1.1\r\n\r\n") == .reject(status: 400))
    }

    @Test func rejectsPathTraversalAndOddPaths() {
        let bad = ["/../etc/passwd", "/a/../b", "/a/./b", "/%2e%2e/a", "/a/%2E%2e/b", "/a%2fb", "/a%5cb", "/a\\b", "//a/b", "/a//b",
                   "/a/%00", "/a b", "/a/\u{e9}", "/" + String(repeating: "a", count: 600), "/a/%252e%252e"]
        for p in bad {
            #expect(HTTPRequestParser.sanitizedPath(p) == nil, "\(p.prefix(30))")
        }
        #expect(HTTPRequestParser.sanitizedPath("/tok/seg1.m4s") == "/tok/seg1.m4s")
        #expect(HTTPRequestParser.sanitizedPath("/tok/live.m3u8?a=b#c") == "/tok/live.m3u8")
    }

    @Test func routeNeedsTheExactToken() {
        let token = HLSRoute.makeToken()
        #expect(HLSRoute.resourceName(path: "/\(token)/live.m3u8", token: token) == "live.m3u8")
        #expect(HLSRoute.resourceName(path: "/\(token)/seg7.m4s", token: token) == "seg7.m4s")
        #expect(HLSRoute.resourceName(path: "/wrong/live.m3u8", token: token) == nil)
        #expect(HLSRoute.resourceName(path: "/\(token.dropLast())/live.m3u8", token: token) == nil)
        #expect(HLSRoute.resourceName(path: "/live.m3u8", token: token) == nil)
        #expect(HLSRoute.resourceName(path: "/\(token)/", token: token) == nil)
        #expect(HLSRoute.resourceName(path: "/\(token)/a/live.m3u8", token: token) == nil)
        #expect(HLSRoute.resourceName(path: "/\(token)/.hidden", token: token) == nil)
        #expect(HLSRoute.resourceName(path: "/\(token)/a b", token: token) == nil)
    }

    @Test func tokensAreLongRandomAndHex() {
        let a = HLSRoute.makeToken(), b = HLSRoute.makeToken()
        #expect(a.count == 32 && a != b)
        #expect(a.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    @Test func rangeHeader() {
        #expect(HTTPRange.parse("bytes=0-9", length: 100) == .range(0 ... 9))
        #expect(HTTPRange.parse("bytes=90-", length: 100) == .range(90 ... 99))
        #expect(HTTPRange.parse("bytes=-10", length: 100) == .range(90 ... 99))
        #expect(HTTPRange.parse("bytes=50-500", length: 100) == .range(50 ... 99))
        #expect(HTTPRange.parse("bytes=100-", length: 100) == .unsatisfiable)
        #expect(HTTPRange.parse("bytes=0-1,5-6", length: 100) == nil)
        #expect(HTTPRange.parse("items=0-1", length: 100) == nil)
        #expect(HTTPRange.parse("bytes=9-3", length: 100) == nil)
        #expect(HTTPRange.parse(nil, length: 100) == nil)
    }

    @Test func responses() throws {
        func text(_ d: Data) -> String { String(decoding: d, as: UTF8.self) }
        let res = HLSResource(contentType: "video/mp4", data: Data("0123456789".utf8))
        func request(_ method: String, range: String? = nil, close: Bool = false) throws -> HTTPRequest {
            var raw = "\(method) /t/init.mp4 HTTP/1.1\r\nHost: x\r\n"
            if let range { raw += "Range: \(range)\r\n" }
            if close { raw += "Connection: close\r\n" }
            guard case .request(let r, _) = parse(raw + "\r\n") else { throw CocoaError(.fileReadCorruptFile) }
            return r
        }
        let ok = text(HTTPResponse.answer(try request("GET"), resource: res))
        #expect(ok.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(ok.contains("Content-Type: video/mp4\r\n") && ok.contains("Content-Length: 10\r\n"))
        #expect(ok.contains("Cache-Control: no-cache") && ok.contains("Connection: keep-alive\r\n"))
        #expect(ok.hasSuffix("\r\n\r\n0123456789"))
        let head = text(HTTPResponse.answer(try request("HEAD"), resource: res))
        #expect(head.contains("Content-Length: 10\r\n") && head.hasSuffix("\r\n\r\n"))
        let part = text(HTTPResponse.answer(try request("GET", range: "bytes=2-4"), resource: res))
        #expect(part.hasPrefix("HTTP/1.1 206 Partial Content\r\n") && part.contains("Content-Range: bytes 2-4/10\r\n") && part.hasSuffix("234"))
        let bad = text(HTTPResponse.answer(try request("GET", range: "bytes=20-"), resource: res))
        #expect(bad.hasPrefix("HTTP/1.1 416") && bad.contains("Content-Range: bytes */10\r\n"))
        let missing = text(HTTPResponse.answer(try request("GET", close: true), resource: nil))
        #expect(missing.hasPrefix("HTTP/1.1 404 Not Found\r\n") && missing.contains("Connection: close\r\n"))
    }
}

@Suite("Presenter network address")
struct PresenterAddressTests {
    private func iface(_ name: String, _ ip: String, up: Bool = true, loop: Bool = false, p2p: Bool = false) -> PresenterNetworkInterface {
        PresenterNetworkInterface(name: name, address: ip, isUp: up, isLoopback: loop, isPointToPoint: p2p)
    }

    @Test func selectsTheLANInterface() {
        let list = [iface("lo0", "127.0.0.1", loop: true), iface("utun3", "10.8.0.2", p2p: true),
                    iface("awdl0", "169.254.7.7"), iface("en0", "192.168.1.20"), iface("bridge100", "192.168.64.1")]
        #expect(PresenterLANAddress.select(from: list)?.name == "en0")
    }

    @Test func skipsDownLoopbackLinkLocalAndTunnels() {
        #expect(PresenterLANAddress.select(from: []) == nil)
        #expect(PresenterLANAddress.select(from: [iface("lo0", "127.0.0.1", loop: true), iface("en0", "192.168.1.5", up: false),
                                                  iface("en1", "169.254.1.1"), iface("utun0", "10.0.0.1", p2p: true)]) == nil)
        #expect(PresenterLANAddress.select(from: [iface("en0", "0.0.0.0"), iface("en1", "239.1.1.1")]) == nil)
    }

    @Test func prefersPrivateAddressesAndEthernetOrWiFiNames() {
        let list = [iface("en4", "203.0.113.9"), iface("en0", "10.0.0.5"), iface("pdp_ip0", "172.20.1.1")]
        #expect(PresenterLANAddress.select(from: list)?.name == "en0")
        #expect(PresenterLANAddress.select(from: [iface("en0", "172.32.0.1"), iface("en1", "172.31.0.1")])?.name == "en1")  // 172.32 is public
        // A preferred interface that is usable wins; an unusable one is ignored.
        #expect(PresenterLANAddress.select(from: [iface("en0", "192.168.1.5"), iface("en7", "192.168.5.5")], preferred: "en7")?.name == "en7")
        #expect(PresenterLANAddress.select(from: [iface("en0", "192.168.1.5"), iface("en7", "192.168.5.5", up: false)], preferred: "en7")?.name == "en0")
    }

    @Test func addressOfNamedInterface() {
        let list = [iface("en0", "192.168.1.5"), iface("en1", "192.168.1.6", up: false), iface("lo0", "127.0.0.1", loop: true)]
        #expect(PresenterLANAddress.address(ofInterface: "en0", in: list) == "192.168.1.5")
        #expect(PresenterLANAddress.address(ofInterface: "en1", in: list) == nil)
        #expect(PresenterLANAddress.address(ofInterface: "lo0", in: list) == nil)
        #expect(PresenterLANAddress.address(ofInterface: "nope", in: list) == nil)
    }

    @Test func hostSwapKeepsPortAndPath() throws {
        let url = try #require(PresenterLANAddress.streamURL(host: "127.0.0.1", port: 50123, token: "abc"))
        #expect(url.absoluteString == "http://127.0.0.1:50123/abc/live.m3u8")
        let lan = try #require(PresenterLANAddress.replacingHost(in: url, with: "192.168.1.20"))
        #expect(lan.absoluteString == "http://192.168.1.20:50123/abc/live.m3u8")
        let back = try #require(PresenterLANAddress.replacingHost(in: lan, with: PresenterLANAddress.loopbackHost))
        #expect(back == url)
        #expect(PresenterLANAddress.isLoopbackHost(url.host))
        #expect(!PresenterLANAddress.isLoopbackHost(lan.host))
        #expect(PresenterLANAddress.isLoopbackHost("localhost") && PresenterLANAddress.isLoopbackHost("127.1.2.3"))
        #expect(!PresenterLANAddress.isLoopbackHost(nil))
    }

    @Test func systemListContainsLoopback() {
        let all = PresenterLANAddress.currentInterfaces()
        #expect(all.contains { $0.isLoopback && $0.address == "127.0.0.1" })
        // Whatever is chosen is never loopback, never link-local.
        if let chosen = PresenterLANAddress.current() { #expect(!chosen.isLoopback && !chosen.address.hasPrefix("169.254.")) }
    }
}

@Suite("Presenter status")
struct PresenterStatusTests {
    private func run(_ events: [PresenterEvent]) -> PresenterStatus {
        var s = PresenterStatus()
        for e in events { s.apply(e) }
        return s
    }

    @Test func happyPathThroughAirPlayAndBack() {
        var s = PresenterStatus()
        #expect(s.state == .idle && !s.isActive)
        #expect(s.apply(.startRequested) && s.state == .starting && s.isActive)
        #expect(s.apply(.ready(latencyEstimate: 2.5)) && s.state == .live(latencyEstimate: 2.5))
        #expect(s.apply(.latencyUpdated(3)) && s.state == .live(latencyEstimate: 3))
        #expect(s.apply(.externalPlaybackChanged(active: true, routeName: "Living Room")) && s.state == .external(routeName: "Living Room"))
        #expect(s.apply(.latencyUpdated(4)) && s.state == .external(routeName: "Living Room"))
        #expect(s.apply(.externalPlaybackChanged(active: false, routeName: nil)) && s.state == .live(latencyEstimate: 4))
        #expect(s.apply(.stopRequested) && s.state == .stopping)
        #expect(s.apply(.stopped) && s.state == .idle)
    }

    @Test func invalidEventsAreIgnored() {
        var s = PresenterStatus()
        #expect(!s.apply(.stopRequested) && s.state == .idle)
        #expect(!s.apply(.ready(latencyEstimate: 1)) && s.state == .idle)
        #expect(!s.apply(.externalPlaybackChanged(active: true, routeName: "TV")) && s.state == .idle)
        s.apply(.startRequested)
        #expect(!s.apply(.startRequested) && s.state == .starting)
        #expect(!s.apply(.latencyUpdated(1)) && s.state == .starting)
        s.apply(.stopRequested)
        #expect(!s.apply(.ready(latencyEstimate: 1)) && s.state == .stopping)
    }

    @Test func failuresAndRestart() {
        var s = run([.startRequested, .failure(.localNetworkDenied)])
        #expect(s.state == .failed(PresenterFailure.localNetworkDenied.message))
        #expect(s.state != .idle && !s.isActive)
        #expect(s.line.contains("System Settings › Privacy & Security › Local Network"))
        #expect(s.apply(.startRequested) && s.state == .starting)
        s.apply(.ready(latencyEstimate: 2))
        s.apply(.failure(.encoderFailed("disk")))
        #expect(s.state == .failed("Video encoding failed: disk"))
        // A failure while stopping just ends in idle.
        s = run([.startRequested, .stopRequested, .failure(.playerFailed("x"))])
        #expect(s.state == .idle)
        // A failure before start (e.g. the display vanished) is reported, too.
        s = run([.failure(.displayRemoved)])
        #expect(s.state == .failed("The presenter display was disconnected"))
    }

    @Test func routeBeforeReadyIsAccepted() {
        let s = run([.startRequested, .externalPlaybackChanged(active: true, routeName: nil)])
        #expect(s.state == .external(routeName: "AirPlay"))
    }

    @Test func lineTextsAreEnglishSentences() {
        #expect(PresenterStatus().line == "Not presenting")
        #expect(run([.startRequested]).line == "Starting…")
        #expect(run([.startRequested, .ready(latencyEstimate: 2.5)]).line == "Live preview on this Mac (about 2.5 s delay)")
        #expect(run([.startRequested, .externalPlaybackChanged(active: true, routeName: "Den")]).line == "Playing on Den")
        #expect(run([.startRequested, .stopRequested]).line == "Stopping…")
        for f: PresenterFailure in [.noNetworkInterface, .serverFailed("x"), .encoderFailed("x"), .playerFailed("x"), .displayRemoved, .serverStopped] {
            #expect(!f.message.isEmpty)
        }
    }
}
