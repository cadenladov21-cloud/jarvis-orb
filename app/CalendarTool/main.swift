// jarvis-calendar: fast calendar access for Jarvis through EventKit (milliseconds, where
// AppleScript to Calendar takes seconds). Bundled at JarvisOrb.app/Contents/Resources/bin.
//
//   jarvis-calendar list [--from today|tomorrow|YYYY-MM-DD] [--days N] [--json]
//   jarvis-calendar reminders [--days N] [--json]   overdue + due within N days (default 1)
//   jarvis-calendar calendars
//   jarvis-calendar add --title T --start "YYYY-MM-DD HH:MM" [--minutes 60 | --end "YYYY-MM-DD HH:MM"]
//                       [--calendar NAME] [--location L] [--notes N] [--no-show]
//
// Reading (list, reminders, calendars) runs without an approval card; `add` changes the calendar, so Claude Code asks for
// permission and the orb shows a card. Calendar access is granted to Jarvis Orb (macOS asks once).
// After adding, the event is shown in the Calendar app unless --no-show.

import EventKit
import Foundation

let store = EKEventStore()
let args = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func requestAccess() {
    let done = DispatchSemaphore(value: 0)
    var granted = false
    store.requestFullAccessToEvents { ok, _ in
        granted = ok
        done.signal()
    }
    done.wait()
    if !granted {
        fail("No calendar access. Allow Jarvis Orb in System Settings › Privacy & Security › Calendars.")
    }
}

func requestReminderAccess() {
    let done = DispatchSemaphore(value: 0)
    var granted = false
    store.requestFullAccessToReminders { ok, _ in
        granted = ok
        done.signal()
    }
    done.wait()
    if !granted {
        fail("No Reminders access. Allow Jarvis Orb in System Settings › Privacy & Security › Reminders.")
    }
}

let wantsJSON = args.contains("--json")

func printJSON(_ value: Any) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}

let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.timeZone = .current
    f.formatOptions = [.withInternetDateTime]
    return f
}()

let calendar = Calendar.current

func parseDay(_ text: String) -> Date? {
    let today = calendar.startOfDay(for: Date())
    switch text.lowercased() {
    case "today": return today
    case "tomorrow": return calendar.date(byAdding: .day, value: 1, to: today)
    case "yesterday": return calendar.date(byAdding: .day, value: -1, to: today)
    default:
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: text)
    }
}

func parseDateTime(_ text: String) -> Date? {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss"] {
        f.dateFormat = format
        if let date = f.date(from: text) { return date }
    }
    return nil
}

func describe(_ event: EKEvent) -> String {
    let day = DateFormatter()
    day.dateFormat = "EEE yyyy-MM-dd"
    let time = DateFormatter()
    time.dateFormat = "h:mm a"
    var line = "\(day.string(from: event.startDate))  "
    line += event.isAllDay ? "all day" : "\(time.string(from: event.startDate))–\(time.string(from: event.endDate))"
    line += "  \(event.title ?? "(no title)")  [\(event.calendar.title)]"
    if let location = event.location, !location.isEmpty { line += "  @ \(location)" }
    return line
}

