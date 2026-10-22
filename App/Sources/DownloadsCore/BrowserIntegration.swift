import CaptureProtocol
import Foundation

/// Registers mdm-native-host with Chromium-based browsers (per user, no admin rights)
/// and keeps a copy of the extension where the user can load it.
public struct BrowserIntegration: Sendable {
    public struct Browser: Identifiable, Hashable, Sendable {
        public let name: String
        /// Under ~/Library/Application Support.
        public let profileRoot: String
        /// The app to open (open -a).
        public let appName: String
        /// Where its extensions are managed.
        public let extensionsPage: String
        public var id: String { name }
    }

    public static let browsers = [
        Browser(name: "Google Chrome", profileRoot: "Google/Chrome", appName: "Google Chrome",
                extensionsPage: "chrome://extensions"),
        Browser(name: "Google Chrome Beta", profileRoot: "Google/Chrome Beta", appName: "Google Chrome Beta",
                extensionsPage: "chrome://extensions"),
        Browser(name: "Microsoft Edge", profileRoot: "Microsoft Edge", appName: "Microsoft Edge",
                extensionsPage: "edge://extensions"),
        Browser(name: "Brave", profileRoot: "BraveSoftware/Brave-Browser", appName: "Brave Browser",
                extensionsPage: "brave://extensions"),
        Browser(name: "Chromium", profileRoot: "Chromium", appName: "Chromium", extensionsPage: "chrome://extensions"),
        Browser(name: "Vivaldi", profileRoot: "Vivaldi", appName: "Vivaldi", extensionsPage: "vivaldi://extensions"),
        Browser(name: "Arc", profileRoot: "Arc/User Data", appName: "Arc", extensionsPage: "chrome://extensions"),
    ]

    /// Derived from the public key in the extension's manifest (BrowserExtension/keys).
    public static let extensionID = "jncpnpgiplpngajifloafgmalaogafog"

    let applicationSupport: URL
    /// Where the extension is kept for "Load unpacked" (our own support folder).
    public let extensionFolder: URL

    public init(applicationSupport: URL = .applicationSupportDirectory,
                extensionFolder: URL = CaptureProtocol.supportDirectory.appendingPathComponent("ChromeExtension", isDirectory: true)) {
        self.applicationSupport = applicationSupport
        self.extensionFolder = extensionFolder
    }

    /// Browsers with a profile folder on this Mac.
    public var installedBrowsers: [Browser] {
        Self.browsers.filter { FileManager.default.fileExists(atPath: profileFolder($0).path) }
    }

    func profileFolder(_ browser: Browser) -> URL {
        applicationSupport.appendingPathComponent(browser.profileRoot, isDirectory: true)
    }

    public func manifestURL(for browser: Browser) -> URL {
        profileFolder(browser).appendingPathComponent("NativeMessagingHosts/\(CaptureProtocol.hostName).json")
    }

    /// Whether this browser's host manifest points at `hostPath`.
    public func isRegistered(_ browser: Browser, hostPath: URL) -> Bool {
        guard let data = try? Data(contentsOf: manifestURL(for: browser)),
            let manifest = try? JSONDecoder().decode(HostManifest.self, from: data)
        else { return false }
        return manifest.path == hostPath.path
    }

    /// Writes the host manifest for every installed browser; returns the ones registered.
    @discardableResult
    public func register(hostPath: URL) throws -> [Browser] {
        let manifest = HostManifest(
            name: CaptureProtocol.hostName,
            description: "Mac Download Manager browser integration",
            path: hostPath.path,
            type: "stdio",
            allowed_origins: ["chrome-extension://\(Self.extensionID)/"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(manifest)
        let browsers = installedBrowsers
        for browser in browsers {
            let url = manifestURL(for: browser)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        return browsers
    }

    public func unregister() {
        for browser in Self.browsers { try? FileManager.default.removeItem(at: manifestURL(for: browser)) }
    }

    /// Whether a profile of this browser has our extension (its preferences list it by ID).
    public func hasExtension(_ browser: Browser) -> Bool {
        let root = profileFolder(browser)
        let profiles = (try? FileManager.default.contentsOfDirectory(atPath: root.path))?
            .filter { $0 == "Default" || $0.hasPrefix("Profile ") } ?? []
        let id = Data(Self.extensionID.utf8)
        return profiles.contains { profile in
            ["Secure Preferences", "Preferences"].contains { file in
                let url = root.appendingPathComponent(profile).appendingPathComponent(file)
                return (try? Data(contentsOf: url, options: .mappedIfSafe))?.range(of: id) != nil
            }
        }
    }

    /// Copies the bundled extension to the stable folder for "Load unpacked"; returns it.
    /// The copy is swapped in whole, so a browser never reads a half-written extension.
    @discardableResult
    public func installExtension(from bundled: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: extensionFolder.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = extensionFolder.deletingLastPathComponent().appendingPathComponent(".ChromeExtension.new")
        try? fm.removeItem(at: staged)
        try fm.copyItem(at: bundled, to: staged)
        if fm.fileExists(atPath: extensionFolder.path) {
            _ = try fm.replaceItemAt(extensionFolder, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: extensionFolder)
        }
        return extensionFolder
    }

    /// The version in an extension folder's manifest.json.
    public static func extensionVersion(in folder: URL) -> String? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
            let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return manifest["version"] as? String
    }

    public struct SetupResult: Equatable, Sendable {
        public var registered: [String] = []
        public var extensionUpdated = false
    }

    /// Run at every launch: registers the native host with installed browsers where it's
    /// missing or points elsewhere (e.g. after the app moved to Applications), and keeps
    /// the extension folder at the bundled version. Does nothing that is already in place.
    @discardableResult
    public func autoSetup(hostPath: URL, bundledExtension: URL) throws -> SetupResult {
        var result = SetupResult()
        let missing = installedBrowsers.filter { !isRegistered($0, hostPath: hostPath) }
        if !missing.isEmpty {
            result.registered = try register(hostPath: hostPath).filter(missing.contains).map(\.name)
        }
        let bundled = Self.extensionVersion(in: bundledExtension)
        if bundled == nil || bundled != Self.extensionVersion(in: extensionFolder) {
            try installExtension(from: bundledExtension)
            result.extensionUpdated = true
        }
        return result
    }

    struct HostManifest: Codable {
        var name: String
        var description: String
        var path: String
        var type: String
        var allowed_origins: [String]
    }
}
