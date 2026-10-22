import DownloadEngineTestSupport
import Foundation
import Testing
@testable import DownloadsCore

@MainActor @Suite(.serialized) struct DownloadManagerTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("mdm-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    static func randomData(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    /// Settings in a private UserDefaults domain, so tests never touch the real ones.
    func testSettings() -> AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: "mdm-tests-\(UUID().uuidString)")!)
    }

    func makeManager(storeURL: URL? = nil) -> DownloadManager {
        DownloadManager(storeURL: storeURL, settings: testSettings())
    }

    /// A manager whose downloads take a few seconds against the slow test server.
    func slowManager(storeURL: URL? = nil) -> DownloadManager {
        let manager = makeManager(storeURL: storeURL)
        manager.settings.maxConnections = 2
        return manager
    }

    /// Polls until `condition` holds, failing after `timeout`.
    func waitUntil(timeout: TimeInterval = 30, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                Issue.record("Timed out waiting")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func downloadsToTheChosenFolder() async throws {
        let body = Self.randomData(400_000)
        let server = try TestServer(body: body)
        defer { server.stop() }
        let manager = makeManager()

        let item = manager.add(url: server.url, to: folder)
        try await waitUntil { item.status == .completed }

        #expect(item.destination == folder.appendingPathComponent("file.bin"))
        #expect(try Data(contentsOf: item.destination) == body)
        #expect(item.downloaded == Int64(body.count))
    }

    @Test func pauseKeepsProgressAndResumeFinishes() async throws {
        let body = Self.randomData(2_000_000)
        let server = try TestServer(body: body, chunkSize: 8 * 1024, chunkDelay: 0.05)
        defer { server.stop() }
        let manager = slowManager()

        let item = manager.add(url: server.url, to: folder)
        try await waitUntil { item.downloaded > 100_000 }
        manager.pause(item)
        #expect(item.status == .paused)
        try await waitUntil { item.task == nil }
        let pausedAt = item.downloaded

        // Nothing arrives while paused.
        try await Task.sleep(for: .milliseconds(300))
        #expect(item.status == .paused)
        #expect(item.downloaded == pausedAt)

        manager.resume(item)
        try await waitUntil { item.status == .completed }
        #expect(try Data(contentsOf: item.destination) == body)
    }

    @Test func quickPauseAndResumeDoesNotCorruptTheFile() async throws {
        let body = Self.randomData(1_500_000)
        let server = try TestServer(body: body, chunkSize: 16 * 1024, chunkDelay: 0.005)
        defer { server.stop() }
        let manager = makeManager()

        let item = manager.add(url: server.url, to: folder)
        for _ in 0..<3 {
            try await waitUntil { item.downloaded > 0 }
            manager.pause(item)
            manager.resume(item)
        }
        try await waitUntil { item.status == .completed }
        #expect(try Data(contentsOf: item.destination) == body)
    }

    @Test func secondDownloadOfTheSameNameGetsANumber() async throws {
        let server = try TestServer(body: Self.randomData(1000))
        defer { server.stop() }
        let manager = makeManager()

        let first = manager.add(url: server.url, to: folder)
        let second = manager.add(url: server.url, to: folder)
        #expect(first.fileName == "file.bin")
        #expect(second.fileName == "file (2).bin")
        try await waitUntil { first.status == .completed && second.status == .completed }
    }

    @Test func failedDownloadShowsTheReason() async throws {
        let manager = makeManager()
        // Nothing listens on port 9 locally.
        let item = manager.add(url: URL(string: "http://127.0.0.1:9/missing.bin")!, to: folder)
        try await waitUntil { if case .failed = item.status { true } else { false } }
    }

    @Test func listSurvivesARestartWithRunningDownloadsPaused() async throws {
        let body = Self.randomData(2_000_000)
        let server = try TestServer(body: body, chunkSize: 8 * 1024, chunkDelay: 0.05)
        defer { server.stop() }
        let store = folder.appendingPathComponent("downloads.json")

        let manager = slowManager(storeURL: store)
        let item = manager.add(url: server.url, to: folder)
        try await waitUntil { item.downloaded > 100_000 }
        manager.pause(item)
        try await waitUntil { item.task == nil }

        let relaunched = makeManager(storeURL: store)
        #expect(relaunched.items.count == 1)
        let restored = try #require(relaunched.items.first)
        #expect(restored.status == .paused)
        #expect(restored.downloaded > 0)

        relaunched.resume(restored)
        try await waitUntil { restored.status == .completed }
        #expect(try Data(contentsOf: restored.destination) == body)
    }

    @Test func removeDeletesPartialData() async throws {
        let body = Self.randomData(2_000_000)
        let server = try TestServer(body: body, chunkSize: 8 * 1024, chunkDelay: 0.05)
        defer { server.stop() }
        let manager = slowManager()

        let item = manager.add(url: server.url, to: folder)
        try await waitUntil { item.downloaded > 0 }
        manager.pause(item)
        try await waitUntil { item.task == nil }
        manager.remove(item)

        #expect(manager.items.isEmpty)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(leftovers.isEmpty)
    }

    @Test func progressStartViewMigratesTheOldSwitch() {
        let defaults = UserDefaults(suiteName: "mdm-tests-\(UUID().uuidString)")!
        #expect(AppSettings(defaults: defaults).progressStartView == .normal)
        defaults.set(false, forKey: "showProgressWindow")
        #expect(AppSettings(defaults: defaults).progressStartView == .hidden)
        let settings = AppSettings(defaults: defaults)
        settings.progressStartView = .minimized
        #expect(AppSettings(defaults: defaults).progressStartView == .minimized)
    }

    @Test func categoryComesFromTheExtension() {
        #expect(DownloadCategory.forFile(named: "a.ZIP") == .compressed)
        #expect(DownloadCategory.forFile(named: "movie.r01") == .compressed)
        #expect(DownloadCategory.forFile(named: "song.mp3") == .music)
        #expect(DownloadCategory.forFile(named: "app.dmg") == .programs)
        #expect(DownloadCategory.forFile(named: "clip.mkv") == .video)
        #expect(DownloadCategory.forFile(named: "notes") == .general)
    }

    @Test func eachCategorySavesIntoItsOwnFolder() async throws {
        let server = try TestServer(body: Self.randomData(1000))
        defer { server.stop() }
        let manager = makeManager()
        manager.settings.defaultFolder = folder
        #expect(manager.settings.folder(for: .video).path == folder.appendingPathComponent("Video").path)
        #expect(manager.settings.folder(for: .general) == folder)
        manager.settings.categoryFolders["Music"] = "/tmp/elsewhere"
        #expect(manager.settings.folder(for: .music).path == "/tmp/elsewhere")

        // A .zip lands in <default>/Compressed, which is created when needed.
        let zipURL = URL(string: server.url.absoluteString.replacingOccurrences(of: "file.bin", with: "archive.zip"))!
        let item = manager.add(url: zipURL)
        #expect(item.category == .compressed)
        #expect(item.destination == folder.appendingPathComponent("Compressed/archive.zip"))
        try await waitUntil { item.status == .completed }
        #expect(FileManager.default.fileExists(atPath: item.destination.path))
    }

    @Test func downloadLaterAddsItPaused() async throws {
        let server = try TestServer(body: Self.randomData(1000))
        defer { server.stop() }
        let manager = makeManager()
        let item = manager.add(url: server.url, destination: folder.appendingPathComponent("later.bin"),
                               note: "for later", startNow: false)
        #expect(item.status == .paused)
        #expect(item.note == "for later")
        try await Task.sleep(for: .milliseconds(200))
        #expect(server.ranges.isEmpty)

        manager.resume(item)
        try await waitUntil { item.status == .completed }
        #expect(item.lastTry != nil)
    }

    @Test func perDownloadSpeedLimitSlowsItDown() async throws {
        let body = Self.randomData(400_000)
        let server = try TestServer(body: body)
        defer { server.stop() }
        let manager = makeManager()
        let item = manager.add(url: server.url, destination: folder.appendingPathComponent("limited.bin"),
                               startNow: false)
        item.speedLimitKBps = 200
        try await Task.sleep(for: .milliseconds(50))
        let started = Date()
        manager.resume(item)
        try await waitUntil { item.status == .completed }
        // 400 KB at 200 KB/s is about 2s; unlimited it takes a fraction of a second.
        #expect(Date().timeIntervalSince(started) > 1.4)
        #expect(try Data(contentsOf: item.destination) == body)
    }

    @Test func editedDescriptionIsSaved() throws {
        let store = folder.appendingPathComponent("list.json")
        let manager = makeManager(storeURL: store)
        let item = manager.add(url: URL(string: "https://example.com/a.zip")!,
                               destination: folder.appendingPathComponent("a.zip"),
                               headers: ["Referer": "https://example.com/page"], startNow: false)
        manager.setNote("Installer for the office", for: item)
        let reloaded = makeManager(storeURL: store).item(id: item.id)
        #expect(reloaded?.note == "Installer for the office")
        #expect(reloaded?.referrer == "https://example.com/page")
    }

    @Test func completionHookFires() async throws {
        let server = try TestServer(body: Self.randomData(1000))
        defer { server.stop() }
        let manager = makeManager()
        var started: [UUID] = []
        var completed: [UUID] = []
        manager.didStart = { started.append($0.id) }
        manager.didComplete = { completed.append($0.id) }
        let item = manager.add(url: server.url, to: folder)
        try await waitUntil { item.status == .completed }
        #expect(started == [item.id])
        #expect(completed == [item.id])
    }
}
