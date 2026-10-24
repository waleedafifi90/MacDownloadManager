import AppKit
import DownloadEngine
import DownloadsCore
import SwiftUI

/// IDM's two steps: "Enter new address to download", then "Download File Info"
/// (category, Save As, description, Start Download / Download Later).
struct AddDownloadFlow: View {
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var confirmedURL: URL?

    var body: some View {
        if let confirmedURL {
            FileInfoStep(url: confirmedURL, close: { dismiss() })
        } else {
            addressStep
        }
    }

    private var addressStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enter new address to download").font(.headline)
            TextField("Address", text: $link, prompt: Text("https://example.com/file.zip"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(confirm)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("OK", action: confirm).keyboardShortcut(.defaultAction).disabled(parsedURL == nil)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear(perform: pasteLinkFromClipboard)
    }

    private var parsedURL: URL? { Self.httpURL(link) }

    private func confirm() {
        if let parsedURL { confirmedURL = parsedURL }
    }

    private func pasteLinkFromClipboard() {
        if let text = NSPasteboard.general.string(forType: .string), let url = Self.httpURL(text) {
            link = url.absoluteString
        }
    }

    static func httpURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
            ["http", "https"].contains(url.scheme?.lowercased()), url.host != nil
        else { return nil }
        return url
    }
}

/// "Download File Info": used after typing an address and for downloads taken over
/// from the browser (with the browser's cookies, referrer and user agent as `headers`).
struct FileInfoStep: View {
    @Environment(DownloadManager.self) private var manager
    @Environment(QueueManager.self) private var queues
    /// "Download Later" puts the download in this queue.
    @State private var queueID = DownloadQueue.mainID
    let url: URL
    var headers: [String: String] = [:]
    /// The browser's file name, when it knows one.
    var suggestedName: String?
    /// A quality picked over a video player; its size is already known, so no probe.
    var media: MediaSource?
    var knownSize: Int64?
    let close: () -> Void

    @State private var info: RemoteFileInfo?
    @State private var probeError: String?
    @State private var category = DownloadCategory.general
    @State private var saveAs: URL?
    @State private var rememberPath = false
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: category.symbol)
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Download File Info").font(.headline)
                    if let info {
                        Text(info.size.map(Format.bytes) ?? "Size unknown")
                            + Text(info.resumable ? "  ·  Resumable" : "  ·  Cannot be resumed")
                    } else if let probeError {
                        Text(probeError).foregroundStyle(.red)
                    } else {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Connecting to the site…") }
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("URL").gridColumnAlignment(.trailing)
                    Text(url.absoluteString).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                GridRow {
                    Text("Category")
                    Picker("", selection: $category) {
                        ForEach(DownloadCategory.all) { Label($0.name, systemImage: $0.symbol).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    .onChange(of: category) { _, new in moveToCategoryFolder(new) }
                }
                GridRow {
                    Text("Save As")
                    HStack {
                        Text(saveAs?.path(percentEncoded: false) ?? "")
                            .lineLimit(1).truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(5)
                            .background(.background, in: .rect(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
                        Button("…", action: chooseSaveAs)
                    }
                }
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    Toggle("Remember this path for \"\(category.name)\" category", isOn: $rememberPath)
                }
                GridRow {
                    Text("Queue")
                    Picker("", selection: $queueID) {
                        ForEach(queues.queues) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    .help("Where “Download Later” puts this download")
                }
                GridRow {
                    Text("Description")
                    TextField("", text: $note, prompt: Text("Optional"))
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: close).keyboardShortcut(.cancelAction)
                Button("Download Later") { add(startNow: false) }.disabled(saveAs == nil)
                Button("Start Download") { add(startNow: true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saveAs == nil)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task {
            await probe()
            // Development aid for demo recordings (see DevHooks).
            if let delay = ProcessInfo.processInfo.environment["MDM_DEV_AUTO_START"].flatMap(Double.init) {
                try? await Task.sleep(for: .seconds(delay))
                add(startNow: true)
            }
        }
    }

    private func probe() async {
        // Propose a name from the URL right away; refine it when the server answers.
        apply(fileName: suggestedName ?? url.lastPathComponent)
        if media != nil {
            info = RemoteFileInfo(size: knownSize, resumable: true, suggestedFilename: nil, mimeType: nil)
            return
        }
        do {
            let info = try await SegmentedDownload.probe(url: url, headers: headers)
            self.info = info
            if suggestedName == nil, let name = info.suggestedFilename, name != saveAs?.lastPathComponent {
                apply(fileName: name)
            }
        } catch {
            probeError = "Could not get file info. You can still start the download."
        }
    }

    private func apply(fileName: String) {
        category = .forFile(named: fileName)
        saveAs = manager.proposedDestination(fileName: fileName, in: manager.settings.folder(for: category))
    }

    private func moveToCategoryFolder(_ category: DownloadCategory) {
        guard let name = saveAs?.lastPathComponent else { return }
        saveAs = manager.proposedDestination(fileName: name, in: manager.settings.folder(for: category))
    }

    private func chooseSaveAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = saveAs?.lastPathComponent ?? ""
        panel.directoryURL = saveAs?.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { saveAs = url }
    }

    private func add(startNow: Bool) {
        guard let saveAs else { return }
        if rememberPath {
            manager.settings.categoryFolders[category.name] = saveAs.deletingLastPathComponent().path
        }
        let item = manager.add(url: url, destination: saveAs, category: category, note: note, headers: headers,
                               media: media, startNow: startNow)
        if !startNow { queues.add(item, to: queueID) }
        close()
    }
}
