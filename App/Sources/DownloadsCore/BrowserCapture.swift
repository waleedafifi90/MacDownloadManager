import CaptureProtocol
import Foundation
import Observation

/// A download handed over by the browser extension, waiting for the user to confirm it
/// in the "Download File Info" window.
public struct PendingCapture: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let request: CaptureRequest
    public let url: URL
    /// Set when the user picked a quality from the menu over a video player.
    public var media: MediaRequest?

    /// For a video/audio quality: what to download, and its file name.
    public var mediaSource: MediaSource? {
        guard let option = media?.option else { return nil }
        return MediaSource(url: url, formatSpec: option.formatSpec)
    }

    public var suggestedName: String? {
        guard let media, let option = media.option else { return request.filename }
        return MediaNaming.fileName(title: media.title ?? "video", ext: option.ext)
    }
}

public enum MediaNaming {
    /// A file name from a video title: no path separators or characters macOS dislikes.
    public static func fileName(title: String, ext: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let base = cleaned.isEmpty ? "video" : String(cleaned.prefix(180))
        return "\(base).\(ext)"
    }
}

/// Receives downloads from the browser extension (through mdm-native-host) and keeps the
/// rules file the host reads up to date.
@MainActor @Observable
public final class BrowserCapture {
    public private(set) var pending: [PendingCapture] = []
    /// Called for every new capture, so the UI can open its window.
    public var didReceive: ((PendingCapture) -> Void)?
    /// When the browser extension last talked to the app, and its version (the setup
    /// window uses this to confirm the extension is installed).
    public private(set) var extensionLastSeen: Date?
    public private(set) var extensionVersion: String?

    private let settings: AppSettings
    private let tools: VideoTools
    private let socketURL: URL
    private let rulesURL: URL
    private var server: UnixSocketServer?

    public init(settings: AppSettings, tools: VideoTools = VideoTools(),
                socketURL: URL = CaptureProtocol.socketURL, rulesURL: URL = CaptureProtocol.rulesURL) {
        self.settings = settings
        self.tools = tools
        self.socketURL = socketURL
        self.rulesURL = rulesURL
    }

    public func start() throws {
        publishRules()
        let server = UnixSocketServer(path: socketURL) { [weak self] message in
            await self?.handle(message) ?? .result(accepted: false, error: "App is closing")
        }
        try server.start()
        self.server = server
    }

    public func stop() {
        server?.stop()
        server = nil
    }

    /// Writes the current rules for the host; call after the capture settings change.
    public func publishRules() {
        try? settings.captureRules.save(to: rulesURL)
    }

    public func pendingCapture(id: UUID) -> PendingCapture? { pending.first { $0.id == id } }

    /// The user confirmed or cancelled the File Info window.
    public func finish(_ capture: PendingCapture) {
        pending.removeAll { $0.id == capture.id }
    }

    func handle(_ message: CaptureMessage) async -> CaptureMessage {
        switch message.type {
        case "listFormats":
            guard let media = message.media else { return .result(accepted: false, error: "Missing media") }
            return await formats(for: media)
        case "downloadMedia":
            return queueMedia(message.media)
        case "hello":
            extensionLastSeen = Date()
            extensionVersion = message.extensionVersion
            return .result(accepted: true)
        case "capture":
            break
        default:
            return .result(accepted: false, error: "Unknown message type")
        }
        extensionLastSeen = Date()
        guard let request = message.capture else { return .result(accepted: false, error: "Missing capture") }
        guard settings.captureEnabled else { return .result(accepted: false, error: "Capture is turned off") }
        guard let url = request.httpURL else { return .result(accepted: false, error: "Not an http(s) link") }
        let capture = PendingCapture(id: UUID(), request: request, url: url)
        pending.append(capture)
        didReceive?(capture)
        return .result(accepted: true)
    }

    // MARK: - Video and audio from pages

    /// The qualities for a page: first the page itself (YouTube and the other sites
    /// yt-dlp knows), then the stream links the extension saw in its traffic.
    func formats(for media: MediaRequest) async -> CaptureMessage {
        // The first video asked for downloads yt-dlp (once); the user doesn't have to.
        let ytDlp: URL
        do {
            ytDlp = try await ToolSetup.ytDlp(tools)
        } catch {
            return CaptureMessage(type: "formats", error: "Could not download yt-dlp (\(error)). Try Options ▸ Video.")
        }
        let extractor = MediaExtractor(ytDlp: ytDlp)
        var candidates: [String] = []
        // Each try can take seconds, so only the page and the latest few streams.
        for link in [media.pageUrl] + (media.mediaUrls ?? []).suffix(3) where !candidates.contains(link) {
            candidates.append(link)
        }
        var lastError = "No downloadable video found on this page"
        for link in candidates {
            guard let url = CaptureRequest(url: link).httpURL else { continue }
            // The page itself first without the browser's cookies: with a signed-in YouTube
            // session yt-dlp often gets no usable formats ("Requested format is not
            // available"). Cookies are still tried next, for private or age-restricted videos.
            // Stream links seen in the traffic usually need the page's cookies and Referer.
            let attempts: [[String: String]] = link == media.pageUrl ? [[:], media.headers] : [media.headers]
            for headers in attempts {
                do {
                    let info = try await extractor.info(for: url, headers: headers)
                    guard !info.options.isEmpty else { continue }
                    var reply = media
                    reply.title = info.title
                    reply.sourceUrl = link
                    reply.mediaUrls = nil
                    if headers.isEmpty {
                        // Download the same way the qualities were found.
                        reply.cookies = nil
                        reply.referrer = nil
                        reply.userAgent = nil
                    }
                    return CaptureMessage(type: "formats", media: reply, formats: info.options)
                } catch {
                    if case ToolError.failed(let message) = error { lastError = message }
                }
            }
        }
        return CaptureMessage(type: "formats", error: lastError)
    }

    /// The user picked a quality: confirm it in "Download File Info" like any capture.
    func queueMedia(_ media: MediaRequest?) -> CaptureMessage {
        guard let media, media.option != nil, let source = media.sourceUrl,
            let url = CaptureRequest(url: source).httpURL
        else { return .result(accepted: false, error: "Missing quality") }
        let request = CaptureRequest(url: source, size: media.option?.size, referrer: media.referrer,
                                     cookies: media.cookies, userAgent: media.userAgent, source: "media")
        let capture = PendingCapture(id: UUID(), request: request, url: url, media: media)
        pending.append(capture)
        didReceive?(capture)
        return .result(accepted: true)
    }
}
