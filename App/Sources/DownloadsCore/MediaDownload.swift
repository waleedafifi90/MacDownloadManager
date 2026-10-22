import DownloadEngine
import Foundation

/// What to fetch for a video/audio download: the page (or stream) link and the chosen quality.
public struct MediaSource: Codable, Equatable, Sendable {
    public var url: URL
    public var formatSpec: String

    public init(url: URL, formatSpec: String) {
        self.url = url
        self.formatSpec = formatSpec
    }
}

/// Downloads one video/audio quality. Each run asks yt-dlp for fresh stream links (they
/// expire). Direct streams go through our engine (several connections, resumable) and
/// separate video and audio are joined by ffmpeg without re-encoding; fragmented streams
/// (HLS/DASH segments) are left to yt-dlp.
struct MediaDownload: Sendable {
    let tools: VideoTools
    let source: MediaSource
    let destination: URL
    let headers: [String: String]
    let options: DownloadOptions

    /// Partial streams live here until they are joined.
    var workFolder: URL {
        destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).parts")
    }

    func run(onProgress: @escaping @Sendable (DownloadProgress) -> Void) async throws {
        let ytDlp = try await ToolSetup.ytDlp(tools)
        let resolved = try await MediaExtractor(ytDlp: ytDlp).resolve(source.url, formatSpec: source.formatSpec,
                                                                      headers: headers)
        if resolved.isDirect {
            try await downloadDirect(resolved, onProgress: onProgress)
        } else {
            try await downloadWithYtDlp(ytDlp, onProgress: onProgress)
        }
    }

    private func downloadDirect(_ media: ResolvedMedia, onProgress: @escaping @Sendable (DownloadProgress) -> Void) async throws {
        // Separate video and audio need ffmpeg to be joined; fetch it first if it's missing.
        if media.parts.count > 1 { _ = try await ToolSetup.ffmpeg(tools) }
        try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
        let combined = CombinedProgress(parts: media.parts.count, report: onProgress)
        let files = media.parts.indices.map { workFolder.appendingPathComponent("part\($0).\(media.parts[$0].ext)") }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, part) in media.parts.enumerated() {
                var options = options
                options.headers = headers.merging(part.headers) { _, stream in stream }
                // The stream link changes on every resolve; the format and part don't.
                options.resumeKey = "\(source.formatSpec)#\(index)"
                let download = SegmentedDownload(url: part.url, destination: files[index], options: options)
                group.addTask {
                    try await download.start { progress in Task { await combined.update(index, progress) } }
                }
            }
            try await group.waitForAll()
        }

        if files.count == 1 {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: files[0], to: destination)
        } else {
            try await merge(files)
        }
        try? FileManager.default.removeItem(at: workFolder)
    }

    /// Joins the video and audio streams into the destination without re-encoding.
    private func merge(_ files: [URL]) async throws {
        guard let ffmpeg = tools.ffmpeg else { throw ToolError.missing("ffmpeg") }
        let inputs = files.flatMap { ["-i", $0.path] }
        let maps = files.indices.flatMap { ["-map", "\($0)"] }
        let temp = workFolder.appendingPathComponent("merged.\(destination.pathExtension)")
        let result = try await ProcessRunner.run(ffmpeg, arguments: ["-y", "-loglevel", "error"] + inputs + maps
                                                 + ["-c", "copy", temp.path])
        guard result.status == 0 else { throw ToolError.failed("ffmpeg: \(result.stderr.suffix(300))") }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
    }

    /// Lets yt-dlp fetch fragmented streams; progress comes from its own report lines.
    private func downloadWithYtDlp(_ ytDlp: URL, onProgress: @escaping @Sendable (DownloadProgress) -> Void) async throws {
        var arguments = ["-f", source.formatSpec, "--no-playlist", "--no-warnings", "--newline",
                         "--concurrent-fragments", "\(max(1, options.maxConnections))",
                         "--progress-template", "download:MDM %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s",
                         "-o", destination.path]
        if let ffmpeg = tools.ffmpeg { arguments += ["--ffmpeg-location", ffmpeg.path] }
        if ["mp4", "webm", "mkv"].contains(destination.pathExtension) {
            arguments += ["--merge-output-format", destination.pathExtension]
        }
        arguments += MediaExtractor.headerArguments(headers) + [source.url.absoluteString]

        let process = Process()
        process.executableURL = ytDlp
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        out.fileHandleForReading.readabilityHandler = { handle in
            for line in String(decoding: handle.availableData, as: UTF8.self).split(separator: "\n") {
                let fields = line.split(separator: " ")
                guard fields.first == "MDM", fields.count == 4, let done = Int64(fields[1]) else { continue }
                let total = Int64(fields[2]) ?? Double(fields[3]).map { Int64($0) }
                onProgress(DownloadProgress(downloaded: done, total: total, activeConnections: 1, resumable: true))
            }
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { process in
                    out.fileHandleForReading.readabilityHandler = nil
                    let errors = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    if process.terminationStatus == 0 {
                        continuation.resume()
                    } else if process.terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        let message = errors.split(separator: "\n").last { $0.contains("ERROR") } ?? "yt-dlp failed"
                        continuation.resume(throwing: ToolError.failed(String(message)))
                    }
                }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            // yt-dlp keeps its .part files, so starting again resumes.
            process.terminate()
        }
    }
}

/// Adds up the progress of the streams of one video (e.g. video + audio).
private actor CombinedProgress {
    private var latest: [Int: DownloadProgress] = [:]
    private let parts: Int
    private let report: @Sendable (DownloadProgress) -> Void

    init(parts: Int, report: @escaping @Sendable (DownloadProgress) -> Void) {
        self.parts = parts
        self.report = report
    }

    func update(_ part: Int, _ progress: DownloadProgress) {
        latest[part] = progress
        let all = Array(latest.values)
        let totals = all.compactMap(\.total)
        report(DownloadProgress(
            downloaded: all.reduce(0) { $0 + $1.downloaded },
            total: totals.count == parts ? totals.reduce(0, +) : nil,
            activeConnections: all.reduce(0) { $0 + $1.activeConnections },
            resumable: true))
    }
}
