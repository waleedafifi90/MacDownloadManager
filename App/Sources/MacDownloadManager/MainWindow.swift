import AppKit
import DownloadsCore
import SwiftUI
import UniformTypeIdentifiers

/// IDM's layout: a row of large buttons on top, the Categories tree on the left and
/// the download list on the right.
struct MainWindow: View {
    let panels: Panels
    @Environment(DownloadManager.self) private var manager
    @Environment(UIState.self) private var ui
    @Environment(BrowserCapture.self) private var capture
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var filter = CategoryFilter.all
    @State private var selection = Set<DownloadItem.ID>()

    @Environment(QueueManager.self) private var queues
    private var visibleItems: [DownloadItem] { manager.items.filter { filter.includes($0, queues: queues) } }
    private var selected: [DownloadItem] { manager.items.filter { selection.contains($0.id) } }

    var body: some View {
        @Bindable var ui = ui
        VStack(spacing: 0) {
            ButtonBar(selected: selected, openOptions: { openSettings() })
            Divider()
            HStack(spacing: 0) {
                if ui.showCategories {
                    CategoriesSidebar(filter: $filter)
                        .frame(width: 190)
                    Divider()
                }
                DownloadsTable(items: visibleItems, selection: $selection, panels: panels)
            }
        }
        .sheet(isPresented: $ui.showingAddURL) { AddDownloadFlow() }
        .onAppear {
            manager.didStart = { [manager, panels, queues] item in
                // Like IDM: queue downloads always start minimized; otherwise the "Start view" setting.
                let fromQueue = queues.queue(of: item).map { queues.running.contains($0.id) } ?? false
                if manager.settings.progressStartView == .normal && !fromQueue { panels.showProgress(item) }
            }
            manager.didComplete = { [manager, panels] item in
                if manager.settings.showCompleteDialog { panels.showComplete(item) }
            }
            // Panels show over the browser without activating the app or switching Spaces.
            capture.didReceive = { [panels] pending in panels.showCapture(pending) }
            // Captures that arrived before this window existed.
            for pending in capture.pending { panels.showCapture(pending) }
            DevHooks.run(manager: manager)
            if ProcessInfo.processInfo.environment["MDM_DEV_OPEN_SCHEDULER"] != nil { openWindow(id: "scheduler") }
            if ProcessInfo.processInfo.environment["MDM_DEV_OPEN_PROPERTIES"] != nil, let first = manager.items.first {
                panels.showProperties(first)
            }
        }
    }
}

// MARK: - Button bar

