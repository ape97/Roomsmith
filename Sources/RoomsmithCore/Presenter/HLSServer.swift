import Foundation
import Network

/// Minimal HTTP/1.1 server for the live HLS stream (GET/HEAD only, keep-alive, random path token).
/// Binds to exactly one address: loopback, or the IPv4 address of one LAN interface. Never `0.0.0.0`.
public final class HLSServer: @unchecked Sendable {
    // Safe: every mutable property below is only touched on `queue` (or through `Locked` boxes).

    public enum Bind: Sendable, Equatable {
        case loopback
        /// The IPv4 address of this interface (e.g. found with `PresenterLANAddress`).
        case lan(interfaceName: String)
    }

    public enum ServerError: Error, Equatable, LocalizedError {
        case localNetworkDenied
        case noAddress(String)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .localNetworkDenied: PresenterFailure.localNetworkDenied.message
            case .noAddress(let n): "No IPv4 address on network interface \(n)"
            case .failed(let d): d
            }
        }
    }

    /// Returns the file for a plain name (`live.m3u8`, `init.mp4`, `seg3.m4s`) or nil.
    public typealias Provider = @Sendable (String) -> HLSResource?

    public let bind: Bind
    /// Unguessable path component; the URL is `http://<host>:<port>/<token>/live.m3u8`.
    public let token: String

    /// Connection limits. A request header must be complete within `headerDeadline` seconds of the connection start
    /// (or of the end of the previous response); the deadline is never extended by incoming bytes (slowloris).
    public struct Limits: Sendable, Equatable {
        public var maxConnections = 16
        public var maxConnectionsPerAddress = 8
        public var headerDeadline: TimeInterval = 10
        public init(maxConnections: Int = 16, maxConnectionsPerAddress: Int = 8, headerDeadline: TimeInterval = 10) {
            self.maxConnections = maxConnections
            self.maxConnectionsPerAddress = maxConnectionsPerAddress
            self.headerDeadline = headerDeadline
        }
    }

    public let limits: Limits
    /// Called once when the listener dies after it was ready (e.g. the interface went away). Not called by `stop()`.
    public var onFailure: (@Sendable (ServerError) -> Void)? {
        get { failureBox.withLock { $0 } }
        set { failureBox.withLock { $0 = newValue } }
    }

    private let provider: Provider
    private let queue = DispatchQueue(label: "roomsmith.presenter.http")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: ServerConnection] = [:]
    private let portBox = Locked<UInt16?>(nil)
    private let failureBox = Locked<(@Sendable (ServerError) -> Void)?>(nil)
    /// Finishes a `start()` that is still waiting for `.ready` (queue only).
    private var pendingStart: (@Sendable (Result<UInt16, Error>) -> Void)?
    /// A server is single-use: once stopped it never starts again (queue only).
    private var stopped = false

    public init(bind: Bind, token: String = HLSRoute.makeToken(), limits: Limits = Limits(),
                provider: @escaping Provider) {
        self.bind = bind
        self.limits = limits
        self.token = token
        self.provider = provider
    }

    /// Port while running.
    public var port: UInt16? { portBox.withLock { $0 } }

    /// Starts listening and returns the port once the listener is ready. Throws `CancellationError` when `stop()`
    /// comes first and `ServerError.failed` when the server was already started.
    public func start() async throws -> UInt16 {
        let address: IPv4Address
        switch bind {
        case .loopback:
            address = .loopback
        case .lan(let name):
            guard let text = PresenterLANAddress.address(ofInterface: name), let a = IPv4Address(text) else { throw ServerError.noAddress(name) }
            address = a
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(address), port: .any)
        let listener: NWListener
        do { listener = try NWListener(using: params) } catch { throw ServerError.failed(error.localizedDescription) }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            queue.async { [weak self] in
                guard let self else { cont.resume(throwing: ServerError.failed("Server released")); return }
                if self.stopped { cont.resume(throwing: CancellationError()); return }
                if self.listener != nil { cont.resume(throwing: ServerError.failed("Server already started")); return }
                let resumed = Locked(false)
                @Sendable func finish(_ result: Result<UInt16, Error>) {
                    guard resumed.withLock({ r in let was = r; r = true; return !was }) else { return }
                    cont.resume(with: result)
                }
                self.listener = listener
                self.pendingStart = finish
                listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
                listener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        let p = listener.port?.rawValue ?? 0
                        self?.portBox.withLock { $0 = p }
                        self?.pendingStart = nil
                        finish(.success(p))
                    case .failed(let e):
                        self?.listenerDied(Self.map(e), finish: finish)
                    case .waiting(let e):
                        // Usually permission or a missing address; give up instead of waiting silently.
                        self?.listenerDied(Self.map(e), finish: finish)
                    case .cancelled:
                        finish(.failure(ServerError.failed("Listener cancelled")))
                    default:
                        break
                    }
                }
                listener.start(queue: self.queue)
            }
        }
    }

    public func stop() {
        queue.async {
            self.stopped = true
            self.stopOnQueue()
        }
    }

    private func listenerDied(_ error: ServerError, finish: @Sendable (Result<UInt16, Error>) -> Void) {
        if port != nil {   // was ready
            let callback = onFailure
            stopOnQueue()
            callback?(error)
        } else {
            finish(.failure(error))
            stopOnQueue()
        }
    }

    static func map(_ error: NWError) -> ServerError {
        if case .posix(let code) = error, code == .EPERM || code == .EACCES { return .localNetworkDenied }
        if case .dns(let code) = error, code == -65570 { return .localNetworkDenied }   // kDNSServiceErr_PolicyDenied
        return .failed(error.localizedDescription)
    }

    private func stopOnQueue() {
        stopped = true   // single-use, also after the listener died
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        portBox.withLock { $0 = nil }
        // A `start()` that never saw `.ready` must not hang: end it exactly once (the handler is idempotent).
        pendingStart?(.failure(CancellationError()))
        pendingStart = nil
        for c in connections.values { c.close() }
        connections.removeAll()
    }

    private func accept(_ nw: NWConnection) {
        guard connections.count < limits.maxConnections else { nw.cancel(); return }
        let address = ServerConnection.addressKey(of: nw.endpoint)
        guard connections.values.filter({ $0.address == address }).count < limits.maxConnectionsPerAddress else {
            nw.cancel()
            return
        }
        let c = ServerConnection(connection: nw, address: address, server: self)
        connections[ObjectIdentifier(c)] = c
        c.start()
    }

    fileprivate func remove(_ c: ServerConnection) {
        connections[ObjectIdentifier(c)] = nil
    }

    fileprivate func response(for request: HTTPRequest) -> Data {
        let resource = HLSRoute.resourceName(path: request.path, token: token).flatMap(provider)
        return HTTPResponse.answer(request, resource: resource)
    }

    fileprivate var serverQueue: DispatchQueue { queue }
}

