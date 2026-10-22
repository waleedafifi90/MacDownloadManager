import Darwin
import Foundation

/// One request/response exchange over a Unix-domain socket: connect, send one JSON line,
/// read one JSON line back.
public enum UnixSocketClient {
    public static func exchange(_ message: CaptureMessage, socket path: URL = CaptureProtocol.socketURL,
                                timeout: TimeInterval = 15) throws -> CaptureMessage {
        let fd = try connect(to: path)
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var line = try JSONEncoder().encode(message)
        line.append(0x0A)
        try writeAll(fd, line)
        guard let reply = readLine(fd) else { throw CaptureError.noReply }
        return try JSONDecoder().decode(CaptureMessage.self, from: reply)
    }

    static func connect(to path: URL) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CaptureError.connectFailed(errno) }
        var address = try UnixSocketAddress.make(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let error = errno
            close(fd)
            throw CaptureError.connectFailed(error)
        }
        return fd
    }
}

/// Accepts connections on a Unix-domain socket that only the current user can open, and
/// answers each JSON line with the handler's reply.
public final class UnixSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (CaptureMessage) async -> CaptureMessage

    private let path: URL
    private let handler: Handler
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "UnixSocketServer")

    public init(path: URL = CaptureProtocol.socketURL, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        unlink(path.path)  // a stale socket from a previous run
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CaptureError.connectFailed(errno) }
        var address = try UnixSocketAddress.make(path)
        // Owner-only permissions on the socket file itself.
        let oldMask = umask(0o077)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(oldMask)
        guard bound == 0, listen(fd, 16) == 0 else {
            let error = errno
            close(fd)
            throw CaptureError.connectFailed(error)
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        source = nil
        if fd >= 0 { close(fd); fd = -1 }
        unlink(path.path)
    }

    private func acceptClient() {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let handler = handler
        Task.detached {
            defer { close(client) }
            let reply: CaptureMessage
            if let line = readLine(client), let message = try? JSONDecoder().decode(CaptureMessage.self, from: line) {
                reply = await handler(message)
            } else {
                reply = .result(accepted: false, error: "Malformed message")
            }
            guard var data = try? JSONEncoder().encode(reply) else { return }
            data.append(0x0A)
            try? writeAll(client, data)
        }
    }
}

enum UnixSocketAddress {
    static func make(_ path: URL) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw CaptureError.socketPathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }
}

/// Reads up to the first newline (at most 4 MB), or nil on error or timeout.
func readLine(_ fd: Int32) -> Data? {
    var data = Data()
    var byte: UInt8 = 0
    while data.count < NativeMessaging.maxIncoming {
        let n = read(fd, &byte, 1)
        if n <= 0 { return data.isEmpty ? nil : data }
        if byte == 0x0A { return data }
        data.append(byte)
    }
    return nil
}

func writeAll(_ fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
            guard n > 0 else { throw CaptureError.connectFailed(errno) }
            offset += n
        }
    }
}
