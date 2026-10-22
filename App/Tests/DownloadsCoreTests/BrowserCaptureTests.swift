import CaptureProtocol
import Foundation
import Testing
@testable import DownloadsCore

@MainActor @Suite(.serialized) struct BrowserCaptureTests {
    /// Short, so the socket path fits sockaddr_un (104 bytes).
    let dir: URL
    var socket: URL { dir.appendingPathComponent("capture.sock") }
    var rules: URL { dir.appendingPathComponent("capture-rules.json") }

    init() throws {
        dir = URL(fileURLWithPath: "/tmp/mdm-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func makeCapture(enabled: Bool = true) -> BrowserCapture {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "mdm-tests-\(UUID().uuidString)")!)
        settings.captureEnabled = enabled
        return BrowserCapture(settings: settings, socketURL: socket, rulesURL: rules)
    }

    /// Socket calls block, so they run off the main actor the server's handler needs.
    func send(_ message: CaptureMessage) async throws -> CaptureMessage {
        let socket = socket
        return try await Task.detached { try UnixSocketClient.exchange(message, socket: socket) }.value
    }

    @Test func acceptsACaptureAndQueuesIt() async throws {
        let capture = makeCapture()
        var received: [PendingCapture] = []
        capture.didReceive = { received.append($0) }
        try capture.start()
        defer { capture.stop() }

        let request = CaptureRequest(url: "https://example.com/a.zip", filename: "a.zip", size: 1234,
                                     referrer: "https://example.com/", cookies: "s=1", userAgent: "UA")
        let reply = try await send(CaptureMessage(type: "capture", capture: request))

        #expect(reply == .result(accepted: true))
        #expect(capture.pending.map(\.request) == [request])
        #expect(received.count == 1)
        #expect(request.headers == ["Cookie": "s=1", "Referer": "https://example.com/", "User-Agent": "UA"])
    }

    @Test func refusesWhenCaptureIsOffOrTheLinkIsNotHTTP() async throws {
        let off = makeCapture(enabled: false)
        try off.start()
        let reply = try await send(CaptureMessage(type: "capture", capture: CaptureRequest(url: "https://e.com/a.zip")))
        #expect(reply.accepted == false)
        off.stop()

        let on = makeCapture()
        try on.start()
        defer { on.stop() }
        let ftp = try await send(CaptureMessage(type: "capture", capture: CaptureRequest(url: "file:///etc/passwd")))
        #expect(ftp.accepted == false)
        #expect(on.pending.isEmpty)
    }

    @Test func publishesRulesForTheHost() throws {
        let capture = makeCapture()
        capture.publishRules()
        let saved = CaptureRules.load(from: rules)
        #expect(saved.enabled)
        #expect(saved.extensions.contains("zip"))
        #expect(saved.extensions.contains("dmg"))
    }

    // MARK: - The real host, spoken to the way Chrome does

    var hostExecutable: URL {
        // <package>/Tests/DownloadsCoreTests/this file → <package>/.build/debug/mdm-native-host
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/debug/mdm-native-host")
    }

    @Test func hostAnswersHelloWithRulesAndRelaysCaptures() async throws {
        let capture = makeCapture()
        try capture.start()  // also writes the rules file the host reads
        defer { capture.stop() }

        let host = Process()
        host.executableURL = hostExecutable
        host.arguments = ["chrome-extension://abcdefghijklmnopabcdefghijklmnop/"]
        host.environment = ["MDM_SUPPORT_DIR": dir.path]
        let input = Pipe(), output = Pipe()
        host.standardInput = input
        host.standardOutput = output
        try host.run()
        defer { host.terminate() }

        func exchange(_ message: CaptureMessage) async throws -> CaptureMessage? {
            let body = try JSONEncoder().encode(message)
            input.fileHandleForWriting.write(NativeMessaging.frame(body))
            let reader = output.fileHandleForReading
            let reply = try await Task.detached { try NativeMessaging.read(from: reader) }.value
            return try reply.map { try JSONDecoder().decode(CaptureMessage.self, from: $0) }
        }

        let hello = try await exchange(CaptureMessage(type: "hello"))
        #expect(hello?.type == "rules")
        #expect(hello?.rules?.extensions.contains("zip") == true)

        let request = CaptureRequest(url: "https://example.com/big.iso", filename: "big.iso", source: "download")
        let result = try await exchange(CaptureMessage(type: "capture", capture: request))
        #expect(result == .result(accepted: true))
        #expect(capture.pending.map(\.request) == [request])

        let bad = try await exchange(CaptureMessage(type: "capture", capture: CaptureRequest(url: "javascript:alert(1)")))
        #expect(bad?.accepted == false)

        // Chrome closing the pipe ends the host.
        try input.fileHandleForWriting.close()
        let ended = try await Task.detached { host.waitUntilExit(); return host.terminationStatus }.value
        #expect(ended == 0)
    }
}

@Suite struct BrowserIntegrationTests {
    @Test func registersTheHostOnlyForInstalledBrowsers() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("mdm-int-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        try FileManager.default.createDirectory(at: support.appendingPathComponent("Google/Chrome"),
                                                withIntermediateDirectories: true)
        let integration = BrowserIntegration(applicationSupport: support)
        let host = URL(fileURLWithPath: "/Applications/MacDownloadManager.app/Contents/MacOS/mdm-native-host")

        let registered = try integration.register(hostPath: host)

        #expect(registered.map(\.name) == ["Google Chrome"])
        let chrome = BrowserIntegration.browsers[0]
        #expect(integration.isRegistered(chrome, hostPath: host))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: integration.manifestURL(for: chrome))) as! [String: Any]
        #expect(json["name"] as? String == "com.macdownloadmanager.host")
        #expect(json["type"] as? String == "stdio")
        #expect(json["allowed_origins"] as? [String] == ["chrome-extension://jncpnpgiplpngajifloafgmalaogafog/"])
        // Edge is not installed in this fake profile, so nothing was written for it.
        #expect(!FileManager.default.fileExists(atPath: integration.manifestURL(for: BrowserIntegration.browsers[2]).path))

        integration.unregister()
        #expect(!integration.isRegistered(chrome, hostPath: host))
    }

    @Test func extensionIDMatchesTheManifestKey() throws {
        // Chrome derives the ID from the "key": the first 32 hex digits of the key's
        // SHA-256, written with the letters a–p.
        let manifestURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("BrowserExtension/chrome/manifest.json")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        let key = try #require(Data(base64Encoded: manifest["key"] as! String))
        let hash = SHA256Hex.digest(key).prefix(32)
        let id = String(hash.map { Character(UnicodeScalar(UInt8(97) + UInt8(String($0), radix: 16)!)) })
        #expect(id == BrowserIntegration.extensionID)
    }
}

import CryptoKit
enum SHA256Hex {
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
