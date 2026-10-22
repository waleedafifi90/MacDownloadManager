import CaptureProtocol
import Foundation

/// Registers mdm-native-host with Chromium-based browsers (per user, no admin rights)
/// and keeps a copy of the extension where the user can load it.
public struct BrowserIntegration: Sendable {
    public struct Browser: Identifiable, Hashable, Sendable {
        public let name: String
        /// Under ~/Library/Application Support.
        public let profileRoot: String
        public var id: String { name }
    }

    public static let browsers = [
        Browser(name: "Google Chrome", profileRoot: "Google/Chrome"),
        Browser(name: "Google Chrome Beta", profileRoot: "Google/Chrome Beta"),
        Browser(name: "Microsoft Edge", profileRoot: "Microsoft Edge"),
        Browser(name: "Brave", profileRoot: "BraveSoftware/Brave-Browser"),
        Browser(name: "Chromium", profileRoot: "Chromium"),
        Browser(name: "Vivaldi", profileRoot: "Vivaldi"),
        Browser(name: "Arc", profileRoot: "Arc/User Data"),
    ]

    /// Derived from the public key in the extension's manifest (BrowserExtension/keys).
    public static let extensionID = "jncpnpgiplpngajifloafgmalaogafog"

    let applicationSupport: URL

    public init(applicationSupport: URL = .applicationSupportDirectory) {
        self.applicationSupport = applicationSupport
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

    /// Copies the bundled extension to a stable folder for "Load unpacked"; returns it.
    public func installExtension(from bundled: URL) throws -> URL {
        let target = CaptureProtocol.supportDirectory.appendingPathComponent("ChromeExtension", isDirectory: true)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: bundled, to: target)
        return target
    }

    struct HostManifest: Codable {
        var name: String
        var description: String
        var path: String
        var type: String
        var allowed_origins: [String]
    }
}
