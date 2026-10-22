import CaptureProtocol
import DownloadEngine
import Foundation
import Observation

/// The list of downloads: starts, pauses, resumes and removes them, and keeps the
/// list on disk so paused downloads survive a restart.
@MainActor @Observable
public final class DownloadManager {
    public private(set) var items: [DownloadItem] = []
    public let settings: AppSettings
    /// Engine options other than connections and speed limits, which come from settings.
    public var engineOptions = DownloadOptions()
    /// Called when a download starts running and when it finishes, so the UI can open
    /// the progress and "Download complete" windows.
    public var didStart: ((DownloadItem) -> Void)?
    public var didComplete: ((DownloadItem) -> Void)?
    /// Called whenever a run ends (completed, failed or paused); used by the queues.
    var runEnded: ((DownloadItem) -> Void)?

    public var videoTools = VideoTools()
    /// Shared by every download: the global Speed Limiter.
    private let globalLimiter = SpeedLimiter()
    private let storeURL: URL?
    private var lastSave = Date.distantPast

    public static var defaultStoreURL: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("MacDownloadManager", isDirectory: true)
            .appendingPathComponent("downloads.json")
    }

    /// Pass nil to keep the list in memory only.
    public init(storeURL: URL? = DownloadManager.defaultStoreURL, settings: AppSettings = AppSettings()) {
        self.storeURL = storeURL
        self.settings = settings
        load()
        applySpeedLimit()
    }

    // MARK: - Adding

    /// Adds a download. With `startNow` false it is listed as paused ("Download Later").
    @discardableResult
    public func add(url: URL, destination: URL? = nil, category: DownloadCategory? = nil, note: String = "",
                    headers: [String: String] = [:], media: MediaSource? = nil, startNow: Bool = true) -> DownloadItem {
        let destination = destination ?? proposedDestination(
            fileName: url.lastPathComponent, in: settings.folder(for: category ?? .forFile(named: url.lastPathComponent)))
        let item = DownloadItem(url: url, destination: destination,
                                category: category ?? .forFile(named: destination.lastPathComponent),
                                note: note, requestHeaders: headers, media: media, status: startNow ? .downloading : .paused)
        items.insert(item, at: 0)
        if startNow { run(item) } else { save() }
        return item
    }

    @discardableResult
    public func add(url: URL, to folder: URL) -> DownloadItem {
        add(url: url, destination: proposedDestination(fileName: url.lastPathComponent, in: folder))
    }

    /// `name.ext` in `folder`, or `name (2).ext` when the file or another download already uses it.
    public func proposedDestination(fileName: String, in folder: URL) -> URL {
        let original = fileName.isEmpty || fileName == "/" ? "download" : fileName
        let base = (original as NSString).deletingPathExtension
        let ext = (original as NSString).pathExtension
        var candidate = folder.appendingPathComponent(original)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path)
            || items.contains(where: { $0.destination == candidate }) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }

    // MARK: - Actions

    public func pause(_ item: DownloadItem) {
        guard item.status == .downloading else { return }
        item.status = .paused
        item.resetRate()
        item.task?.cancel()
        save()
    }

    public func resume(_ item: DownloadItem) {
        switch item.status {
        case .paused, .failed: run(item)
        case .downloading, .completed: break
        }
    }

    public func pauseAll() {
        items.filter { $0.status == .downloading }.forEach(pause)
    }

    /// Pauses running downloads before the app quits to update, remembering them.
    public func pauseAllForUpdate() {
        settings.resumeAfterUpdate = items.filter { $0.status == .downloading }.map(\.id.uuidString)
        pauseAll()
    }

    /// After an update: resumes the downloads that were running before it.
    public func resumeAfterUpdate() {
        let ids = Set(settings.resumeAfterUpdate)
        settings.resumeAfterUpdate = []
        items.filter { ids.contains($0.id.uuidString) }.forEach(resume)
    }

    /// Removes the download from the list and deletes its partial data.
    /// The finished file is only deleted when `deleteFile` is true.
    public func remove(_ item: DownloadItem, deleteFile: Bool = false) {
        item.task?.cancel()
        item.task = nil
        item.runID = nil
        items.removeAll { $0.id == item.id }
        let fm = FileManager.default
        let part = item.destination.appendingPathExtension("mdmpart")
        try? fm.removeItem(at: part)
        try? fm.removeItem(at: part.appendingPathExtension("json"))
        if item.media != nil {
            let dir = item.destination.deletingLastPathComponent()
            try? fm.removeItem(at: dir.appendingPathComponent(".\(item.destination.lastPathComponent).parts"))
            try? fm.removeItem(at: dir.appendingPathComponent(item.destination.lastPathComponent + ".part"))
        }
        if deleteFile { try? fm.removeItem(at: item.destination) }
        save()
    }

    /// Removes finished downloads from the list; the files stay.
    public func removeCompleted() {
        items.removeAll { $0.status == .completed }
        save()
    }

    public func item(id: UUID) -> DownloadItem? { items.first { $0.id == id } }

    /// The "Description" field (File Properties, Download File Info).
    public func setNote(_ note: String, for item: DownloadItem) {
        item.note = note
        save()
    }

    /// Applies the global Speed Limiter setting to every running download.
    public func applySpeedLimit() {
        let limit = settings.globalLimit
        Task { [globalLimiter] in await globalLimiter.setLimit(limit) }
    }

    // MARK: - Running

    private func run(_ item: DownloadItem) {
        item.status = .downloading
        item.lastTry = Date()
        item.resetRate()
        var options = engineOptions
        options.maxConnections = settings.maxConnections
        options.speedLimiters = [globalLimiter, item.limiter]
        options.headers = item.requestHeaders
        try? FileManager.default.createDirectory(at: item.destination.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let work: (@escaping @Sendable (DownloadProgress) -> Void) async throws -> Void
        if let media = item.media {
            let download = MediaDownload(tools: videoTools, source: media, destination: item.destination,
                                         headers: item.requestHeaders, options: options)
            work = { try await download.run(onProgress: $0) }
        } else {
            let engine = SegmentedDownload(url: item.url, destination: item.destination, options: options)
            work = { try await engine.start(onProgress: $0) }
        }
        // After a quick pause and resume the previous run may still be stopping;
        // wait for it so two runs never write the same file.
        let previous = item.task
        let saveIfDue: @MainActor () -> Void = { [weak self] in self?.saveIfDue() }
        let runID = UUID()
        item.runID = runID
        item.task = Task { [weak self] in
            await previous?.value
            var outcome: DownloadStatus
            do {
                try Task.checkCancellation()
                try await work { progress in
                    Task { @MainActor in
                        guard item.runID == runID else { return }
                        item.apply(progress)
                        saveIfDue()
                    }
                }
                outcome = .completed
            } catch {
                // Pausing cancels the task; anything else is a real failure.
                outcome = item.status == .paused ? .paused : .failed(Self.describe(error))
            }
            guard item.runID == runID else { return }
            item.status = outcome
            if outcome == .completed {
                item.total = item.total ?? item.downloaded
                item.downloaded = item.total ?? item.downloaded
                item.segments = []
            }
            item.resetRate()
            item.task = nil
            self?.save()
            if outcome == .completed { self?.didComplete?(item) }
            self?.runEnded?(item)
        }
        save()
        didStart?(item)
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case DownloadError.badStatus(let code): return "Server replied \(code)"
        case DownloadError.dataMismatch: return "The file changed on the server"
        case DownloadError.tooManyRetries: return "Connection kept failing"
        case ToolError.missing(let tool): return "\(tool) could not be downloaded. Check the internet connection, or install it in Options ▸ Video."
        case ToolError.failed(let message): return message
        case let error as URLError: return error.localizedDescription
        default: return "\(error)"
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let storeURL, let data = try? Data(contentsOf: storeURL),
            let records = try? JSONDecoder().decode([DownloadRecord].self, from: data)
        else { return }
        items = records.map {
            DownloadItem(id: $0.id, url: $0.url, destination: $0.destination, addedAt: $0.addedAt,
                         category: $0.category.map(DownloadCategory.named) ?? .forFile(named: $0.destination.lastPathComponent),
                         note: $0.note ?? "", requestHeaders: $0.requestHeaders ?? [:], media: $0.media,
                         // A download that was running when the app quit comes back paused.
                         status: $0.status == .downloading ? .paused : $0.status,
                         downloaded: $0.downloaded, total: $0.total, lastTry: $0.lastTry,
                         resumable: $0.resumable, speedLimitKBps: $0.speedLimitKBps)
        }
    }

    /// Saves at most every few seconds, so progress survives the app being killed.
    private func saveIfDue() {
        if Date().timeIntervalSince(lastSave) >= 3 { save() }
    }

    func save() {
        lastSave = Date()
        guard let storeURL else { return }
        let records = items.map {
            DownloadRecord(id: $0.id, url: $0.url, destination: $0.destination, addedAt: $0.addedAt,
                           status: $0.status, downloaded: $0.downloaded, total: $0.total,
                           category: $0.category.name, note: $0.note, lastTry: $0.lastTry,
                           resumable: $0.resumable, speedLimitKBps: $0.speedLimitKBps,
                           requestHeaders: $0.requestHeaders.isEmpty ? nil : $0.requestHeaders, media: $0.media)
        }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? JSONEncoder().encode(records).write(to: storeURL, options: .atomic)
    }
}
