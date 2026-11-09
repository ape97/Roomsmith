import Foundation
import RoomsmithCore
import Synchronization

/// One accepted client connection. Writes are serialized; the fd is closed exactly once.
final class ServerConnection: @unchecked Sendable {
    let fd: Int32
    private let isOpen = Mutex(true)
    private let writeLock = NSLock()

    /// Total time one response line may take to leave the process before the connection is shut down.
    let sendTimeout: TimeInterval
    /// Idle bookkeeping: time of the last complete request line (or accept) and number of requests still being handled.
    private let activity = Mutex((lastLine: UnixSocket.now(), pending: 0))

    init(fd: Int32, sendTimeout: TimeInterval = AgentSocketServer.Limits.standard.sendTimeout) {
        self.fd = fd
        self.sendTimeout = sendTimeout
    }

    func noteLine() { activity.withLock { $0.lastLine = UnixSocket.now() } }
    func beginRequest() { activity.withLock { $0.pending += 1 } }
    func endRequest() { activity.withLock { $0.pending -= 1 } }

    /// True when no request is in flight and no complete line arrived for `seconds`.
    func isIdle(for seconds: TimeInterval) -> Bool {
        activity.withLock { $0.pending == 0 && UnixSocket.now() &- $0.lastLine > UInt64(seconds * 1_000_000_000) }
    }

    private func tryWrite(_ pointer: UnsafeRawPointer, _ count: Int) -> (written: Int, error: Int32) {
        isOpen.withLock { open in
            guard open else { return (-2, 0) }
            let n = Darwin.write(fd, pointer, count)
            return (n, n < 0 ? errno : 0)
        }
    }

    /// Sends one complete line (newline is appended). Never blocks the caller longer than `sendTimeout` in total:
    /// a dead or non-reading peer (or a closed connection/server) ends the write and the connection is shut down,
    /// because a half-written line would corrupt the stream.
    func send(line data: Data) {
        var payload = data
        payload.append(10)
        writeLock.lock()
        defer { writeLock.unlock() }
        let deadline = UnixSocket.deadline(after: sendTimeout)
        payload.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let (n, err) = tryWrite(raw.baseAddress! + offset, raw.count - offset)
                if n > 0 { offset += n; continue }
                if n == -2 { return }
                if err == EINTR { continue }
                if err == EAGAIN {
                    if UnixSocket.now() >= deadline {
                        shutdownBoth()
                        return
                    }
                    var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&p, 1, 100)
                    continue
                }
                shutdownBoth()
                return
            }
        }
    }

    func shutdownBoth() {
        isOpen.withLock { open in
            if open { shutdown(fd, SHUT_RDWR) }
        }
    }

    func close() {
        isOpen.withLock { open in
            if open {
                open = false
                Darwin.close(fd)
            }
        }
    }
}

/// Unix-domain-socket server speaking newline-delimited JSON (`AgentRequest` -> `AgentResponse`).
public final class AgentSocketServer: Sendable {
    public typealias Handler = @Sendable (AgentRequest) async -> AgentResponse

    /// Resource limits. Defaults are the production values; tests lower them per server instance before `start()`.
    struct Limits: Sendable {
        var maxConnections = 16
        /// Seconds a connection may stay without a complete request line (and without a request in flight).
        var idleTimeout: TimeInterval = 30
        /// Seconds one response may take to be written to a client.
        var sendTimeout: TimeInterval = 10
        static let standard = Limits()
    }

    private struct State {
        var socketIdentity: (dev: dev_t, ino: ino_t)?
        var running = false
        var listenFD: Int32 = -1
        var connections: [Int32: ServerConnection] = [:]
        var acceptDone: DispatchSemaphore?
    }

    private let socketPath: String
    private let token: String
    private let handler: Handler
    private let state = Mutex(State())
    private let limitsBox = Mutex(Limits.standard)

    var limits: Limits {
        get { limitsBox.withLock { $0 } }
        set { limitsBox.withLock { $0 = newValue } }
    }

    var connectionCount: Int { state.withLock { $0.connections.count } }

    /// Called (clientId, tool) for every request with a wrong token; never receives the token itself.
    /// The host can route it into the audit log.
    private let onAuthFailure: (@Sendable (String, String) -> Void)?

