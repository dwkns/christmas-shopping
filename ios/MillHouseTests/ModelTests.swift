@testable import MillHouse
import XCTest

final class ModelTests: XCTestCase {
    func testDecodesTombstoneAndFullItem() throws {
        let json = #"[{"id":"abcdef","deleted":true,"updatedAt":5},{"id":"ghijkl","type":"todo","name":"Wrap","done":false,"due":"2026-12-24","createdAt":1,"updatedAt":2}]"#
        let items = try JSONDecoder().decode([Item].self, from: Data(json.utf8))
        XCTAssertTrue(items[0].deleted)
        XCTAssertEqual(items[0].updatedAt, 5)
        XCTAssertTrue(items[1].isTodo)
        XCTAssertEqual(items[1].due, "2026-12-24")
    }

    func testTombstoneEncodesOnlyIdDeletedUpdatedAt() throws {
        var t = Item(id: "abcdef")
        t.deleted = true
        t.updatedAt = 9
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(t)) as! [String: Any]
        XCTAssertEqual(Set(obj.keys), ["id", "deleted", "updatedAt"])
    }

    func testMergeNewestWinsAndPendingOutboxSurvives() {
        var a = Item(id: "aaaaaa"); a.name = "old"; a.updatedAt = 1
        var b = Item(id: "bbbbbb"); b.name = "mine"; b.updatedAt = 10
        var items = ["aaaaaa": a, "bbbbbb": b]
        var outbox = ["bbbbbb": b]
        var ra = a; ra.name = "new"; ra.updatedAt = 2
        var rb = b; rb.name = "theirs"; rb.updatedAt = 5
        XCTAssertTrue(mergeRemote([ra, rb], into: &items, outbox: &outbox))
        XCTAssertEqual(items["aaaaaa"]?.name, "new")
        XCTAssertEqual(items["bbbbbb"]?.name, "mine")
        XCTAssertNotNil(outbox["bbbbbb"])
        rb.updatedAt = 10
        mergeRemote([rb], into: &items, outbox: &outbox)
        XCTAssertNil(outbox["bbbbbb"])
    }

    func testTodoSections() {
        var t = Item(id: "tttttt", type: "todo")
        let s = { TodoSection.of(t, today: "2026-12-20", tomorrow: "2026-12-21") }
        XCTAssertEqual(s(), .noDate)
        t.due = "2026-12-19"; XCTAssertEqual(s(), .overdue)
        t.due = "2026-12-20"; XCTAssertEqual(s(), .today)
        t.due = "2026-12-21"; XCTAssertEqual(s(), .tomorrow)
        t.due = "2026-12-25"; XCTAssertEqual(s(), .later)
        t.done = true; XCTAssertEqual(s(), .done)
    }

    func testNotesAndWhenRoundTripAndSection() throws {
        var t = Item(id: "abcdef", type: "todo")
        t.notes = "Ring first"
        t.when = "soon"
        let back = try JSONDecoder().decode(Item.self, from: JSONEncoder().encode(t))
        XCTAssertEqual(back.notes, "Ring first")
        XCTAssertEqual(back.when, "soon")
        XCTAssertEqual(TodoSection.of(back), .soon)
        t.due = "2026-12-24" // a date wins over When
        XCTAssertEqual(TodoSection.of(t, today: "2026-11-24", tomorrow: "2026-11-25"), .later)
        t.due = ""; t.when = "norush"
        XCTAssertEqual(TodoSection.of(t), .noRush)
    }

    func testOldMultipleDayCountsAsAll() {
        var i = Item(id: "mmmmmm"); i.day = "Multiple"
        XCTAssertEqual(i.dayKey, "All")
    }
}

final class DueReminderTests: XCTestCase {
    private func todo(_ name: String, due: String, assignee: String = "", done: Bool = false) -> Item {
        var t = Item(id: "t" + name.lowercased() + "xxxxx", type: "todo")
        t.name = name; t.due = due; t.assignee = assignee; t.done = done
        return t
    }

    private func at(_ ymd: String, hour: Int) -> Date {
        var c = Calendar.current.dateComponents([.year, .month, .day], from: Day.date(ymd)!)
        c.hour = hour
        return Calendar.current.date(from: c)!
    }

    func testOneReminderPerDayForMeAndAnyone() {
        let todos = [todo("Wrap", due: "2026-12-24"), todo("Carve", due: "2026-12-24", assignee: "Darrell"),
                     todo("Helen's", due: "2026-12-24", assignee: "Helen"), todo("Done", due: "2026-12-24", done: true),
                     todo("Later", due: "2026-12-26")]
        let plan = DueReminders.plan(todos: todos, me: "Darrell", now: at("2026-12-20", hour: 9))
        XCTAssertEqual(plan.map(\.day), ["2026-12-24", "2026-12-26"])
        XCTAssertEqual(plan[0].title, "2 to-dos due today")
        XCTAssertFalse(plan[0].body.contains("Helen's"))
    }

    func testOverdueJoinTheNextMorning() {
        let todos = [todo("Old", due: "2026-12-18"), todo("Today", due: "2026-12-20")]
        let before8 = DueReminders.plan(todos: todos, me: "D", now: at("2026-12-20", hour: 7))
        XCTAssertEqual(before8.map(\.day), ["2026-12-20"])
        XCTAssertEqual(before8[0].title, "2 to-dos due (1 overdue)")
        let after8 = DueReminders.plan(todos: todos, me: "D", now: at("2026-12-20", hour: 9))
        XCTAssertEqual(after8.map(\.day), ["2026-12-21"])
    }
}