/// Large icon-over-label buttons, in IDM's order.
private struct ButtonBar: View {
    @Environment(DownloadManager.self) private var manager
    @Environment(UIState.self) private var ui
    @Environment(QueueManager.self) private var queues
    @Environment(\.openWindow) private var openWindow
    let selected: [DownloadItem]
    let openOptions: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            BigButton("Add URL", symbol: "plus.circle.fill", tint: .blue) { ui.showingAddURL = true }
            BigButton("Resume", symbol: "play.circle.fill", tint: .green,
                      enabled: selected.contains(where: \.canResume)) { selected.forEach(manager.resume) }
            BigButton("Stop", symbol: "stop.circle.fill", tint: .orange,
                      enabled: selected.contains { $0.status == .downloading }) { selected.forEach(manager.pause) }
            BigButton("Stop All", symbol: "stop.fill", tint: .orange,
                      enabled: manager.items.contains { $0.status == .downloading }) { manager.pauseAll() }
            Divider().frame(height: 40).padding(.horizontal, 6)
            BigButton("Delete", symbol: "trash.circle.fill", tint: .red,
                      enabled: !selected.isEmpty) { selected.forEach { manager.remove($0) } }
            BigButton("Delete Completed", symbol: "checkmark.circle.badge.xmark", tint: .red,
                      enabled: manager.items.contains { $0.status == .completed }) { manager.removeCompleted() }
            Divider().frame(height: 40).padding(.horizontal, 6)
            BigButton("Options", symbol: "gearshape.fill", tint: .gray, action: openOptions)
            BigButton("Scheduler", symbol: "calendar.badge.clock", tint: .indigo) { openWindow(id: "scheduler") }
            QueueMenuButton(title: "Start Queue", symbol: "play.square.stack.fill", tint: .green,
                            candidates: queues.queues.filter { !queues.running.contains($0.id) }) { queues.start($0.id) }
            QueueMenuButton(title: "Stop Queue", symbol: "stop.circle", tint: .orange,
                            candidates: queues.queues.filter { queues.running.contains($0.id) }) { queues.stop($0.id) }
            BigButton("Speed Limiter", symbol: "gauge.with.dots.needle.33percent",
                      tint: manager.settings.speedLimitEnabled ? .purple : .gray) {
                manager.settings.speedLimitEnabled.toggle()
                manager.applySpeedLimit()
            }
            .overlay(alignment: .topTrailing) {
                if manager.settings.speedLimitEnabled {
                    Text("ON").font(.system(size: 8, weight: .bold)).padding(.horizontal, 3)
                        .background(.purple, in: .capsule).foregroundStyle(.white).offset(x: -6, y: 2)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// "Start Queue" / "Stop Queue": acts directly with one queue, or offers a menu of queues.
private struct QueueMenuButton: View {
    let title: String
    let symbol: String
    let tint: Color
    let candidates: [DownloadQueue]
    let action: (DownloadQueue) -> Void

    var body: some View {
        if candidates.count > 1 {
            Menu {
                ForEach(candidates) { queue in Button(queue.name) { action(queue) } }
            } label: {
                BigButtonLabel(title: title, symbol: symbol, tint: tint, enabled: true)
            }
            // Plain button style keeps our icon-over-label look instead of a menu's.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        } else {
            BigButton(title, symbol: symbol, tint: tint, enabled: !candidates.isEmpty) {
                if let queue = candidates.first { action(queue) }
            }
        }
    }
}

private struct BigButtonLabel: View {
    let title: String
    let symbol: String
    let tint: Color
    let enabled: Bool

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 24))
                .foregroundStyle(enabled ? tint : .secondary)
                .frame(height: 28)
            Text(title).font(.system(size: 11))
        }
        .frame(minWidth: 64)
        .padding(.vertical, 4)
        .padding(.horizontal, 3)
        .contentShape(.rect)
    }
}

private struct BigButton: View {
    let title: String
    let symbol: String
    let tint: Color
    var enabled = true
    let action: () -> Void

