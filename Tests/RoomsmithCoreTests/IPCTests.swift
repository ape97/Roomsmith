import Foundation
import Synchronization
import Testing
@testable import RoomsmithCore
@testable import RoomsmithIPC

private let testToken = "secret-token"

private func tempSocketPath() -> String {
    "/private/tmp/rs-ipc-\(UUID().uuidString.prefix(8).lowercased()).sock"
}

private final class Counter: Sendable {
    private let value = Mutex(0)
    func increment() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

private let sampleTools = [
    ToolDescriptor(name: "echo", description: "Echo", readOnly: true),
    ToolDescriptor(name: "wall.add", description: "Add a wall", readOnly: false),
]

@Sendable private func echoHandler(_ request: AgentRequest) async -> AgentResponse {
    switch request.tool {
    case "slow":
        try? await Task.sleep(for: .seconds(1))
    case "fail":
        return .failure(id: request.id, AgentError(code: AgentError.notFound, message: "nope", details: ["x": 1]))
    case agentListToolsName:
        return .success(id: request.id, (try? JSONValue(encoding: sampleTools)) ?? .null)
    default:
        break
    }
    return .success(id: request.id, [
        "tool": .string(request.tool),
        "arguments": request.arguments,
        "clientId": .string(request.clientId),
    ])
}

private func withServer(
    handler: @escaping AgentSocketServer.Handler = echoHandler,
    _ body: (String) async throws -> Void
) async throws {
    let path = tempSocketPath()
    let server = AgentSocketServer(socketPath: path, token: testToken, handler: handler)
    try server.start()
    defer {
        server.stop()
        unlink(path)
    }
    try await body(path)
}

private func withServerAt(_ path: String, _ body: () async throws -> Void) async throws {
    let server = AgentSocketServer(socketPath: path, token: testToken, handler: echoHandler)
    try server.start()
    defer { server.stop(); unlink(path) }
    try await body()
}

private func rawConnect(_ path: String) throws -> Int32 { try UnixSocket.connect(path: path) }

private func rawSend(_ fd: Int32, _ request: AgentRequest) throws {
    var data = try JSONEncoder().encode(request)
    data.append(10)
    try UnixSocket.writeAll(fd, data, deadline: UnixSocket.deadline(after: 5))
}

private func rawRead(_ fd: Int32) throws -> AgentResponse {
    let data = try UnixSocket.readLine(fd, deadline: UnixSocket.deadline(after: 10), maxBytes: 1 << 26)
    return try JSONDecoder().decode(AgentResponse.self, from: data)
}

private struct FakeTransport: AgentTransport {
    let handler: @Sendable (String, JSONValue) async throws -> JSONValue
    func call(_ tool: String, _ args: JSONValue) async throws -> JSONValue { try await handler(tool, args) }
}

private func parse(_ line: String?) throws -> JSONValue {
    try JSONValue.parse(Data(try #require(line).utf8))
}

@Suite("IPC") struct IPCTests {
    // MARK: JSONValue

    @Test func jsonValueKeepsInt64Exact() throws {
        for value in [Int64.max, Int64.min, 0, -1, 9_007_199_254_740_993] {
            let text = JSONValue.int(value).jsonString()
            #expect(text == String(value))
            #expect(try JSONValue.parse(Data(text.utf8)) == .int(value))
        }
        let object = try JSONValue.parse(Data(#"{"a":9223372036854775807,"b":1.5,"c":[true,null,"x"]}"#.utf8))
        #expect(object["a"]?.int64Value == Int64.max)
        #expect(object["b"]?.doubleValue == 1.5)
        #expect(object["b"]?.int64Value == nil)
        #expect(object["c"]?[0]?.boolValue == true)
        #expect(object["c"]?[2]?.stringValue == "x")
        #expect(JSONValue.int(5).jsonString() == "5")
    }

    @Test func jsonValueCodableRoundTrip() throws {
        struct Sample: Codable, Equatable { var name: String; var count: Int64; var ratio: Double }
        let sample = Sample(name: "w", count: 4_000_000_000_000, ratio: 0.25)
        let value = try JSONValue(encoding: sample)
        #expect(value["count"]?.int64Value == 4_000_000_000_000)
        #expect(try value.decode(Sample.self) == sample)
    }

    // MARK: Server and client

    @Test func callSucceeds() async throws {
        try await withServer { path in
            let client = AgentSocketClient(socketPath: path, token: testToken, clientId: "tester")
            let result = try await client.call("echo", arguments: ["a": 1])
            #expect(result["tool"]?.stringValue == "echo")
            #expect(result["arguments"]?["a"]?.int64Value == 1)
            #expect(result["clientId"]?.stringValue == "tester")
        }
    }

    @Test func handlerErrorIsThrown() async throws {
        try await withServer { path in
            let client = AgentSocketClient(socketPath: path, token: testToken, clientId: "t")
            do {
                _ = try await client.call("fail")
                Issue.record("expected error")
            } catch let error as AgentError {
                #expect(error.code == AgentError.notFound)
                #expect(error.details?["x"]?.int64Value == 1)
            }
        }
    }

    @Test func wrongTokenIsUnauthorizedWithoutHandlerCall() async throws {
        let counter = Counter()
        try await withServer(handler: { request in
            counter.increment()
            return .success(id: request.id, .null)
        }) { path in
            let client = AgentSocketClient(socketPath: path, token: "wrong", clientId: "t")
            do {
                _ = try await client.call("echo")
                Issue.record("expected error")
            } catch let error as AgentError {
                #expect(error.code == AgentError.unauthorized)
            }
            #expect(counter.count == 0)
        }
    }

    @Test func wrongTokenTriggersAuthCallbackWithoutToken() async throws {
        let seen = Mutex<[String]>([])
        let path = tempSocketPath()
        let server = AgentSocketServer(socketPath: path, token: testToken, onAuthFailure: { client, tool in
            seen.withLock { $0.append("\(client)|\(tool)") }
        }, handler: echoHandler)
        try server.start()
        defer { server.stop(); unlink(path) }
        let client = AgentSocketClient(socketPath: path, token: "wrong-secret", clientId: "intruder")
        _ = try? await client.call("echo")
        let entries = seen.withLock { $0 }
        #expect(entries == ["intruder|echo"])
        #expect(!entries.joined().contains("wrong-secret"))
    }

    @Test func malformedRequestIsInvalidArgument() async throws {
        try await withServer { path in
            let fd = try rawConnect(path)
            defer { close(fd) }
            try UnixSocket.writeAll(fd, Data("{\"id\":7,\"foo\":1}\n".utf8), deadline: UnixSocket.deadline(after: 5))
            let response = try rawRead(fd)
            #expect(response.id == 7)
            #expect(response.error?.code == AgentError.invalidArgument)
        }
    }

    @Test func fiftyParallelCallsAreMatched() async throws {
        try await withServer { path in
            let client = AgentSocketClient(socketPath: path, token: testToken, clientId: "t")
            try await withThrowingTaskGroup(of: (Int64, Int64?).self) { group in
                for n in 0..<50 {
                    group.addTask {
                        let result = try await client.call("echo", arguments: ["n": .int(Int64(n))])
                        return (Int64(n), result["arguments"]?["n"]?.int64Value)
                    }
                }
                var seen = 0
                for try await (expected, actual) in group {
                    #expect(actual == expected)
                    seen += 1
                }
                #expect(seen == 50)
            }
        }
    }

    @Test func slowHandlerDoesNotBlockSameConnection() async throws {
        try await withServer { path in
            let fd = try rawConnect(path)
            defer { close(fd) }
            let started = Date()
            try rawSend(fd, AgentRequest(id: 1, token: testToken, clientId: "t", tool: "slow"))
            try rawSend(fd, AgentRequest(id: 2, token: testToken, clientId: "t", tool: "echo"))
            let first = try rawRead(fd)
            #expect(first.id == 2)
            #expect(Date().timeIntervalSince(started) < 0.8)
            let second = try rawRead(fd)
            #expect(second.id == 1)
            #expect(Date().timeIntervalSince(started) >= 0.9)
        }
    }

    @Test func largeArgumentArrives() async throws {
        try await withServer { path in
            let client = AgentSocketClient(socketPath: path, token: testToken, clientId: "t")
            let big = String(repeating: "x", count: 5 * 1024 * 1024)
            let result = try await client.call("echo", arguments: ["blob": .string(big)])
            #expect(result["arguments"]?["blob"]?.stringValue?.utf8.count == big.utf8.count)
        }
    }

    @Test func serverSurvivesAbortedClients() async throws {
        try await withServer { path in
            // Partial line, then drop.
            let a = try rawConnect(path)
            try UnixSocket.writeAll(a, Data("{\"id\":1,\"tok".utf8), deadline: UnixSocket.deadline(after: 5))
            close(a)
            // Slow request, drop before the response is written.
            let b = try rawConnect(path)
            try rawSend(b, AgentRequest(id: 2, token: testToken, clientId: "t", tool: "slow"))
            close(b)
            try await Task.sleep(for: .milliseconds(1300))
            let client = AgentSocketClient(socketPath: path, token: testToken, clientId: "t")
            let result = try await client.call("echo", arguments: ["ok": true])
            #expect(result["arguments"]?["ok"]?.boolValue == true)
        }
    }

    @Test func unreachableAppReportsNotRunning() async throws {
        let client = AgentSocketClient(socketPath: tempSocketPath(), token: testToken, clientId: "t")
        do {
            _ = try await client.call("echo")
            Issue.record("expected error")
        } catch let error as AgentError {
            #expect(error.code == AgentError.notRunning)
            #expect(error.message.contains("Start Roomsmith first"))
        }
    }

    @Test func socketFileIsPrivate() async throws {
        try await withServer { path in
            var info = stat()
            #expect(stat(path, &info) == 0)
            #expect(info.st_mode & 0o777 == 0o600)
        }
    }

    @Test func tokenFileRoundTrip() throws {
        let dir = "/private/tmp/rs-tok-\(UUID().uuidString.prefix(8).lowercased())"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("agent-token")
        let token = try AgentToken.loadOrCreate(at: url)
        #expect(token.count == 64)
        #expect(try AgentToken.loadOrCreate(at: url) == token)
        #expect(try AgentToken.load(at: url) == token)
        var info = stat()
        #expect(stat(url.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(stat(dir, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700)
    }

    @Test func tokenFileModeIsTightened() throws {
        let dir = "/private/tmp/rs-tok-\(UUID().uuidString.prefix(8).lowercased())"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("agent-token")
        let token = try AgentToken.loadOrCreate(at: url)
        chmod(url.path, 0o644)
        #expect(try AgentToken.loadOrCreate(at: url) == token)
        var info = stat()
        #expect(stat(url.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
    }

    @Test func unusableTokenFileDoesNotRecurseForever() throws {
        // A directory at the token path can neither be read nor created over; removal is possible, so it is replaced once.
        let dir = "/private/tmp/rs-tok-\(UUID().uuidString.prefix(8).lowercased())"
        defer { chmod(dir, 0o700); try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/agent-token/sub", withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: dir).appendingPathComponent("agent-token")
        // Non-empty directory: removeItem succeeds (recursive), so the retry creates the file.
        #expect(try AgentToken.loadOrCreate(at: url).count == 64)
        // Parent not writable: remove fails -> must throw, not loop.
        let dir2 = "/private/tmp/rs-tok-\(UUID().uuidString.prefix(8).lowercased())"
        try FileManager.default.createDirectory(atPath: dir2 + "/agent-token", withIntermediateDirectories: true)
        chmod(dir2, 0o500)
        defer { chmod(dir2, 0o700); try? FileManager.default.removeItem(atPath: dir2) }
        if geteuid() != 0 {
            #expect(throws: AgentError.self) { try AgentToken.loadOrCreate(at: URL(fileURLWithPath: dir2).appendingPathComponent("agent-token")) }
        }
    }

    @Test func nonReadingClientIsCutOffAfterSendTimeout() async throws {
        let path = tempSocketPath()
        let server = AgentSocketServer(socketPath: path, token: testToken, handler: echoHandler)
        server.limits.sendTimeout = 0.5
        try server.start()
        defer { server.stop(); unlink(path) }
        let fd = try rawConnect(path)
        defer { close(fd) }
        var small = 4096
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &small, socklen_t(MemoryLayout<Int>.size))
        let big = String(repeating: "x", count: 8 * 1024 * 1024)
        try rawSend(fd, AgentRequest(id: 1, token: testToken, clientId: "t", tool: "echo", arguments: ["blob": .string(big)]))
        // The client never reads; the server must give up on its own.
        for _ in 0..<40 where server.connectionCount > 0 { try await Task.sleep(for: .milliseconds(250)) }
        #expect(server.connectionCount == 0)
    }

    @Test func connectionCapRejectsExtraClients() async throws {
        let path = tempSocketPath()
        let server = AgentSocketServer(socketPath: path, token: testToken, handler: echoHandler)
        server.limits.maxConnections = 2
        try server.start()
        defer { server.stop(); unlink(path) }
        let a = try rawConnect(path), b = try rawConnect(path)
        defer { close(a); close(b) }
        try await Task.sleep(for: .milliseconds(400))
        let c = try rawConnect(path)
        defer { close(c) }
        let response = try rawRead(c)
        #expect(!response.ok)
        #expect(response.error?.message.contains("Too many connections") == true)
        // Admitted clients still work.
        try rawSend(a, AgentRequest(id: 5, token: testToken, clientId: "t", tool: "echo"))
        #expect(try rawRead(a).ok)
    }

    @Test func idleConnectionIsClosed() async throws {
        let path = tempSocketPath()
        let server = AgentSocketServer(socketPath: path, token: testToken, handler: echoHandler)
        server.limits.idleTimeout = 0.5
        try server.start()
        defer { server.stop(); unlink(path) }
        let fd = try rawConnect(path)
        defer { close(fd) }
        try UnixSocket.writeAll(fd, Data("{\"id\":1,\"tok".utf8), deadline: UnixSocket.deadline(after: 5))
        let response = try rawRead(fd)
        #expect(!response.ok)
        #expect(response.error?.message.contains("No complete request line") == true)
        for _ in 0..<20 where server.connectionCount > 0 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(server.connectionCount == 0)
    }

    @Test func staleSocketFileIsReplaced() async throws {
        let path = tempSocketPath()
        // Leave a stale socket file behind: bind without listening, close, keep the file.
        var addr = try UnixSocket.makeAddress(path)
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        close(stale)
        #expect(access(path, F_OK) == 0)
        try await withServerAt(path) {
            let client = AgentSocketClient(socketPath: path, token: testToken, clientId: "t")
            let reply = try await client.call("echo")
            #expect(reply["tool"]?.stringValue == "echo")
        }
    }

    @Test func secondServerOnSamePathFailsAndFirstSurvives() async throws {
        try await withServer { path in
            let second = AgentSocketServer(socketPath: path, token: testToken, handler: echoHandler)
            do {
                try second.start()
                Issue.record("expected start() to fail")
            } catch let error as AgentError {
                #expect(error.message.contains("Another Roomsmith instance is already serving agents"))
            }
            second.stop()
            // The failed second server must not have removed the first one's socket.
            let client = AgentSocketClient(socketPath: path, token: testToken, clientId: "t")
            let reply = try await client.call("echo")
            #expect(reply["tool"]?.stringValue == "echo")
        }
    }

    @Test func stopKeepsSocketFileOfNewerOwner() async throws {
        let path = tempSocketPath()
        let first = AgentSocketServer(socketPath: path, token: testToken, handler: echoHandler)
        try first.start()
        // Another process replaces the file (new inode) while the first server still runs.
        unlink(path)
        let second = AgentSocketServer(socketPath: path, token: testToken, handler: echoHandler)
        try second.start()
        defer { second.stop(); unlink(path) }
        first.stop()
        #expect(access(path, F_OK) == 0)
        let client = AgentSocketClient(socketPath: path, token: testToken, clientId: "t")
        let reply = try await client.call("echo")
        #expect(reply["tool"]?.stringValue == "echo")
    }

    @Test func pipelinedRequestsGetTwoResponses() async throws {
        try await withServer { path in
            let fd = try rawConnect(path)
            defer { close(fd) }
            var data = Data()
            for id in [1, 2] as [Int64] {
                data.append(try JSONEncoder().encode(AgentRequest(id: id, token: testToken, clientId: "t", tool: "echo")))
                data.append(10)
            }
            try UnixSocket.writeAll(fd, data, deadline: UnixSocket.deadline(after: 5))
            var buffer = Data()
            var ids = Set<Int64>()
            for _ in 0..<2 {
                let line = try UnixSocket.readLine(fd, buffer: &buffer, deadline: UnixSocket.deadline(after: 10), maxBytes: 1 << 20)
                ids.insert(try JSONDecoder().decode(AgentResponse.self, from: line).id)
            }
            #expect(ids == [1, 2])
        }
    }

    @Test func readLineKeepsBytesAfterNewline() throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        try UnixSocket.writeAll(fds[0], Data("one\ntwo\nthr".utf8), deadline: UnixSocket.deadline(after: 5))
        var buffer = Data()
        let d = UnixSocket.deadline(after: 5)
        #expect(String(decoding: try UnixSocket.readLine(fds[1], buffer: &buffer, deadline: d, maxBytes: 1024), as: UTF8.self) == "one")
        #expect(String(decoding: try UnixSocket.readLine(fds[1], buffer: &buffer, deadline: d, maxBytes: 1024), as: UTF8.self) == "two")
        try UnixSocket.writeAll(fds[0], Data("ee\n".utf8), deadline: d)
        #expect(String(decoding: try UnixSocket.readLine(fds[1], buffer: &buffer, deadline: d, maxBytes: 1024), as: UTF8.self) == "three")
    }

    // MARK: MCPBridge

    @Test func bridgeInitializeAndPing() async throws {
        let bridge = MCPBridge(transport: FakeTransport { _, _ in .null })
        let reply = try parse(await bridge.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#))
        #expect(reply["id"]?.int64Value == 1)
        #expect(reply["result"]?["protocolVersion"]?.stringValue == "2025-03-26")
        #expect(reply["result"]?["serverInfo"]?["name"]?.stringValue == "roomsmith")
        #expect(reply["result"]?["serverInfo"]?["version"]?.stringValue == RoomsmithMCP.version)
        #expect(reply["result"]?["capabilities"]?["tools"]?["listChanged"]?.boolValue == false)
        #expect(reply["result"]?["instructions"]?.stringValue == RoomsmithMCP.instructions)
        #expect(RoomsmithMCP.instructions.contains("Never guess a size"))
        let other = try parse(await bridge.handle(line: #"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"1999"}}"#))
        #expect(other["id"]?.stringValue == "a")
        #expect(other["result"]?["protocolVersion"]?.stringValue == "2025-06-18")
        let ping = try parse(await bridge.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#))
        #expect(ping["result"]?.objectValue?.isEmpty == true)
    }

    @Test func bridgeNotificationHasNoReply() async {
        let bridge = MCPBridge(transport: FakeTransport { _, _ in .null })
        #expect(await bridge.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(await bridge.handle(line: #"{"jsonrpc":"2.0","method":"whatever/else"}"#) == nil)
    }

    @Test func bridgeUnknownMethodAndParseError() async throws {
        let bridge = MCPBridge(transport: FakeTransport { _, _ in .null })
        let unknown = try parse(await bridge.handle(line: #"{"jsonrpc":"2.0","id":3,"method":"nope"}"#))
        #expect(unknown["error"]?["code"]?.int64Value == -32601)
        let broken = try parse(await bridge.handle(line: "{not json"))
        #expect(broken["error"]?["code"]?.int64Value == -32700)
    }

    @Test func bridgeToolsListSetsReadOnlyHint() async throws {
        let bridge = MCPBridge(transport: FakeTransport { tool, _ in
            #expect(tool == agentListToolsName)
            return try JSONValue(encoding: sampleTools)
        })
        let reply = try parse(await bridge.handle(line: #"{"jsonrpc":"2.0","id":4,"method":"tools/list"}"#))
        let tools = try #require(reply["result"]?["tools"]?.arrayValue)
        #expect(tools.count == 2)
        #expect(tools[0]["name"]?.stringValue == "echo")
        #expect(tools[0]["annotations"]?["readOnlyHint"]?.boolValue == true)
        #expect(tools[1]["annotations"]?["readOnlyHint"]?.boolValue == false)
        #expect(tools[1]["inputSchema"]?["type"]?.stringValue == "object")
    }

    @Test func bridgeToolsCallMovesImageToContentBlock() async throws {
        let bridge = MCPBridge(transport: FakeTransport { _, _ in
            ["width": 4, "image": ["mimeType": "image/png", "base64": "QUJD"]]
        })
        let reply = try parse(await bridge.handle(line: #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"render.scene_image"}}"#))
        let result = try #require(reply["result"])
        let content = try #require(result["content"]?.arrayValue)
        #expect(content.count == 2)
        #expect(content[1]["type"]?.stringValue == "image")
        #expect(content[1]["data"]?.stringValue == "QUJD")
        #expect(content[1]["mimeType"]?.stringValue == "image/png")
        #expect(result["structuredContent"]?["image"] == nil)
        #expect(result["structuredContent"]?["width"]?.int64Value == 4)
        #expect(content[0]["text"]?.stringValue?.contains("QUJD") == false)
    }

    @Test func bridgeToolsCallSuccessAndError() async throws {
        let bridge = MCPBridge(transport: FakeTransport { tool, args in
            if tool == "bad" { throw AgentError(code: AgentError.outOfRange, message: "too big", details: ["max": 10]) }
            return ["tool": .string(tool), "args": args]
        })
        let ok = try parse(await bridge.handle(line: #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"wall.add","arguments":{"len":2500}}}"#))
        let result = try #require(ok["result"])
        #expect(result["isError"]?.boolValue == false)
        #expect(result["structuredContent"]?["args"]?["len"]?.int64Value == 2500)
        let text = try #require(result["content"]?[0]?["text"]?.stringValue)
        #expect(result["content"]?[0]?["type"]?.stringValue == "text")
        #expect(text.contains("\"len\" : 2500"))

        let bad = try parse(await bridge.handle(line: #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"bad"}}"#))
        #expect(bad["result"]?["isError"]?.boolValue == true)
        #expect(bad["result"]?["content"]?[0]?["text"]?.stringValue?.hasPrefix("OUT_OF_RANGE: too big") == true)

        let missing = try parse(await bridge.handle(line: #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{}}"#))
        #expect(missing["error"]?["code"]?.int64Value == -32602)
    }

    // MARK: Full round trip: bridge -> client -> socket -> server

    @Test func bridgeOverRealSocket() async throws {
        try await withServer { path in
            let client = AgentSocketClient(socketPath: path, token: testToken, clientId: "mcp")
            let bridge = MCPBridge(transport: client)
            let list = try parse(await bridge.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
            #expect(list["result"]?["tools"]?.arrayValue?.count == 2)
            let call = try parse(await bridge.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"n":42}}}"#))
            #expect(call["result"]?["isError"]?.boolValue == false)
            #expect(call["result"]?["structuredContent"]?["arguments"]?["n"]?.int64Value == 42)
            #expect(call["result"]?["structuredContent"]?["clientId"]?.stringValue == "mcp")
            let failed = try parse(await bridge.handle(line: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"fail"}}"#))
            #expect(failed["result"]?["isError"]?.boolValue == true)
            #expect(failed["result"]?["content"]?[0]?["text"]?.stringValue?.hasPrefix("NOT_FOUND") == true)
        }
    }
}
