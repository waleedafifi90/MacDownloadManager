import CaptureProtocol
import CryptoKit
import DownloadEngine
import Foundation
import Security

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

    /// Downloads a static ffmpeg for this Mac's processor from ffmpeg.martin-riedl.de (no
    /// libraries needed), checks it against the SHA-256 published next to it, and installs
    /// it only if it carries a valid Developer ID signature from that build's author.
    public func installFfmpeg(session: URLSession = .shared) async throws {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "amd64"
        #endif
        let latest = URL(string: "https://ffmpeg.martin-riedl.de/redirect/latest/macos/\(arch)/release/ffmpeg.zip")!
        let (zip, response) = try await session.download(from: latest)
        defer { try? FileManager.default.removeItem(at: zip) }
        guard let final = response.url, (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ToolError.assetNotFound
        }
        // The checksum sits next to the file the link led to.
        let (checksum, _) = try await session.data(from: URL(string: final.absoluteString + ".sha256")!)
        guard let expected = String(decoding: checksum, as: UTF8.self).split(separator: " ").first,
            try sha256(of: zip) == expected.lowercased()
        else { throw ToolError.checksumMismatch }

        let unpacked = toolsDirectory.appendingPathComponent("ffmpeg.unpack")
        try? FileManager.default.removeItem(at: unpacked)
        defer { try? FileManager.default.removeItem(at: unpacked) }
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/ditto"),
                                                 arguments: ["-x", "-k", zip.path, unpacked.path])
        let binary = unpacked.appendingPathComponent("ffmpeg")
        guard result.status == 0, FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw ToolError.failed("ffmpeg: could not unpack the download")
        }
        guard Self.isSigned(binary, team: Self.ffmpegTeam) else { throw ToolError.failed("ffmpeg: signature not valid") }

        let target = toolsDirectory.appendingPathComponent("ffmpeg")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: binary, to: target)
    }

    /// The Apple Developer team that signs the ffmpeg builds (Martin Riedl).
    static let ffmpegTeam = "KU3N25YGLU"

    /// Whether `url` has a valid signature from a Developer ID certificate of `team`.
    static func isSigned(_ url: URL, team: String) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
            SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess
        else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess
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

/// Gets the video tools without the user having to: each is installed when first needed
/// (or at launch), and yt-dlp is refreshed weekly, since sites like YouTube often break
/// older versions.
@MainActor
public enum ToolSetup {
    private static var running: [String: Task<Void, Error>] = [:]
    static let refreshAfter: TimeInterval = 7 * 24 * 3600

    /// yt-dlp, downloading it first if it's missing. Callers at the same time share one download.
    public static func ytDlp(_ tools: VideoTools) async throws -> URL {
        if let url = tools.ytDlp { return url }
        try await install("yt-dlp") { _ = try await tools.installYtDlp() }
        guard let url = tools.ytDlp else { throw ToolError.missing("yt-dlp") }
        return url
    }

    /// ffmpeg, downloading it first if it's missing.
    public static func ffmpeg(_ tools: VideoTools) async throws -> URL {
        if let url = tools.ffmpeg { return url }
        try await install("ffmpeg") { try await tools.installFfmpeg() }
        guard let url = tools.ffmpeg else { throw ToolError.missing("ffmpeg") }
        return url
    }

    /// At launch: install what's missing, update our own yt-dlp when it's a week old.
    /// Errors are left for later (the first video retries).
    public static func refreshInBackground(_ tools: VideoTools) {
        let ours = tools.toolsDirectory.appendingPathComponent("yt-dlp")
        if tools.ytDlp == nil {
            Task { _ = try? await ytDlp(tools) }
        } else if tools.ytDlp == ours,
            let modified = try? ours.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
            Date().timeIntervalSince(modified) > refreshAfter {
            Task { try? await install("yt-dlp") { _ = try await tools.installYtDlp() } }
        }
        if tools.ffmpeg == nil { Task { _ = try? await ffmpeg(tools) } }
    }

    private static func install(_ name: String, _ work: @escaping @Sendable () async throws -> Void) async throws {
        let task = running[name] ?? Task { try await work() }
        running[name] = task
        defer { running[name] = nil }
        try await task.value
    }
}

public enum ToolError: Error, Equatable {
    case assetNotFound
    case checksumMismatch
    case missing(String)
    case failed(String)
}
