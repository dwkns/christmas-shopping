import SwiftUI

struct RootView: View {
    @EnvironmentObject var store: Store
    @State private var whatsNew: String?

    var body: some View {
        TabView(selection: $store.tab) {
            ShopView()
                .updateBar()
                .tabItem { Label("Shopping", systemImage: "cart") }
                .tag(Store.Tab.shop)
            TodoView()
                .updateBar()
                .tabItem { Label("To-do", systemImage: "checklist") }
                .tag(Store.Tab.todo)
            NavigationStack { SettingsView() }
                .updateBar()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Store.Tab.settings)
        }
        .sheet(isPresented: .constant(store.me == nil)) {
            NavigationStack { WelcomeView() }.interactiveDismissDisabled()
        }
        .sheet(isPresented: Binding(get: { whatsNew != nil && store.me != nil }, set: { if !$0 { whatsNew = nil } })) {
            WhatsNewView(version: Updates.shared.version, notes: whatsNew ?? "")
        }
        .task {
            whatsNew = Updates.shared.notesForFirstLaunch()
            await Updates.shared.check()
        }
        .overlay(alignment: .bottom) { ToastView() }
        .onChange(of: store.shopTab) { _, _ in store.persist() }
        .onChange(of: store.todoFilter) { _, _ in store.persist() }
    }
}

// MARK: - Shopping

struct ShopView: View {
    @EnvironmentObject var store: Store
    @State private var editing: Item?
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Group by", selection: $store.shopTab) {
                        Text("All").tag("all")
                        Text("Day").tag("day")
                        Text("Meal").tag("meal")
                        Text("Aisle").tag("aisle")
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                if store.shopItems.isEmpty {
                    EmptyState(emoji: "🎄", title: "Nothing on the list yet", text: "Tap + to put the first item on the shared list.")
                } else {
                    ForEach(groups, id: \.title) { g in
                        Section {
                            ForEach(g.items) { i in row(i, hide: g.hide) }
                        } header: {
                            if !g.title.isEmpty { SectionHeader(title: g.title, items: g.items, word: "to buy") }
                        }
                    }
                    if store.shopTab == "aisle", store.shopItems.contains(where: { store.aisle(of: $0) == nil }), store.syncState == .offline {
                        Text("Items are sorted into aisles when the phone is online.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .refreshable {
                await store.sync()
                await store.fetchAisles(force: true)
            }
            .navigationTitle("Shopping")
            .toolbar { ListToolbar(count: store.shopItems.filter { !$0.done }.count, word: "to buy") { adding = true } }
            .sheet(item: $editing) { ItemSheet(item: $0) }
            .sheet(isPresented: $adding) { ItemSheet(item: nil) }
            .task(id: store.shopTab) { if store.shopTab == "aisle" { await store.fetchAisles() } }
        }
    }

    private func row(_ i: Item, hide: String) -> some View {
        var tags: [Tag] = []
        if !i.day.isEmpty, hide != "day" { tags.append(Tag(text: Catalog.dayNames[i.dayKey] ?? i.day, color: .blue)) }
        if !i.meal.isEmpty, hide != "meal" { tags.append(Tag(text: i.meal, color: .orange)) }
        return ItemRow(item: i, dot: i.by.isEmpty ? nil : i.color, detail: i.qty, tags: tags) { editing = i }
    }

    struct Group { let title: String; let items: [Item]; let hide: String }

    private var groups: [Group] {
        let all = store.shopItems.sorted(by: byName)
        switch store.shopTab {
        case "day":
            var g = Catalog.days.map { d in Group(title: Catalog.dayNames[d]!, items: all.filter { $0.dayKey == d }, hide: "day") }
            g.append(Group(title: "Other Days", items: all.filter { !Catalog.days.contains($0.dayKey) }, hide: ""))
            return g.filter { !$0.items.isEmpty }
        case "meal":
            var g = Catalog.meals.map { m in Group(title: m, items: all.filter { $0.meal == m }, hide: "meal") }
            g.append(Group(title: "No Meal", items: all.filter { !Catalog.meals.contains($0.meal) }, hide: "meal"))
            return g.filter { !$0.items.isEmpty }
        case "aisle":
            var g = Catalog.aisles.map { a in Group(title: a, items: all.filter { store.aisle(of: $0) == a }, hide: "") }
            let unsorted = all.filter { !Catalog.aisles.contains(store.aisle(of: $0) ?? "") }
            g.append(Group(title: store.aisleBusy ? "Sorting…" : "Not Sorted Yet", items: unsorted, hide: ""))
            return g.filter { !$0.items.isEmpty }
        default:
            return [Group(title: "", items: all, hide: "")]
        }
    }
}

func byName(_ a: Item, _ b: Item) -> Bool {
    if a.done != b.done { return !a.done }
    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
}

// MARK: - To-do

