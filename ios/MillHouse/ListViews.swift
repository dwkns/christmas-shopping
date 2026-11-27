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
    @StateObject private var popups = Popups()

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
        .overlay { PopupHost() }
        .environmentObject(popups)
        .onChange(of: store.shopTab) { _, _ in store.persist() }
        .onChange(of: store.todoFilter) { _, _ in store.persist() }
        .onChange(of: store.todoGroup) { _, _ in store.persist() }
        .onChange(of: store.todoSort) { _, _ in store.persist() }
    }
}

// MARK: - Shopping

struct ShopView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var popups: Popups
    @Environment(\.scenePhase) private var phase
    /// The item open as a card, edited here and saved when it closes (the to-do pattern).
    @State private var draft: Item?
    @State private var isNew = false
    /// Where the open card is on screen, so a tap anywhere else closes it.
    @State private var cardFrame: CGRect = .zero
    @FocusState private var nameFocused: Bool
    private var boughtCount: Int { store.shopItems.filter(\.done).count }

    @ViewBuilder private var moreMenu: some View {
        Button { store.archiveDone(todos: false) } label: {
            Label(boughtCount > 0 ? "Archive \(boughtCount) Bought" : "Nothing Bought to Archive", systemImage: "archivebox")
        }
        .disabled(boughtCount == 0)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                List {
                    if isNew, draft != nil { Section { card } }
                    if store.shopItems.isEmpty, draft == nil {
                        EmptyState(emoji: "🎄", title: "Nothing on the list yet", text: "Tap + to put the first item on the shared list.")
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(groups, id: \.title) { g in
                            Section {
                                ForEach(g.items) { i in
                                    if !isNew, draft?.id == i.id { card } else { row(i, hide: g.hide) }
                                }
                            } header: {
                                if !g.title.isEmpty { SectionHeader(title: g.title, items: g.items, word: "to buy") }
                            }
                        }
                        if store.shopTab == "aisle", store.shopItems.contains(where: { store.aisle(of: $0) == nil }), store.syncState == .offline {
                            Text("Items are sorted into aisles when the phone is online.").font(.footnote).foregroundStyle(.secondary)
                                .listRowSeparator(.hidden)
                        }
                    }
                    Section { ArchiveLink(todos: false) }
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, Look.rowHeight)
                .scrollDismissesKeyboard(.interactively)
                .safeAreaInset(edge: .top, spacing: 0) {
                    SubTabs(selection: $store.shopTab, options: [("all", "All"), ("day", "Day"), ("meal", "Meal"), ("aisle", "Aisle")])
                        .padding(.horizontal, 16).padding(.bottom, 6).background(.bar)
                }
                .navigationBarTitleDisplayMode(.inline)
                .refreshable {
                    await store.sync()
                    await store.fetchAisles(force: true)
                }
                .animation(.snappy(duration: 0.25), value: draft?.id)

                if draft == nil {
                    AddButton(label: "New item", action: add)
                }
            }
            .simultaneousGesture(SpatialTapGesture(coordinateSpace: .global).onEnded { v in
                if draft != nil, !cardFrame.contains(v.location) { close() }
            }, isEnabled: draft != nil)
            .toolbar {
                CompactHeader(title: "Shopping", count: store.shopItems.filter { !$0.done }.count, word: "to buy",
                              done: draft == nil ? nil : { close() }, add: nil, more: AnyView(moreMenu))
            }
            .task(id: store.shopTab) { if store.shopTab == "aisle" { await store.fetchAisles() } }
        }
        .onChange(of: phase) { _, p in if p != .active { close() } }
        .onDisappear { close() }
    }

    @ViewBuilder private var card: some View {
        if let d = draft {
            ShopCard(item: Binding(get: { draft ?? d }, set: { draft = $0 }), focus: $nameFocused,
                     onDay: { nameFocused = false; popups.show(.day(d.id)) },
                     onMeal: { nameFocused = false; popups.show(.meal(d.id)) },
                     onDelete: delete, onSubmit: close)
                .onAppear { popups.editing = $draft }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { cardFrame = $0 }
        }
    }

    private func add() {
        close()
        var i = Item(id: newID())
        i.createdAt = nowMillis()
        i.by = store.me?.name ?? ""
        i.color = store.me?.color ?? ""
        i.day = "All"
        isNew = true
        draft = i
        nameFocused = true
    }

    private func open(_ i: Item) {
        isNew = false
        draft = i
    }

    /// Saves the open card if anything changed; a new one with no name is dropped.
    private func close() {
        guard var d = draft else { return }
        nameFocused = false
        d.name = d.name.trimmingCharacters(in: .whitespacesAndNewlines)
        d.qty = d.qty.trimmingCharacters(in: .whitespaces)
        d.notes = d.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let old = store.items[d.id]
        if d.name.isEmpty { d.name = isNew ? "" : (old?.name ?? "") }
        if !d.name.isEmpty, isNew || (old != nil && old != d) {
            store.save(d)
            if isNew { store.toast = .init(message: "Added “\(d.name)”") }
        }
        withAnimation(.snappy(duration: 0.25)) {
            draft = nil
            isNew = false
        }
    }

    private func delete() {
        if let d = draft, !isNew { store.remove(d) }
        draft = nil
        isNew = false
    }

    private func row(_ i: Item, hide: String) -> some View {
        var tags: [Tag] = []
        if !i.day.isEmpty, hide != "day" { tags.append(Tag(text: Catalog.dayNames[i.dayKey] ?? i.day, color: Look.accent)) }
        if !i.meal.isEmpty, hide != "meal" { tags.append(Tag(text: i.meal, color: Look.green)) }
        return ItemRow(item: i, dot: i.by.isEmpty ? nil : i.color, detail: i.qty, tags: tags) { open(i) }
            .opacity(draft == nil ? 1 : 0.45)
            .allowsHitTesting(draft == nil) // while a card is open, a tap here only closes it
    }

    struct Group { let title: String; let items: [Item]; let hide: String }

    /// The sections, with any where everything is bought moved to the bottom (in their usual order).
    private var groups: [Group] {
        let g = rawGroups
        let complete = { (x: Group) in !x.items.isEmpty && x.items.allSatisfy(\.done) }
        return g.filter { !complete($0) } + g.filter(complete)
    }

    private var rawGroups: [Group] {
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

/// Three pull-down menus in a row above the to-do list: who to show, how to group, how to sort.
struct TodoControls: View {
    @EnvironmentObject var store: Store
    let names: [String]

    var body: some View {
        HStack(spacing: 8) {
            control("Show", "person.2", $store.todoFilter, [("all", "Everyone"), ("mine", "Mine")]
                    + shown.map { ($0, firstName($0)) } + [("anyone", "Unassigned")])
            control("Organise by", "square.stack.3d.up", $store.todoGroup, [("person", "Person"), ("due", "Due"), ("none", "None")])
            control("Sort by", "arrow.up.arrow.down", $store.todoSort, [("due", "Due date"), ("added", "Newest"), ("name", "A–Z")])
        }
        .sensoryFeedback(.selection, trigger: store.todoFilter + store.todoGroup + store.todoSort)
        // "Mine" covers my own name, so a filter saved as my name becomes Mine.
        .onAppear { if let me = store.me?.name, !me.isEmpty, sameName(store.todoFilter, me) { store.todoFilter = "mine" } }
    }

    /// The other people (Mine covers me), plus the one chosen before, so the menu still names them once their to-dos
    /// are all gone.
    private var shown: [String] {
        let f = store.todoFilter, me = store.me?.name ?? ""
        let others = names.filter { me.isEmpty || !sameName($0, me) }
        return ["all", "mine", "anyone"].contains(f) || others.contains(where: { sameName($0, f) }) ? others : others + [f]
    }

    private func control(_ label: String, _ icon: String, _ value: Binding<String>, _ options: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.leading, 10)
                .accessibilityHidden(true)
            menu(label, icon, value, options)
        }
    }

    private func menu(_ label: String, _ icon: String, _ value: Binding<String>, _ options: [(String, String)]) -> some View {
        Menu {
            Section(label) {
                Picker(label, selection: value) {
                    ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.inline)
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .accessibilityLabel(label)
                Text(options.first { $0.0 == value.wrappedValue }?.1 ?? options[0].1).lineLimit(1).minimumScaleFactor(0.85)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10).frame(height: 30).frame(maxWidth: .infinity)
            .background(Color(.tertiarySystemFill), in: Capsule())
        }
        .tint(.primary)
    }
}

