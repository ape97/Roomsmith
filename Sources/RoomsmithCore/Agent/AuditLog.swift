import Foundation

/// Append-only JSON Lines log of every agent call. Never contains the token.
/// Writes happen on a private serial queue so tool calls never wait for the disk.
public final class AuditLog: @unchecked Sendable {
    public static let maxBytes = 5 * 1024 * 1024
    public static let maxSummaryLength = 300

    public let url: URL
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "roomsmith.audit-log", qos: .utility)
    private var fd: Int32 = -1
    private var size = 0
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init(url: URL, maxBytes: Int = AuditLog.maxBytes) {
        self.url = url
        self.maxBytes = maxBytes
    }

    deinit { if fd >= 0 { close(fd) } }

    public func record(clientId: String, tool: String, arguments: JSONValue, ok: Bool, errorCode: String?,
                       revision: Int64, durationMs: Int, date: Date = Date()) {
        let summary = AuditLog.summary(of: arguments)
        queue.async { [self] in
            var o: [String: JSONValue] = [
                "ts": .string(formatter.string(from: date)),
                "clientId": .string(clientId),
                "tool": .string(tool),
                "args": .string(summary),
                "ok": .bool(ok),
                "revision": .int(revision),
                "durationMs": .int(Int64(durationMs)),
            ]
            if let errorCode { o["errorCode"] = .string(errorCode) }
            guard var data = JSONValue.object(o).jsonString().data(using: .utf8) else { return }
            data.append(0x0A)
            append(data)
        }
    }

    /// Waits until all queued writes are done (tests, shutdown).
    public func flush() { queue.sync {} }

    /// Compact argument summary of at most 300 characters; values of keys that look like secrets are redacted.
    static func summary(of arguments: JSONValue) -> String {
        func redact(_ v: JSONValue) -> JSONValue {
            switch v {
            case .object(let o):
                return .object(o.reduce(into: [:]) { acc, kv in
                    let k = kv.key.lowercased()
                    acc[kv.key] = (k.contains("token") || k.contains("secret") || k.contains("password")) ? .string("<redacted>") : redact(kv.value)
                })
            case .array(let a): return .array(a.map(redact))
            default: return v
            }
        }
        let text = redact(arguments).jsonString()
        guard text.count > maxSummaryLength else { return text }
        return String(text.prefix(maxSummaryLength - 1)) + "…"
    }

    // MARK: Disk (queue only)

    private func append(_ data: Data) {
        if fd < 0 && !openFile() { return }
        if size + data.count > maxBytes && size > 0 { rotate() }
        if fd < 0 && !openFile() { return }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        if written > 0 { size += written }
    }

    private func openFile() -> Bool {
        let dir = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let f = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard f >= 0 else { return false }
        fchmod(f, 0o600)
        fd = f
        var st = stat()
        size = fstat(f, &st) == 0 ? Int(st.st_size) : 0
        return true
    }

    private func rotate() {
        if fd >= 0 { close(fd); fd = -1 }
        let old = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
        size = 0
        _ = openFile()
    }
}
