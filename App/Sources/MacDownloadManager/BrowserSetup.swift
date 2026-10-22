import AppKit
import DownloadsCore

/// What the app bundle brings for the browsers, and setting it up without the user's help.
@MainActor
enum BrowserSetup {
    /// mdm-native-host inside this app bundle (absent when run with `swift run`).
    static var hostPath: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/mdm-native-host")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static var bundledExtension: URL? {
        Bundle.main.url(forResource: "ChromeExtension", withExtension: nil)
    }

    /// At every launch: connects the browsers found (again, if the app moved) and keeps the
    /// extension folder at this version, so an extension already loaded picks up updates.
    /// Development runs (MDM_SUPPORT_DIR) leave the real browser folders alone.
    static func runAtLaunch() {
        guard ProcessInfo.processInfo.environment["MDM_SUPPORT_DIR"] == nil,
            let hostPath, let bundledExtension
        else { return }
        do {
            try BrowserIntegration().autoSetup(hostPath: hostPath, bundledExtension: bundledExtension)
        } catch {
            print("Browser setup failed: \(error)")
        }
    }

    /// At first launch, unless a browser already has the extension (an earlier version
    /// was set up by hand). MDM_DEV_OPEN_BROWSER_SETUP shows it in development runs.
    static func shouldShowWelcome(settings: AppSettings) -> Bool {
        let env = ProcessInfo.processInfo.environment
        if env["MDM_DEV_OPEN_BROWSER_SETUP"] != nil { return true }
        guard env["MDM_SUPPORT_DIR"] == nil, hostPath != nil, !settings.browserSetupShown else { return false }
        settings.browserSetupShown = true
        let integration = BrowserIntegration()
        return !integration.installedBrowsers.contains(where: integration.hasExtension)
    }

    /// Opens the browser's extensions page. chrome:// pages can't be opened as links from
    /// another app, so the browser is asked directly.
    static func openExtensionsPage(_ browser: BrowserIntegration.Browser) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", browser.appName, browser.extensionsPage]
        try? process.run()
    }
}
