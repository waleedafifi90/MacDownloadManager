import AppKit
import DownloadEngine
import DownloadsCore
import SwiftUI

/// IDM's "Download progress" window: status tabs, the overall bar, Pause/Cancel and,
/// under "details", the start positions and progress of every connection.
struct DownloadProgressWindow: View {
    @Environment(DownloadManager.self) private var manager
    @Environment(\.closeWindow) private var closeWindow
    let item: DownloadItem
    @State private var showDetails = true

    private var title: String {
        let percent = item.fraction.map { "\(Int($0 * 100))% " } ?? ""
        return percent + item.fileName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TabView {
                StatusTab(item: item).tabItem { Text("Download status") }
                SpeedLimiterTab(item: item).tabItem { Text("Speed Limiter") }
                CompletionTab(item: item).tabItem { Text("Options on completion") }
            }
            .frame(height: 190)

            ProgressView(value: item.fraction ?? 0)
                .tint(item.status == .paused ? .secondary : .accentColor)

            HStack {
                Button(showDetails ? "<< Hide details" : "Show details >>") {
                    withAnimation { showDetails.toggle() }
                }
                Spacer()
                switch item.status {
                case .downloading:
                    Button("Pause") { manager.pause(item) }.frame(minWidth: 70)
                case .paused, .failed:
                    Button("Resume") { manager.resume(item) }.frame(minWidth: 70)
                case .completed:
                    EmptyView()
                }
                if item.status == .downloading {
                    // Like IDM's "Minimize to system tray": the download keeps going and the
                    // window comes back from the menu bar icon.
                    Button("Hide") { closeWindow() }
                        .frame(minWidth: 70)
                        .help("Keep downloading in the background. Bring this window back from the menu bar icon.")
                }
                Button(item.status == .completed ? "Close" : "Cancel") {
                    // Like IDM, Cancel stops the download; it stays in the list.
                    manager.pause(item)
                    closeWindow()
                }
                .frame(minWidth: 70)
            }

            if showDetails {
                ConnectionsDetails(item: item)
            }
        }
        .padding(14)
        .frame(width: 560)
        .windowTitle(title)
        .onChange(of: item.status) { _, new in
            // Like IDM, the progress window closes when the download finishes.
            if new == .completed { closeWindow() }
        }
    }
}

private struct StatusTab: View {
    let item: DownloadItem

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text(item.url.absoluteString).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled).gridCellColumns(2)
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            row("Status", statusText)
            row("File size", item.total.map(Format.bytes) ?? "(unknown)")
            row("Downloaded", downloadedText)
            row("Transfer rate", Format.speed(item.speed))
            row("Time left", Format.duration(item.timeRemaining))
            row("Resume capability", item.resumable.map { $0 ? "Yes" : "No" } ?? "(unknown)")
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var statusText: String {
        switch item.status {
        case .downloading: item.downloaded == 0 ? "Connecting…" : "Receiving data…"
        case .paused: "Paused"
        case .completed: "Complete"
        case .failed(let message): "Error: \(message)"
        }
    }

    private var downloadedText: String {
        let bytes = Format.bytes(item.downloaded)
        guard let fraction = item.fraction else { return bytes }
        return "\(bytes) (\(fraction.formatted(.percent.precision(.fractionLength(2)))))"
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.leading)
            Text(value).monospacedDigit()
        }
    }
}

private struct SpeedLimiterTab: View {
    @Bindable var item: DownloadItem
    @State private var kbps = 512

    var body: some View {
        Form {
            LabeledContent("Transfer rate", value: Format.speed(item.speed))
            Toggle("Use Speed Limiter", isOn: Binding(
                get: { item.speedLimitKBps != nil },
                set: { item.speedLimitKBps = $0 ? kbps : nil }))
            HStack {
                Text("Maximum download speed:")
                TextField("", value: $kbps, format: .number)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                    .onSubmit { if item.speedLimitKBps != nil { item.speedLimitKBps = max(1, kbps) } }
                Text("KBytes/sec")
            }
            .disabled(item.speedLimitKBps == nil)
        }
        .padding(10)
        .onAppear { kbps = item.speedLimitKBps ?? 512 }
    }
}

private struct CompletionTab: View {
    @Environment(DownloadManager.self) private var manager
    let item: DownloadItem

    var body: some View {
        @Bindable var settings = manager.settings
        Form {
            LabeledContent("Save To:") {
                Text(item.destination.path(percentEncoded: false)).lineLimit(1).truncationMode(.head)
            }
            Toggle("Show download complete dialog", isOn: $settings.showCompleteDialog)
        }
        .padding(10)
    }
}

/// "Start positions and download progress by connections": a bar with every segment,
/// and a row per segment below it.
private struct ConnectionsDetails: View {
    let item: DownloadItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Start positions and download progress by connections")
                .font(.callout).foregroundStyle(.secondary)
            SegmentBar(segments: item.segments, total: item.total ?? 0)
                .frame(height: 16)
            Table(rows) {
                TableColumn("N.") { row in Text("\(row.number)").monospacedDigit() }
                    .width(30)
                TableColumn("Downloaded") { row in
                    Text(Format.bytes(row.segment.current - row.segment.start)).monospacedDigit()
                }
                .width(min: 80, ideal: 100)
                TableColumn("Info") { row in Text(info(row.segment)).foregroundStyle(.secondary) }
            }
            .frame(height: 150)
        }
        .transition(.opacity)
    }

    private struct Row: Identifiable {
        let number: Int
        let segment: SegmentProgress
        var id: Int64 { segment.start }
    }

    private var rows: [Row] {
        item.segments.enumerated().map { Row(number: $0.offset + 1, segment: $0.element) }
    }

    private func info(_ segment: SegmentProgress) -> String {
        if segment.current > segment.end { return "Complete" }
        switch segment.connections {
        case 0: return item.status == .downloading ? "Waiting" : "Stopped"
        case 1: return segment.current == segment.start ? "Connecting…" : "Receiving data…"
        default: return "Receiving data… (\(segment.connections) connections)"
        }
    }
}

/// The whole file as a bar: downloaded parts filled, the part a connection is working on
/// marked at its current position.
struct SegmentBar: View {
    let segments: [SegmentProgress]
    let total: Int64

    var body: some View {
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            context.fill(Path(roundedRect: bounds, cornerRadius: 3), with: .color(.secondary.opacity(0.18)))
            guard total > 0 else { return }
            let scale = size.width / CGFloat(total)
            for segment in segments {
                let x = CGFloat(segment.start) * scale
                let width = CGFloat(segment.current - segment.start) * scale
                context.fill(Path(CGRect(x: x, y: 0, width: width, height: size.height)), with: .color(.accentColor))
                if segment.connections > 0, segment.current <= segment.end {
                    // The connection's current position.
                    context.fill(Path(CGRect(x: x + width - 1, y: 0, width: 2, height: size.height)),
                                 with: .color(.green))
                }
                // Segment boundary.
                context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)),
                             with: .color(.primary.opacity(0.35)))
            }
        }
        .clipShape(.rect(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(.separator))
    }
}
