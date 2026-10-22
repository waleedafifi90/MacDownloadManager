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

/// Installs the signed static ffmpeg; run with MDM_NETWORK_TESTS=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MDM_NETWORK_TESTS"] == "1"))
struct FfmpegNetworkTests {
    @Test func installsAVerifiedFfmpeg() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mdm-ff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let tools = VideoTools(toolsDirectory: dir, searchPaths: [])
        try await tools.installFfmpeg()
        let ffmpeg = try #require(tools.ffmpeg)
        #expect(VideoTools.isSigned(ffmpeg, team: VideoTools.ffmpegTeam))
        let result = try await ProcessRunner.run(ffmpeg, arguments: ["-version"])
        #expect(result.status == 0)
    }

    @Test func refusesABinaryFromAnotherSigner() {
        // Signed by Apple, not by the ffmpeg builder.
        #expect(!VideoTools.isSigned(URL(fileURLWithPath: "/bin/ls"), team: VideoTools.ffmpegTeam))
    }
}

/// Downloads a small Creative Commons video from YouTube; run with MDM_NETWORK_TESTS=1.
@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["MDM_NETWORK_TESTS"] == "1"))
struct MediaDownloadNetworkTests {
    @Test func downloadsVideoAndAudioAndJoinsThem() async throws {
        let tools = VideoTools()
        _ = try await ToolSetup.ytDlp(tools)
        _ = try await ToolSetup.ffmpeg(tools)
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

        // One file with both a video and an audio stream (ffmpeg lists them for -i).
        let probe = try await ProcessRunner.run(tools.ffmpeg!, arguments: ["-hide_banner", "-i", item.destination.path])
        #expect(probe.stderr.contains("Video:") && probe.stderr.contains("Audio:"))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".bbb.mp4.parts").path))
    }
}
