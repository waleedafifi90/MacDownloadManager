import DownloadEngineTestSupport
import Foundation
import Testing
@testable import DownloadsCore

struct QueueScheduleTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    @Test func dailyStartIsLaterTodayOrTomorrow() {
        let time = TimeOfDay(hour: 2, minute: 30)
        #expect(QueueSchedule.nextOccurrence(of: time, after: date("2026-10-22T01:00:00Z"), calendar: calendar)
                == date("2026-10-22T02:30:00Z"))
        #expect(QueueSchedule.nextOccurrence(of: time, after: date("2026-10-22T02:30:00Z"), calendar: calendar)
                == date("2026-10-23T02:30:00Z"))
    }

    @Test func dailyStartRespectsWeekdays() {
        // 2026-10-22 is a Thursday; next Monday (weekday 2) is the 26th.
        let start = QueueStart.daily(TimeOfDay(hour: 9, minute: 0), weekdays: [2])
        #expect(QueueSchedule.nextStart(start, after: date("2026-10-22T12:00:00Z"), calendar: calendar)
                == date("2026-10-26T09:00:00Z"))
    }

    @Test func onceStartsOnlyOnce() {
        let start = QueueStart.once(date("2026-10-22T20:00:00Z"))
        #expect(QueueSchedule.fires(start, from: date("2026-10-22T19:59:00Z"), to: date("2026-10-22T20:00:30Z"),
                                    calendar: calendar))
        #expect(!QueueSchedule.fires(start, from: date("2026-10-22T20:00:30Z"), to: date("2026-10-23T20:00:30Z"),
                                     calendar: calendar))
    }
}

