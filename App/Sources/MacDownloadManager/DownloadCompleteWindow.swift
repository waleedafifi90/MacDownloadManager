import AppKit
import DownloadsCore
import SwiftUI
import UniformTypeIdentifiers

/// IDM's "Download complete" dialog.
struct DownloadCompleteWindow: View {
    @Environment(DownloadManager.self) private var manager
    @Environment(\.closeWindow) private var closeWindow
    let item: DownloadItem

    var body: some View {
        @Bindable var settings = manager.settings
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.destination.path))
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Download complete").font(.headline)
                    Text("Downloaded \(Format.bytes(item.total ?? item.downloaded)) (\((item.total ?? item.downloaded).formatted()) bytes)")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Address").font(.caption).foregroundStyle(.secondary)
                Text(item.url.absoluteString).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("The file saved as").font(.caption).foregroundStyle(.secondary)
                Text(item.destination.path(percentEncoded: false)).lineLimit(2).textSelection(.enabled)
            }

            HStack {
                Button("Open") { NSWorkspace.shared.open(item.destination); closeWindow() }
                    .keyboardShortcut(.defaultAction)
                Button("Open with…", action: openWith)
                Button("Open folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([item.destination])
                    closeWindow()
                }
                Spacer()
                Button("Close") { closeWindow() }.keyboardShortcut(.cancelAction)
            }

            Toggle("Don't show this dialog again", isOn: Binding(
                get: { !settings.showCompleteDialog }, set: { settings.showCompleteDialog = !$0 }))
                .font(.callout)
        }
        .padding(18)
        .frame(width: 460)

    }

    private func openWith() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let app = panel.url else { return }
        NSWorkspace.shared.open([item.destination], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        closeWindow()
    }
}
