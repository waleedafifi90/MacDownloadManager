import CaptureProtocol
import Foundation
import Testing
@testable import DownloadsCore

struct MediaExtractorTests {
    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)"))
    }

    @Test func offersOneQualityPerResolutionPreferringH264() throws {
        let info = try MediaExtractor.parseInfo(try fixture("youtube-bbb.json"),
                                                fallbackURL: URL(string: "https://youtu.be/aqz-KE-bpKQ")!)
        #expect(info.title == "Big Buck Bunny 60fps 4K - Official Blender Foundation Short Film")
        #expect(info.options.map(\.formatSpec) == [
            "401+140",  // 2160p: only AV1/VP9 exist; AV1 MP4 wins over VP9 WebM
            "400+140",  // 1440p
            "299+140",  // 1080p60 H.264
            "298+140",  // 720p60 H.264
            "135+140", "134+140", "133+140", "160+140",
            "140",      // audio only, m4a 129 kbps (not the -drc copy)
        ])
        let top = try #require(info.options.first)
        #expect(top.label == "2160p60 · MP4 · " + Format.bytes(712_445_280 + 10_271_496))
        #expect(top.ext == "mp4")
        #expect(info.options.last?.audioOnly == true)
        #expect(info.options.last?.label == "Audio only · M4A · 129 kbps")
    }

    @Test func webmVideoIsPairedWithWebmAudio() {
        let formats = [
            MediaExtractor.YtFormat(format_id: "303", ext: "webm", proto: "https", vcodec: "vp9", acodec: "none",
                                    height: 1080, fps: 60, tbr: 2000, abr: nil, filesize: 100, filesize_approx: nil,
                                    format_note: nil, url: nil, http_headers: nil),
            MediaExtractor.YtFormat(format_id: "251", ext: "webm", proto: "https", vcodec: "none", acodec: "opus",
                                    height: nil, fps: nil, tbr: 128, abr: 128, filesize: 10, filesize_approx: nil,
                                    format_note: nil, url: nil, http_headers: nil),
        ]
        let options = MediaExtractor.options(from: formats)
        #expect(options.first?.formatSpec == "303+251")
        #expect(options.first?.ext == "webm")
        #expect(options.first?.size == 110)
    }

    @Test func resolvesTheChosenStreams() throws {
        let json = """
            {"title": "Clip", "requested_formats": [
              {"format_id": "299", "ext": "mp4", "protocol": "https", "url": "https://v.example/video", "filesize": 5,
               "http_headers": {"User-Agent": "UA"}},
              {"format_id": "140", "ext": "m4a", "protocol": "https", "url": "https://v.example/audio", "filesize": 2}
            ]}
            """
        let resolved = try MediaExtractor.parseResolved(Data(json.utf8))
        #expect(resolved.parts.map(\.url.absoluteString) == ["https://v.example/video", "https://v.example/audio"])
        #expect(resolved.parts[0].headers == ["User-Agent": "UA"])
        #expect(resolved.ext == "mp4")
        #expect(resolved.isDirect)
    }

    @Test func singleDirectFileResolves() throws {
        let json = #"{"title": "movie", "url": "https://cdn.example/movie.mp4", "ext": "mp4", "protocol": "https", "format_id": "0"}"#
        let resolved = try MediaExtractor.parseResolved(Data(json.utf8))
        #expect(resolved.parts.count == 1)
        #expect(resolved.ext == "mp4")
    }

    @Test func hlsIsNotDirect() throws {
        let json = #"{"title": "live", "url": "https://cdn.example/master.m3u8", "ext": "mp4", "protocol": "m3u8_native"}"#
        #expect(!(try MediaExtractor.parseResolved(Data(json.utf8))).isDirect)
    }

    @Test func headersBecomeYtDlpArguments() {
        #expect(MediaExtractor.headerArguments(["Referer": "https://a/", "Cookie": "x=1"])
                == ["--add-headers", "Cookie:x=1", "--add-headers", "Referer:https://a/"])
    }
}

/// A stand-in for yt-dlp: fails like a signed-in YouTube session does when given a
/// Cookie header, and otherwise prints the recorded Big Buck Bunny formats.
@MainActor struct BrowserCaptureMediaTests {
    @Test func listsQualitiesWithoutTheBrowserCookiesFirst() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mdm-fake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/youtube-bbb.json")
        let script = """
            #!/bin/sh
            case "$*" in *Cookie:*)
              echo "ERROR: [youtube] x: Requested format is not available." >&2; exit 1;;
            esac
            cat '\(fixture.path)'
            """
        let fake = dir.appendingPathComponent("yt-dlp")
        try script.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let settings = AppSettings(defaults: UserDefaults(suiteName: "mdm-\(UUID().uuidString)")!)
        let capture = BrowserCapture(settings: settings, tools: VideoTools(toolsDirectory: dir, searchPaths: []),
                                     socketURL: dir.appendingPathComponent("s"), rulesURL: dir.appendingPathComponent("r"))
        let request = MediaRequest(pageUrl: "https://www.youtube.com/watch?v=aqz-KE-bpKQ", title: "YouTube",
                                   cookies: "SID=signed-in", referrer: "https://www.youtube.com/", userAgent: "UA")

        let reply = await capture.formats(for: request)

        #expect(reply.error == nil)
        #expect(reply.formats?.first?.formatSpec == "401+140")
        // The download then also runs without the cookies, like the listing that worked.
        #expect(reply.media?.cookies == nil)
        #expect(reply.media?.sourceUrl == request.pageUrl)
    }
}
