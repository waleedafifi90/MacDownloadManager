import AppKit
import DownloadsCore
import SwiftUI

/// IDM's Options, with the tabs that exist so far.
struct OptionsView: View {
    @Environment(DownloadManager.self) private var manager

    var body: some View {
        TabView {
            ConnectionOptions().tabItem { Label("Connection", systemImage: "network") }
            SaveToOptions().tabItem { Label("Save to", systemImage: "folder") }
            DownloadsOptions().tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
            BrowserOptions().tabItem { Label("Browsers", systemImage: "globe") }
            VideoOptions().tabItem { Label("Video", systemImage: "film") }
            UpdateOptions().tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
        }
        .frame(width: 560, height: 460)
        .environment(manager)
    }
}

private struct ConnectionOptions: View {
    @Environment(DownloadManager.self) private var manager

    var body: some View {
        @Bindable var settings = manager.settings
        Form {
            Picker("Max. connections number", selection: $settings.maxConnections) {
                ForEach([1, 2, 4, 8, 16, 24, 32], id: \.self) { Text("\($0)").tag($0) }
            }
            Text("Applies to downloads started after the change. Some servers limit how many connections one computer may open.")
                .font(.callout).foregroundStyle(.secondary)
            Section("Speed Limiter") {
                Toggle("Turn on", isOn: Binding(
                    get: { settings.speedLimitEnabled },
                    set: { settings.speedLimitEnabled = $0; manager.applySpeedLimit() }))
                HStack {
                    Text("Maximum download speed:")
                    TextField("", value: Binding(
                        get: { settings.speedLimitKBps },
                        set: { settings.speedLimitKBps = max(1, $0); manager.applySpeedLimit() }), format: .number)
                        .frame(width: 80)
                    Text("KBytes/sec")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct SaveToOptions: View {
    @Environment(DownloadManager.self) private var manager

    var body: some View {
        Form {
            folderRow("Default folder", url: manager.settings.defaultFolder) { manager.settings.defaultFolder = $0 }
            Section("Per category") {
                ForEach(DownloadCategory.all) { category in
                    folderRow(category.name, url: manager.settings.folder(for: category)) {
                        manager.settings.categoryFolders[category.name] = $0.path
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func folderRow(_ title: String, url: URL, set: @escaping (URL) -> Void) -> some View {
        LabeledContent(title) {
            HStack {
                Text(url.path(percentEncoded: false)).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                Button("Change…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.directoryURL = url
                    if panel.runModal() == .OK, let chosen = panel.url { set(chosen) }
                }
            }
        }
    }
}

private struct DownloadsOptions: View {
    @Environment(DownloadManager.self) private var manager

    var body: some View {
        @Bindable var settings = manager.settings
        Form {
            Picker("Download progress dialog", selection: $settings.progressStartView) {
                ForEach(ProgressStartView.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Text("Hidden and minimized downloads keep running; bring their window back from the menu bar icon. Downloads started by a queue always start minimized.")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("Show download complete dialog", isOn: $settings.showCompleteDialog)
            Section {
                Toggle("Keep the Mac awake while downloading", isOn: $settings.keepAwakeWhileDownloading)
                    .onChange(of: settings.keepAwakeWhileDownloading) { manager.updateSleepPrevention() }
                Text("The screen still turns off and locks as usual, and downloads go on in the background. Closing a laptop's lid still puts it to sleep; downloads continue when it wakes.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct UpdateOptions: View {
    @Environment(DownloadManager.self) private var manager
    @Environment(AppUpdater.self) private var updater

    var body: some View {
        @Bindable var settings = manager.settings
        Form {
            LabeledContent("Version", value: updater.currentVersion?.description ?? "?")
            Toggle("Check for updates automatically", isOn: $settings.checkForUpdates)
            LabeledContent("Last checked",
                           value: settings.lastUpdateCheck?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
            HStack {
                Button("Check Now") { Task { await updater.check(userInitiated: true) } }
                    .disabled(updater.state == .checking)
                Text(status).foregroundStyle(.secondary)
            }
            Text("Updates come from the project's releases on GitHub. Each one is checked against the SHA-256 GitHub publishes and the developer's signature before it is installed.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var status: String {
        switch updater.state {
        case .checking: "Checking…"
        case .upToDate: "Up to date"
        case .available(let release): "Version \(release.version) is available"
        case .failed(let message): message
        case .downloading, .installing: "Updating…"
        case .idle: ""
        }
    }
}