    init(_ title: String, symbol: String, tint: Color, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            BigButtonLabel(title: title, symbol: symbol, tint: tint, enabled: enabled)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

// MARK: - Categories

enum CategoryFilter: Hashable {
    case all
    case category(String)
    case unfinished
    case finished
    case queue(UUID)

    @MainActor func includes(_ item: DownloadItem, queues: QueueManager) -> Bool {
        switch self {
        case .all: true
        case .category(let name): item.category.name == name
        case .unfinished: item.status != .completed
        case .finished: item.status == .completed
        case .queue(let id): queues.queue(id: id)?.itemIDs.contains(item.id) == true
        }
    }
}

private struct CategoriesSidebar: View {
    @Environment(DownloadManager.self) private var manager
    @Environment(QueueManager.self) private var queues
    @Environment(UIState.self) private var ui
    @Binding var filter: CategoryFilter
    @State private var allExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Categories").font(.headline)
                Spacer()
                Button { ui.showCategories = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Hide categories")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            List(selection: Binding(get: { filter }, set: { filter = $0 ?? .all })) {
                DisclosureGroup(isExpanded: $allExpanded) {
                    ForEach(DownloadCategory.all) { category in
                        row(category.name, symbol: category.symbol, filter: .category(category.name))
                    }
                } label: {
                    row("All Downloads", symbol: "tray.full", filter: .all)
                }
                row("Unfinished", symbol: "arrow.down.circle", filter: .unfinished)
                row("Finished", symbol: "checkmark.circle", filter: .finished)
                Section("Queues") {
                    ForEach(queues.queues) { queue in
                        row(queue.name, symbol: queues.running.contains(queue.id) ? "play.circle.fill" : "list.bullet",
                            filter: .queue(queue.id))
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func row(_ title: String, symbol: String, filter: CategoryFilter) -> some View {
        let count = manager.items.filter { filter.includes($0, queues: queues) }.count
        return Label(title, systemImage: symbol)
            .badge(count)
            .tag(filter)
    }
}

// MARK: - Download list

private struct DownloadsTable: View {
    @Environment(DownloadManager.self) private var manager
    @Environment(QueueManager.self) private var queues
    let items: [DownloadItem]
    @Binding var selection: Set<DownloadItem.ID>
    let panels: Panels

    var body: some View {
        Table(items, selection: $selection) {
            TableColumn("File Name") { item in
                HStack(spacing: 6) {
                    Image(nsImage: NSWorkspace.shared.icon(
                        for: UTType(filenameExtension: item.destination.pathExtension) ?? .data))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(item.fileName).lineLimit(1).truncationMode(.middle)
                }
            }
            .width(min: 180, ideal: 280)
            TableColumn("Size") { item in
                Text(item.total.map(Format.bytes) ?? "").monospacedDigit()
            }
            .width(min: 60, ideal: 80)
            TableColumn("Status") { item in StatusText(item: item) }
                .width(min: 70, ideal: 90)
            TableColumn("Time Left") { item in
                Text(Format.duration(item.timeRemaining)).monospacedDigit()
            }
            .width(min: 60, ideal: 80)
            TableColumn("Transfer Rate") { item in
                Text(Format.speed(item.speed)).monospacedDigit()
            }
            .width(min: 70, ideal: 90)
            TableColumn("Last Try Date") { item in
                Text(item.lastTry.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
            }
            .width(min: 90, ideal: 130)
            TableColumn("Description") { item in
                Text(item.note).lineLimit(1).foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 160)
        }
        .contextMenu(forSelectionType: DownloadItem.ID.self) { ids in
            let items = manager.items.filter { ids.contains($0.id) }
            Button("Open") { items.forEach { NSWorkspace.shared.open($0.destination) } }
                .disabled(!items.contains { $0.status == .completed })
            Button("Open Folder") { revealInFinder(items) }
            Divider()
            Button("Download Now") { items.forEach(manager.resume) }
                .disabled(!items.contains(where: \.canResume))
            Button("Stop Download") { items.forEach(manager.pause) }
                .disabled(!items.contains { $0.status == .downloading })
            Button("Show Progress") { items.forEach(panels.showProgress) }
                .disabled(!items.contains { $0.status != .completed })
            Divider()
            Button("Copy Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(items.map(\.url.absoluteString).joined(separator: "\n"), forType: .string)
            }
            Menu("Move to Queue") {
                ForEach(queues.queues) { queue in
                    Button(queue.name) { items.forEach { queues.add($0, to: queue.id) } }
                }
            }
            Button("Delete from Queue") { items.forEach(queues.removeFromQueues) }
                .disabled(!items.contains { queues.queue(of: $0) != nil })
            Divider()
            Button("Remove") { items.forEach { manager.remove($0) } }
            Divider()
            Button("Properties") { items.forEach(panels.showProperties) }
        } primaryAction: { ids in
            // Like IDM: a finished file shows its File Properties; an unfinished one its progress.
            for item in manager.items where ids.contains(item.id) {
                if item.status == .completed { panels.showProperties(item) }
                else { panels.showProgress(item) }
            }
        }
        .onDeleteCommand { manager.items.filter { selection.contains($0.id) }.forEach { manager.remove($0) } }
    }

    private func revealInFinder(_ items: [DownloadItem]) {
        NSWorkspace.shared.activateFileViewerSelecting(items.map { item in
            FileManager.default.fileExists(atPath: item.destination.path)
                ? item.destination : item.destination.deletingLastPathComponent()
        })
    }
}

/// IDM's Status column: the percentage while unfinished, "Complete" when done.
private struct StatusText: View {
    let item: DownloadItem

    var body: some View {
        switch item.status {
        case .completed:
            Text("Complete")
        case .failed(let message):
            Text("Error").foregroundStyle(.red).help(message)
        case .downloading, .paused:
            if let fraction = item.fraction {
                Text(fraction, format: .percent.precision(.fractionLength(2))).monospacedDigit()
                    .foregroundStyle(item.status == .paused ? .secondary : .primary)
            } else {
                Text(item.status == .paused ? "Paused" : "Connecting…").foregroundStyle(.secondary)
            }
        }
    }
}

extension DownloadItem {
    var canResume: Bool {
        switch status {
        case .paused, .failed: true
        case .downloading, .completed: false
        }
    }
}