switch args.first {
case "list":
    requestAccess()
    let start = option("--from").flatMap(parseDay) ?? calendar.startOfDay(for: Date())
    let days = Int(option("--days") ?? "1") ?? 1
    let end = calendar.date(byAdding: .day, value: max(1, min(days, 366)), to: start)!
    let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
    let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
    if wantsJSON {
        printJSON(events.map { event -> [String: Any] in
            var item: [String: Any] = [
                "title": event.title ?? "(no title)",
                "start": isoFormatter.string(from: event.startDate),
                "end": isoFormatter.string(from: event.endDate),
                "allDay": event.isAllDay,
                "calendar": event.calendar.title,
            ]
            if let location = event.location, !location.isEmpty { item["location"] = location }
            return item
        })
    } else {
        if events.isEmpty { print("No events.") }
        events.forEach { print(describe($0)) }
    }

case "reminders":
    requestReminderAccess()
    let days = Int(option("--days") ?? "1") ?? 1
    let horizon = calendar.date(byAdding: .day, value: max(1, min(days, 60)), to: calendar.startOfDay(for: Date()))!
    let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: horizon, calendars: nil)
    let done = DispatchSemaphore(value: 0)
    var found: [EKReminder] = []
    store.fetchReminders(matching: predicate) { reminders in
        found = reminders ?? []
        done.signal()
    }
    done.wait()
    let now = Date()
    let items: [(EKReminder, Date?)] = found
        .map { ($0, $0.dueDateComponents.flatMap { calendar.date(from: $0) }) }
        .sorted { ($0.1 ?? .distantFuture) < ($1.1 ?? .distantFuture) }
    if wantsJSON {
        printJSON(items.map { reminder, due -> [String: Any] in
            var item: [String: Any] = ["title": reminder.title ?? "(no title)", "list": reminder.calendar.title, "priority": reminder.priority]
            if let due {
                item["due"] = isoFormatter.string(from: due)
                // A date-only reminder is overdue once its day has passed; a timed one once its time has.
                let dateOnly = reminder.dueDateComponents?.hour == nil
                item["overdue"] = dateOnly ? due < calendar.startOfDay(for: now) : due < now
            }
            return item
        })
    } else {
        if items.isEmpty { print("No reminders due.") }
        let day = DateFormatter()
        day.dateFormat = "EEE yyyy-MM-dd"
        for (reminder, due) in items {
            let overdue = due.map { $0 < now } ?? false
            print("\(overdue ? "OVERDUE  " : "")\(due.map { day.string(from: $0) } ?? "no date")  \(reminder.title ?? "(no title)")  [\(reminder.calendar.title)]")
        }
    }

case "calendars":
    requestAccess()
    for cal in store.calendars(for: .event) {
        print("\(cal.title)\(cal.allowsContentModifications ? "" : " (read-only)")\(cal == store.defaultCalendarForNewEvents ? " (default)" : "")")
    }

case "add":
    requestAccess()
    guard let title = option("--title"), !title.isEmpty else { fail("add needs --title") }
    guard let startText = option("--start"), let start = parseDateTime(startText) else {
        fail("add needs --start \"YYYY-MM-DD HH:MM\"")
    }
    let end: Date
    if let endText = option("--end") {
        guard let parsed = parseDateTime(endText) else { fail("--end must be \"YYYY-MM-DD HH:MM\"") }
        end = parsed
    } else {
        end = start.addingTimeInterval(Double(Int(option("--minutes") ?? "60") ?? 60) * 60)
    }
    let event = EKEvent(eventStore: store)
    event.title = title
    event.startDate = start
    event.endDate = end
    event.location = option("--location")
    event.notes = option("--notes")
    if let name = option("--calendar") {
        guard let cal = store.calendars(for: .event).first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) else {
            fail("No calendar named \"\(name)\". Run: jarvis-calendar calendars")
        }
        event.calendar = cal
    } else {
        event.calendar = store.defaultCalendarForNewEvents
    }
    do {
        try store.save(event, span: .thisEvent)
    } catch {
        fail("Could not save the event: \(error.localizedDescription)")
    }
    print("Added: \(describe(event))")
    if !args.contains("--no-show"), let id = event.calendarItemIdentifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
        // Bring Calendar forward on the new event so the owner sees it.
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["ical://ekevent/\(id)?method=show&options=more"]
        try? open.run()
        open.waitUntilExit()
        if open.terminationStatus != 0 {
            let fallback = Process()
            fallback.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            fallback.arguments = ["-a", "Calendar"]
            try? fallback.run()
        }
    }

default:
    fail("usage: jarvis-calendar list [--from today|tomorrow|YYYY-MM-DD] [--days N] [--json] | reminders [--days N] [--json] | calendars | add --title T --start \"YYYY-MM-DD HH:MM\" [--minutes N | --end ...] [--calendar NAME] [--location L] [--notes N] [--no-show]")
}