    public init(socketPath: String, token: String, onAuthFailure: (@Sendable (String, String) -> Void)? = nil,
                handler: @escaping Handler) {
        self.socketPath = socketPath
        self.token = token
        self.onAuthFailure = onAuthFailure
        self.handler = handler
    }

    deinit { stop() }

    public func start() throws {
        signal(SIGPIPE, SIG_IGN)
        if state.withLock({ $0.running }) {
            throw AgentError(code: AgentError.internal, message: "Server already running")
        }
        var addr = try UnixSocket.makeAddress(socketPath)

        let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try removeStaleSocketFile()

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw AgentError(code: AgentError.internal, message: "socket() failed: \(UnixSocket.lastError())")
        }
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let text = UnixSocket.lastError()
            close(fd)
            throw AgentError(code: AgentError.internal, message: "bind(\(socketPath)) failed: \(text)")
        }
        chmod(socketPath, 0o600)
        var boundInfo = stat()
        let identity: (dev: dev_t, ino: ino_t)? = stat(socketPath, &boundInfo) == 0 ? (boundInfo.st_dev, boundInfo.st_ino) : nil
        guard listen(fd, 128) == 0 else {
            let text = UnixSocket.lastError()
            close(fd)
            unlinkIfOwned(identity)
            throw AgentError(code: AgentError.internal, message: "listen() failed: \(text)")
        }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let done = DispatchSemaphore(value: 0)
        state.withLock {
            $0.running = true
            $0.listenFD = fd
            $0.socketIdentity = identity
            $0.acceptDone = done
        }
        Thread.detachNewThread { [self] in
            acceptLoop(listenFD: fd)
            done.signal()
        }
    }

    public func stop() {
        let (wasRunning, connections, done, identity): (Bool, [ServerConnection], DispatchSemaphore?, (dev: dev_t, ino: ino_t)?) = state.withLock {
            let was = $0.running
            let identity = $0.socketIdentity
            $0.socketIdentity = nil
            $0.running = false
            let conns = Array($0.connections.values)
            let sem = $0.acceptDone
            $0.acceptDone = nil
            return (was, conns, sem, identity)
        }
        guard wasRunning else { return }
        for connection in connections { connection.shutdownBoth() }
        _ = done?.wait(timeout: .now() + 2)
        unlinkIfOwned(identity)
    }

    /// Removes the socket file only if it is still the one this server bound (a newer instance may own the path now).
    private func unlinkIfOwned(_ identity: (dev: dev_t, ino: ino_t)?) {
        guard let identity else { return }
        var info = stat()
        if stat(socketPath, &info) == 0, info.st_dev == identity.dev, info.st_ino == identity.ino {
            unlink(socketPath)
        }
    }

    /// Replaces a stale socket file; refuses to start when a live server answers or the path is not a socket.
    private func removeStaleSocketFile() throws {
        var info = stat()
        guard lstat(socketPath, &info) == 0 else { return }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else {
            throw AgentError(code: AgentError.internal, message: "\(socketPath) exists and is not a socket; not replacing it")
        }
        do {
            let probe = try UnixSocket.connect(path: socketPath)
            close(probe)
            throw AgentError(code: AgentError.internal, message: "Another Roomsmith instance is already serving agents at \(socketPath)")
        } catch let error as AgentError where error.code == AgentError.notRunning {
            unlink(socketPath)
        }
    }

    private var isRunning: Bool { state.withLock { $0.running } }

    private func acceptLoop(listenFD: Int32) {
        while isRunning {
            var p = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 200) > 0 else { continue }
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else { continue }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(clientFD, &uid, &gid) == 0, uid == geteuid() else {
                close(clientFD)
                continue
            }
            UnixSocket.configure(clientFD)
            let limits = self.limits
            let connection = ServerConnection(fd: clientFD, sendTimeout: limits.sendTimeout)
            let accepted: Bool? = state.withLock {
                guard $0.running else { return false }
                guard $0.connections.count < limits.maxConnections else { return nil }
                $0.connections[clientFD] = connection
                return true
            }
            guard accepted == true else {
                if accepted == nil {
                    send(.failure(id: 0, AgentError(
                        code: AgentError.internal,
                        message: "Too many connections (max \(limits.maxConnections)); try again later")), on: connection)
                }
                connection.close()
                continue
            }
            Thread.detachNewThread { [self] in
                readLoop(connection)
                _ = state.withLock { $0.connections.removeValue(forKey: connection.fd) }
                connection.close()
            }
        }
        close(listenFD)
        state.withLock { $0.listenFD = -1 }
    }

    private func readLoop(_ connection: ServerConnection) {
        let fd = connection.fd
        var buffer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 256 * 1024)
        var partialSince: UInt64?
        while isRunning {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, 200)
            if ready == 0 {
                if connection.isIdle(for: limits.idleTimeout) {
                    send(.failure(id: 0, AgentError(
                        code: AgentError.invalidArgument,
                        message: "No complete request line within \(Int(limits.idleTimeout)) s; closing connection")), on: connection)
                    return
                }
                continue
            }
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n == 0 { return }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return
            }
            let scanFrom = buffer.count
            buffer.append(contentsOf: chunk[0..<n])
            var start = 0
            var cursor = scanFrom
            while let index = buffer[cursor...].firstIndex(of: 10) {
                if index - start > UnixSocket.maxLineBytes {
                    rejectOversize(connection)
                    return
                }
                if index > start {
                    connection.noteLine()
                    process(line: Data(buffer[start..<index]), on: connection)
                }
                start = index + 1
                cursor = start
            }
            if start > 0 { buffer.removeSubrange(0..<start) }
            if buffer.count > UnixSocket.maxLineBytes {
                rejectOversize(connection)
                return
            }
            // A client trickling bytes without ever finishing a line is idle too: one line must complete within
            // `idleTimeout` of its first byte (measured from the first unfinished byte, so a pause between lines
            // never counts against the next one).
            if buffer.isEmpty {
                partialSince = nil
            } else {
                let now = UnixSocket.now()
                if partialSince == nil || start > 0 { partialSince = now }
                if let since = partialSince, now &- since > UInt64(limits.idleTimeout * 1_000_000_000) {
                    send(.failure(id: 0, AgentError(
                        code: AgentError.invalidArgument,
                        message: "No complete request line within \(Int(limits.idleTimeout)) s; closing connection")), on: connection)
                    return
                }
            }
        }
    }

    private func rejectOversize(_ connection: ServerConnection) {
        let error = AgentError(
            code: AgentError.invalidArgument,
            message: "Request line exceeds \(UnixSocket.maxLineBytes) bytes; closing connection")
        send(.failure(id: 0, error), on: connection)
    }

    private func send(_ response: AgentResponse, on connection: ServerConnection) {
        let data: Data
        if let encoded = try? JSONEncoder().encode(response) {
            data = encoded
        } else {
            let fallback = AgentResponse.failure(id: response.id, AgentError(code: AgentError.internal, message: "Cannot encode response"))
            data = (try? JSONEncoder().encode(fallback)) ?? Data("{\"id\":0,\"ok\":false}".utf8)
        }
        connection.send(line: data)
    }

    private func process(line: Data, on connection: ServerConnection) {
        let request: AgentRequest
        do {
            request = try JSONDecoder().decode(AgentRequest.self, from: line)
        } catch {
            let id = (try? JSONValue.parse(line))?["id"]?.int64Value ?? 0
            send(.failure(id: id, AgentError(
                code: AgentError.invalidArgument,
                message: "Request must be a JSON object with id, token, clientId, tool, arguments")), on: connection)
            return
        }
        guard Self.constantTimeEqual(request.token, token) else {
            onAuthFailure?(request.clientId, request.tool)
            send(.failure(id: request.id, AgentError(code: AgentError.unauthorized, message: "Invalid token")), on: connection)
            return
        }
        let handler = self.handler
        connection.beginRequest()
        Task.detached { [self] in
            var response = await handler(request)
            response.id = request.id
            send(response, on: connection)
            connection.endRequest()
        }
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = x.count ^ y.count
        for i in 0..<max(x.count, y.count) {
            diff |= Int((i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0))
        }
        return diff == 0
    }
}
