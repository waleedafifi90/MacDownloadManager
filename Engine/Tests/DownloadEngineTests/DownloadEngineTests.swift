import Foundation
import Testing
@testable import DownloadEngine
import DownloadEngineTestSupport

@Suite struct SegmentPlannerTests {
    @Test func splitLargestGivesAwayTheSecondHalfOfTheRemainder() {
        var segments = [Segment(start: 0, current: 100, end: 999), Segment(start: 1000, current: 1900, end: 1999)]
        let new = SegmentPlanner.splitLargest(&segments, minSplitSize: 10)
        #expect(new == 2)
        #expect(segments[0] == Segment(start: 0, current: 100, end: 549))
        #expect(segments[2] == Segment(start: 550, end: 999))
    }

    @Test func splitLargestRefusesTinyRemainders() {
        var segments = [Segment(start: 0, current: 90, end: 99), Segment(start: 100, current: 150, end: 199)]
        #expect(SegmentPlanner.splitLargest(&segments, minSplitSize: 30) == nil)
    }

    @Test func firstSplitStaysNearTheStartOfALargeFile() {
        // 100 MB file, 50 KB received: the new connection starts at
        // 10 × (50 KB + 11,680) instead of jumping to the middle.
        var segments = [Segment(start: 0, current: 50_000, end: 99_999_999)]
        let new = SegmentPlanner.splitLargest(&segments, minSplitSize: 64 * 1024)
        #expect(new == 1)
        #expect(segments[1].start == 616_800)
        #expect(segments[0].end == 616_799)
    }

    @Test func firstSplitUsesTheMiddleWhenItIsCloser() {
        var segments = [Segment(start: 0, end: 199_999)]
        _ = SegmentPlanner.splitLargest(&segments, minSplitSize: 1024)
        #expect(segments[1].start == 100_000)
    }

    @Test func laterSplitsUseTheMiddle() {
        var segments = [Segment(start: 0, current: 50_000, end: 616_799), Segment(start: 616_800, end: 99_999_999)]
        _ = SegmentPlanner.splitLargest(&segments, minSplitSize: 64 * 1024)
        #expect(segments[2].start == 616_800 + (99_999_999 - 616_800 + 1) / 2)
    }
}

@Suite(.serialized) struct SegmentedDownloadTests {
    static func randomData(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mdm-test-\(UUID().uuidString).bin")
    }

    /// Writes a part file and resume state as if a download had been interrupted.
    func prepareResume(_ download: SegmentedDownload, body: Data, segments: [Segment],
                       disk: Data? = nil) async throws {
        var partial = Data(count: body.count)
        for s in segments where s.downloaded > 0 {
            partial.replaceSubrange(Int(s.start)..<Int(s.current), with: body[Int(s.start)..<Int(s.current)])
        }
        try (disk ?? partial).write(to: await download.partURL)
        try JSONEncoder().encode(ResumeState(url: await download.url, totalSize: Int64(body.count), segments: segments))
            .write(to: await download.stateURL)
    }

    @Test func downloadsWithParallelRanges() async throws {
        let body = Self.randomData(3_000_000)
        let server = try TestServer(body: body, chunkSize: 32 * 1024, chunkDelay: 0.002)
        defer { server.stop() }
        var options = DownloadOptions()
        options.maxConnections = 4

        let out = tempFile()
        defer { try? FileManager.default.removeItem(at: out) }
        try await SegmentedDownload(url: server.url, destination: out, options: options).start()

        #expect(try Data(contentsOf: out) == body)
        // Probe, the first connection, and at least three more from splitting.
        #expect(server.ranges.count >= 5)
        // The first split stays near the start: 10 × (0 + 11,680) when nothing arrived yet.
        #expect(server.ranges.contains { $0.hasPrefix("bytes=116800-") })
    }

    @Test func fallsBackToSingleStreamWithoutRangeSupport() async throws {
        let body = Self.randomData(500_000)
        let server = try TestServer(body: body, supportsRanges: false)
        defer { server.stop() }

        let out = tempFile()
        defer { try? FileManager.default.removeItem(at: out) }
        try await SegmentedDownload(url: server.url, destination: out).start()

        #expect(try Data(contentsOf: out) == body)
    }

