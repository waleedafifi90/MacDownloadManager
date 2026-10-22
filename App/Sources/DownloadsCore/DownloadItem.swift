import DownloadEngine
import Foundation
import Observation

public enum DownloadStatus: Codable, Equatable, Sendable {
    case downloading
    case paused
    case completed
    case failed(String)
}

/// One row of the download list.
@MainActor @Observable
public final class DownloadItem: Identifiable {
    public let id: UUID
    public let url: URL
    public let destination: URL
    public let addedAt: Date
    public let category: DownloadCategory
    public var note: String
    /// Sent with every request, e.g. the browser's Cookie, Referer and User-Agent.
    public let requestHeaders: [String: String]
    /// Set for video/audio from a page (fetched through yt-dlp); nil for plain files.
    public let media: MediaSource?
    public internal(set) var status: DownloadStatus
    public internal(set) var downloaded: Int64
    public internal(set) var total: Int64?
    public internal(set) var lastTry: Date?
    public internal(set) var resumable: Bool?
    public internal(set) var connections = 0
    /// Where each part of the file stands, from the last progress update.
    public internal(set) var segments: [SegmentProgress] = []
    /// Bytes per second over the last few seconds.
    public internal(set) var speed: Double = 0
    /// This download's own limit in KB/s, or nil for none.
    public var speedLimitKBps: Int? {
        didSet { Task { [limiter, speedLimitKBps] in await limiter.setLimit(speedLimitKBps.map { Int64($0) * 1024 }) } }
    }

    let limiter = SpeedLimiter()
    var task: Task<Void, Never>?
    /// Identifies the latest run, so a stopping older run cannot change the status.
    var runID: UUID?
    private var samples: [(time: Date, bytes: Int64)] = []

    init(id: UUID = UUID(), url: URL, destination: URL, addedAt: Date = Date(), category: DownloadCategory,
         note: String = "", requestHeaders: [String: String] = [:], media: MediaSource? = nil, status: DownloadStatus, downloaded: Int64 = 0, total: Int64? = nil,
         lastTry: Date? = nil, resumable: Bool? = nil, speedLimitKBps: Int? = nil) {
        self.id = id
        self.url = url
        self.destination = destination
        self.addedAt = addedAt
        self.category = category
        self.note = note
        self.requestHeaders = requestHeaders
        self.media = media
        self.status = status
        self.downloaded = downloaded
        self.total = total
        self.lastTry = lastTry
        self.resumable = resumable
        self.speedLimitKBps = speedLimitKBps
        if let speedLimitKBps {
            Task { [limiter] in await limiter.setLimit(Int64(speedLimitKBps) * 1024) }
        }
    }

    public var fileName: String { destination.lastPathComponent }

    /// The page the file came from, as the browser reported it (File Properties).
    public var referrer: String? { requestHeaders["Referer"] }

    public var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(downloaded) / Double(total))
    }

    public var timeRemaining: TimeInterval? {
        guard status == .downloading, let total, speed > 0 else { return nil }
        return Double(total - downloaded) / speed
    }

    func apply(_ progress: DownloadProgress) {
        guard status == .downloading else { return }
        downloaded = progress.downloaded
        total = progress.total ?? total
        connections = progress.activeConnections
        resumable = progress.resumable
        if !progress.segments.isEmpty { segments = progress.segments }

        let now = Date()
        samples.append((now, progress.downloaded))
        samples.removeAll { now.timeIntervalSince($0.time) > 3 }
        if let first = samples.first, let last = samples.last, last.time > first.time {
            speed = Double(last.bytes - first.bytes) / last.time.timeIntervalSince(first.time)
        }
    }

    func resetRate() {
        samples = []
        speed = 0
        connections = 0
        segments = segments.map { var s = $0; s.connections = 0; return s }
    }
}

/// What is stored on disk for each download between launches.
struct DownloadRecord: Codable {
    var id: UUID
    var url: URL
    var destination: URL
    var addedAt: Date
    var status: DownloadStatus
    var downloaded: Int64
    var total: Int64?
    // Added after 0.1; optional so older lists still load.
    var category: String?
    var note: String?
    var lastTry: Date?
    var resumable: Bool?
    var speedLimitKBps: Int?
    var requestHeaders: [String: String]?
    var media: MediaSource?
}