struct TodoView: View {
    @EnvironmentObject var store: Store
    @State private var editing: Item?
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Show", selection: $store.todoFilter) {
                        Text("Everyone").tag("all")
                        Text("Mine").tag("mine")
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                if visible.isEmpty {
                    EmptyState(emoji: "✅", title: store.todoFilter == "mine" ? "Nothing for you to do" : "No to-dos yet",
                               text: "Tap + to give someone a job.")
                } else {
                    ForEach(TodoSection.allCases, id: \.self) { s in
                        let list = sorted(visible.filter { TodoSection.of($0) == s }, s)
                        if !list.isEmpty {
                            Section {
                                ForEach(list) { row($0) }
                            } header: {
                                SectionHeader(title: s.rawValue, items: list, word: "to do")
                            }
                        }
                    }
                }
            }
            .refreshable { await store.sync() }
            .navigationTitle("To-do")
            .toolbar { ListToolbar(count: store.todoItems.filter { !$0.done }.count, word: "to do") { adding = true } }
            .sheet(item: $editing) { TodoSheet(todo: $0) }
            .sheet(isPresented: $adding) { TodoSheet(todo: nil) }
        }
    }

    private var visible: [Item] {
        let all = store.todoItems
        guard store.todoFilter == "mine" else { return all }
        let myName = store.me?.name ?? ""
        return all.filter { $0.assignee.isEmpty || (!myName.isEmpty && sameName($0.assignee, myName)) }
    }

    private func sorted(_ list: [Item], _ s: TodoSection) -> [Item] {
        if s == .done { return list.sorted { $0.updatedAt > $1.updatedAt } }
        return list.sorted {
            let a = $0.due.isEmpty ? "9999" : $0.due, b = $1.due.isEmpty ? "9999" : $1.due
            return a != b ? a < b : $0.name.localizedCompare($1.name) == .orderedAscending
        }
    }

    private func row(_ t: Item) -> some View {
        let c = t.assignee.isEmpty ? Catalog.anyoneColor : (t.assigneeColor.isEmpty ? store.colorFor(t.assignee) : t.assigneeColor)
        var tags = [Tag(text: t.assignee.isEmpty ? "Anyone" : firstName(t.assignee), color: Color(hex: c))]
        if !t.due.isEmpty {
            let s = TodoSection.of(t)
            let label: String
            let color: Color
            switch s {
            case .overdue: label = "Overdue · \(Day.label(t.due))"; color = .red
            case .today: label = "Today"; color = .orange
            case .tomorrow: label = "Tomorrow"; color = .blue
            default: label = Day.label(t.due); color = .secondary
            }
            tags.append(Tag(text: label, color: t.done ? .secondary : color))
        }
        return ItemRow(item: t, dot: c, detail: "", tags: tags) { editing = t }
    }
}

// MARK: - Shared pieces

struct Tag: Hashable {
    let text: String
    let color: Color
}

struct ItemRow: View {
    @EnvironmentObject var store: Store
    let item: Item
    let dot: String?
    let detail: String
    let tags: [Tag]
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button { store.toggle(item) } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(item.done ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.selection, trigger: item.done)
            .accessibilityLabel(item.done ? (item.isTodo ? "Mark as not done" : "Mark as not bought")
                : (item.isTodo ? "Mark as done" : "Mark as bought"))

            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if let dot { Circle().fill(Color(hex: dot.isEmpty ? Catalog.anyoneColor : dot)).frame(width: 9, height: 9) }
                        Text(item.name).strikethrough(item.done).foregroundStyle(item.done ? .secondary : .primary)
                        if !detail.isEmpty { Text("· \(detail)").foregroundStyle(.secondary) }
                    }
                    if !tags.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(tags, id: \.self) { t in
                                Text(t.text).font(.caption.weight(.medium))
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(t.color.opacity(0.15), in: Capsule())
                                    .foregroundStyle(t.color)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { store.remove(item) } label: { Label("Delete", systemImage: "trash") }
        }
    }
}

struct SectionHeader: View {
    let title: String
    let items: [Item]
    let word: String

    var body: some View {
        let left = items.filter { !$0.done }.count
        HStack {
            Text(title)
            Spacer()
            Text(left > 0 ? "\(left) \(word)" : "All done ✓").textCase(nil)
        }
    }
}

struct EmptyState: View {
    let emoji: String
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Text(emoji).font(.system(size: 48))
            Text(title).font(.headline)
            Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .listRowBackground(Color.clear)
    }
}

struct ListToolbar: ToolbarContent {
    @EnvironmentObject var store: Store
    let count: Int
    let word: String
    let add: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            switch store.syncState {
            case .offline: Label("Offline", systemImage: "wifi.slash").labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.orange)
            case .syncing: ProgressView().controlSize(.small)
            case .synced: Text(count > 0 ? "\(count) \(word)" : "").font(.caption).foregroundStyle(.secondary)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: add) { Image(systemName: "plus.circle.fill").font(.title2) }
                .accessibilityLabel("Add")
        }
    }
}

struct ToastView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        if let t = store.toast {
            HStack {
                Text(t.message).lineLimit(1)
                if t.undo != nil {
                    Spacer()
                    Button("Undo") { store.undo(t) }.bold()
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .foregroundStyle(.white)
            .background(.black.opacity(0.85), in: Capsule())
            .padding(.horizontal, 24).padding(.bottom, 64)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: t.id) {
                try? await Task.sleep(for: .seconds(t.undo == nil ? 1.6 : 4.5))
                withAnimation { if store.toast == t { store.toast = nil } }
            }
        }
    }
}