    @Test func resumesAndVerifiesTheOverlapWithTheNextSegment() async throws {
        let body = Self.randomData(1_000_000)
        let server = try TestServer(body: body)
        defer { server.stop() }
        let out = tempFile()
        defer { try? FileManager.default.removeItem(at: out) }

        var options = DownloadOptions()
        options.maxConnections = 2
        options.minSplitSize = 1_000_000  // no splitting: keep the requests predictable
        let download = SegmentedDownload(url: server.url, destination: out, options: options)
        try await prepareResume(download, body: body, segments: [
            Segment(start: 0, current: 250_000, end: 499_999),
            Segment(start: 500_000, current: 750_000, end: 999_999),
        ])

        try await download.start()

        #expect(try Data(contentsOf: out) == body)
        // 64 extra bytes past the first segment, checked against the second one.
        #expect(server.ranges.contains("bytes=250000-500063"))
        #expect(server.ranges.contains("bytes=750000-999999"))
        #expect(!server.ranges.contains("bytes=0-0"))
    }

    @Test func pausesByCancellingAndResumesWhereItStopped() async throws {
        let body = Self.randomData(2_000_000)
        let server = try TestServer(body: body, chunkSize: 16 * 1024, chunkDelay: 0.01)
        defer { server.stop() }
        let out = tempFile()
        defer { try? FileManager.default.removeItem(at: out) }
        var options = DownloadOptions()
        options.maxConnections = 4

        let first = SegmentedDownload(url: server.url, destination: out, options: options)
        let task = Task { try await first.start() }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }

        // The saved state reflects everything written before the pause.
        let state = try JSONDecoder().decode(ResumeState.self, from: Data(contentsOf: await first.stateURL))
        let saved = state.segments.reduce(0) { $0 + $1.downloaded }
        #expect(saved > 0 && saved < Int64(body.count))
        let requestsBeforeResume = server.ranges.count

