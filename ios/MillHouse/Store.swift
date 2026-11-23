import Foundation
import SwiftUI

/// The app's state. The local file is the offline source of truth; changes queue in an outbox, which is POSTed before
/// every GET of the whole list (the web app's rules, public/app.js).
@MainActor
final class Store: ObservableObject {
    nonisolated static let baseURL = URL(string: "https://christmas-shopping-uovm.netlify.app")!

    enum SyncState { case synced, syncing, offline }
    enum Tab: String { case shop, todo, settings }

    @Published private(set) var items: [String: Item] = [:]
    @Published private(set) var outbox: [String: Item] = [:]
    @Published private(set) var aisleMap: [String: String] = [:]
    @Published var me: Person?
    @Published var tab: Tab = .shop
    @Published var shopTab: String = "all"
    @Published var todoFilter: String = "all"
    @Published private(set) var syncState: SyncState = .syncing
    @Published private(set) var aisleBusy = false
    @Published var toast: Toast?

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var message: String
        var undo: Item?
        static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
    }

    private struct Saved: Codable {
        var items: [String: Item]
        var outbox: [String: Item]
        var aisleMap: [String: String]
        var me: Person?
        var shopTab: String?
        var todoFilter: String?
    }

    private let file: URL
    private var syncing = false
    private var again = false
    private var aisleFailAt = Date.distantPast
    private var pollTask: Task<Void, Never>?

    init(file: URL? = nil) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.file = file ?? dir.appendingPathComponent("store.json")
        if let data = try? Data(contentsOf: self.file), let s = try? JSONDecoder().decode(Saved.self, from: data) {
            items = s.items
            outbox = s.outbox
            aisleMap = s.aisleMap
            me = s.me
            shopTab = s.shopTab ?? "all"
            todoFilter = s.todoFilter ?? "all"
        }
    }

    func persist() {
        let s = Saved(items: items, outbox: outbox, aisleMap: aisleMap, me: me, shopTab: shopTab, todoFilter: todoFilter)
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: file, options: .atomic) }
    }

    // MARK: - Reading

    var live: [Item] { items.values.filter { !$0.deleted } }
    var shopItems: [Item] { live.filter { !$0.isTodo } }
    var todoItems: [Item] { live.filter(\.isTodo) }

    /// Everyone the list knows about: item authors, to-do assignees, and me.
    func people() -> [Person] {
        var out: [Person] = []
        func add(_ name: String, _ color: String) {
            let n = name.trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty else { return }
            if let i = out.firstIndex(where: { sameName($0.name, n) }) {
                if out[i].color.isEmpty, !color.isEmpty { out[i].color = color }
            } else {
                out.append(Person(name: n, color: color))
            }
        }
        if let me { add(me.name, me.color) }
        for i in live.sorted(by: { $0.createdAt < $1.createdAt }) {
            add(i.by, i.color)
            add(i.assignee, i.assigneeColor)
        }
        return out
    }

    /// A name keeps the colour it already has; a new name takes the first colour nobody uses.
    func colorFor(_ name: String) -> String {
        if let me, sameName(name, me.name) { return me.color }
        let all = people()
        if let known = all.first(where: { sameName($0.name, name) && !$0.color.isEmpty }) { return known.color }
        let used = Set(all.filter { !sameName($0.name, name) }.map(\.color))
        return Catalog.colors.first { !used.contains($0) } ?? Catalog.colors[0]
    }

    func aisle(of item: Item) -> String? { aisleMap[normName(item.name)] }

    // MARK: - Writing

    func save(_ item: Item) {
        var item = item
        item.updatedAt = max(nowMillis(), (items[item.id]?.updatedAt ?? 0) + 1)
        items[item.id] = item
        outbox[item.id] = item
        persist()
        Task { await sync() }
    }

    func toggle(_ item: Item) {
        guard var i = items[item.id] else { return }
        i.done.toggle()
        save(i)
    }

    func remove(_ item: Item) {
        guard let old = items[item.id], !old.deleted else { return }
        var t = Item(id: old.id)
        t.deleted = true
        save(t)
        toast = Toast(message: "Deleted “\(old.name)”", undo: old)
    }

    func undo(_ toast: Toast) {
        if let old = toast.undo { save(old) }
        self.toast = nil
    }

    func clearDone(todos: Bool) {
        for i in (todos ? todoItems : shopItems) where i.done {
            var t = Item(id: i.id)
            t.deleted = true
            save(t)
        }
    }

    func setMe(name: String, color: String) {
        let name = name.trimmingCharacters(in: .whitespaces).split(separator: " ").joined(separator: " ")
        guard !name.isEmpty else { return }
        let changedName = me.map { !sameName($0.name, name) } ?? true
        me = Person(name: name, color: color)
        // Keep every dot for this person the same colour.
        for i in live {
            var c = i
            var dirty = false
            if sameName(i.by, name), i.color != color { c.color = color; dirty = true }
            if i.isTodo, sameName(i.assignee, name), i.assigneeColor != color { c.assigneeColor = color; dirty = true }
            if dirty { save(c) }
        }
        persist()
        if changedName { Task { await Push.shared.registerIfAllowed(store: self) } }
    }

    // MARK: - Sync

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sync()
                try? await Task.sleep(for: .seconds(8))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func sync() async {
        if syncing { again = true; return }
        syncing = true
        syncState = .syncing
        defer {
            syncing = false
            if again { again = false; Task { await sync() } }
        }
        do {
            let pending = Array(outbox.values)
            if !pending.isEmpty {
                struct Body: Encodable { let changes: [Item]; let actor: String }
                struct Saved: Decodable { let items: [Item] }
                let saved: Saved = try await API.post("/api/items", Body(changes: pending, actor: me?.name ?? ""))
                for p in pending where outbox[p.id]?.updatedAt == p.updatedAt { outbox[p.id] = nil }
                mergeRemote(saved.items, into: &items, outbox: &outbox)
            }
            struct All: Decodable { let items: [Item] }
            let all: All = try await API.get("/api/items")
            mergeRemote(all.items, into: &items, outbox: &outbox)
            persist()
            syncState = outbox.isEmpty ? .synced : .syncing
            await fetchAisles()
        } catch {
            syncState = .offline
        }
    }

    /// Claude sorts unknown names into aisles (/api/aisles); answers are cached per name here and on the server.
    func fetchAisles(force: Bool = false) async {
        if force { aisleFailAt = .distantPast }
        let names = Array(Set(shopItems.map { normName($0.name) })).filter { aisleMap[$0] == nil }
        guard !names.isEmpty, !aisleBusy, Date().timeIntervalSince(aisleFailAt) > 30 else { return }
        aisleBusy = true
        defer { aisleBusy = false }
        struct Body: Encodable { let names: [String] }
        struct Out: Decodable { let aisles: [String: String]? }
        do {
            let (out, ok): (Out, Bool) = try await API.postAllowingError("/api/aisles", Body(names: names))
            aisleMap.merge(out.aisles ?? [:]) { _, new in new }
            if !ok { aisleFailAt = Date() }
            persist()
        } catch {
            aisleFailAt = Date()
        }
    }
}

enum API {
    struct HTTPError: Error { let status: Int }

    static func get<T: Decodable>(_ path: String) async throws -> T {
        var req = URLRequest(url: Store.baseURL.appendingPathComponent(path))
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, res) = try await URLSession.shared.data(for: req)
        guard (res as? HTTPURLResponse)?.statusCode == 200 else { throw HTTPError(status: (res as? HTTPURLResponse)?.statusCode ?? 0) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func post<T: Decodable>(_ path: String, _ body: some Encodable) async throws -> T {
        let (out, ok): (T, Bool) = try await postAllowingError(path, body)
        guard ok else { throw HTTPError(status: 0) }
        return out
    }

    /// Decodes the body whatever the status (the aisles endpoint returns partial answers with a 502).
    static func postAllowingError<T: Decodable>(_ path: String, _ body: some Encodable) async throws -> (T, Bool) {
        var req = URLRequest(url: Store.baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, res) = try await URLSession.shared.data(for: req)
        let status = (res as? HTTPURLResponse)?.statusCode ?? 0
        return (try JSONDecoder().decode(T.self, from: data), status == 200)
    }
}
