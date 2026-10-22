import CaptureProtocol
import Foundation

public struct MediaInfo: Equatable, Sendable {
    public var title: String
    public var pageURL: URL
    public var options: [MediaOption]
}

/// A chosen quality, resolved to the streams to download right now (stream links expire,
/// so this is done again whenever a download starts or resumes).
public struct ResolvedMedia: Sendable {
    public struct Part: Sendable {
        public var url: URL
        public var headers: [String: String]
        public var ext: String
        public var proto: String
        public var size: Int64?
    }
    public var title: String
    public var parts: [Part]
    public var ext: String
    /// Direct files our engine can fetch with several connections; otherwise (HLS/DASH
    /// fragments) yt-dlp downloads them itself.
    public var isDirect: Bool { parts.allSatisfy { $0.proto == "https" || $0.proto == "http" } }
}

/// Runs yt-dlp to list a page's qualities and to resolve a chosen one.
public struct MediaExtractor: Sendable {
    let ytDlp: URL

    public init(ytDlp: URL) { self.ytDlp = ytDlp }

    public func info(for url: URL, headers: [String: String] = [:]) async throws -> MediaInfo {
        // Listing must not fail just because yt-dlp's default quality isn't there.
        let json = try await run(["-J", "--no-playlist", "--no-warnings", "--ignore-no-formats-error"]
                                 + Self.headerArguments(headers) + [url.absoluteString])
        return try Self.parseInfo(json, fallbackURL: url)
    }

    public func resolve(_ url: URL, formatSpec: String, headers: [String: String] = [:]) async throws -> ResolvedMedia {
        let json = try await run(["-J", "--no-playlist", "--no-warnings", "-f", formatSpec]
                                 + Self.headerArguments(headers) + [url.absoluteString])
        return try Self.parseResolved(json)
    }

    static func headerArguments(_ headers: [String: String]) -> [String] {
        headers.sorted { $0.key < $1.key }.flatMap { ["--add-headers", "\($0.key):\($0.value)"] }
    }

    private func run(_ arguments: [String]) async throws -> Data {
        let result = try await ProcessRunner.run(ytDlp, arguments: arguments)
        guard result.status == 0 else {
            let message = result.stderr.split(separator: "\n").last { $0.contains("ERROR") } ?? "yt-dlp failed"
            throw ToolError.failed(String(message))
        }
        return result.stdout
    }

    // MARK: - Choosing the qualities to offer

    struct YtFormat: Decodable {
        var format_id: String
        var ext: String?
        var proto: String?
        var vcodec: String?
        var acodec: String?
        var height: Int?
        var fps: Double?
        var tbr: Double?
        var abr: Double?
        var filesize: Int64?
        var filesize_approx: Int64?
        var format_note: String?
        var url: String?
        var http_headers: [String: String]?

        enum CodingKeys: String, CodingKey {
            case format_id, ext, vcodec, acodec, height, fps, tbr, abr, filesize, filesize_approx, format_note, url,
                 http_headers
            case proto = "protocol"
        }

        var hasVideo: Bool { vcodec != nil && vcodec != "none" }
        /// yt-dlp reports nil acodec for some HLS formats that do carry audio.
        var hasAudio: Bool { acodec != "none" && (acodec != nil || !hasVideo) }
        var size: Int64? { filesize ?? filesize_approx }
        var isDirect: Bool { proto == "https" || proto == "http" }
        /// "-drc" are dynamic-range-compressed duplicates of the same audio.
        var isDRC: Bool { format_id.hasSuffix("-drc") || (format_note ?? "").contains("DRC") }
        var isStoryboard: Bool { ext == "mhtml" || proto == "mhtml" }
    }

    struct Info: Decodable {
        var title: String?
        var webpage_url: String?
        var formats: [YtFormat]?
        var requested_formats: [YtFormat]?
        // Single-format results (e.g. a direct file) carry the format at the top level.
        var url: String?
        var ext: String?
        var format_id: String?
        var http_headers: [String: String]?
        var filesize: Int64?
        var `protocol`: String?
    }

    static func parseInfo(_ json: Data, fallbackURL: URL) throws -> MediaInfo {
        let info = try JSONDecoder().decode(Info.self, from: json)
        let page = info.webpage_url.flatMap(URL.init(string:)) ?? fallbackURL
        let formats = (info.formats ?? []).filter { !$0.isStoryboard && !$0.isDRC }
        return MediaInfo(title: info.title ?? page.lastPathComponent, pageURL: page, options: options(from: formats))
    }

