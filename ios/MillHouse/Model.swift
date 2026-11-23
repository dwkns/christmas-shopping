import Foundation

/// One shopping item or to-do, exactly as the Netlify API stores it (docs/ios-plan.md, "Backend contract").
/// A deleted item is a tombstone: `{ id, deleted: true, updatedAt }`.
struct Item: Codable, Identifiable, Equatable {
    var id: String
    var type: String = ""          // "" shopping, "todo" to-do
    var name: String = ""
    var qty: String = ""
    var day: String = ""
    var meal: String = ""
    var done: Bool = false
    var by: String = ""
    var color: String = ""
    var assignee: String = ""
    var assigneeColor: String = ""
    var due: String = ""
    var createdAt: Int64 = 0
    var updatedAt: Int64 = 0
    var deleted: Bool = false

    var isTodo: Bool { type == "todo" }
    /// Old "Multiple" items count as All.
    var dayKey: String { day == "Multiple" ? "All" : day }

    init(id: String, type: String = "") {
        self.id = id
        self.type = type
    }

    enum CodingKeys: String, CodingKey {
        case id, type, name, qty, day, meal, done, by, color, assignee, assigneeColor, due, createdAt, updatedAt, deleted
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? ""
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        qty = (try? c.decodeIfPresent(String.self, forKey: .qty)) ?? ""
        day = (try? c.decodeIfPresent(String.self, forKey: .day)) ?? ""
        meal = (try? c.decodeIfPresent(String.self, forKey: .meal)) ?? ""
        done = (try? c.decodeIfPresent(Bool.self, forKey: .done)) ?? false
        by = (try? c.decodeIfPresent(String.self, forKey: .by)) ?? ""
        color = (try? c.decodeIfPresent(String.self, forKey: .color)) ?? ""
        assignee = (try? c.decodeIfPresent(String.self, forKey: .assignee)) ?? ""
        assigneeColor = (try? c.decodeIfPresent(String.self, forKey: .assigneeColor)) ?? ""
        due = (try? c.decodeIfPresent(String.self, forKey: .due)) ?? ""
        createdAt = Self.millis(c, .createdAt)
        updatedAt = Self.millis(c, .updatedAt)
        deleted = (try? c.decodeIfPresent(Bool.self, forKey: .deleted)) ?? false
    }

    private static func millis(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int64 {
        if let v = try? c.decodeIfPresent(Int64.self, forKey: key) { return v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: key) { return Int64(v) }
        return 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(updatedAt, forKey: .updatedAt)
        if deleted {
            try c.encode(true, forKey: .deleted)
            return
        }
        try c.encode(type, forKey: .type)
        try c.encode(name, forKey: .name)
        try c.encode(qty, forKey: .qty)
        try c.encode(day, forKey: .day)
        try c.encode(meal, forKey: .meal)
        try c.encode(done, forKey: .done)
        try c.encode(by, forKey: .by)
        try c.encode(color, forKey: .color)
        try c.encode(assignee, forKey: .assignee)
        try c.encode(assigneeColor, forKey: .assigneeColor)
        try c.encode(due, forKey: .due)
        try c.encode(createdAt, forKey: .createdAt)
    }
}

struct Person: Codable, Equatable {
    var name: String
    var color: String
}

enum Catalog {
    static let days = ["Fri", "Sat", "Sun", "All"]
    static let dayNames = ["Mon": "Monday", "Tue": "Tuesday", "Wed": "Wednesday", "Thu": "Thursday", "Fri": "Friday",
                           "Sat": "Saturday", "Sun": "Sunday", "All": "All Days"]
    static let meals = ["Breakfast", "Lunch", "Dinner", "Snacks"]
    /// Sainsbury's sections in walk order. Keep in sync with AISLES in public/app.js and netlify/functions/aisles.mjs.
    static let aisles = ["Fruit & Veg", "Bakery", "Meat & Poultry", "Fish & Seafood", "Deli & Cheese", "Dairy & Eggs",
                         "Chilled & Ready Meals", "Frozen", "Food Cupboard", "Baking & Home Cooking", "World Foods",
                         "Cereals & Spreads", "Tea & Coffee", "Crisps & Snacks", "Chocolate & Sweets",
                         "Soft Drinks & Juice", "Beer, Wine & Spirits", "Christmas & Seasonal", "Household",
                         "Health & Beauty", "Baby", "Pet", "Home & Clothing"]
    static let colors = ["#007AFF", "#FF9500", "#AF52DE", "#FF2D55", "#30B0C7", "#5856D6", "#D4A900", "#A2845E",
                         "#00A89F", "#8E8E93"]
    static let anyoneColor = "#8E8E93"
}

// MARK: - Small helpers shared with the web app's rules

func sameName(_ a: String, _ b: String) -> Bool {
    a.trimmingCharacters(in: .whitespaces).lowercased() == b.trimmingCharacters(in: .whitespaces).lowercased()
}

func firstName(_ n: String) -> String {
    n.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
}

func normName(_ s: String) -> String {
    let collapsed = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    return String(collapsed.prefix(200))
}

func newID() -> String {
    let t = String(Int64(Date().timeIntervalSince1970 * 1000), radix: 36)
    let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
    return t + String((0 ..< 8).map { _ in chars.randomElement()! })
}

func nowMillis() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

/// Dates are "YYYY-MM-DD" in local time.
enum Day {
    static func ymd(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func today() -> String { ymd(Date()) }
    static func addDays(_ n: Int) -> String { ymd(Calendar.current.date(byAdding: .day, value: n, to: Date())!) }

    static func date(_ s: String) -> Date? {
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))
    }

    /// "Fri 25 Dec"
    static func label(_ s: String) -> String {
        guard let d = date(s) else { return s }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "EEE d MMM"
        return f.string(from: d)
    }
}

/// Merge server items into the local store by `updatedAt`; an outbox entry newer than the server's copy wins and stays
/// queued. Same rules as `merge()` in public/app.js. Returns true when anything visible changed.
@discardableResult
func mergeRemote(_ remote: [Item], into items: inout [String: Item], outbox: inout [String: Item]) -> Bool {
    var changed = false
    for r in remote {
        let pending = outbox[r.id]
        if let p = pending, p.updatedAt > r.updatedAt { continue }
        if let local = items[r.id] {
            if r.updatedAt > local.updatedAt || (r.updatedAt == local.updatedAt && r != local) {
                items[r.id] = r
                changed = true
            }
        } else {
            items[r.id] = r
            changed = true
        }
        if let p = pending, p.updatedAt <= r.updatedAt { outbox[r.id] = nil }
    }
    return changed
}

enum TodoSection: String, CaseIterable {
    case overdue = "Overdue", today = "Today", tomorrow = "Tomorrow", later = "Later", noDate = "No Date", done = "Done"

    static func of(_ t: Item, today: String = Day.today(), tomorrow: String = Day.addDays(1)) -> TodoSection {
        if t.done { return .done }
        if t.due.isEmpty { return .noDate }
        if t.due < today { return .overdue }
        if t.due == today { return .today }
        if t.due == tomorrow { return .tomorrow }
        return .later
    }
}
