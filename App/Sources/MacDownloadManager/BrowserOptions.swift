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
    @Environment(\.openWindow) private var openWindow

    private var hostPath: URL? { BrowserSetup.hostPath }
    private var bundledExtension: URL? { BrowserSetup.bundledExtension }

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
                    Button("Set Up Extension…") { openWindow(id: "browserSetup") }
                    Button("Connect Browsers", action: install).disabled(hostPath == nil || bundledExtension == nil)
                    Button("Show Extension Folder", action: showExtension)
                    Button("Open Chrome Extensions") { openChromeExtensionsPage() }
                }
                if hostPath == nil {
                    Text("Run the app from its .app bundle (make-app.sh) to connect browsers.")
                        .font(.callout).foregroundStyle(.orange)
                }
                if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
                Text("The app connects the browsers by itself when it starts. Set Up Extension shows how to add the extension.")
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
        BrowserSetup.openExtensionsPage(integration.installedBrowsers.first ?? BrowserIntegration.browsers[0])
    }
}
