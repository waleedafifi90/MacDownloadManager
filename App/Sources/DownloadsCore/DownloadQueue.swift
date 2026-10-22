import Foundation

public struct TimeOfDay: Codable, Equatable, Hashable, Sendable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }
}

/// When a queue starts by itself (IDM's Scheduler ▸ Schedule tab).
public enum QueueStart: Codable, Equatable, Sendable {
    /// "Once at": a single date and time.
    case once(Date)
    /// "Daily": at this time on these weekdays (1 = Sunday … 7 = Saturday; empty = every day).
    case daily(TimeOfDay, weekdays: Set<Int>)
}

/// What to do after a queue has processed all its files.
public enum QueueFinishAction: String, Codable, CaseIterable, Sendable {
    case nothing
    case quitApp
    case sleep
    case shutDown
}

/// A queue of downloads processed in order, a few at a time, optionally on a schedule.
public struct DownloadQueue: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Downloads in processing order.
    public var itemIDs: [UUID] = []
    /// "Download N files at the same time".
    public var maxConcurrent = 1
    /// "Start download on app startup".
    public var startOnLaunch = false
    public var start: QueueStart?
    /// "Stop download at".
    public var stopAt: TimeOfDay?
    /// "Number of retries for each file if download failed".
    public var retries = 3
    /// "Open the following file when done".
    public var openWhenDone: URL?
    public var whenDone = QueueFinishAction.nothing

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }

    public static let mainID = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    public static var main: DownloadQueue { DownloadQueue(id: mainID, name: "Main download queue") }
}

public enum QueueSchedule {
    /// The first scheduled start strictly after `date`, if any.
    public static func nextStart(_ start: QueueStart, after date: Date, calendar: Calendar = .current) -> Date? {
        switch start {
        case .once(let when):
            return when > date ? when : nil
        case .daily(let time, let weekdays):
            return nextOccurrence(of: time, after: date, weekdays: weekdays, calendar: calendar)
        }
    }

    /// The next time the clock shows `time` after `date`, on one of `weekdays` (any if empty).
    public static func nextOccurrence(of time: TimeOfDay, after date: Date, weekdays: Set<Int> = [],
                                      calendar: Calendar = .current) -> Date? {
        let startOfDay = calendar.startOfDay(for: date)
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfDay),
                let candidate = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day)
            else { continue }
            if candidate > date, weekdays.isEmpty || weekdays.contains(calendar.component(.weekday, from: candidate)) {
                return candidate
            }
        }
        return nil
    }

    /// Whether `start` fires in the interval (`from`, `to`].
    static func fires(_ start: QueueStart, from: Date, to: Date, calendar: Calendar = .current) -> Bool {
        guard let next = nextStart(start, after: from, calendar: calendar) else { return false }
        return next <= to
    }

    /// Whether the clock passed `time` in the interval (`from`, `to`].
    static func passes(_ time: TimeOfDay, from: Date, to: Date, calendar: Calendar = .current) -> Bool {
        guard let next = nextOccurrence(of: time, after: from, calendar: calendar) else { return false }
        return next <= to
    }
}