    /// One option per resolution, best first, then the best audio-only option.
    static func options(from formats: [YtFormat]) -> [MediaOption] {
        let audio = formats.filter { $0.hasAudio && !$0.hasVideo }
        let bestM4A = audio.filter { $0.ext == "m4a" && $0.isDirect }.max { ($0.abr ?? $0.tbr ?? 0) < ($1.abr ?? $1.tbr ?? 0) }
        let bestWebMAudio = audio.filter { $0.ext == "webm" && $0.isDirect }.max { ($0.abr ?? $0.tbr ?? 0) < ($1.abr ?? $1.tbr ?? 0) }
        let bestAudio = bestM4A ?? bestWebMAudio ?? audio.max { ($0.abr ?? $0.tbr ?? 0) < ($1.abr ?? $1.tbr ?? 0) }

        var options: [MediaOption] = []
        let videos = formats.filter(\.hasVideo)
        for height in Set(videos.compactMap(\.height)).sorted(by: >) {
            guard let video = videos.filter({ $0.height == height }).max(by: { rank($0) < rank($1) }) else { continue }
            let fps = video.fps.map { $0 > 30 ? "\(Int($0.rounded()))" : "" } ?? ""
            if video.hasAudio {
                options.append(option(spec: video.format_id, height: height, fps: fps, ext: video.ext ?? "mp4",
                                      size: video.size))
            } else {
                // Pair with audio in a matching container so ffmpeg can join them without re-encoding.
                let pair = video.ext == "webm" ? (bestWebMAudio ?? bestAudio) : (bestM4A ?? bestAudio)
                guard let pair else { continue }
                let ext = video.ext == "mp4" && pair.ext == "m4a" ? "mp4" : (video.ext == "webm" && pair.ext == "webm" ? "webm" : "mkv")
                let size = video.size.map { $0 + (pair.size ?? 0) }
                options.append(option(spec: "\(video.format_id)+\(pair.format_id)", height: height, fps: fps,
                                      ext: ext, size: size))
            }
        }
        if let bestAudio {
            let kbps = (bestAudio.abr ?? bestAudio.tbr).map { " · \(Int($0.rounded())) kbps" } ?? ""
            options.append(MediaOption(formatSpec: bestAudio.format_id,
                                       label: "Audio only · \((bestAudio.ext ?? "m4a").uppercased())\(kbps)",
                                       height: nil, ext: bestAudio.ext ?? "m4a", size: bestAudio.size, audioOnly: true))
        }
        return options
    }

    private static func option(spec: String, height: Int, fps: String, ext: String, size: Int64?) -> MediaOption {
        let sizeText = size.map { " · " + Format.bytes($0) } ?? ""
        return MediaOption(formatSpec: spec, label: "\(height)p\(fps) · \(ext.uppercased())\(sizeText)",
                           height: height, ext: ext, size: size, audioOnly: false)
    }

    /// Prefer direct files over fragments, then H.264 (plays everywhere), AV1, VP9; then bitrate.
    private static func rank(_ f: YtFormat) -> (Int, Int, Double) {
        let direct = f.isDirect ? 1 : 0
        let codec = f.vcodec ?? ""
        let codecScore = codec.hasPrefix("avc1") ? 3 : codec.hasPrefix("av01") ? 2 : codec.hasPrefix("vp") ? 1 : 0
        return (direct, codecScore, f.tbr ?? 0)
    }

    static func parseResolved(_ json: Data) throws -> ResolvedMedia {
        let info = try JSONDecoder().decode(Info.self, from: json)
        let formats = info.requested_formats ?? (info.url.map {
            [YtFormat(format_id: info.format_id ?? "", ext: info.ext, proto: info.protocol, vcodec: nil, acodec: nil,
                    height: nil, fps: nil, tbr: nil, abr: nil, filesize: info.filesize, filesize_approx: nil,
                    format_note: nil, url: $0, http_headers: info.http_headers)]
        } ?? [])
        let parts = formats.compactMap { f -> ResolvedMedia.Part? in
            guard let link = f.url, let url = URL(string: link) else { return nil }
            return ResolvedMedia.Part(url: url, headers: f.http_headers ?? [:], ext: f.ext ?? "bin",
                                      proto: f.proto ?? "https", size: f.size)
        }
        guard !parts.isEmpty else { throw ToolError.failed("No streams for this quality") }
        let ext: String
        if parts.count == 1 {
            ext = parts[0].ext
        } else if parts.allSatisfy({ ["mp4", "m4a"].contains($0.ext) }) {
            ext = "mp4"
        } else if parts.allSatisfy({ $0.ext == "webm" }) {
            ext = "webm"
        } else {
            ext = "mkv"
        }
        return ResolvedMedia(title: info.title ?? "video", parts: parts, ext: ext)
    }
}

/// Runs a command and collects its output without blocking the caller.
enum ProcessRunner {
    struct Result {
        var status: Int32
        var stdout: Data
        var stderr: String
    }

    static func run(_ executable: URL, arguments: [String]) async throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { _ in }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                // Read both pipes fully before waiting, so a large JSON can't fill the pipe and stall.
                DispatchQueue.global().async {
                    let stdout = out.fileHandleForReading.readDataToEndOfFile()
                    let stderr = err.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: Result(status: process.terminationStatus, stdout: stdout,
                                                          stderr: String(decoding: stderr, as: UTF8.self)))
                }
            }
        } onCancel: {
            process.terminate()
        }
    }
}
