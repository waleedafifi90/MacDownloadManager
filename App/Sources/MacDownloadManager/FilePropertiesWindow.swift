import AppKit
import DownloadsCore
import SwiftUI
import UniformTypeIdentifiers

/// IDM's "File Properties": what a download is, where it came from and where it went.
struct FilePropertiesWindow: View {
    @Environment(DownloadManager.self) private var manager
    @Environment(\.closeWindow) private var closeWindow
    let item: DownloadItem
    @State private var note = ""

    private var fileExists: Bool { FileManager.default.fileExists(atPath: item.destination.path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: fileExists
                      ? NSWorkspace.shared.icon(forFile: item.destination.path)
                      : NSWorkspace.shared.icon(for: UTType(filenameExtension: item.destination.pathExtension) ?? .data))
                    .resizable()
                    .frame(width: 48, height: 48)
                Text(item.fileName)
                    .font(.headline)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                row("Type:", typeText)
                row("Status:", statusText)
                row("Size:", sizeText)
                GridRow {
                    label("Save To:")
                    HStack {
                        Text(item.destination.deletingLastPathComponent().path(percentEncoded: false))
                            .lineLimit(1).truncationMode(.head).textSelection(.enabled)
                        Spacer()
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [fileExists ? item.destination : item.destination.deletingLastPathComponent()])
                        }
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    label("Address:")
                    HStack {
                        Text(item.url.absoluteString).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(item.url.absoluteString, forType: .string)
                        }
                    }
                }
                GridRow {
                    label("Description:")
                    TextField("", text: $note, prompt: Text("Add a description"), axis: .vertical)
                        .lineLimit(1...3)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveNote)
                }
                row("Referer:", item.referrer ?? "Unknown")
                row("Category:", item.category.name)
                Divider().gridCellUnsizedAxes(.horizontal)
                row("Added:", item.addedAt.formatted(date: .abbreviated, time: .shortened))
                row("Last try:", item.lastTry.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                row("Result:", resultText)
            }

            HStack {
                Button("Open") { NSWorkspace.shared.open(item.destination) }
                    .disabled(item.status != .completed || !fileExists)
                Spacer()
                Button("OK") {
                    saveNote()
                    closeWindow()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 520)
        .windowTitle("File Properties")
        .onAppear { note = item.note }
        .onDisappear(perform: saveNote)
    }

    private func saveNote() {
        if note != item.note { manager.setNote(note, for: item) }
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            label(title)
            Text(value).textSelection(.enabled)
        }
    }

    private var typeText: String {
        UTType(filenameExtension: item.destination.pathExtension)?.localizedDescription
            ?? (item.destination.pathExtension.isEmpty ? "File" : item.destination.pathExtension.uppercased() + " file")
    }

    private var statusText: String {
        switch item.status {
        case .completed: return "Complete"
        case .downloading: return item.fraction.map { "Downloading — \($0.formatted(.percent.precision(.fractionLength(1))))" } ?? "Downloading"
        case .paused: return item.fraction.map { "Paused at \($0.formatted(.percent.precision(.fractionLength(1))))" } ?? "Paused"
        case .failed: return "Error"
        }
    }

    private var sizeText: String {
        guard let total = item.total else { return "Unknown" }
        return "\(Format.bytes(total)) (\(total.formatted()) bytes)"
    }

    private var resultText: String {
        switch item.status {
        case .completed: return fileExists ? "Downloaded successfully" : "Downloaded, but the file has been moved or deleted"
        case .failed(let message): return message
        case .paused: return "Stopped"
        case .downloading: return "In progress"
        }
    }
}
