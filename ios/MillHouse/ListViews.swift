import AppUpdates
import SwiftUI

/// Sizes and colours from the web app (public/style.css), so the lists look as tight as they did there.
enum Look {
    static let accent = Color("AccentColor")                 // --accent #d1242f
    static let green = Color(red: 0x1F / 255, green: 0x8A / 255, blue: 0x4C / 255) // --green #1f8a4c
    static let rowHeight: CGFloat = 40                       // .row min-height
    static let rowInsets = EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12)
    static let check: CGFloat = 24                           // .check
    static let dot: CGFloat = 8                              // .who
}

struct RootView: View {
    @EnvironmentObject var store: Store

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
        // What's New, the launch and foreground checks and polling; the bar itself is placed in each tab (updateBar()).
        .appUpdates(AppUpdater.shared, bar: false)
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
            TightList {
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
                            .listRowBackground(Color.clear)
                    }
                }
            } top: {
                SubTabs(selection: $store.shopTab, options: [("all", "All"), ("day", "Day"), ("meal", "Meal"), ("aisle", "Aisle")])
            }
            .refreshable {
                await store.sync()
                await store.fetchAisles(force: true)
            }
            .toolbar { CompactHeader(title: "Shopping", count: store.shopItems.filter { !$0.done }.count, word: "to buy") { adding = true } }
            .sheet(item: $editing) { ItemSheet(item: $0) }
            .sheet(isPresented: $adding) { ItemSheet(item: nil) }
            .task(id: store.shopTab) { if store.shopTab == "aisle" { await store.fetchAisles() } }
        }
    }

    private func row(_ i: Item, hide: String) -> some View {
        var tags: [Tag] = []
        if !i.day.isEmpty, hide != "day" { tags.append(Tag(text: Catalog.dayNames[i.dayKey] ?? i.day, color: Look.accent)) }
        if !i.meal.isEmpty, hide != "meal" { tags.append(Tag(text: i.meal, color: Look.green)) }
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
            TightList {
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
            } top: {
                SubTabs(selection: $store.todoFilter, options: [("all", "Everyone"), ("mine", "Mine")])
            }
            .refreshable { await store.sync() }
            .toolbar { CompactHeader(title: "To-do", count: store.todoItems.filter { !$0.done }.count, word: "to do") { adding = true } }
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
            let label: String
            let color: Color
            switch TodoSection.of(t) {
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

/// An inset list with the web app's spacing: 40 pt rows, 12 pt side padding, small gaps between sections, and the
/// sub-tabs pinned above it.
struct TightList<Content: View, Top: View>: View {
    @ViewBuilder let content: Content
    @ViewBuilder let top: Top

    var body: some View {
        List { content }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .environment(\.defaultMinListRowHeight, Look.rowHeight)
            .contentMargins(.top, 4, for: .scrollContent)
            .safeAreaInset(edge: .top, spacing: 0) {
                top.padding(.horizontal, 16).padding(.bottom, 6).background(.bar)
            }
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// The web app's segmented sub-tabs (.subtabs): 13 pt, a light fill, the chosen one raised.
struct SubTabs: View {
    @Binding var selection: String
    let options: [(String, String)]

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// The web app's nav row: a 22 pt bold title on the left with the sync dot and count beside it, + on the right.
struct CompactHeader: ToolbarContent {
    @EnvironmentObject var store: Store
    let title: String
    let count: Int
    let word: String
    let add: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 22, weight: .bold)).kerning(0.35).fixedSize()
                SyncDot(state: store.syncState)
                if count > 0 { Text("\(count) \(word)").font(.system(size: 13)).foregroundStyle(.secondary).fixedSize() }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: add) { Image(systemName: "plus") .font(.system(size: 17, weight: .semibold)) }
                .accessibilityLabel("Add")
        }
    }
}

