import Foundation
import RoomsmithCore
import Synchronization

/// Calls tools of the running Roomsmith app over its Unix domain socket.
public final class AgentSocketClient: Sendable {
    private let socketPath: String
    private let tokenProvider: @Sendable () throws -> String
    private let clientId: String
    private let counter = Mutex<Int64>(0)

    /// The token is supplied by `tokenProvider` on every call (the app may recreate the token file).
    public init(socketPath: String, tokenProvider: @escaping @Sendable () throws -> String, clientId: String) {
        self.socketPath = socketPath
        self.tokenProvider = tokenProvider
        self.clientId = clientId
    }

    public convenience init(socketPath: String, token: String, clientId: String) {
        self.init(socketPath: socketPath, tokenProvider: { token }, clientId: clientId)
    }

    private func nextID() -> Int64 {
        counter.withLock { value in
            value += 1
            return value
        }
    }

    public func call(_ tool: String, arguments: JSONValue = .object([:]), timeout: TimeInterval = 60) async throws -> JSONValue {
        let request = AgentRequest(id: nextID(), token: try tokenProvider(), clientId: clientId, tool: tool, arguments: arguments)
        let path = socketPath
        let response: AgentResponse = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    continuation.resume(returning: try Self.roundTrip(socketPath: path, request: request, timeout: timeout))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        if response.ok { return response.result ?? .null }
        throw response.error ?? AgentError(code: AgentError.internal, message: "Request failed without error details")
    }

    private static func roundTrip(socketPath: String, request: AgentRequest, timeout: TimeInterval) throws -> AgentResponse {
        let deadline = UnixSocket.deadline(after: timeout)
        let fd = try UnixSocket.connect(path: socketPath)
        defer { close(fd) }
        var line = try JSONEncoder().encode(request)
        line.append(10)
        try UnixSocket.writeAll(fd, line, deadline: deadline)
        var buffer = Data()
        while true {
            let data = try UnixSocket.readLine(fd, buffer: &buffer, deadline: deadline, maxBytes: 4 * UnixSocket.maxLineBytes)
            if data.isEmpty { continue }
            let response = try JSONDecoder().decode(AgentResponse.self, from: data)
            if response.id == request.id || response.id == 0 { return response }
        }
    }
}

public protocol AgentTransport: Sendable {
    func call(_ tool: String, _ args: JSONValue) async throws -> JSONValue
}

extension AgentSocketClient: AgentTransport {
    public func call(_ tool: String, _ args: JSONValue) async throws -> JSONValue {
        try await call(tool, arguments: args, timeout: 60)
    }
}
