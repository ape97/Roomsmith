import Foundation

/// Structured error for reading and writing project files. `line` is the 1-based line in `project.md`.
public struct PersistenceError: Error, CustomStringConvertible, Equatable, Sendable {
    public var message: String
    public var line: Int?
    public var path: String?

    public init(_ message: String, line: Int? = nil, path: String? = nil) {
        self.message = message; self.line = line; self.path = path
    }

    public var description: String {
        var s = ""
        if let line { s += "line \(line): " }
        s += message
        if let path { s += " (\(path))" }
        return s
    }
}
