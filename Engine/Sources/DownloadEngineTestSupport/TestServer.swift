import Foundation
import Network

/// A tiny local HTTP server that serves one in-memory file, with or without
/// range support, and records the Range headers it received.
public final class TestServer: @unchecked Sendable {
    public let body: Data
    let supportsRanges: Bool
    /// Bytes per write and pause between writes, to keep connections busy long
    /// enough for dynamic splitting to happen.
    let chunkSize: Int
    let chunkDelay: TimeInterval

    /// What to do with the first range requests (the 0-0 probe is not counted).
    public enum Fault {
        /// Close the connection after sending this many body bytes.
        case drop(afterBytes: Int)
        /// Stop sending after this many body bytes but keep the connection open.
        case stall(afterBytes: Int)
    }
    private var faults: [Fault]

    private let listener: NWListener
    private let queue = DispatchQueue(label: "TestServer")
    private let lock = NSLock()
    private var _ranges: [String] = []
    /// Stalled connections are kept here so they stay open.
    private var stalled: [NWConnection] = []

    public var ranges: [String] { lock.withLock { _ranges } }
    public var port: UInt16 { listener.port?.rawValue ?? 0 }
    public var url: URL { URL(string: "http://127.0.0.1:\(port)/file.bin")! }

    public init(body: Data, supportsRanges: Bool = true, chunkSize: Int = 64 * 1024, chunkDelay: TimeInterval = 0,
         faults: [Fault] = []) throws {
        self.body = body
        self.supportsRanges = supportsRanges
        self.chunkSize = chunkSize
        self.chunkDelay = chunkDelay
        self.faults = faults
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] in self?.handle($0) }
        listener.start(queue: queue)
        ready.wait()
    }

    public func stop() {
        listener.cancel()
        queue.sync { stalled.forEach { $0.cancel() } }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHeaders(connection, buffer: Data())
    }

    private func receiveHeaders(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [self] data, _, done, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                respond(connection, headers: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if !done && error == nil {
                receiveHeaders(connection, buffer: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(_ connection: NWConnection, headers: String) {
        let rangeLine = headers.split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("range:") }
            .map { $0.dropFirst("range:".count).trimmingCharacters(in: .whitespaces) }

        var status = "200 OK"
        var slice = body.startIndex..<body.endIndex
        var extra = ""
        var fault: Fault?
        if supportsRanges, let rangeLine, rangeLine.hasPrefix("bytes=") {
            lock.withLock { _ranges.append(rangeLine) }
            if rangeLine != "bytes=0-0", !faults.isEmpty { fault = faults.removeFirst() }
            let parts = rangeLine.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
            let start = Int(parts[0]) ?? 0
            let end = min(parts.count > 1 ? Int(parts[1]) ?? body.count - 1 : body.count - 1, body.count - 1)
            slice = start..<(end + 1)
            status = "206 Partial Content"
            extra = "Content-Range: bytes \(start)-\(end)/\(body.count)\r\n"
        }
        let head = "HTTP/1.1 \(status)\r\nContent-Length: \(slice.count)\r\n"
            + (supportsRanges ? "Accept-Ranges: bytes\r\n" : "") + extra + "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        sendBody(connection, from: slice.lowerBound, to: slice.upperBound, fault: fault, sent: 0)
    }

    private func sendBody(_ connection: NWConnection, from: Int, to: Int, fault: Fault?, sent: Int) {
        switch fault {
        case .drop(let limit) where sent >= limit:
            connection.cancel()
            return
        case .stall(let limit) where sent >= limit:
            stalled.append(connection)
            return
        default:
            break
        }
        guard from < to else {
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let limit: Int
        switch fault {
        case .drop(let afterBytes), .stall(let afterBytes): limit = from + afterBytes - sent
        case nil: limit = to
        }
        let next = min(from + chunkSize, to, limit)
        let count = next - from
        connection.send(content: body[from..<next], completion: .contentProcessed { [self] error in
            guard error == nil else { connection.cancel(); return }
            queue.asyncAfter(deadline: .now() + chunkDelay) {
                self.sendBody(connection, from: next, to: to, fault: fault, sent: sent + count)
            }
        })
    }
}
