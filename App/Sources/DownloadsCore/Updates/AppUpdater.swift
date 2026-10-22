import DownloadEngine
import Foundation
import Observation

public enum UpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case available(UpdateRelease)
    case downloading(Double)
    case installing
    case failed(String)
}

/// Checks GitHub for a newer release, then downloads, verifies and installs it, all
/// without a server of our own.
@MainActor @Observable
public final class AppUpdater {
    public static let defaultAPI = URL(string: "https://api.github.com/repos/waleedafifi90/MacDownloadManager/releases/latest")!

    public private(set) var state = UpdateState.idle
    /// Called when a check finds an update, so the UI can show it.
    public var didFindUpdate: ((UpdateRelease) -> Void)?

    private let settings: AppSettings
    private let api: URL
    private let current: AppVersion?
    private let publicKey: String
    private let session: URLSession

    public init(settings: AppSettings, api: URL = AppUpdater.defaultAPI, current: AppVersion? = .current,
                publicKey: String = UpdateSignature.publicKey, session: URLSession = .shared) {
        self.settings = settings
        self.api = api
        self.current = current
        self.publicKey = publicKey
        self.session = session
    }

    public var currentVersion: AppVersion? { current }

    // MARK: - Checking

    /// The automatic check: at most once a day, and only when turned on.
    public func checkIfDue(now: Date = Date()) async {
        guard settings.checkForUpdates else { return }
        if let last = settings.lastUpdateCheck, now.timeIntervalSince(last) < 24 * 3600 { return }
        await check(userInitiated: false, now: now)
    }

    /// "Check for Updates…" (userInitiated) also offers a version the user skipped.
    public func check(userInitiated: Bool, now: Date = Date()) async {
        state = .checking
        settings.lastUpdateCheck = now
        do {
            var request = URLRequest(url: api, timeoutInterval: 30)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 404 { throw UpdateError.noUsableRelease }
            let release = try UpdateRelease.parse(data)
            guard let current, current < release.version,
                userInitiated || settings.skippedUpdateVersion != release.version.description
            else {
                state = .upToDate
                return
            }
            state = .available(release)
            didFindUpdate?(release)
        } catch {
            state = userInitiated ? .failed(Self.describe(error)) : .idle
        }
    }

    public func skip(_ release: UpdateRelease) {
        settings.skippedUpdateVersion = release.version.description
        state = .idle
    }

    public func dismiss() { state = .idle }

    // MARK: - Downloading and verifying

    /// Downloads the DMG and its signature into `folder` and checks both; returns the DMG.
    public func download(_ release: UpdateRelease, to folder: URL) async throws -> URL {
        state = .downloading(0)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dmg = folder.appendingPathComponent(release.dmgURL.lastPathComponent)
        try? FileManager.default.removeItem(at: dmg)
        let total = Double(max(release.dmgSize, 1))
        try await SegmentedDownload(url: release.dmgURL, destination: dmg, session: session).start { progress in
            Task { @MainActor in self.state = .downloading(min(1, Double(progress.downloaded) / total)) }
        }
        let (signature, _) = try await session.data(from: release.signatureURL)
        try verify(dmg, sha256: release.dmgSHA256, signature: String(decoding: signature, as: UTF8.self))
        return dmg
    }

    /// The file must match the SHA-256 GitHub published and carry our release signature.
    public func verify(_ file: URL, sha256 expected: String, signature: String) throws {
        let actual = try UpdateSignature.sha256Hex(of: file)
        guard actual == expected.lowercased() else { throw UpdateError.checksumMismatch }
        guard UpdateSignature.isValid(signature, sha256: actual, publicKeyBase64: publicKey) else {
            throw UpdateError.badSignature
        }
    }

    // MARK: - Installing

    /// Whether the app can replace itself where it is (not inside a read-only DMG or an
    /// App Translocation copy, which macOS uses for apps opened straight from Downloads).
    public static func canReplace(_ app: URL) -> Bool {
        let parent = app.deletingLastPathComponent().path
        return app.pathExtension == "app" && !parent.contains("/AppTranslocation/")
            && FileManager.default.isWritableFile(atPath: parent)
    }

    /// Copies the app out of the DMG and swaps it in for `app`. The running app keeps
    /// working from the old files until it quits.
    public func install(dmg: URL, replacing app: URL, expecting version: AppVersion) async throws {
        state = .installing
        try await Self.replaceApp(app, withAppFrom: dmg, expecting: version)
    }

    nonisolated static func replaceApp(_ app: URL, withAppFrom dmg: URL, expecting version: AppVersion) async throws {
        let fm = FileManager.default
        let mount = fm.temporaryDirectory.appendingPathComponent("mdm-update-\(UUID().uuidString)")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: mount) }

        let attach = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), arguments: [
            "attach", "-nobrowse", "-readonly", "-noverify", "-mountpoint", mount.path, dmg.path,
        ])
        guard attach.status == 0 else { throw UpdateError.installFailed("Could not open the update: \(attach.stderr)") }
        defer {
            let detach = Process()
            detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", "-quiet", "-force", mount.path]
            try? detach.run()
            detach.waitUntilExit()
        }

        guard let newApp = try fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" })
        else { throw UpdateError.installFailed("The update contains no app") }
        let newVersion = Bundle(url: newApp)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard newVersion.flatMap(AppVersion.init) == version else {
            throw UpdateError.installFailed("The update is version \(newVersion ?? "?"), expected \(version)")
        }

        // Copy next to the app first (same volume), then swap in one step.
        let staged = app.deletingLastPathComponent().appendingPathComponent(".\(app.lastPathComponent).update")
        try? fm.removeItem(at: staged)
        try fm.copyItem(at: newApp, to: staged)
        do {
            _ = try fm.replaceItemAt(app, withItemAt: staged)
        } catch {
            try? fm.removeItem(at: staged)
            throw UpdateError.installFailed(error.localizedDescription)
        }
    }

    /// Opens `app` again once this process has quit (a second copy would otherwise hand
    /// off to this one and exit).
    public static func relaunchAfterQuit(_ app: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \"$PARENT\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$APP\""]
        process.environment = ["PARENT": "\(ProcessInfo.processInfo.processIdentifier)", "APP": app.path]
        try? process.run()
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case UpdateError.noUsableRelease: "No release to update to was found."
        case UpdateError.checksumMismatch: "The downloaded update is damaged (its checksum doesn't match)."
        case UpdateError.badSignature: "The update isn't signed by the developer, so it wasn't installed."
        case UpdateError.badVersion(let tag): "Unrecognized release version “\(tag)”."
        case UpdateError.notInstallable(let message), UpdateError.installFailed(let message): message
        case let error as URLError: error.localizedDescription
        default: "\(error)"
        }
    }

    public func fail(_ error: Error) { state = .failed(Self.describe(error)) }
}
