import AppKit
import DownloadsCore

/// Development aids, active only when their environment variables are set
/// (use MDM_DEV_STORE as well, so test downloads stay out of the real list):
/// - MDM_DEV_ADD_URL + MDM_DEV_SAVE_DIR: start downloading that URL at launch.
/// - MDM_DEV_OPEN_SCHEDULER: open the Scheduler window at launch.
/// - MDM_DEV_OPEN_PROPERTIES: open File Properties for the first download at launch.
/// - MDM_DEV_SNAPSHOT_DIR: after MDM_DEV_SNAPSHOT_DELAY seconds (default 4), save a PNG of
///   every visible window of this app there. Only this app's own windows are drawn, so
///   no screen-recording permission is involved.
@MainActor
enum DevHooks {
    static func run(manager: DownloadManager) {
        let env = ProcessInfo.processInfo.environment
        if let link = env["MDM_DEV_ADD_URL"], let url = URL(string: link), let dir = env["MDM_DEV_SAVE_DIR"] {
            manager.add(url: url, to: URL(fileURLWithPath: dir))
        }
        if let dir = env["MDM_DEV_SNAPSHOT_DIR"] {
            let delay = env["MDM_DEV_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 4
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { snapshotWindows(to: URL(fileURLWithPath: dir)) }
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
