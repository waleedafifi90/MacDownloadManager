import AppKit
import DownloadsCore
import SwiftUI

/// The menu bar icon (IDM's system tray icon): running downloads, bringing hidden progress
/// windows back, and opening the app.
struct MenuBarMenu: View {
    @Environment(DownloadManager.self) private var manager
    let panels: Panels

    private var running: [DownloadItem] { manager.items.filter { $0.status == .downloading } }

    var body: some View {
        if running.isEmpty {
            Text("No downloads running")
        } else {
            Section("Downloading") {
                ForEach(running) { item in
                    Button(title(item)) { panels.showProgress(item) }
                }
            }
        }
        Divider()
        Button("Restore All Download Windows") { panels.restoreAll() }
            .disabled(panels.minimized.isEmpty)
        if panels.minimized.isEmpty && !running.isEmpty {
            Text("No minimized downloads")
        }
        Button("Pause All") { manager.pauseAll() }
            .disabled(running.isEmpty)
        Divider()
        Button("Open Mac Download Manager") { AppLifecycle.shared.showMainWindow() }
        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func title(_ item: DownloadItem) -> String {
        let percent = item.fraction.map { "\(Int($0 * 100))%  " } ?? ""
        let speed = item.speed > 0 ? "  —  " + Format.speed(item.speed) : ""
        return percent + item.fileName + speed
    }
}

/// The icon itself: filled while something downloads, with the number of running downloads.
struct MenuBarLabel: View {
    @Environment(DownloadManager.self) private var manager

    var body: some View {
        let count = manager.items.filter { $0.status == .downloading }.count
        if count > 0 {
            Label("\(count)", systemImage: "arrow.down.circle.fill").labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "arrow.down.circle")
        }
    }
}
