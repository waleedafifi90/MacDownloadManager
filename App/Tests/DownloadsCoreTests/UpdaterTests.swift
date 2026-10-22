import CryptoKit
import DownloadEngineTestSupport
import Foundation
import Testing
@testable import DownloadsCore

struct AppVersionTests {
    @Test func comparesNumerically() {
        #expect(AppVersion("0.1.10")! > AppVersion("0.1.9")!)
        #expect(AppVersion("v0.2")! > AppVersion("0.1.11")!)
        #expect(AppVersion("1.0")! == AppVersion("1.0.0")!)
        #expect(AppVersion("not-a-version") == nil)
    }
}

/// GitHub's "latest release" JSON, trimmed to the fields the updater reads.
func releaseJSON(tag: String, dmg: URL, sig: URL, sha: String, size: Int, prerelease: Bool = false,
                 withSignature: Bool = true) -> Data {
    var assets: [[String: Any]] = [[
        "name": "MacDownloadManager-\(tag.dropFirst()).dmg", "browser_download_url": dmg.absoluteString,
        "digest": "sha256:\(sha)", "size": size,
    ]]
    if withSignature {
        assets.append(["name": "MacDownloadManager-\(tag.dropFirst()).dmg.sig", "browser_download_url": sig.absoluteString,
                       "digest": "sha256:00", "size": 90])
    }
    let json: [String: Any] = ["tag_name": tag, "body": "## What's new\n- Things", "draft": false,
                               "prerelease": prerelease, "html_url": "https://github.com/x/y/releases/tag/\(tag)",
                               "assets": assets]
    return try! JSONSerialization.data(withJSONObject: json)
}

struct UpdateReleaseTests {
    let dmg = URL(string: "https://example.com/a.dmg")!
    let sig = URL(string: "https://example.com/a.dmg.sig")!

    @Test func readsVersionDMGChecksumAndSignature() throws {
        let release = try UpdateRelease.parse(releaseJSON(tag: "v0.2.0", dmg: dmg, sig: sig, sha: "ABCD", size: 10))
        #expect(release.version == AppVersion("0.2.0")!)
        #expect(release.dmgSHA256 == "abcd")
        #expect(release.signatureURL == sig)
        #expect(release.notes.contains("What's new"))
    }

    @Test func refusesReleasesItCannotVerify() {
        #expect(throws: UpdateError.noUsableRelease) {
            try UpdateRelease.parse(releaseJSON(tag: "v0.2.0", dmg: dmg, sig: sig, sha: "ab", size: 1, withSignature: false))
        }
        #expect(throws: UpdateError.noUsableRelease) {
            try UpdateRelease.parse(releaseJSON(tag: "v0.2.0", dmg: dmg, sig: sig, sha: "ab", size: 1, prerelease: true))
        }
    }

    @Test func signatureMustMatchTheKeyAndTheFile() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let sha = String(repeating: "ab", count: 32)
        let signature = try UpdateSignature.sign(sha256: sha, with: key)
        #expect(UpdateSignature.isValid(signature, sha256: sha, publicKeyBase64: publicKey))
        #expect(!UpdateSignature.isValid(signature, sha256: String(repeating: "cd", count: 32), publicKeyBase64: publicKey))
        let otherKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        #expect(!UpdateSignature.isValid(signature, sha256: sha, publicKeyBase64: otherKey))
    }

    @Test func appShipsWithARealPublicKey() {
        #expect(Data(base64Encoded: UpdateSignature.publicKey)?.count == 32)
    }
}