        try await SegmentedDownload(url: server.url, destination: out, options: options).start()
        #expect(try Data(contentsOf: out) == body)
        // Resuming continues from the saved state: no new probe.
        #expect(!server.ranges.dropFirst(requestsBeforeResume).contains("bytes=0-0"))
    }

    @Test func speedLimiterCapsTheCombinedRate() async throws {
        let body = Self.randomData(600_000)
        let server = try TestServer(body: body)
        defer { server.stop() }
        let out = tempFile()
        defer { try? FileManager.default.removeItem(at: out) }

        var options = DownloadOptions()
        options.maxConnections = 4
        options.speedLimiters = [SpeedLimiter(bytesPerSecond: 300_000)]
        let started = Date()
        try await SegmentedDownload(url: server.url, destination: out, options: options).start()
        let elapsed = Date().timeIntervalSince(started)

        #expect(try Data(contentsOf: out) == body)
        // 600 KB at 300 KB/s takes about 2s (minus the quarter-second burst); unlimited,
        // the local server takes well under 0.5s. The upper bound only guards against hangs.
        #expect(elapsed > 1.6 && elapsed < 8, "took \(elapsed)s")
    }

    @Test func slowLimitDoesNotTripTheRequestTimeout() async throws {
        // While data waits for the limiter the request is suspended; it must not be
        // treated as an idle connection.
        let body = Self.randomData(1_200_000)
        let server = try TestServer(body: body)
        defer { server.stop() }
        let out = tempFile()
        defer { try? FileManager.default.removeItem(at: out) }

        var options = DownloadOptions()
        options.maxConnections = 2
        options.maxRetries = 0
        options.requestTimeout = 2
        options.speedLimiters = [SpeedLimiter(bytesPerSecond: 250_000)]
        try await SegmentedDownload(url: server.url, destination: out, options: options).start()
        #expect(try Data(contentsOf: out) == body)
    }

    @Test func probeReportsSizeNameAndResumeSupport() async throws {
        let server = try TestServer(body: Self.randomData(12_345))
        defer { server.stop() }
        let info = try await SegmentedDownload.probe(url: server.url)
        #expect(info == RemoteFileInfo(size: 12_345, resumable: true, suggestedFilename: "file.bin", mimeType: nil))

        let plain = try TestServer(body: Self.randomData(500), supportsRanges: false)
        defer { plain.stop() }
        let plainInfo = try await SegmentedDownload.probe(url: plain.url)
        #expect(plainInfo.size == 500)
        #expect(!plainInfo.resumable)
    }

    @Test func filenameFromContentDisposition() {
        #expect(Filename.fromContentDisposition("attachment; filename=\"report.pdf\"") == "report.pdf")
        #expect(Filename.fromContentDisposition("attachment; filename=a.zip; filename*=UTF-8''%D9%85%D9%84%D9%81.zip")
                == "ملف.zip")
        #expect(Filename.fromContentDisposition("inline") == nil)
        #expect(Filename.sanitized("../../etc/passwd") == "passwd")
        #expect(Filename.sanitized("a:b.txt") == "a-b.txt")
    }

    @Test func resumeKeyAcceptsANewLinkToTheSameFile() async throws {
        let body = Self.randomData(1_000_000)
        let first = try TestServer(body: body, chunkSize: 16 * 1024, chunkDelay: 0.01)
        let out = tempFile()
        defer { try? FileManager.default.removeItem(at: out) }
        var options = DownloadOptions()
        options.maxConnections = 2
        options.resumeKey = "video-299"

        let task = Task { try await SegmentedDownload(url: first.url, destination: out, options: options).start() }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        _ = try? await task.value
        first.stop()

        // Same bytes behind a different link (as with a fresh, re-signed stream URL).
        let second = try TestServer(body: body)
        defer { second.stop() }
        try await SegmentedDownload(url: second.url, destination: out, options: options).start()
        #expect(try Data(contentsOf: out) == body)
        #expect(!second.ranges.contains("bytes=0-0"), "resumed instead of starting over")
    }

    @Test func failsWhenTheOverlapDoesNotMatch() async throws {
        let body = Self.randomData(200_000)
        let server = try TestServer(body: body)
        defer { server.stop() }
        let out = tempFile()
        defer { try? FileManager.default.removeItem(at: out) }

        var options = DownloadOptions()
        options.maxConnections = 1
        let download = SegmentedDownload(url: server.url, destination: out, options: options)
        // The second segment's bytes on disk are not what the server has.
        var disk = Data(count: body.count)
        disk.replaceSubrange(100_000..<150_000, with: Self.randomData(50_000))
        try await prepareResume(download, body: body, segments: [
            Segment(start: 0, end: 99_999),
            Segment(start: 100_000, current: 150_000, end: 199_999),
        ], disk: disk)

        await #expect(throws: DownloadError.dataMismatch(offset: 100_000)) { try await download.start() }
    }

    @Test func retriesWhenTheServerDropsConnections() async throws {
        let body = Self.randomData(600_000)
        let server = try TestServer(body: body, chunkSize: 16 * 1024,
                                    faults: [.drop(afterBytes: 100_000), .drop(afterBytes: 50_000)])
        defer { server.stop() }
        let out = tempFile()
        defer { try? FileManager.default.removeItem(at: out) }

        var options = DownloadOptions()
        options.maxConnections = 1
        try await SegmentedDownload(url: server.url, destination: out, options: options).start()

        #expect(try Data(contentsOf: out) == body)
        #expect(server.ranges == ["bytes=0-0", "bytes=0-599999", "bytes=100000-599999", "bytes=150000-599999"])
    }

    @Test func givesUpAfterTooManyRetries() async throws {
        let body = Self.randomData(100_000)
        let server = try TestServer(body: body, faults: Array(repeating: .drop(afterBytes: 0), count: 10))
        defer { server.stop() }
        let out = tempFile()
        defer { try? FileManager.default.removeItem(at: out) }

        var options = DownloadOptions()
        options.maxConnections = 1
        options.maxRetries = 2
        let error = await #expect(throws: DownloadError.self) {
            try await SegmentedDownload(url: server.url, destination: out, options: options).start()
        }
        guard case .tooManyRetries = error else {
            Issue.record("Expected tooManyRetries, got \(String(describing: error))")
            return
        }
        // URLSession may itself retry a dropped request once, so the server can see
        // more than our three attempts, but it must stop.
        #expect(server.ranges.count <= 1 + 3 * 3)
    }

    @Test func alternativeConnectionTakesOverAStalledSegment() async throws {
        let body = Self.randomData(300_000)
        let server = try TestServer(body: body, faults: [.stall(afterBytes: 40_000)])
        defer { server.stop() }
        let out = tempFile()
        defer { try? FileManager.default.removeItem(at: out) }

        var options = DownloadOptions()
        options.maxConnections = 2
        options.minSplitSize = 1_000_000  // no splitting: the second connection can only race
        options.stallThreshold = 0.5
        options.requestTimeout = 30
        let started = Date()
        try await SegmentedDownload(url: server.url, destination: out, options: options).start()

        #expect(try Data(contentsOf: out) == body)
        #expect(server.ranges.contains("bytes=40000-299999"))
        // Far quicker than waiting for the 30s timeout of the stalled request.
        #expect(Date().timeIntervalSince(started) < 10)
    }
}