private final class ServerConnection: @unchecked Sendable {
    // Safe: all state is confined to the server queue (every NWConnection callback runs there).
    let connection: NWConnection
    unowned let server: HLSServer
    var buffer = Data()
    let address: String
    var deadline: DispatchWorkItem?
    var closed = false

    /// Peer host without port and interface scope.
    static func addressKey(of endpoint: NWEndpoint) -> String {
        guard case .hostPort(let host, _) = endpoint else { return "\(endpoint)" }
        let text = "\(host)"
        return text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
    }

    init(connection: NWConnection, address: String, server: HLSServer) {
        self.connection = connection
        self.address = address
        self.server = server
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .failed, .cancelled: close()
            default: break
            }
        }
        connection.start(queue: server.serverQueue)
        armDeadline()
        receive()
    }

    func receive() {
        guard !closed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [self] data, _, isComplete, error in
            guard !closed else { return }
            if let data, !data.isEmpty { buffer.append(data) }
            if error != nil { close(); return }
            process()
            guard !closed else { return }
            if isComplete {
                // Peer finished sending: close only after pending responses are written.
                send(Data(), thenClose: true)
            } else {
                receive()
            }
        }
    }

    func process() {
        while !closed {
            switch HTTPRequestParser.parse(buffer) {
            case .needMoreData:
                return
            case .reject(let status):
                buffer.removeAll()
                send(HTTPResponse.make(status: status, body: Data("\(HTTPResponse.reasonPhrase(status))\n".utf8), close: true), thenClose: true)
                return
            case .request(let request, let consumed):
                buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + consumed)
                let close = request.wantsClose
                deadline?.cancel()
                send(server.response(for: request), thenClose: close, rearm: !close)
                if close { return }
            }
        }
    }

    func send(_ data: Data, thenClose: Bool, rearm: Bool = false) {
        connection.send(content: data, completion: .contentProcessed { [self] error in
            if error != nil || thenClose { close() } else if rearm { armDeadline() }
        })
    }

    /// Hard limit for the next complete request header; deliberately not reset by incoming bytes.
    func armDeadline() {
        deadline?.cancel()
        let item = DispatchWorkItem { [self] in close() }
        deadline = item
        server.serverQueue.asyncAfter(deadline: .now() + server.limits.headerDeadline, execute: item)
    }

    func close() {
        guard !closed else { return }
        closed = true
        deadline?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
        server.remove(self)
    }
}
