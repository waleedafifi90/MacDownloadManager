import AppKit
import SwiftUI

/// Keeps the app running in the menu bar when its windows are closed, like IDM in the
/// system tray: the Dock icon shows only while a regular window is open, and opening the
/// app again (Applications, Spotlight, Dock, menu bar icon) brings back the main window
/// of the running app.
@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate {
    /// The instance SwiftUI creates as the app delegate.
    private(set) static var shared: AppLifecycle!

    override init() {
        super.init()
        Self.shared = self
    }

    /// Opens the main window scene; set by the main window once SwiftUI provides it.
    var openMainWindow: (() -> Void)?

    /// Started by the browser helper (`--background`) to take a download: stay in the
    /// menu bar without showing the main window.
    static let launchedInBackground = CommandLine.arguments.contains("--background")
    private var hideMainWindowAtLaunch = launchedInBackground

    /// Called when the main window first appears; closes it after a background launch.
    func mainWindowDidAppear() {
        guard hideMainWindowAtLaunch else { return }
        hideMainWindowAtLaunch = false
        DispatchQueue.main.async { NSApp.windows.first(where: Self.isMainWindow)?.close() }
    }

    // MARK: - App delegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) {
            [weak self] note in
            let closing = note.object as? NSWindow
            MainActor.assumeIsolated { self?.windowWillClose(closing) }
        }
    }

    /// Closing the last window never quits: downloads and queues keep going.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Opening the app while it runs (Finder, Spotlight, Dock) shows its main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }

    // MARK: - Showing and hiding

    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        if let main = NSApp.windows.first(where: Self.isMainWindow) {
            main.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
        NSApp.activate()
    }

    private func windowWillClose(_ closing: NSWindow?) {
        // The window is still listed while closing, so leave it out.
        let stillOpen = NSApp.windows.contains { $0 !== closing && $0.isVisible && Self.isRegularWindow($0) }
        if !stillOpen { NSApp.setActivationPolicy(.accessory) }
    }

    /// Windows that warrant a Dock icon: not the download panels or the menu bar item.
    static func isRegularWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.canBecomeMain && window.level == .normal
    }

    static func isMainWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix("main") == true
    }

    // MARK: - One running copy

    /// If another copy of the app is already running (e.g. one from Applications and one
    /// from a build folder), bring that one forward and return true; this copy should quit
    /// before it touches the browser connection or the download list.
    static func handOffToRunningCopy() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier,
            let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }),
            let url = other.bundleURL
        else { return false }
        // The browser helper only needs a running copy; don't bring up its window.
        if launchedInBackground { return true }
        // Opening a running app sends it a "reopen", which shows its main window.
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return true
    }
}
