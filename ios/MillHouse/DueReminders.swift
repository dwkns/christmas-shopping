import Foundation
import UserNotifications

/// One local notification at 08:00 on each day a to-do of mine (or for Anyone) is due, listing that day's to-dos, with
/// overdue ones added to the next morning's. Scheduled on the phone, so it works offline and needs no server; the
/// server's 08:00 UTC reminder (netlify/functions/reminders.mjs) is for web app users only. Rescheduled after every
/// sync and change, so done, deleted, reassigned or re-dated to-dos drop out.
enum DueReminders {
    static let prefix = "due-"
    static let hour = 8

    struct Reminder: Equatable {
        let day: String      // YYYY-MM-DD
        let title: String
        let body: String
    }

    /// What to schedule, from now on. Pure, for the tests.
    static func plan(todos: [Item], me: String, now: Date = Date()) -> [Reminder] {
        let today = Day.ymd(now)
        let pastMorning = Calendar.current.component(.hour, from: now) >= hour
        let mine = todos.filter { !$0.deleted && $0.isTodo && !$0.done && !$0.due.isEmpty
            && ($0.assignee.isEmpty || (!me.isEmpty && sameName($0.assignee, me))) }
        // The first morning still to come: today before 08:00, otherwise tomorrow. Anything due before it is overdue then.
        let first = pastMorning ? Day.ymd(Calendar.current.date(byAdding: .day, value: 1, to: now)!) : today
        var byDay: [String: [Item]] = [:]
        for t in mine { byDay[max(t.due, first), default: []].append(t) }
        return byDay.keys.sorted().prefix(60).map { day in
            let list = byDay[day]!.sorted { ($0.due, $0.name) < ($1.due, $1.name) }
            let overdue = list.filter { $0.due < day }.count
            let n = list.count
            let title = overdue > 0 ? "\(n) to-do\(n > 1 ? "s" : "") due (\(overdue) overdue)" : "\(n) to-do\(n > 1 ? "s" : "") due today"
            var lines = list.prefix(4).map { "• \($0.name)\($0.due < day ? " (was due \(Day.label($0.due)))" : "")" }
            if n > 4 { lines.append("and \(n - 4) more") }
            return Reminder(day: day, title: title, body: lines.joined(separator: "\n"))
        }
    }

    /// Replace every pending due reminder with the current plan. Only when notifications are allowed.
    static func reschedule(todos: [Item], me: String) async {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        guard status == .authorized || status == .provisional, Push.todosWanted else { return }
        for r in plan(todos: todos, me: me) {
            guard let date = Day.date(r.day) else { continue }
            var when = Calendar.current.dateComponents([.year, .month, .day], from: date)
            when.hour = hour
            let content = UNMutableNotificationContent()
            content.title = r.title
            content.body = r.body
            content.sound = .default
            content.threadIdentifier = "reminder"
            content.userInfo = ["view": "todo"]
            let request = UNNotificationRequest(identifier: prefix + r.day, content: content,
                                                trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false))
            try? await center.add(request)
        }
    }
}