struct SyncDot: View {
    let state: Store.SyncState

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
                .opacity(state == .syncing ? 0.5 : 1)
                .animation(state == .syncing ? .easeInOut(duration: 0.5).repeatForever() : .default, value: state)
            Text(label).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch state {
        case .synced: Look.green
        case .syncing: .secondary
        case .offline: .orange
        }
    }

    private var label: String {
        switch state {
        case .synced: "Synced"
        case .syncing: "Syncing"
        case .offline: "Offline"
        }
    }
}

struct Tag: Hashable {
    let text: String
    let color: Color
}

/// One row as on the web (.row): check circle, then the name, quantity and tags on one line that wraps when it must.
struct ItemRow: View {
    @EnvironmentObject var store: Store
    let item: Item
    let dot: String?
    let detail: String
    let tags: [Tag]
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button { store.toggle(item) } label: { CheckCircle(done: item.done) }
                .buttonStyle(.plain)
                .sensoryFeedback(.selection, trigger: item.done)
                .accessibilityLabel(item.done ? (item.isTodo ? "Mark as not done" : "Mark as not bought")
                    : (item.isTodo ? "Mark as done" : "Mark as bought"))

            Button(action: onEdit) {
                HStack(spacing: 6) {
                    Flow(spacing: 6, lineSpacing: 2) {
                        HStack(spacing: 0) {
                            if let dot {
                                Circle().fill(Color(hex: dot.isEmpty ? Catalog.anyoneColor : dot))
                                    .frame(width: Look.dot, height: Look.dot).padding(.trailing, 7)
                            }
                            Text(item.name).font(.system(size: 16)).strikethrough(item.done)
                                .foregroundStyle(item.done ? .secondary : .primary)
                            if !detail.isEmpty { Text(" · \(detail)").font(.system(size: 16)).foregroundStyle(.secondary) }
                        }
                        ForEach(tags, id: \.self) { TagView(tag: $0) }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .listRowInsets(Look.rowInsets)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { store.remove(item) } label: { Label("Delete", systemImage: "trash") }
        }
    }
}

struct CheckCircle: View {
    let done: Bool

    var body: some View {
        ZStack {
            Circle().strokeBorder(done ? Look.green : Color(.tertiaryLabel), lineWidth: 2)
            if done {
                Circle().fill(Look.green)
                Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundStyle(.white)
            }
        }
        .frame(width: Look.check, height: Look.check)
        .contentShape(Rectangle().inset(by: -8))
        .animation(.easeOut(duration: 0.15), value: done)
    }
}

/// .tag: 11 pt medium, 1x6 padding, 8 pt corners, the colour at 12–15 % behind it.
struct TagView: View {
    let tag: Tag

    var body: some View {
        Text(tag.text)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(tag.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .foregroundStyle(tag.color)
            .lineLimit(1)
    }
}

/// Lays children out left to right, wrapping onto a new line when the row is full (CSS flex-wrap).
struct Flow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for (i, size) in zip(row.indices, row.sizes) {
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var sizes: [CGSize] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            var size = subviews[i].sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var r = rows[rows.count - 1]
            r.width += (r.indices.isEmpty ? 0 : spacing) + size.width
            r.height = max(r.height, size.height)
            r.indices.append(i)
            r.sizes.append(size)
            rows[rows.count - 1] = r
        }
        return rows
    }
}

/// .section-header: 13 pt capitals, the count of what is left on the right.
struct SectionHeader: View {
    let title: String
    let items: [Item]
    let word: String

    var body: some View {
        let left = items.filter { !$0.done }.count
        HStack {
            Text(title)
            Spacer()
            Text(left > 0 ? "\(left) \(word)" : "All done ✓")
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 4, trailing: 12))
    }
}

struct EmptyState: View {
    let emoji: String
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 6) {
            Text(emoji).font(.system(size: 56))
            Text(title).font(.system(size: 20, weight: .semibold))
            Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .listRowBackground(Color.clear)
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
