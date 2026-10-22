import Foundation

public enum DownloadError: Error, Equatable {
    case notHTTP
    case badStatus(Int)
    case rangeMismatch(expectedStart: Int64)
    case sizeMismatch(expected: Int64, actual: Int64)
    /// The server closed the connection before sending the whole requested range.
    case connectionClosedEarly
    /// Bytes re-fetched past a segment's end differ from what is already on disk:
    /// the file changed on the server, or the data is corrupt.
    case dataMismatch(offset: Int64)
    case tooManyRetries(underlying: String)

    var isRetryable: Bool {
        switch self {
        case .connectionClosedEarly: return true
        case .badStatus(let code): return code == 408 || code == 429 || (500..<600).contains(code)
        default: return false
        }
    }
}

public struct DownloadOptions: Sendable {
    public var maxConnections = 8
    /// A running segment is only split when it has at least twice this many bytes left.
    public var minSplitSize: Int64 = 64 * 1024
    public var headers: [String: String] = [:]
    /// How often the resume state is written to disk while downloading.
    public var stateSaveInterval: TimeInterval = 1
    /// Failed attempts allowed per segment before the whole download fails.
    public var maxRetries = 5
    /// A connection that receives nothing for this long fails and is retried.
    public var requestTimeout: TimeInterval = 30
    /// A segment that receives nothing for this long gets a second connection
    /// racing on the same bytes, when a connection is free.
    public var stallThreshold: TimeInterval = 5
    /// Extra bytes requested past a segment's end, compared with the already
    /// downloaded start of the next segment.
    public var overlapCheckBytes: Int64 = 64
    /// Minimum time between progress callbacks.
    public var progressInterval: TimeInterval = 0.25
    /// Every limiter here applies, e.g. a global one shared by all downloads plus
    /// one for this download.
    public var speedLimiters: [SpeedLimiter] = []
    /// Matches saved progress by this key instead of by URL, for links that change on
    /// every request (e.g. video streams with expiring tokens) but point to the same bytes.
    public var resumeKey: String?

    public init() {}
}

public struct DownloadProgress: Sendable {
    public var downloaded: Int64
    public var total: Int64?
    public var activeConnections: Int
    /// Whether the server supports ranges, so the download can be paused and resumed.
    public var resumable = false
    /// Where each part of the file stands, in file order.
    public var segments: [SegmentProgress] = []

    public init(downloaded: Int64, total: Int64?, activeConnections: Int, resumable: Bool = false,
                segments: [SegmentProgress] = []) {
        self.downloaded = downloaded
        self.total = total
        self.activeConnections = activeConnections
        self.resumable = resumable
        self.segments = segments
    }
}

public struct SegmentProgress: Sendable, Equatable {
    public var start: Int64
    public var current: Int64
    public var end: Int64
    /// Connections working on this segment right now (2 while an alternative races).
    public var connections: Int
}

/// What a server says about a file before downloading it.
public struct RemoteFileInfo: Sendable, Equatable {
    public var size: Int64?
    public var resumable: Bool
    /// From Content-Disposition, or the last part of the URL.
    public var suggestedFilename: String?
    public var mimeType: String?

    public init(size: Int64?, resumable: Bool, suggestedFilename: String?, mimeType: String?) {
        self.size = size
        self.resumable = resumable
        self.suggestedFilename = suggestedFilename
        self.mimeType = mimeType
    }
}

/// What is saved next to the partial file so a download can resume after a restart.
struct ResumeState: Codable {
    var url: URL
    var totalSize: Int64
    var segments: [Segment]
    var key: String?
}