// MARK: - Shared pieces

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
    /// When set, the right-hand button is Done (a to-do card is open) instead of +.
    var done: (() -> Void)? = nil
    let add: (() -> Void)?
    /// The items of a ••• menu at the top right, when there is no open card.
    var more: AnyView? = nil

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 22, weight: .bold)).kerning(0.35).fixedSize()
                SyncDot(state: store.syncState)
                if count > 0 { Text("\(count) \(word)").font(.system(size: 13)).foregroundStyle(.secondary).fixedSize() }
            }
        }
        .sharedBackgroundVisibility(.hidden) // plain text, not a glass capsule
        if let done {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done", action: done).fontWeight(.semibold)
            }
        } else if let more {
            ToolbarItem(placement: .topBarTrailing) {
                Menu { more } label: { Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold)) }
                    .accessibilityLabel("More")
            }
        } else if let add {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: add) { Image(systemName: "plus").font(.system(size: 17, weight: .semibold)) }
                    .accessibilityLabel("Add")
            }
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
    /// Shows the tick for a moment before the item slides down to the bottom, so you see what happened.
    @State private var ticking = false

    private func tick() {
        guard !item.done else { return withAnimation(.snappy(duration: 0.4)) { store.toggle(item) } }
        ticking = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            withAnimation(.snappy(duration: 0.45)) { store.toggle(item) }
            ticking = false
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: tick) { CheckCircle(done: item.done || ticking) }
                .buttonStyle(.plain)
                .sensoryFeedback(.selection, trigger: item.done)
                .accessibilityLabel(item.done ? (item.isTodo ? "Mark as not done" : "Mark as not bought")
                    : (item.isTodo ? "Mark as done" : "Mark as bought"))

            Button(action: onEdit) {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
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
                    // Notes under the name, so they can be read while shopping.
                    if !item.notes.isEmpty {
                        Text(item.notes).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
                            .padding(.leading, dot == nil ? 0 : Look.dot + 7)
                    }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .listRowInsets(Look.rowInsets)
        // Dividers run the full width of the card, 12 pt in from each side, not from under the name.
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
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
