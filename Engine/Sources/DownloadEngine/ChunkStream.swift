import Foundation

enum ChunkEvent: Sendable {
    case response(HTTPURLResponse)
    case data(Data)
}

/// A running request whose response and body arrive as chunks.
struct ChunkRequest {
    let stream: AsyncThrowingStream<ChunkEvent, Error>
    /// Cancels the request from outside; iteration then ends with a cancellation error.
    let cancel: @Sendable () -> Void
    /// Call after handling each `.data` chunk. While too much received data is waiting
    /// to be handled, the request is suspended so the server slows down too.
    let consumed: @Sendable (Int) -> Void
}

/// Delivers a request's response and body as chunks, as they arrive from the network.
/// Ending iteration early cancels the underlying task.
func chunkStream(session: URLSession, request: URLRequest) -> AsyncThrowingStream<ChunkEvent, Error> {
    let request = startChunkRequest(session: session, request: request, flowControl: false)
    return request.stream
}

/// With flow control the request's own `timeoutInterval` is replaced by an idle timeout
/// that ignores time spent suspended (URLSession would count it and time out).
func startChunkRequest(session: URLSession, request: URLRequest, flowControl: Bool = true) -> ChunkRequest {
    var request = request
    let idleTimeout = request.timeoutInterval
    if flowControl { request.timeoutInterval = 7 * 24 * 3600 }
    let task = session.dataTask(with: request)
    let flow = flowControl ? FlowControl(task: task, idleTimeout: idleTimeout) : nil
    let stream = AsyncThrowingStream<ChunkEvent, Error> { continuation in
        task.delegate = ChunkDelegate(continuation: continuation, flow: flow)
        continuation.onTermination = { _ in task.cancel() }
        task.resume()
    }
    return ChunkRequest(stream: stream, cancel: { task.cancel() }, consumed: { flow?.consumed($0) })
}

/// Suspends the task while more than `highWater` bytes are received but not yet handled,
/// and resumes it once the backlog drops below `lowWater`. Also fails the task when it
/// receives nothing for `idleTimeout` while running.
private final class FlowControl: @unchecked Sendable {
    static let highWater = 512 * 1024
    static let lowWater = 128 * 1024

    private let task: URLSessionDataTask
    private let idleTimeout: TimeInterval
    private let lock = NSLock()
    private var pending = 0
    private var suspended = false
    private var lastActivity = Date()
    private var timer: DispatchSourceTimer?
    private(set) var timedOut = false

    init(task: URLSessionDataTask, idleTimeout: TimeInterval) {
        self.task = task
        self.idleTimeout = idleTimeout
        let timer = DispatchSource.makeTimerSource(queue: .global())
        let interval = min(1, idleTimeout / 4)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.checkIdle() }
        timer.resume()
        self.timer = timer
    }

    private func checkIdle() {
        lock.withLock {
            guard !suspended, !timedOut, Date().timeIntervalSince(lastActivity) > idleTimeout else { return }
            timedOut = true
            task.cancel()
        }
    }

    func stop() {
        lock.withLock { timer?.cancel(); timer = nil }
    }

    func received(_ count: Int) {
        lock.withLock {
            pending += count
            lastActivity = Date()
            if !suspended && pending > Self.highWater {
                suspended = true
                task.suspend()
            }
        }
    }

    func consumed(_ count: Int) {
        lock.withLock {
            pending -= count
            if suspended && pending < Self.lowWater {
                suspended = false
                lastActivity = Date()  // the idle clock only runs while not suspended
                task.resume()
            }
        }
    }
}

private final class ChunkDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let continuation: AsyncThrowingStream<ChunkEvent, Error>.Continuation
    let flow: FlowControl?

    init(continuation: AsyncThrowingStream<ChunkEvent, Error>.Continuation, flow: FlowControl?) {
        self.continuation = continuation
        self.flow = flow
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            continuation.finish(throwing: DownloadError.notHTTP)
            completionHandler(.cancel)
            return
        }
        continuation.yield(.response(http))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        flow?.received(data.count)
        continuation.yield(.data(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        flow?.stop()
        if flow?.timedOut == true {
            continuation.finish(throwing: URLError(.timedOut))
        } else if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}
