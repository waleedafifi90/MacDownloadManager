import Foundation
import Observation

/// Runs download queues: starts their files in order, a few at a time, retries failures,
/// follows each queue's schedule, and reports when a queue is done.
@MainActor @Observable
public final class QueueManager {
    public private(set) var queues: [DownloadQueue]
    public private(set) var running: Set<UUID> = []
    /// Called when a running queue has processed all its files, so the UI can carry out
    /// its "when done" action. Not called for a queue that had nothing to download.
    public var didFinishQueue: ((DownloadQueue) -> Void)?

    private let manager: DownloadManager
    private let storeURL: URL?
    /// Failed attempts per download while its queue runs.
    var failures: [UUID: Int] = [:]
    /// Downloads a running queue won't start again: the user stopped them, or they ran out of retries.
    private var skipped: Set<UUID> = []
    /// Downloads started by a queue in its current run.
    private var processed: [UUID: Set<UUID>] = [:]
    private var lastCheck: Date

    public init(manager: DownloadManager, storeURL: URL? = nil, now: Date = Date()) {
        self.manager = manager
        self.storeURL = storeURL
        self.lastCheck = now
        queues = [.main]
        load()
        manager.runEnded = { [weak self] item in self?.runEnded(item) }
    }

    public static func storeURL(nextTo downloads: URL?) -> URL? {
        downloads?.deletingLastPathComponent().appendingPathComponent("queues.json")
    }

    // MARK: - Queues

    public func queue(id: UUID) -> DownloadQueue? { queues.first { $0.id == id } }

    @discardableResult
    public func addQueue(named name: String) -> DownloadQueue {
        let queue = DownloadQueue(name: name)
        queues.append(queue)
        save()
        return queue
    }

    /// Any queue but the main one can be deleted; its downloads stay in the list.
    public func deleteQueue(id: UUID) {
        guard id != DownloadQueue.mainID else { return }
        stop(id)
        queues.removeAll { $0.id == id }
        save()
    }

    /// Saves a queue's settings. Its downloads are kept as they are: they change only
    /// through add/remove/move, so an editor holding an older copy can't drop any.
    public func update(_ queue: DownloadQueue) {
        guard let index = queues.firstIndex(where: { $0.id == queue.id }) else { return }
        var queue = queue
        queue.itemIDs = queues[index].itemIDs
        queues[index] = queue
        save()
        if running.contains(queue.id) { pump(queue.id) }
    }

    /// The queue a download belongs to, if any.
    public func queue(of item: DownloadItem) -> DownloadQueue? {
        queues.first { $0.itemIDs.contains(item.id) }
    }

    /// Moves a download into a queue (a download is in at most one queue).
    public func add(_ item: DownloadItem, to queueID: UUID) {
        for index in queues.indices { queues[index].itemIDs.removeAll { $0 == item.id } }
        guard let index = queues.firstIndex(where: { $0.id == queueID }) else { return }
        queues[index].itemIDs.append(item.id)
        save()
        if running.contains(queueID) { pump(queueID) }
    }

    public func removeFromQueues(_ item: DownloadItem) {
        for index in queues.indices { queues[index].itemIDs.removeAll { $0 == item.id } }
        save()
    }

    /// Moves a download up or down within its queue.
    public func move(_ item: DownloadItem, by offset: Int) {
        guard let q = queues.firstIndex(where: { $0.itemIDs.contains(item.id) }),
            let i = queues[q].itemIDs.firstIndex(of: item.id)
        else { return }
        let j = min(max(i + offset, 0), queues[q].itemIDs.count - 1)
        queues[q].itemIDs.swapAt(i, j)
        save()
    }

    /// The queue's downloads that still exist, in order.
    public func items(in queueID: UUID) -> [DownloadItem] {
        (queue(id: queueID)?.itemIDs ?? []).compactMap(manager.item(id:))
    }

    // MARK: - Running

    public func start(_ queueID: UUID) {
        guard queue(id: queueID) != nil, !running.contains(queueID) else { return }
        running.insert(queueID)
        processed[queueID] = []
        for item in items(in: queueID) {
            failures[item.id] = nil
            skipped.remove(item.id)
        }
        pump(queueID)
    }

    /// Stops the queue and the downloads it started.
    public func stop(_ queueID: UUID) {
        guard running.remove(queueID) != nil else { return }
        for item in items(in: queueID) where item.status == .downloading { manager.pause(item) }
        processed[queueID] = nil
    }

    /// Starts queues marked "Start download on app startup".
    public func startQueuesOnLaunch() {
        for queue in queues where queue.startOnLaunch { start(queue.id) }
    }

    /// Checks the schedules; call regularly (the app does every 15 seconds).
    public func tick(now: Date = Date()) {
        let from = lastCheck
        lastCheck = now
        guard now > from else { return }
        for queue in queues {
            if !running.contains(queue.id), let trigger = queue.start, QueueSchedule.fires(trigger, from: from, to: now) {
                start(queue.id)
            }
            if running.contains(queue.id), let stopAt = queue.stopAt, QueueSchedule.passes(stopAt, from: from, to: now) {
                stop(queue.id)
            }
        }
    }

    private func isWaiting(_ item: DownloadItem) -> Bool {
        guard !skipped.contains(item.id) else { return false }
        switch item.status {
        case .paused, .failed: return true
        case .downloading, .completed: return false
        }
    }

    /// Starts downloads in order until the queue's limit is reached, or finishes the queue.
    func pump(_ queueID: UUID) {
        guard running.contains(queueID), let queue = queue(id: queueID) else { return }
        let items = items(in: queueID)
        var active = items.filter { $0.status == .downloading }.count
        for item in items where active < queue.maxConcurrent && isWaiting(item) {
            processed[queueID, default: []].insert(item.id)
            manager.resume(item)
            active += 1
        }
        if active == 0 { finish(queue) }
    }

    private func finish(_ queue: DownloadQueue) {
        running.remove(queue.id)
        let didWork = !(processed[queue.id]?.isEmpty ?? true)
        processed[queue.id] = nil
        if didWork { didFinishQueue?(queue) }
    }

    /// A download stopped running (finished, failed or paused).
    func runEnded(_ item: DownloadItem) {
        guard let queue = queue(of: item), running.contains(queue.id),
            processed[queue.id]?.contains(item.id) == true
        else { return }
        switch item.status {
        case .failed:
            failures[item.id, default: 0] += 1
            if failures[item.id]! > queue.retries { skipped.insert(item.id) }
        case .paused:
            // Stopped by the user while the queue runs: move on to the next file.
            skipped.insert(item.id)
        case .completed, .downloading:
            break
        }
        pump(queue.id)
    }

    // MARK: - Persistence

    private func load() {
        guard let storeURL, let data = try? Data(contentsOf: storeURL),
            let saved = try? JSONDecoder().decode([DownloadQueue].self, from: data)
        else { return }
        queues = saved.contains { $0.id == DownloadQueue.mainID } ? saved : [.main] + saved
    }

    private func save() {
        guard let storeURL else { return }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(queues).write(to: storeURL, options: .atomic)
    }
}
