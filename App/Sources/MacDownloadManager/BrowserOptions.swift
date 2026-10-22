import AppKit
import DownloadsCore
import SwiftUI

/// Options ▸ Browsers: what to capture, and connecting the browsers to the app.
struct BrowserOptions: View {
    @Environment(DownloadManager.self) private var manager
    @Environment(BrowserCapture.self) private var capture
    @State private var integration = BrowserIntegration()
    @State private var message: String?
    @State private var refresh = 0

    /// mdm-native-host inside this app bundle (absent when run with `swift run`).
    private var hostPath: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/mdm-native-host")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    private var bundledExtension: URL? {
        Bundle.main.url(forResource: "ChromeExtension", withExtension: nil)
    }

    var body: some View {
        @Bindable var settings = manager.settings
        Form {
            Section("Capture") {
                Toggle("Take over downloads from the browser", isOn: $settings.captureEnabled)
                LabeledContent("File types") {
                    TextField("", text: $settings.captureExtensions, axis: .vertical)
                        .lineLimit(3...5)
                        .font(.system(.callout, design: .monospaced))
                }
                LabeledContent("Don't capture from") {
                    TextField("", text: $settings.captureExcludedHosts, prompt: Text("example.com other.org"))
                }
                LabeledContent("Minimum size") {
                    HStack {
                        TextField("", value: $settings.captureMinimumKB, format: .number).frame(width: 70)
                        Text("KB")
                    }
                }
            }
            .onChange(of: settings.captureRules) { capture.publishRules() }

            Section("Browsers") {
                let _ = refresh
                if integration.installedBrowsers.isEmpty {
                    Text("No Chromium-based browser found.").foregroundStyle(.secondary)
                }
                ForEach(integration.installedBrowsers) { browser in
                    LabeledContent(browser.name) {
                        if let hostPath, integration.isRegistered(browser, hostPath: hostPath) {
                            Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Text("Not connected").foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Button("Connect Browsers", action: install).disabled(hostPath == nil || bundledExtension == nil)
                    Button("Show Extension Folder", action: showExtension)
                    Button("Open Chrome Extensions") { openChromeExtensionsPage() }
                }
                if hostPath == nil {
                    Text("Run the app from its .app bundle (make-app.sh) to connect browsers.")
                        .font(.callout).foregroundStyle(.orange)
                }
                if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
                Text("""
                    After connecting: in Chrome open chrome://extensions, turn on Developer mode, \
                    choose "Load unpacked" and select the extension folder.
                    """)
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func install() {
        guard let hostPath, let bundledExtension else { return }
        do {
            let browsers = try integration.register(hostPath: hostPath)
            let folder = try integration.installExtension(from: bundledExtension)
            message = "Connected \(browsers.map(\.name).joined(separator: ", ")). Extension copied to \(folder.path)."
        } catch {
            message = "Could not connect: \(error.localizedDescription)"
        }
        refresh += 1
    }

    private func showExtension() {
        guard let bundledExtension else { return }
        let folder = (try? integration.installExtension(from: bundledExtension)) ?? bundledExtension
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    private func openChromeExtensionsPage() {
        // chrome:// pages can't be opened as URLs from other apps; ask Chrome directly.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Google Chrome", "chrome://extensions"]
        try? process.run()
    }
}
