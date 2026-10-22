import AppKit
import DownloadsCore
import SwiftUI

/// IDM's Scheduler: queues on the left; on the right the selected queue's "Schedule" and
/// "Files in the queue" tabs; New queue / Delete / Start now / Stop below.
struct SchedulerWindow: View {
    @Environment(QueueManager.self) private var queues
    @State private var selection: UUID? = DownloadQueue.mainID
    @State private var naming = false
    @State private var newName = ""

    private var selected: DownloadQueue? { selection.flatMap(queues.queue(id:)) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Queues").font(.headline).padding(.horizontal, 10).padding(.top, 8)
                    List(selection: $selection) {
                        ForEach(queues.queues) { queue in
                            Label {
                                Text(queue.name)
                            } icon: {
                                Image(systemName: queues.running.contains(queue.id) ? "play.circle.fill" : "list.bullet")
                                    .foregroundStyle(queues.running.contains(queue.id) ? .green : .secondary)
                            }
                            .tag(queue.id)
                        }
                    }
                    .listStyle(.sidebar)
                }
                .frame(width: 210)
                Divider()
                if let queue = selected {
                    QueueEditor(queue: queue).id(queue.id)
                } else {
                    ContentUnavailableView("No queue selected", systemImage: "list.bullet")
                }
            }
            Divider()
            HStack {
                Button("New Queue…") { newName = ""; naming = true }
                Button("Delete") { if let id = selection { queues.deleteQueue(id: id); selection = DownloadQueue.mainID } }
                    .disabled(selection == nil || selection == DownloadQueue.mainID)
                Spacer()
                Button("Start Now") { if let id = selection { queues.start(id) } }
                    .disabled(selection.map { queues.running.contains($0) } ?? true)
                Button("Stop") { if let id = selection { queues.stop(id) } }
                    .disabled(!(selection.map { queues.running.contains($0) } ?? false))
            }
            .padding(10)
        }
        .frame(width: 720, height: 500)
        .alert("Enter a name for the new queue", isPresented: $naming) {
            TextField("Queue name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("OK") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { selection = queues.addQueue(named: name).id }
            }
        }
    }
}

private struct QueueEditor: View {
    @Environment(QueueManager.self) private var queues
    @State var queue: DownloadQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Queue name", text: $queue.name)
                .textFieldStyle(.roundedBorder)
                .font(.headline)
                .disabled(queue.id == DownloadQueue.mainID)
            TabView {
                ScheduleTab(queue: $queue).tabItem { Text("Schedule") }
                FilesTab(queue: $queue).tabItem { Text("Files in the queue") }
            }
        }
        .padding(12)
        // Changes apply right away (IDM needs "Apply").
        .onChange(of: queue) { _, new in queues.update(new) }
    }
}

private struct ScheduleTab: View {
    @Binding var queue: DownloadQueue
    @State private var startEnabled = false
    @State private var daily = true
    @State private var startTime = Date()
    @State private var onceDate = Date().addingTimeInterval(3600)
    @State private var weekdays: Set<Int> = Set(1...7)
    @State private var stopEnabled = false
    @State private var stopTime = Date()