/// Downloads one URL into `destination` using several parallel range requests.
/// Data goes to `<destination>.mdmpart` and resume state to `<destination>.mdmpart.json`;
/// the part file is renamed to `destination` when every byte has arrived.
public actor SegmentedDownload {
    public let url: URL
    public let destination: URL
    let options: DownloadOptions
    let session: URLSession

    private var segments: [Segment] = []
    /// Number of connections working on each segment (2 while an alternative races).
    private var connections: [Int: Int] = [:]
    private var lastProgress: [Int: Date] = [:]
    private var failures: [Int: Int] = [:]
    /// Cancels the requests still running for a segment once it is complete.
    private var cancellers: [Int: [UUID: @Sendable () -> Void]] = [:]
    private var totalSize: Int64?
    private var file: FileHandle?
    private var lastStateSave = Date.distantPast
    private var lastProgressReport = Date.distantPast
    private var onProgress: (@Sendable (DownloadProgress) -> Void)?

    var partURL: URL { destination.appendingPathExtension("mdmpart") }
    var stateURL: URL { partURL.appendingPathExtension("json") }

    public init(url: URL, destination: URL, options: DownloadOptions = .init(), session: URLSession = .shared) {
        self.url = url
        self.destination = destination
        self.options = options
        self.session = session
    }

    @discardableResult
    public func start(onProgress: (@Sendable (DownloadProgress) -> Void)? = nil) async throws -> URL {
        self.onProgress = onProgress
        defer { try? file?.close(); file = nil }

        if let state = loadState() {
            totalSize = state.totalSize
            segments = state.segments
            file = try FileHandle(forUpdating: partURL)
        } else if let size = try await probeRangeSupport() {
            totalSize = size
            // Start like IDM: one segment for the whole file; the other connections
            // join by splitting it.
            segments = [Segment(start: 0, end: size - 1)]
            try createPartFile(size: size)
            try saveState()
        } else {
            try createPartFile(size: 0)
            try await downloadWithoutRanges()
            return try finish()
        }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<options.maxConnections {
                    group.addTask { try await self.runWorker() }
                }
                try await group.waitForAll()
            }
        } catch {
            // Paused (task cancelled) or failed: keep exact progress for resuming.
            try? saveState()
            throw error
        }

        let received = segments.reduce(0) { $0 + $1.downloaded }
        guard received == totalSize else {
            throw DownloadError.sizeMismatch(expected: totalSize ?? 0, actual: received)
        }
        return try finish()
    }

    // MARK: - Probing

    /// Asks the server about a file without downloading it.
    public static func probe(url: URL, headers: [String: String] = [:], session: URLSession = .shared) async throws
        -> RemoteFileInfo
    {
        var request = URLRequest(url: url, timeoutInterval: 30)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        for try await event in chunkStream(session: session, request: request) {
            guard case .response(let response) = event else { continue }
            guard (200..<300).contains(response.statusCode) else { throw DownloadError.badStatus(response.statusCode) }
            let total = response.value(forHTTPHeaderField: "Content-Range")?
                .split(separator: "/").last.flatMap { Int64($0) }
            let resumable = response.statusCode == 206 && total != nil
            let size = resumable ? total : (response.expectedContentLength > 0 ? response.expectedContentLength : nil)
            let mime = response.value(forHTTPHeaderField: "Content-Type")?
                .split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) }
            return RemoteFileInfo(size: size, resumable: resumable,
                                  suggestedFilename: Filename.suggested(by: response), mimeType: mime)
        }
        throw DownloadError.connectionClosedEarly
    }

    /// Asks for the first byte only. A 206 reply with a total size means the server
    /// supports ranges; anything else means a single plain download.
    private func probeRangeSupport() async throws -> Int64? {
        var request = makeRequest()
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        for try await event in chunkStream(session: session, request: request) {
            guard case .response(let response) = event else { continue }
            guard response.statusCode == 206,
                let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
                let total = contentRange.split(separator: "/").last.flatMap({ Int64($0) }),
                total > 0
            else { return nil }
            return total
        }
        try Task.checkCancellation()
        return nil
    }

    // MARK: - Workers

    private enum Claim {
        case segment(Int)
        case wait
        case done
    }

    private func runWorker() async throws {
        // A session per connection: within one session URLSession puts every request to
        // an HTTP/2 server on a single TCP connection, which defeats the point of
        // downloading with several connections.
        let connection = URLSession(configuration: session.configuration)
        defer { connection.finishTasksAndInvalidate() }
        while true {
            try Task.checkCancellation()
            switch claimWork() {
            case .done:
                return
            case .wait:
                try await Task.sleep(for: .milliseconds(250))
            case .segment(let index):
                do {
                    try await fetch(segmentAt: index, using: connection)
                    connections[index, default: 1] -= 1
                } catch {
                    connections[index, default: 1] -= 1
                    if Task.isCancelled { throw CancellationError() }
                    // A request cancelled because a racing connection finished its
                    // segment is not a failure.
                    if segments[index].isComplete, (error as? URLError)?.code == .cancelled { continue }
                    try await recordFailure(error, segment: index)
                }
            }
        }
    }

    /// Picks an unstarted segment, splits the largest running one, or races a
    /// stalled one; waits while other connections may still need help.
    private func claimWork() -> Claim {
        if let idle = segments.indices.first(where: { connections[$0, default: 0] == 0 && !segments[$0].isComplete }) {
            return occupy(idle)
        }
        if let new = SegmentPlanner.splitLargest(&segments, minSplitSize: options.minSplitSize) {
            return occupy(new)
        }
        let now = Date()
        if let stalled = segments.indices.first(where: {
            connections[$0, default: 0] == 1 && !segments[$0].isComplete
                && now.timeIntervalSince(lastProgress[$0] ?? now) >= options.stallThreshold
        }) {
            return occupy(stalled)
        }
        return segments.allSatisfy(\.isComplete) ? .done : .wait
    }

    private func occupy(_ index: Int) -> Claim {
        connections[index, default: 0] += 1
        if connections[index] == 1 { lastProgress[index] = Date() }
        return .segment(index)
    }

    private func recordFailure(_ error: Error, segment index: Int) async throws {
        let retryable = (error as? DownloadError)?.isRetryable ?? (error is URLError)
        failures[index, default: 0] += 1
        guard retryable, failures[index]! <= options.maxRetries else {
            if retryable { throw DownloadError.tooManyRetries(underlying: "\(error)") }
            throw error
        }
        // Back off 0.5s, 1s, 2s, ... up to 10s before the segment is picked up again.
        let delay = min(0.5 * pow(2, Double(failures[index]! - 1)), 10)
        connections[index, default: 0] += 1
        defer { connections[index, default: 1] -= 1 }
        try await Task.sleep(for: .seconds(delay))
    }

    private func fetch(segmentAt index: Int, using connection: URLSession) async throws {
        let s = segments[index]
        let overlap = overlapBytes(after: s.end)
        var request = makeRequest()
        request.setValue("bytes=\(s.current)-\(s.end + overlap)", forHTTPHeaderField: "Range")

        let id = UUID()
        let chunks = startChunkRequest(session: connection, request: request)
        cancellers[index, default: [:]][id] = chunks.cancel
        defer { cancellers[index]?[id] = nil }

        var position = s.current
        var verifying = Data()
        for try await event in chunks.stream {
            if case .data(let data) = event {
                for limiter in options.speedLimiters { try await limiter.acquire(data.count) }
                chunks.consumed(data.count)
            }
            switch event {
            case .response(let response):
                guard response.statusCode == 206 else { throw DownloadError.badStatus(response.statusCode) }
                let range = response.value(forHTTPHeaderField: "Content-Range") ?? ""
                guard range.hasPrefix("bytes \(s.current)-") else {
                    throw DownloadError.rangeMismatch(expectedStart: s.current)
                }
            case .data(let data):
                if !segments[index].isComplete {
                    let consumed = try write(data, at: position, to: index)
                    position += Int64(data.count)
                    guard segments[index].isComplete else { continue }
                    finishSegment(index, except: id)
                    // Only verify if the segment still ends where it did when we asked.
                    guard overlap > 0, segments[index].end == s.end else { return }
                    verifying.append(data.dropFirst(consumed))
                } else {
                    verifying.append(data)
                }
                if Int64(verifying.count) >= overlap {
                    try verifyOverlap(verifying.prefix(Int(overlap)), at: s.end + 1)
                    return
                }
            }
        }
        // The stream ended. Fine if the segment is done (the overlap may be cut short
        // when the server sent less); otherwise we were paused or the connection dropped.
        try Task.checkCancellation()
        if !segments[index].isComplete { throw DownloadError.connectionClosedEarly }
    }

    /// Writes the part of `data` (which starts at file offset `position`) that is new
    /// for the segment: bytes before `current` were already written by a racing
    /// connection, bytes after `end` belong to the next segment.
    /// Returns how many bytes of `data` were within the segment.
    private func write(_ data: Data, at position: Int64, to index: Int) throws -> Int {
        let s = segments[index]
        let dataEnd = position + Int64(data.count)            // exclusive
        let from = max(s.current, position)
        let to = min(s.end + 1, dataEnd)                       // exclusive
        if from < to, let file {
            try file.seek(toOffset: UInt64(from))
            try file.write(contentsOf: data.subdata(in: Int(from - position)..<Int(to - position)))
            segments[index].current = to
            lastProgress[index] = Date()
            reportProgress()
            try saveStateIfDue()
        }
        return Int(max(0, min(s.end + 1, dataEnd) - position))
    }

    /// Stops any other connection still racing on a finished segment.
    private func finishSegment(_ index: Int, except id: UUID) {
        for (other, cancel) in cancellers[index] ?? [:] where other != id { cancel() }
    }

    /// How many bytes to request past `end`: only when the next segment already has
    /// at least that many bytes on disk to compare against.
    private func overlapBytes(after end: Int64) -> Int64 {
        guard options.overlapCheckBytes > 0,
            let next = segments.first(where: { $0.start == end + 1 }),
            next.downloaded >= options.overlapCheckBytes
        else { return 0 }
        return options.overlapCheckBytes
    }

    private func verifyOverlap(_ received: Data, at offset: Int64) throws {
        guard let file else { return }
        try file.seek(toOffset: UInt64(offset))
        let onDisk = try file.read(upToCount: received.count) ?? Data()
        guard onDisk == received else { throw DownloadError.dataMismatch(offset: offset) }
    }

    // MARK: - Servers without range support

    private func downloadWithoutRanges() async throws {
        var written: Int64 = 0
        let chunks = startChunkRequest(session: session, request: makeRequest())
        for try await event in chunks.stream {
            if case .data(let data) = event {
                for limiter in options.speedLimiters { try await limiter.acquire(data.count) }
                chunks.consumed(data.count)
            }
            switch event {
            case .response(let response):
                guard (200..<300).contains(response.statusCode) else {
                    throw DownloadError.badStatus(response.statusCode)
                }
                if response.expectedContentLength > 0 { totalSize = response.expectedContentLength }
            case .data(let data):
                try file?.write(contentsOf: data)
                written += Int64(data.count)
                onProgress?(DownloadProgress(downloaded: written, total: totalSize, activeConnections: 1))
            }
        }
        // Without range support a paused download restarts from zero next time.
        try Task.checkCancellation()
        if let totalSize, written != totalSize {
            throw DownloadError.sizeMismatch(expected: totalSize, actual: written)
        }
    }

    // MARK: - Files and state

    private func makeRequest() -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: options.requestTimeout)
        for (name, value) in options.headers { request.setValue(value, forHTTPHeaderField: name) }
        // Ask for raw bytes so byte offsets match the file on the server.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }

    private func createPartFile(size: Int64) throws {
        FileManager.default.createFile(atPath: partURL.path, contents: nil)
        let handle = try FileHandle(forUpdating: partURL)
        if size > 0 { try handle.truncate(atOffset: UInt64(size)) }
        file = handle
    }

    private func loadState() -> ResumeState? {
        guard FileManager.default.fileExists(atPath: partURL.path),
            let data = try? Data(contentsOf: stateURL),
            let state = try? JSONDecoder().decode(ResumeState.self, from: data),
            options.resumeKey.map({ $0 == state.key }) ?? (state.url == url)
        else { return nil }
        return state
    }

    private func saveState() throws {
        guard let totalSize else { return }
        let state = ResumeState(url: url, totalSize: totalSize, segments: segments, key: options.resumeKey)
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        lastStateSave = Date()
    }

    private func saveStateIfDue() throws {
        if Date().timeIntervalSince(lastStateSave) >= options.stateSaveInterval { try saveState() }
    }

    private func reportProgress() {
        guard let onProgress, Date().timeIntervalSince(lastProgressReport) >= options.progressInterval else { return }
        lastProgressReport = Date()
        let downloaded = segments.reduce(0) { $0 + $1.downloaded }
        let active = connections.values.reduce(0, +)
        let parts = segments.indices
            .map { SegmentProgress(start: segments[$0].start, current: segments[$0].current,
                                   end: segments[$0].end, connections: connections[$0, default: 0]) }
            .sorted { $0.start < $1.start }
        onProgress(DownloadProgress(downloaded: downloaded, total: totalSize, activeConnections: active,
                                    resumable: true, segments: parts))
    }

    private func finish() throws -> URL {
        try file?.synchronize()
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partURL, to: destination)
        try? FileManager.default.removeItem(at: stateURL)
        return destination
    }
}
