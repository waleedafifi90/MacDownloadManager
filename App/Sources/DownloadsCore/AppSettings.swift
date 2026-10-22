import CaptureProtocol
import Foundation
import Observation

/// How the "Download progress" window starts (IDM's "Start view").
public enum ProgressStartView: String, CaseIterable, Sendable {
    /// Opens on screen.
    case normal
    /// Starts hidden in the menu bar; the download is listed there to bring it back.
    case minimized
    /// Not shown at all.
    case hidden

    public var title: String {
        switch self {
        case .normal: "Show normally sized"
        case .minimized: "Show minimized (in the menu bar)"
        case .hidden: "Don't show"
        }
    }
}

/// User preferences, stored in UserDefaults.
@MainActor @Observable
public final class AppSettings {
    private let defaults: UserDefaults

    public var maxConnections: Int { didSet { defaults.set(maxConnections, forKey: "maxConnections") } }
    public var speedLimitEnabled: Bool { didSet { defaults.set(speedLimitEnabled, forKey: "speedLimitEnabled") } }
    public var speedLimitKBps: Int { didSet { defaults.set(speedLimitKBps, forKey: "speedLimitKBps") } }
    public var progressStartView: ProgressStartView {
        didSet { defaults.set(progressStartView.rawValue, forKey: "progressStartView") }
    }
    public var showCompleteDialog: Bool { didSet { defaults.set(showCompleteDialog, forKey: "showCompleteDialog") } }
    public var defaultFolder: URL { didSet { defaults.set(defaultFolder.path, forKey: "defaultFolder") } }
    /// Folders remembered per category ("Remember this path for <category>").
    public var categoryFolders: [String: String] {
        didSet { defaults.set(categoryFolders, forKey: "categoryFolders") }
    }

    // Browser capture (Options ▸ Browsers).
    public var captureEnabled: Bool { didSet { defaults.set(captureEnabled, forKey: "captureEnabled") } }
    /// Space-separated, like IDM's "Automatically start downloading the following file types".
    public var captureExtensions: String { didSet { defaults.set(captureExtensions, forKey: "captureExtensions") } }
    /// Space- or newline-separated hosts whose downloads stay in the browser.
    public var captureExcludedHosts: String {
        didSet { defaults.set(captureExcludedHosts, forKey: "captureExcludedHosts") }
    }
    public var captureMinimumKB: Int { didSet { defaults.set(captureMinimumKB, forKey: "captureMinimumKB") } }

    // Updates.
    public var checkForUpdates: Bool { didSet { defaults.set(checkForUpdates, forKey: "checkForUpdates") } }
    public var lastUpdateCheck: Date? { didSet { defaults.set(lastUpdateCheck, forKey: "lastUpdateCheck") } }
    public var skippedUpdateVersion: String? {
        didSet { defaults.set(skippedUpdateVersion, forKey: "skippedUpdateVersion") }
    }
    /// Downloads paused to install an update, resumed when the new version starts.
    public var resumeAfterUpdate: [String] { didSet { defaults.set(resumeAfterUpdate, forKey: "resumeAfterUpdate") } }

    public var captureRules: CaptureRules {
        CaptureRules(enabled: captureEnabled,
                     extensions: captureExtensions.lowercased().split(whereSeparator: \.isWhitespace).map(String.init),
                     excludedHosts: captureExcludedHosts.lowercased().split(whereSeparator: \.isWhitespace).map(String.init),
                     minimumSize: Int64(max(0, captureMinimumKB)) * 1024)
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        maxConnections = defaults.object(forKey: "maxConnections") as? Int ?? 8
        speedLimitEnabled = defaults.bool(forKey: "speedLimitEnabled")
        speedLimitKBps = defaults.object(forKey: "speedLimitKBps") as? Int ?? 1024
        // Before 0.3 this was an on/off "showProgressWindow".
        progressStartView = defaults.string(forKey: "progressStartView").flatMap(ProgressStartView.init(rawValue:))
            ?? ((defaults.object(forKey: "showProgressWindow") as? Bool) == false ? .hidden : .normal)
        showCompleteDialog = defaults.object(forKey: "showCompleteDialog") as? Bool ?? true
        defaultFolder = defaults.string(forKey: "defaultFolder").map { URL(fileURLWithPath: $0) } ?? .downloadsDirectory
        categoryFolders = defaults.dictionary(forKey: "categoryFolders") as? [String: String] ?? [:]
        captureEnabled = defaults.object(forKey: "captureEnabled") as? Bool ?? true
        captureExtensions = defaults.string(forKey: "captureExtensions")
            ?? CaptureRules.defaultExtensions.joined(separator: " ")
        captureExcludedHosts = defaults.string(forKey: "captureExcludedHosts") ?? ""
        captureMinimumKB = defaults.object(forKey: "captureMinimumKB") as? Int ?? 0
        checkForUpdates = defaults.object(forKey: "checkForUpdates") as? Bool ?? true
        lastUpdateCheck = defaults.object(forKey: "lastUpdateCheck") as? Date
        skippedUpdateVersion = defaults.string(forKey: "skippedUpdateVersion")
        resumeAfterUpdate = defaults.stringArray(forKey: "resumeAfterUpdate") ?? []
    }

    /// Like IDM: each category saves into its own subfolder of the default folder
    /// (`~/Downloads/Video`, …) and General into the default folder itself, unless the
    /// user chose a folder for the category.
    public func folder(for category: DownloadCategory) -> URL {
        if let chosen = categoryFolders[category.name] { return URL(fileURLWithPath: chosen) }
        return category == .general ? defaultFolder : defaultFolder.appendingPathComponent(category.name, isDirectory: true)
    }

    /// The global limit in bytes per second, or nil when the limiter is off.
    public var globalLimit: Int64? { speedLimitEnabled ? Int64(speedLimitKBps) * 1024 : nil }
}