    var body: some View {
        Form {
            Toggle("Start download on app startup", isOn: $queue.startOnLaunch)
            Section {
                Toggle("Start download at", isOn: $startEnabled)
                if startEnabled {
                    Picker("", selection: $daily) {
                        Text("Once at").tag(false)
                        Text("Daily").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                    .labelsHidden()
                    if daily {
                        DatePicker("Time", selection: $startTime, displayedComponents: .hourAndMinute)
                        WeekdayPicker(selection: $weekdays)
                    } else {
                        DatePicker("Date and time", selection: $onceDate)
                    }
                }
            }
            Section {
                Toggle("Stop download at", isOn: $stopEnabled)
                if stopEnabled { DatePicker("Time", selection: $stopTime, displayedComponents: .hourAndMinute) }
                Stepper("Number of retries for each file if download failed: \(queue.retries)",
                        value: $queue.retries, in: 0...20)
            }
            Section("When done") {
                LabeledContent("Open the following file") {
                    HStack {
                        Text(queue.openWhenDone?.lastPathComponent ?? "—").foregroundStyle(.secondary)
                        Button("…", action: chooseFile)
                        if queue.openWhenDone != nil { Button("Clear") { queue.openWhenDone = nil } }
                    }
                }
                Picker("Then", selection: $queue.whenDone) {
                    ForEach(QueueFinishAction.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .onChange(of: [startEnabled, daily, stopEnabled]) { store() }
        .onChange(of: [startTime, onceDate, stopTime]) { store() }
        .onChange(of: weekdays) { store() }
    }

    private func load() {
        let calendar = Calendar.current
        switch queue.start {
        case .daily(let time, let days):
            startEnabled = true
            daily = true
            startTime = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: Date()) ?? Date()
            weekdays = days.isEmpty ? Set(1...7) : days
        case .once(let date):
            startEnabled = true
            daily = false
            onceDate = date
        case nil:
            startEnabled = false
        }
        if let stop = queue.stopAt {
            stopEnabled = true
            stopTime = calendar.date(bySettingHour: stop.hour, minute: stop.minute, second: 0, of: Date()) ?? Date()
        }
    }

    private func store() {
        let calendar = Calendar.current
        func timeOfDay(_ date: Date) -> TimeOfDay {
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            return TimeOfDay(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
        }
        if !startEnabled {
            queue.start = nil
        } else if daily {
            queue.start = .daily(timeOfDay(startTime), weekdays: weekdays.count == 7 ? [] : weekdays)
        } else {
            queue.start = .once(onceDate)
        }
        queue.stopAt = stopEnabled ? timeOfDay(stopTime) : nil
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        if panel.runModal() == .OK { queue.openWhenDone = panel.url }
    }
}

private struct WeekdayPicker: View {
    @Binding var selection: Set<Int>

    var body: some View {
        let symbols = Calendar.current.shortWeekdaySymbols  // index 0 = Sunday
        HStack(spacing: 4) {
            ForEach(1...7, id: \.self) { day in
                Toggle(symbols[day - 1], isOn: Binding(
                    get: { selection.contains(day) },
                    set: { if $0 { selection.insert(day) } else if selection.count > 1 { selection.remove(day) } }))
                    .toggleStyle(.button)
            }
        }
    }
}

private struct FilesTab: View {
    @Environment(QueueManager.self) private var queues
    @Environment(DownloadManager.self) private var manager
    @Binding var queue: DownloadQueue
    @State private var selection: DownloadItem.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Stepper("Download \(queue.maxConcurrent) file\(queue.maxConcurrent == 1 ? "" : "s") at the same time",
                    value: $queue.maxConcurrent, in: 1...10)
            Table(queues.items(in: queue.id), selection: $selection) {
                TableColumn("File Name") { item in Text(item.fileName).lineLimit(1) }
                TableColumn("Size") { item in Text(item.total.map(Format.bytes) ?? "") }.width(80)
                TableColumn("Status") { item in Text(statusText(item)).foregroundStyle(.secondary) }.width(100)
            }
            HStack {
                Button { move(-1) } label: { Image(systemName: "arrow.up") }.help("Move up")
                Button { move(1) } label: { Image(systemName: "arrow.down") }.help("Move down")
                Button("Delete from Queue") {
                    if let item = selection.flatMap(manager.item(id:)) { queues.removeFromQueues(item); sync() }
                }
                .disabled(selection == nil)
            }
            .disabled(selection == nil)
        }
        .padding(8)
    }

    private func move(_ offset: Int) {
        guard let item = selection.flatMap(manager.item(id:)) else { return }
        queues.move(item, by: offset)
        sync()
    }

    /// Keep the editor's copy in step with changes made directly on the queue manager.
    private func sync() {
        if let fresh = queues.queue(id: queue.id) { queue.itemIDs = fresh.itemIDs }
    }

    private func statusText(_ item: DownloadItem) -> String {
        switch item.status {
        case .downloading: item.fraction.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "Downloading"
        case .paused: "Waiting"
        case .completed: "Complete"
        case .failed: "Error"
        }
    }
}
