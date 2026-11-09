import Foundation

/// Structured error of a document command. Codes are stable and shared with the agent API.
public struct CommandError: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Code: String, Sendable, Codable, CaseIterable {
        case notFound = "NOT_FOUND"
        case invalidArgument = "INVALID_ARGUMENT"
        case outOfRange = "OUT_OF_RANGE"
        case conflict = "CONFLICT"
        case locked = "LOCKED"
        case writeLocked = "WRITE_LOCKED"
        case busy = "BUSY"
        case internalError = "INTERNAL"
    }

    public var code: Code
    public var message: String
    /// Objects the error refers to.
    public var ids: [UUID]
    /// Extra machine-readable details (e.g. current revisions on CONFLICT).
    public var details: [String: String]

    public init(_ code: Code, _ message: String, ids: [UUID] = [], details: [String: String] = [:]) {
        self.code = code; self.message = message; self.ids = ids; self.details = details
    }

    public var description: String { "\(code.rawValue): \(message)" }

    public static func notFound(_ what: String, _ id: UUID) -> CommandError {
        CommandError(.notFound, "\(what) \(id.uuidString.lowercased()) does not exist", ids: [id])
    }
    public static func invalid(_ message: String, ids: [UUID] = []) -> CommandError { CommandError(.invalidArgument, message, ids: ids) }
    public static func range(_ message: String, ids: [UUID] = []) -> CommandError { CommandError(.outOfRange, message, ids: ids) }
    public static func locked(_ id: UUID) -> CommandError {
        CommandError(.locked, "Object \(id.uuidString.lowercased()) is locked", ids: [id])
    }
}
