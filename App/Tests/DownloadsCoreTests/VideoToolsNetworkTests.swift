import Foundation
import Testing
@testable import DownloadsCore

/// Talks to GitHub and video sites; run with MDM_NETWORK_TESTS=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MDM_NETWORK_TESTS"] == "1"))
struct VideoToolsNetworkTests {
    @Test func installsAVerifiedYtDlp() async throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MDM_TOOLS_DIR"]
                      ?? FileManager.default.temporaryDirectory.appendingPathComponent("mdm-tools-\(UUID().uuidString)").path)
        let tools = VideoTools(toolsDirectory: dir, searchPaths: [])
        let tag = try await tools.installYtDlp()
        #expect(!tag.isEmpty)
        let ytDlp = try #require(tools.ytDlp)
        let version = Process()
        version.executableURL = ytDlp
        version.arguments = ["--version"]
        let pipe = Pipe()
        version.standardOutput = pipe
        try version.run()
        version.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == tag)
    }
}

/// Downloads a small Creative Commons video from YouTube; run with MDM_NETWORK_TESTS=1.
@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["MDM_NETWORK_TESTS"] == "1"))
struct MediaDownloadNetworkTests {
    @Test func downloadsVideoAndAudioAndJoinsThem() async throws {
        let tools = VideoTools()
        try #require(tools.ytDlp != nil && tools.ffmpeg != nil)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mdm-media-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let manager = DownloadManager(storeURL: nil,
                                      settings: AppSettings(defaults: UserDefaults(suiteName: "mdm-\(UUID().uuidString)")!))
        let page = URL(string: "https://www.youtube.com/watch?v=aqz-KE-bpKQ")!  // Big Buck Bunny, CC BY 3.0

        let info = try await MediaExtractor(ytDlp: tools.ytDlp!).info(for: page)
        let smallest = try #require(info.options.last { !$0.audioOnly })
        #expect(smallest.formatSpec == "160+140")

        let item = manager.add(url: page, destination: folder.appendingPathComponent("bbb.\(smallest.ext)"),
                               category: .video, media: MediaSource(url: page, formatSpec: smallest.formatSpec))
        let deadline = Date().addingTimeInterval(180)
        while item.status == .downloading, Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
        #expect(item.status == .completed, "\(item.status)")

        // One file with both a video and an audio stream.
        let probe = Process()
        probe.executableURL = tools.ffmpeg!.deletingLastPathComponent().appendingPathComponent("ffprobe")
        probe.arguments = ["-v", "error", "-show_entries", "stream=codec_type", "-of", "csv=p=0", item.destination.path]
        let pipe = Pipe()
        probe.standardOutput = pipe
        try probe.run()
        probe.waitUntilExit()
        let streams = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").map(String.init)
        #expect(Set(streams) == ["video", "audio"])
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".bbb.mp4.parts").path))
    }
}
