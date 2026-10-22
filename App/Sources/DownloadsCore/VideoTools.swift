import CaptureProtocol
import CryptoKit
import DownloadEngine
import Foundation

/// Locates (and installs) the external tools used for video sites: yt-dlp finds the
/// streams and their qualities, ffmpeg joins separate video and audio streams.
public struct VideoTools: Sendable {
    public let toolsDirectory: URL
    /// Extra places to look, e.g. Homebrew.
    let searchPaths: [URL]

    public init(toolsDirectory: URL = CaptureProtocol.supportDirectory.appendingPathComponent("Tools"),
                searchPaths: [URL] = [URL(fileURLWithPath: "/opt/homebrew/bin"), URL(fileURLWithPath: "/usr/local/bin")]) {
        self.toolsDirectory = toolsDirectory
        self.searchPaths = searchPaths
    }

    public var ytDlp: URL? { find("yt-dlp") }
    public var ffmpeg: URL? { find("ffmpeg") }

    private func find(_ name: String) -> URL? {
        ([toolsDirectory] + searchPaths)
            .map { $0.appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Downloads the latest yt-dlp for macOS from its official GitHub releases into the
    /// tools folder, checking it against the SHA-256 GitHub publishes for the asset.
    /// Returns the release tag.
    @discardableResult
    public func installYtDlp(session: URLSession = .shared) async throws -> String {
        let api = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!
        var request = URLRequest(url: api)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await session.data(for: request)
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard let asset = release.assets.first(where: { $0.name == "yt-dlp_macos" }),
            let digest = asset.digest, digest.hasPrefix("sha256:")
        else { throw ToolError.assetNotFound }

        try FileManager.default.createDirectory(at: toolsDirectory, withIntermediateDirectories: true)
        let downloaded = toolsDirectory.appendingPathComponent("yt-dlp.download")
        try? FileManager.default.removeItem(at: downloaded)
        try await SegmentedDownload(url: asset.browser_download_url, destination: downloaded, session: session).start()

        let actual = try sha256(of: downloaded)
        guard actual == digest.dropFirst("sha256:".count).lowercased() else {
            try? FileManager.default.removeItem(at: downloaded)
            throw ToolError.checksumMismatch
        }
        let target = toolsDirectory.appendingPathComponent("yt-dlp")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: downloaded, to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        return release.tag_name
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
            let digest: String?
        }
        let tag_name: String
        let assets: [Asset]
    }
}

/// Gets yt-dlp without the user having to: installed when it's first needed (or at
/// launch), and refreshed weekly, since sites like YouTube often break older versions.
@MainActor
public enum YtDlpSetup {
    private static var running: Task<Void, Error>?
    static let refreshAfter: TimeInterval = 7 * 24 * 3600

    /// yt-dlp, downloading it first if it's missing. Callers at the same time share one download.
    public static func ensure(_ tools: VideoTools) async throws -> URL {
        if let url = tools.ytDlp { return url }
        try await install(tools)
        guard let url = tools.ytDlp else { throw ToolError.missing("yt-dlp") }
        return url
    }

    /// At launch: install if missing, update our own copy when it's a week old. Errors are
    /// left for later (the first video retries).
    public static func refreshInBackground(_ tools: VideoTools) {
        let ours = tools.toolsDirectory.appendingPathComponent("yt-dlp")
        if tools.ytDlp != nil {
            guard tools.ytDlp == ours,
                let modified = try? ours.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                Date().timeIntervalSince(modified) > refreshAfter
            else { return }
        }
        Task { try? await install(tools) }
    }

    private static func install(_ tools: VideoTools) async throws {
        let task = running ?? Task { _ = try await tools.installYtDlp() }
        running = task
        defer { running = nil }
        try await task.value
    }
}

public enum ToolError: Error, Equatable {
    case assetNotFound
    case checksumMismatch
    case missing(String)
    case failed(String)
}
