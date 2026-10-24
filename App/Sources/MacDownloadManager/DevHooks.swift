import AppKit
import DownloadsCore

/// Development aids, active only when their environment variables are set
/// (use MDM_DEV_STORE as well, so test downloads stay out of the real list):
/// - MDM_DEV_ADD_URL + MDM_DEV_SAVE_DIR: start downloading these URLs (space-separated) at launch.
/// - MDM_DEV_DEFAULTS=<suite>: keep settings in that UserDefaults suite instead of the real ones.
/// - MDM_DEV_AUTO_START=<seconds>: "Download File Info" clicks Start Download by itself.
/// - MDM_DEV_RECORD_DIR (+ MDM_DEV_RECORD_FPS, default 5): save every titled window as
///   numbered PNG frames in <dir>/<title>/<milliseconds>.png, for demo videos.
/// - MDM_DEV_WINDOW_SIZE=<w>x<h>: resize the main window at launch (for recordings).
/// - MDM_DEV_OPEN_SCHEDULER: open the Scheduler window at launch.
/// - MDM_DEV_OPEN_ABOUT: open the About window at launch.
/// - MDM_DEV_OPEN_BROWSER_SETUP: open the browser extension setup window at launch.
/// - MDM_DEV_OPEN_PROPERTIES: open File Properties for the first download at launch.
/// - MDM_DEV_UPDATE_API=<url>: check this "latest release" JSON at launch instead of GitHub;
///   with MDM_DEV_AUTO_INSTALL_UPDATE also install what it finds (see MacDownloadManagerApp).
/// - MDM_DEV_CYCLE_MAIN=<file>: close the main window, then reopen the app the way macOS
///   does, and write what happened (Dock icon, windows) to <file>.
/// - MDM_DEV_SNAPSHOT_DIR: after MDM_DEV_SNAPSHOT_DELAY seconds (default 4), save a PNG of
///   every visible window of this app there. Only this app's own windows are drawn, so
///   no screen-recording permission is involved.
@MainActor
enum DevHooks {
    private static var didRun = false

    /// Runs once per launch, although the main window (which calls this) can be reopened.
    static func run(manager: DownloadManager) {
        guard !didRun else { return }
        didRun = true
        let env = ProcessInfo.processInfo.environment
        if let links = env["MDM_DEV_ADD_URL"], let dir = env["MDM_DEV_SAVE_DIR"] {
            for url in links.split(separator: " ").compactMap({ URL(string: String($0)) }) {
                manager.add(url: url, to: URL(fileURLWithPath: dir))
            }
        }
        if let size = env["MDM_DEV_WINDOW_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let window = NSApp.windows.first(where: AppLifecycle.isMainWindow) else { return }
                window.setContentSize(NSSize(width: size[0], height: size[1]))
                window.center()
            }
        }
        if let dir = env["MDM_DEV_RECORD_DIR"] {
            record(to: URL(fileURLWithPath: dir), fps: env["MDM_DEV_RECORD_FPS"].flatMap(Double.init) ?? 5)
        }
        if let report = env["MDM_DEV_CYCLE_MAIN"] { cycleMainWindow(report: URL(fileURLWithPath: report)) }
        if let dir = env["MDM_DEV_SNAPSHOT_DIR"] {
            let delay = env["MDM_DEV_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 4
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { snapshotWindows(to: URL(fileURLWithPath: dir)) }
        }
    }

    private static func cycleMainWindow(report: URL) {
        var lines: [String] = []
        func record(_ step: String) {
            let policy = NSApp.activationPolicy() == .regular ? "regular (in Dock)" : "accessory (not in Dock)"
            let main = NSApp.windows.filter { AppLifecycle.isMainWindow($0) && $0.isVisible }.count
            lines.append("\(step): \(policy), visible main windows: \(main)")
            try? lines.joined(separator: "\n").write(to: report, atomically: true, encoding: .utf8)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            record("before")
            NSApp.windows.first { AppLifecycle.isMainWindow($0) && $0.isVisible }?.performClose(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            record("after closing")
            // What macOS sends when the running app is opened again from Finder or Spotlight.
            _ = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { record("after reopening") }
    }

    private static var recording: NSObjectProtocol?

    private static func record(to dir: URL, fps: Double) {
        // Without this, App Nap slows the timer to about once a second in the background.
        recording = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                          reason: "Recording demo frames")
        let start = Date()
        Timer.scheduledTimer(withTimeInterval: 1 / fps, repeats: true) { _ in
            MainActor.assumeIsolated {
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                for window in NSApp.windows where window.isVisible && !window.title.isEmpty
                    && !String(describing: type(of: window)).contains("StatusBar") {
                    guard let view = window.contentView?.superview ?? window.contentView,
                        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
                    else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let folder = dir.appendingPathComponent(window.title.replacingOccurrences(of: "/", with: "-"))
                    let file = folder.appendingPathComponent(String(format: "%07d.png", ms))
                    // Encoding a Retina PNG is slow; keep it off the main thread.
                    nonisolated(unsafe) let frame = rep
                    DispatchQueue.global().async {
                        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        try? frame.representation(using: .png, properties: [:])?.write(to: file)
                    }
                }
            }
        }
    }

    private static func snapshotWindows(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (index, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView,
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let name = window.title.isEmpty ? "window-\(index)" : window.title
            let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(safe).png"))
            let behavior = window.collectionBehavior
            let info = """
                level: \(window.level == .floating ? "floating" : "normal")
                canJoinAllSpaces: \(behavior.contains(.canJoinAllSpaces))
                appActive: \(NSApp.isActive)
                fullScreenAuxiliary: \(behavior.contains(.fullScreenAuxiliary))
                isKey: \(window.isKeyWindow)
                """
            try? info.write(to: dir.appendingPathComponent("\(safe).txt"), atomically: true, encoding: .utf8)
        }
    }
}