@MainActor @Suite(.serialized) struct QueueManagerTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("mdm-queue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func makeManager() -> DownloadManager {
        let manager = DownloadManager(storeURL: nil,
                                      settings: AppSettings(defaults: UserDefaults(suiteName: "mdm-\(UUID().uuidString)")!))
        manager.settings.maxConnections = 2
        return manager
    }

    func later(_ manager: DownloadManager, _ server: TestServer, _ name: String) -> DownloadItem {
        manager.add(url: server.url, destination: folder.appendingPathComponent(name), startNow: false)
    }

    func waitUntil(timeout: TimeInterval = 30, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { Issue.record("Timed out waiting"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func runsFilesInOrderOneAtATime() async throws {
        let body = Data((0..<300_000).map { UInt8($0 % 251) })
        let server = try TestServer(body: body, chunkSize: 16 * 1024, chunkDelay: 0.01)
        defer { server.stop() }
        let manager = makeManager()
        let queues = QueueManager(manager: manager)
        let items = ["a.bin", "b.bin", "c.bin"].map { later(manager, server, $0) }
        items.forEach { queues.add($0, to: DownloadQueue.mainID) }
        var finished: [String] = []
        queues.didFinishQueue = { finished.append($0.name) }

        var mostAtOnce = 0
        var completionOrder: [String] = []
        queues.start(DownloadQueue.mainID)
        while queues.running.contains(DownloadQueue.mainID) {
            mostAtOnce = max(mostAtOnce, items.filter { $0.status == .downloading }.count)
            for item in items where item.status == .completed && !completionOrder.contains(item.fileName) {
                completionOrder.append(item.fileName)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        // The last file completes in the same moment the queue finishes.
        for item in items where item.status == .completed && !completionOrder.contains(item.fileName) {
            completionOrder.append(item.fileName)
        }

        #expect(items.allSatisfy { $0.status == .completed })
        #expect(mostAtOnce == 1)
        #expect(completionOrder == ["a.bin", "b.bin", "c.bin"])
        #expect(finished == ["Main download queue"])
    }

    @Test func runsSeveralAtOnceWhenAllowed() async throws {
        let body = Data((0..<300_000).map { UInt8($0 % 251) })
        let server = try TestServer(body: body, chunkSize: 16 * 1024, chunkDelay: 0.01)
        defer { server.stop() }
        let manager = makeManager()
        let queues = QueueManager(manager: manager)
        var queue = queues.addQueue(named: "Night")
        queue.maxConcurrent = 2
        queues.update(queue)
        let items = ["a.bin", "b.bin", "c.bin"].map { later(manager, server, $0) }
        items.forEach { queues.add($0, to: queue.id) }

        queues.start(queue.id)
        #expect(items.filter { $0.status == .downloading }.count == 2)
        try await waitUntil { !queues.running.contains(queue.id) }
        #expect(items.allSatisfy { $0.status == .completed })
    }

    @Test func retriesAFailingFileThenMovesOn() async throws {
        let server = try TestServer(body: Data(count: 50_000))
        defer { server.stop() }
        let manager = makeManager()
        manager.engineOptions.maxRetries = 0
        let queues = QueueManager(manager: manager)
        var queue = queues.queue(id: DownloadQueue.mainID)!
        queue.retries = 2
        queues.update(queue)
        // Nothing listens on port 9: every attempt fails at once.
        let broken = manager.add(url: URL(string: "http://127.0.0.1:9/broken.bin")!,
                                 destination: folder.appendingPathComponent("broken.bin"), startNow: false)
        let good = later(manager, server, "good.bin")
        queues.add(broken, to: queue.id)
        queues.add(good, to: queue.id)

        queues.start(queue.id)
        try await waitUntil { !queues.running.contains(queue.id) }

        #expect(queues.failures[broken.id] == 3)  // first try + 2 retries
        if case .failed = broken.status {} else { Issue.record("expected failed, got \(broken.status)") }
        #expect(good.status == .completed)
    }

    @Test func stoppingAFileMovesTheQueueOn() async throws {
        let body = Data((0..<2_000_000).map { UInt8($0 % 251) })
        let server = try TestServer(body: body, chunkSize: 8 * 1024, chunkDelay: 0.05)
        defer { server.stop() }
        let manager = makeManager()
        let queues = QueueManager(manager: manager)
        let first = later(manager, server, "first.bin")
        let second = later(manager, server, "second.bin")
        queues.add(first, to: DownloadQueue.mainID)
        queues.add(second, to: DownloadQueue.mainID)

        queues.start(DownloadQueue.mainID)
        try await waitUntil { first.downloaded > 0 }
        manager.pause(first)
        try await waitUntil { second.status == .downloading }
        #expect(first.status == .paused)
        queues.stop(DownloadQueue.mainID)
        try await waitUntil { second.status == .paused }
    }

    @Test func scheduleStartsAndStopsTheQueue() async throws {
        let body = Data((0..<2_000_000).map { UInt8($0 % 251) })
        let server = try TestServer(body: body, chunkSize: 8 * 1024, chunkDelay: 0.05)
        defer { server.stop() }
        let manager = makeManager()
        let t0 = Date()
        let queues = QueueManager(manager: manager, now: t0)
        let item = later(manager, server, "night.bin")
        queues.add(item, to: DownloadQueue.mainID)
        var queue = queues.queue(id: DownloadQueue.mainID)!
        queue.start = .once(t0.addingTimeInterval(60))
        let stop = Calendar.current.dateComponents([.hour, .minute], from: t0.addingTimeInterval(180))
        queue.stopAt = TimeOfDay(hour: stop.hour!, minute: stop.minute!)
        queues.update(queue)

        queues.tick(now: t0.addingTimeInterval(30))
        #expect(!queues.running.contains(queue.id))
        queues.tick(now: t0.addingTimeInterval(61))
        #expect(queues.running.contains(queue.id))
        #expect(item.status == .downloading)

        queues.tick(now: t0.addingTimeInterval(241))
        #expect(!queues.running.contains(queue.id))
        try await waitUntil { item.status == .paused }
    }

    @Test func emptyQueueFinishesWithoutTheWhenDoneAction() {
        let queues = QueueManager(manager: makeManager())
        var finished = 0
        queues.didFinishQueue = { _ in finished += 1 }
        queues.start(DownloadQueue.mainID)
        #expect(!queues.running.contains(DownloadQueue.mainID))
        #expect(finished == 0)
    }

    @Test func queuesAreSavedAndTheMainQueueAlwaysExists() {
        let store = folder.appendingPathComponent("queues.json")
        let manager = makeManager()
        let queues = QueueManager(manager: manager, storeURL: store)
        var night = queues.addQueue(named: "Night")
        night.whenDone = .sleep
        night.start = .daily(TimeOfDay(hour: 2, minute: 0), weekdays: [1, 7])
        queues.update(night)
        queues.deleteQueue(id: DownloadQueue.mainID)  // ignored

        let reloaded = QueueManager(manager: manager, storeURL: store)
        #expect(reloaded.queues.map(\.name) == ["Main download queue", "Night"])
        #expect(reloaded.queue(id: night.id) == night)
    }
}
