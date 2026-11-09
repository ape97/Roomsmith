import Foundation

/// Name of the reserved tool that returns `[ToolDescriptor]`.
public let agentListToolsName = "app.list_tools"

public struct AgentRequest: Codable, Sendable {
    public var id: Int64
    public var token: String
    public var clientId: String
    public var tool: String
    public var arguments: JSONValue

    public init(id: Int64, token: String, clientId: String, tool: String, arguments: JSONValue = .object([:])) {
        self.id = id
        self.token = token
        self.clientId = clientId
        self.tool = tool
        self.arguments = arguments
    }
}

public struct AgentError: Codable, Sendable, Error, CustomStringConvertible {
    public var code: String
    public var message: String
    public var details: JSONValue?

    public init(code: String, message: String, details: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }

    public var description: String { "\(code): \(message)" }

    public static let notFound = "NOT_FOUND"
    public static let invalidArgument = "INVALID_ARGUMENT"
    public static let outOfRange = "OUT_OF_RANGE"
    public static let conflict = "CONFLICT"
    public static let locked = "LOCKED"
    public static let writeLocked = "WRITE_LOCKED"
    public static let busy = "BUSY"
    public static let unauthorized = "UNAUTHORIZED"
    public static let unknownTool = "UNKNOWN_TOOL"
    public static let `internal` = "INTERNAL"
    public static let notRunning = "NOT_RUNNING"
}

public struct AgentResponse: Codable, Sendable {
    public var id: Int64
    public var ok: Bool
    public var result: JSONValue?
    public var error: AgentError?

    public init(id: Int64, ok: Bool, result: JSONValue? = nil, error: AgentError? = nil) {
        self.id = id
        self.ok = ok
        self.result = result
        self.error = error
    }

    public static func success(id: Int64, _ result: JSONValue) -> AgentResponse {
        AgentResponse(id: id, ok: true, result: result, error: nil)
    }

    public static func failure(id: Int64, _ error: AgentError) -> AgentResponse {
        AgentResponse(id: id, ok: false, result: nil, error: error)
    }
}

public struct ToolDescriptor: Codable, Sendable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    public var readOnly: Bool

    public init(name: String, description: String, inputSchema: JSONValue = .object(["type": "object"]), readOnly: Bool) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.readOnly = readOnly
    }
}

public enum AgentPaths {
    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    public static var supportDirectory: URL {
        if let override = environment["ROOMSMITH_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        // A test process (`swift test`, hosted app tests) never touches the user's real folder: autosave copies,
        // session and recent files written there would show up as recovery dialogs at the next real launch.
        if isTestProcess { return testSupportDirectory }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Roomsmith", isDirectory: true)
    }

    /// True inside an XCTest / swift-testing host process.
    public static var isTestProcess: Bool {
        environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
            || ["xctest", "swiftpm-testing-helper"].contains(ProcessInfo.processInfo.processName)
            || Bundle.main.bundlePath.hasSuffix(".xctest")
    }

    /// Per-process temp folder used instead of the real support folder while tests run.
    public static let testSupportDirectory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("roomsmith-test-support-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)

    public static var socketURL: URL {
        if let override = environment["ROOMSMITH_SOCKET"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return supportDirectory.appendingPathComponent("agent.sock")
    }

    public static var tokenURL: URL {
        if let override = environment["ROOMSMITH_TOKEN_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return supportDirectory.appendingPathComponent("agent-token")
    }

    public static var auditLogURL: URL {
        supportDirectory.appendingPathComponent("agent-audit.jsonl")
    }
}

public enum AgentToken {
    /// Reads the token; creates a new random one (32 bytes, hex) if the file does not exist.
    /// File mode 0600, parent directory 0700 (when newly created).
    public static func loadOrCreate(at url: URL) throws -> String {
        try loadOrCreate(at: url, retriesLeft: 1)
    }

    private static func loadOrCreate(at url: URL, retriesLeft: Int) throws -> String {
        if let existing = try? load(at: url) {
            // A token readable by others is no secret: tighten the mode of an existing file.
            var info = stat()
            if stat(url.path, &info) == 0, info.st_mode & 0o777 != 0o600 { chmod(url.path, 0o600) }
            return existing
        }
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        let token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        if fd < 0 {
            if errno == EEXIST {
                // Empty/unreadable leftover or concurrent creation: replace it.
                if let existing = try? load(at: url) { return existing }
                guard retriesLeft > 0 else {
                    throw AgentError(code: AgentError.internal, message: "Cannot replace unusable token file at \(url.path)")
                }
                do { try FileManager.default.removeItem(at: url) } catch {
                    throw AgentError(code: AgentError.internal, message: "Cannot remove unusable token file at \(url.path): \(error.localizedDescription)")
                }
                return try loadOrCreate(at: url, retriesLeft: retriesLeft - 1)
            }
            throw AgentError(code: AgentError.internal, message: "Cannot create token file: \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        let bytes = Array((token + "\n").utf8)
        guard write(fd, bytes, bytes.count) == bytes.count else {
            throw AgentError(code: AgentError.internal, message: "Cannot write token file")
        }
        fchmod(fd, 0o600)
        return token
    }

    /// Reads an existing token. Throws `NOT_RUNNING` if the file is missing or empty.
    public static func load(at url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else {
            throw AgentError(code: AgentError.notRunning, message: "Token file not found at \(url.path). Start Roomsmith first.")
        }
        return text
    }
}