@MainActor @Suite(.serialized) struct AppUpdaterTests {
    let key = Curve25519.Signing.PrivateKey()
    var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }

    func settings() -> AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: "mdm-tests-\(UUID().uuidString)")!)
    }

    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mdm-upd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func offersANewerVersionAndRespectsSkip() async throws {
        let api = try TestServer(body: releaseJSON(tag: "v0.3.0", dmg: URL(string: "https://e.com/a.dmg")!,
                                                   sig: URL(string: "https://e.com/a.dmg.sig")!, sha: "aa", size: 1))
        defer { api.stop() }
        let settings = settings()
        let updater = AppUpdater(settings: settings, api: api.url, current: AppVersion("0.1.1"), publicKey: publicKey)
        var found: [String] = []
        updater.didFindUpdate = { found.append($0.version.description) }

        await updater.check(userInitiated: false)
        #expect(found == ["0.3.0"])
        guard case .available(let release) = updater.state else { Issue.record("\(updater.state)"); return }

        updater.skip(release)
        await updater.check(userInitiated: false)
        #expect(updater.state == .upToDate, "a skipped version isn't offered automatically")
        await updater.check(userInitiated: true)
        #expect(updater.state == .available(release), "but Check for Updates… still shows it")

        let current = AppUpdater(settings: settings, api: api.url, current: AppVersion("0.3.0"), publicKey: publicKey)
        await current.check(userInitiated: true)
        #expect(current.state == .upToDate)
    }

    @Test func automaticCheckRunsAtMostDaily() async throws {
        let api = try TestServer(body: releaseJSON(tag: "v0.3.0", dmg: URL(string: "https://e.com/a.dmg")!,
                                                   sig: URL(string: "https://e.com/a.dmg.sig")!, sha: "aa", size: 1))
        defer { api.stop() }
        let settings = settings()
        let updater = AppUpdater(settings: settings, api: api.url, current: AppVersion("0.1.1"), publicKey: publicKey)
        let now = Date()
        await updater.checkIfDue(now: now)
        await updater.checkIfDue(now: now.addingTimeInterval(3600))
        await updater.checkIfDue(now: now.addingTimeInterval(25 * 3600))
        #expect(settings.lastUpdateCheck == now.addingTimeInterval(25 * 3600))
        settings.checkForUpdates = false
        await updater.checkIfDue(now: now.addingTimeInterval(60 * 3600))
        #expect(settings.lastUpdateCheck == now.addingTimeInterval(25 * 3600))
    }

    @Test func downloadsAndVerifiesTheChecksumAndSignature() async throws {
        let dmgBytes = Data((0..<300_000).map { UInt8($0 % 253) })
        let dmgServer = try TestServer(body: dmgBytes)
        defer { dmgServer.stop() }
        let dir = try folder()
        let sha = SHA256.hash(data: dmgBytes).map { String(format: "%02x", $0) }.joined()

        func release(sha: String, signature: String) throws -> (UpdateRelease, TestServer) {
            let sigServer = try TestServer(body: Data(signature.utf8))
            let release = UpdateRelease(version: AppVersion("0.3.0")!, notes: "", pageURL: dmgServer.url,
                                        dmgURL: dmgServer.url, dmgSHA256: sha, dmgSize: Int64(dmgBytes.count),
                                        signatureURL: sigServer.url)
            return (release, sigServer)
        }
        let updater = AppUpdater(settings: settings(), current: AppVersion("0.1.1"), publicKey: publicKey)

        let (good, goodSig) = try release(sha: sha, signature: try UpdateSignature.sign(sha256: sha, with: key))
        let file = try await updater.download(good, to: dir)
        #expect(try Data(contentsOf: file) == dmgBytes)
        goodSig.stop()

        let (tampered, sig2) = try release(sha: String(repeating: "0", count: 64),
                                           signature: try UpdateSignature.sign(sha256: sha, with: key))
        await #expect(throws: UpdateError.checksumMismatch) { _ = try await updater.download(tampered, to: dir) }
        sig2.stop()

        let stranger = Curve25519.Signing.PrivateKey()
        let (forged, sig3) = try release(sha: sha, signature: try UpdateSignature.sign(sha256: sha, with: stranger))
        await #expect(throws: UpdateError.badSignature) { _ = try await updater.download(forged, to: dir) }
        sig3.stop()
    }

    /// Builds a real DMG holding a minimal app bundle of the given version.
    func makeDMG(version: String, in dir: URL) throws -> URL {
        let staging = dir.appendingPathComponent("staging")
        let contents = staging.appendingPathComponent("MacDownloadManager.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleShortVersionString": version, "CFBundleIdentifier": "local.mdm.test"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data("new build".utf8).write(to: contents.appendingPathComponent("marker"))
        let dmg = dir.appendingPathComponent("update.dmg")
        let hdiutil = Process()
        hdiutil.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        hdiutil.arguments = ["create", "-quiet", "-volname", "Update", "-srcfolder", staging.path, "-format", "UDZO", "-ov", dmg.path]
        try hdiutil.run()
        hdiutil.waitUntilExit()
        try #require(hdiutil.terminationStatus == 0)
        return dmg
    }

    @Test func replacesTheInstalledAppWithTheOneInTheDMG() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dmg = try makeDMG(version: "0.3.0", in: dir)
        // The "installed" app, in a folder standing in for /Applications.
        let applications = dir.appendingPathComponent("Applications")
        let installed = applications.appendingPathComponent("MacDownloadManager.app")
        try FileManager.default.createDirectory(at: installed.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data("old build".utf8).write(to: installed.appendingPathComponent("Contents/marker"))
        #expect(AppUpdater.canReplace(installed))

        let updater = AppUpdater(settings: settings(), current: AppVersion("0.1.1"), publicKey: publicKey)
        try await updater.install(dmg: dmg, replacing: installed, expecting: AppVersion("0.3.0")!)

        #expect(try String(contentsOf: installed.appendingPathComponent("Contents/marker"), encoding: .utf8) == "new build")
        #expect(Bundle(url: installed)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == "0.3.0")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: applications.path)
        #expect(leftovers == ["MacDownloadManager.app"])

        // A DMG with another version than the release says is refused.
        await #expect(throws: UpdateError.self) {
            try await updater.install(dmg: dmg, replacing: installed, expecting: AppVersion("0.4.0")!)
        }
    }
}
