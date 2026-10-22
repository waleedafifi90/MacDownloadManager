import AppKit
import DownloadsCore
import SwiftUI

/// Walks the user through loading the extension: shown at first launch and from
/// Options ▸ Browsers. The app has already connected the browsers and copied the
/// extension folder (BrowserSetup.runAtLaunch); this is the part only the user can do.
struct BrowserSetupWindow: View {
    @Environment(BrowserCapture.self) private var capture
    @Environment(\.dismiss) private var dismiss
    @State private var integration = BrowserIntegration()
    @State private var browserName = ""
    @State private var copied = false

    private var browsers: [BrowserIntegration.Browser] {
        let installed = integration.installedBrowsers
        return installed.isEmpty ? [BrowserIntegration.browsers[0]] : installed
    }

    private var browser: BrowserIntegration.Browser {
        browsers.first { $0.name == browserName } ?? browsers[0]
    }

    private var folder: URL { integration.extensionFolder }

    /// The extension has said hello since the app started.
    private var connected: Bool { capture.extensionLastSeen != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if browsers.count > 1 {
                Picker("Browser", selection: $browserName) {
                    ForEach(browsers) { Text($0.name).tag($0.name) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            step(1, "Open the extensions page") {
                Button("Open \(browser.name) Extensions") { BrowserSetup.openExtensionsPage(browser) }
                    .buttonStyle(.borderedProminent)
            }
            step(2, "Turn on Developer mode (top right of that page)") {
                DeveloperModeIllustration()
            }
            step(3, "Drag this folder onto the extensions page") {
                VStack(alignment: .leading, spacing: 8) {
                    ExtensionTile(folder: folder)
                    HStack(spacing: 12) {
                        Text("Or click **Load unpacked** and choose it:").foregroundStyle(.secondary)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                        Button(copied ? "Copied" : "Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(folder.path, forType: .string)
                            copied = true
                        }
                    }
                    .font(.callout)
                }
            }
            Divider()
            HStack {
                status
                Spacer()
                Button(connected ? "Done" : "Later") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear {
            if browserName.isEmpty { browserName = browsers[0].name }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect your browser").font(.title2.bold())
                Text("Three steps, once. Then downloads and the \u{201C}Download this video\u{201D} button come to Mac Download Manager.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if connected {
            Label("Extension connected. You're all set.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for the extension…").foregroundStyle(.secondary)
            }
        }
    }

    private func step(_ number: Int, _ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content()
            }
        }
    }
}

/// A sketch of the corner of chrome://extensions with the switch to turn on.
private struct DeveloperModeIllustration: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("Extensions").font(.callout.bold())
            Spacer()
            Text("Developer mode").font(.callout)
            Capsule().fill(Color.accentColor)
                .frame(width: 30, height: 16)
                .overlay(alignment: .trailing) { Circle().fill(.white).padding(2) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(width: 320)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
    }
}

/// The extension folder, draggable onto the browser like a Finder item.
private struct ExtensionTile: View {
    let folder: URL

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(for: .folder)).resizable().frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.lastPathComponent).font(.callout.bold())
                Text("Drag me").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "hand.draw").foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(width: 320)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4])))
        .onDrag { NSItemProvider(contentsOf: folder) ?? NSItemProvider() }
    }
}
