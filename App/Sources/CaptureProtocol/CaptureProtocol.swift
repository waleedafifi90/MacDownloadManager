import Foundation

/// Messages between the browser extension, the native messaging host and the app.
/// The extension speaks JSON over Native Messaging (4-byte length + JSON); the host
/// relays capture requests to the app as one JSON line per Unix-socket connection.
public enum CaptureProtocol {
    public static let hostName = "com.macdownloadmanager.host"

    /// The app's support folder; MDM_SUPPORT_DIR overrides it for tests and development.
    public static var supportDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["MDM_SUPPORT_DIR"] {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return URL.applicationSupportDirectory.appendingPathComponent("MacDownloadManager", isDirectory: true)
    }

    public static var socketURL: URL { supportDirectory.appendingPathComponent("capture.sock") }
    /// The app writes the current rules here so the host can answer without the app running.
    public static var rulesURL: URL { supportDirectory.appendingPathComponent("capture-rules.json") }
}

/// What the extension should capture. Owned by the app (Options ▸ Browsers).
public struct CaptureRules: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// Lowercase extensions; a trailing `*` matches a prefix (`r0*` matches `r00`).
    public var extensions: [String]
    /// Sites whose downloads are left to the browser (a host or a parent domain).
    public var excludedHosts: [String]
    /// Downloads smaller than this (when the size is known) are left to the browser.
    public var minimumSize: Int64

    public init(enabled: Bool, extensions: [String], excludedHosts: [String], minimumSize: Int64) {
        self.enabled = enabled
        self.extensions = extensions
        self.excludedHosts = excludedHosts
        self.minimumSize = minimumSize
    }

    /// IDM's default "Automatically start downloading the following file types" list,
    /// plus macOS installers.
    public static let defaultExtensions = """
        3gp 7z aac ace aif apk arj asf avi bin bz2 doc docx exe flv gz gzip img iso lzh m4a m4v mkv mov mp3 \
        mp4 mpa mpe mpeg mpg msi msu ogg ogv pdf plj pps ppt qt r0* r1* ra rar rm rmvb sea sit sitx tar \
        tif tiff wav webm wma wmv z zip dmg pkg xz
        """.split(separator: " ").map(String.init)

    public static let `default` = CaptureRules(enabled: true, extensions: defaultExtensions,
                                               excludedHosts: [], minimumSize: 0)

    public static func load(from url: URL = CaptureProtocol.rulesURL) -> CaptureRules {
        (try? JSONDecoder().decode(CaptureRules.self, from: Data(contentsOf: url))) ?? .default
    }

    public func save(to url: URL = CaptureProtocol.rulesURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

/// A download the extension wants the app to take over.
public struct CaptureRequest: Codable, Equatable, Sendable {
    public var url: String
    public var filename: String?
    public var size: Int64?
    public var mime: String?
    public var referrer: String?
    public var cookies: String?
    public var userAgent: String?
    /// "download" (taken from the browser's downloads) or "menu" (context menu).
    public var source: String?

    public init(url: String, filename: String? = nil, size: Int64? = nil, mime: String? = nil,
                referrer: String? = nil, cookies: String? = nil, userAgent: String? = nil, source: String? = nil) {
        self.url = url
        self.filename = filename
        self.size = size
        self.mime = mime
        self.referrer = referrer
        self.cookies = cookies
        self.userAgent = userAgent
        self.source = source
    }

    /// The URL, if it is an http(s) link; anything else is refused.
    public var httpURL: URL? {
        guard let url = URL(string: url), ["http", "https"].contains(url.scheme?.lowercased()), url.host != nil
        else { return nil }
        return url
    }

    /// Headers to send with the download so the server treats it like the browser's request.
    public var headers: [String: String] {
        var headers: [String: String] = [:]
        if let cookies, !cookies.isEmpty { headers["Cookie"] = cookies }
        if let referrer, !referrer.isEmpty { headers["Referer"] = referrer }
        if let userAgent, !userAgent.isEmpty { headers["User-Agent"] = userAgent }
        return headers
    }
}

/// One quality offered in the menu over a video player.
public struct MediaOption: Codable, Equatable, Hashable, Sendable {
    /// yt-dlp format selector, e.g. "299+140" (video + audio) or "140".
    public var formatSpec: String
    public var label: String
    public var height: Int?
    /// Container of the finished file: mp4, webm, m4a…
    public var ext: String
    public var size: Int64?
    public var audioOnly: Bool

    public init(formatSpec: String, label: String, height: Int?, ext: String, size: Int64?, audioOnly: Bool) {
        self.formatSpec = formatSpec
        self.label = label
        self.height = height
        self.ext = ext
        self.size = size
        self.audioOnly = audioOnly
    }
}

/// A page with a video or audio player, as seen by the extension.
public struct MediaRequest: Codable, Equatable, Sendable {
    public var pageUrl: String
    /// Stream links seen in the page's traffic (m3u8, mpd, mp4…), tried when the page
    /// itself isn't a site yt-dlp knows.
    public var mediaUrls: [String]?
    public var title: String?
    public var cookies: String?
    public var referrer: String?
    public var userAgent: String?
    /// The link the qualities were found for (in "formats" replies and "downloadMedia").
    public var sourceUrl: String?
    /// The chosen quality (in "downloadMedia").
    public var option: MediaOption?

    public init(pageUrl: String, mediaUrls: [String]? = nil, title: String? = nil, cookies: String? = nil,
                referrer: String? = nil, userAgent: String? = nil, sourceUrl: String? = nil, option: MediaOption? = nil) {
        self.pageUrl = pageUrl
        self.mediaUrls = mediaUrls
        self.title = title
        self.cookies = cookies
        self.referrer = referrer
        self.userAgent = userAgent
        self.sourceUrl = sourceUrl
        self.option = option
    }

    public var headers: [String: String] {
        CaptureRequest(url: pageUrl, referrer: referrer, cookies: cookies, userAgent: userAgent).headers
    }
}

/// Any message on the wire. `type` says which fields are used:
/// extension → host: "hello", "capture" (with `capture`)
/// host → extension: "rules" (with `rules`), "captureResult" (with `accepted`, `error`)
/// host → app: "capture"; app → host: "captureResult"
/// Video: extension → app "listFormats" (with `media`) → "formats" (with `media`, `formats`);
/// "downloadMedia" (with `media` incl. `option`) → "captureResult".
public struct CaptureMessage: Codable, Equatable, Sendable {
    public var type: String
    public var capture: CaptureRequest?
    public var rules: CaptureRules?
    public var accepted: Bool?
    public var error: String?
    public var media: MediaRequest?
    public var formats: [MediaOption]?

    public init(type: String, capture: CaptureRequest? = nil, rules: CaptureRules? = nil,
                accepted: Bool? = nil, error: String? = nil, media: MediaRequest? = nil, formats: [MediaOption]? = nil) {
        self.type = type
        self.capture = capture
        self.rules = rules
        self.accepted = accepted
        self.error = error
        self.media = media
        self.formats = formats
    }

    public static func result(accepted: Bool, error: String? = nil) -> CaptureMessage {
        CaptureMessage(type: "captureResult", accepted: accepted, error: error)
    }
}

/// Chrome's Native Messaging framing: a 32-bit length in native byte order, then UTF-8 JSON.
public enum NativeMessaging {
    /// Chrome refuses messages from a host larger than 1 MB.
    public static let maxOutgoing = 1024 * 1024
    /// Chrome may send up to 64 MB; we accept far less.
    public static let maxIncoming = 4 * 1024 * 1024

    public static func frame(_ json: Data) -> Data {
        var length = UInt32(json.count).littleEndian
        return Data(bytes: &length, count: 4) + json
    }

    /// Reads one message, or nil at end of input.
    public static func read(from handle: FileHandle) throws -> Data? {
        guard let header = try handle.read(upToCount: 4), header.count == 4 else { return nil }
        let length = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        guard length <= maxIncoming else { throw CaptureError.messageTooLarge }
        guard let body = try handle.read(upToCount: length), body.count == length else { return nil }
        return body
    }
}

public enum CaptureError: Error {
    case messageTooLarge
    case socketPathTooLong
    case connectFailed(Int32)
    case noReply
}
