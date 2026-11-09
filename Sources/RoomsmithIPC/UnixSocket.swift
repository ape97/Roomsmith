import Foundation
import RoomsmithCore

/// Small POSIX helpers shared by server and client.
enum UnixSocket {
    static let maxLineBytes = 16 * 1024 * 1024

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    static func deadline(after seconds: TimeInterval) -> UInt64 {
        // Clamped so absurd, infinite or NaN timeouts never trap the conversion (1e9 s is ~31 years).
        let s = seconds.isNaN ? 0 : min(max(0, seconds), 1_000_000_000)
        return now() &+ UInt64(s * 1_000_000_000)
    }

    static func remainingMs(_ deadline: UInt64) -> Int32 {
        let current = now()
        if current >= deadline { return 0 }
        return Int32(min((deadline - current) / 1_000_000 + 1, 1_000_000))
    }

    static func makeAddress(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard !bytes.isEmpty, bytes.count < capacity else {
            throw AgentError(code: AgentError.invalidArgument, message: "Socket path is empty or too long (max \(capacity - 1) bytes): \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }

    static func lastError() -> String { String(cString: strerror(errno)) }

    static func configure(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    /// Connects to a listening socket; returns a non-blocking fd.
    static func connect(path: String) throws -> Int32 {
        var addr = try makeAddress(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw AgentError(code: AgentError.internal, message: "socket() failed: \(lastError())")
        }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            let code = errno
            let text = lastError()
            close(fd)
            if code == ENOENT || code == ECONNREFUSED || code == ENOTSOCK {
                throw AgentError(code: AgentError.notRunning, message: "Roomsmith is not reachable (\(text)). Start Roomsmith first.")
            }
            throw AgentError(code: AgentError.internal, message: "connect() failed: \(text)")
        }
        configure(fd)
        return fd
    }

    /// Waits until the fd is ready for `events` or the deadline passes. Returns false on timeout.
    static func wait(_ fd: Int32, events: Int32, deadline: UInt64) -> Bool {
        while true {
            var p = pollfd(fd: fd, events: Int16(events), revents: 0)
            let r = poll(&p, 1, remainingMs(deadline))
            if r > 0 { return true }
            if r == 0 { return false }
            if errno != EINTR { return true }
        }
    }

    static func writeAll(_ fd: Int32, _ data: Data, deadline: UInt64) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 { offset += n; continue }
                if n < 0 && errno == EINTR { continue }
                if n < 0 && errno == EAGAIN {
                    guard wait(fd, events: Int32(POLLOUT), deadline: deadline) else {
                        throw AgentError(code: AgentError.internal, message: "Timeout while sending request to Roomsmith")
                    }
                    continue
                }
                throw AgentError(code: AgentError.notRunning, message: "Connection to Roomsmith lost (\(lastError())). Start Roomsmith first.")
            }
        }
    }

    /// Reads one newline-terminated line (without the newline). Bytes after the newline are lost; use the
    /// `buffer:` variant on connections that may carry several lines.
    static func readLine(_ fd: Int32, deadline: UInt64, maxBytes: Int) throws -> Data {
        var buffer = Data()
        return try readLine(fd, buffer: &buffer, deadline: deadline, maxBytes: maxBytes)
    }

    /// Reads one line; surplus bytes of the last chunk stay in `buffer` for the next call (pipelining safe).
    static func readLine(_ fd: Int32, buffer: inout Data, deadline: UInt64, maxBytes: Int) throws -> Data {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var scanFrom = buffer.startIndex
        while true {
            if let index = buffer[scanFrom...].firstIndex(of: 10) {
                let line = Data(buffer[buffer.startIndex..<index])
                buffer = Data(buffer[(index + 1)...])
                return line
            }
            scanFrom = buffer.endIndex
            if buffer.count > maxBytes {
                throw AgentError(code: AgentError.internal, message: "Response line too long")
            }
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                continue
            }
            if n == 0 {
                throw AgentError(code: AgentError.notRunning, message: "Roomsmith closed the connection. Start Roomsmith first.")
            }
            if errno == EINTR { continue }
            if errno == EAGAIN {
                guard wait(fd, events: Int32(POLLIN), deadline: deadline) else {
                    throw AgentError(code: AgentError.internal, message: "Timeout waiting for Roomsmith")
                }
                continue
            }
            throw AgentError(code: AgentError.internal, message: "read() failed: \(lastError())")
        }
    }
}
