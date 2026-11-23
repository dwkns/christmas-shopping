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

    func testOldMultipleDayCountsAsAll() {
        var i = Item(id: "mmmmmm"); i.day = "Multiple"
        XCTAssertEqual(i.dayKey, "All")
    }
}
