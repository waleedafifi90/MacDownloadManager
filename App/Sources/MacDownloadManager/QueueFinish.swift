import AppKit
import DownloadsCore
import SwiftUI

/// Carries out a queue's "when done" settings after it has processed its files.
@MainActor
enum QueueFinish {
    static func perform(_ queue: DownloadQueue, panels: Panels) {
        if let file = queue.openWhenDone { NSWorkspace.shared.open(file) }
        switch queue.whenDone {
        case .nothing:
            return
        case .quitApp:
            panels.showFinishCountdown(queue) { NSApp.terminate(nil) }
        case .sleep:
            panels.showFinishCountdown(queue) { run("/usr/bin/pmset", ["sleepnow"]) }
        case .shutDown:
            // Asks macOS to shut down normally, so apps can save their work first.
            panels.showFinishCountdown(queue) {
                run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to shut down"])
            }
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try? process.run()
    }
}

extension QueueFinishAction {
    var title: String {
        switch self {
        case .nothing: "Do nothing"
        case .quitApp: "Quit Mac Download Manager"
        case .sleep: "Put the Mac to sleep"
        case .shutDown: "Shut down the Mac"
        }
    }
}

/// "Internet Download Manager has finished queue processing…" with a countdown.
struct FinishCountdown: View {
    let queue: DownloadQueue
    let perform: () -> Void
    let cancel: () -> Void
    private let seconds = 30
    @State private var remaining = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("“\(queue.name)” has finished. According to its schedule, Mac Download Manager will now: \(queue.whenDone.title.lowercased()).")
                .fixedSize(horizontal: false, vertical: true)
            ProgressView(value: Double(seconds - remaining), total: Double(seconds))
            HStack {
                Text("In \(remaining) s").monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("\(queue.whenDone == .shutDown ? "Shut Down" : "Do It") Now", action: perform)
            }
        }
        .padding(18)
        .frame(width: 420)
        .task {
            while remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                remaining -= 1
            }
            perform()
        }
    }
}
