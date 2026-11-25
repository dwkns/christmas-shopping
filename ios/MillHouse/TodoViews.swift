import SwiftUI

// The to-do tab, laid out like Things: plain rows with a square check box; tapping a row opens it in place as a card
// with the title, notes, and two controls, When and Who, which open pop-ups over the whole screen (Popups, below).

struct TodoView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var popups: Popups
    @Environment(\.scenePhase) private var phase
    /// The to-do open as a card, edited here and saved when it closes.
    @State private var draft: Item?
    @State private var isNew = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                List {
                    if isNew, draft != nil { Section { card } }
                    if visible.isEmpty, draft == nil {
                        EmptyState(emoji: "✅", title: store.todoFilter == "all" ? "No to-dos yet" : "Nothing here to do",
                                   text: "Tap + to give someone a job.")
                            .listRowSeparator(.hidden)
                    }
                    ForEach(groups, id: \.title) { g in
                        Section {
                            ForEach(g.items) { t in
                                if !isNew, draft?.id == t.id { card } else { row(t) }
                            }
                        } header: {
                            SectionHeader(title: g.title, items: g.items, word: "to do")
                        }
                    }
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 36)
                .scrollDismissesKeyboard(.interactively)
                .safeAreaInset(edge: .top, spacing: 0) {
                    TodoControls(names: assignees).padding(.horizontal, 16).padding(.bottom, 6).background(.bar)
                }
                .navigationBarTitleDisplayMode(.inline)
                .refreshable { await store.sync() }
                .animation(.snappy(duration: 0.25), value: draft?.id)

                if draft == nil {
                    Button(action: add) {
                        Image(systemName: "plus").font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 58, height: 58)
                            .background(Look.accent, in: Circle())
                            .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                    }
                    .padding(.trailing, 20).padding(.bottom, 16)
                    .accessibilityLabel("New to-do")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .toolbar {
                CompactHeader(title: "To-do", count: store.todoItems.filter { !$0.done }.count, word: "to do",
                              done: draft == nil ? nil : { close() }, add: nil)
            }
        }
        .onChange(of: phase) { _, p in if p != .active { close() } }
        .onDisappear { close() }
    }

    // MARK: Rows

    private func row(_ t: Item) -> some View {
        TodoRow(item: t, showWho: t.done || store.todoGroup != "person")
            .contentShape(Rectangle())
            .onTapGesture { draft == nil ? open(t) : close() }
            .opacity(draft == nil ? 1 : 0.45)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) { store.remove(t) } label: { Label("Delete", systemImage: "trash") }
            }
    }

    @ViewBuilder private var card: some View {
        if let d = draft {
            TodoCard(item: Binding(get: { draft ?? d }, set: { draft = $0 }), focus: $titleFocused,
                     onWhen: { titleFocused = false; popups.show(.when(d.id)) },
                     onWho: { titleFocused = false; popups.show(.who(d.id)) },
                     onDelete: delete, onSubmit: close)
                .onAppear { popups.editing = $draft }
        }
    }

    // MARK: Opening and saving

    private func add() {
        close()
        var t = Item(id: newID(), type: "todo")
        t.createdAt = nowMillis()
        t.by = store.me?.name ?? ""
        t.color = store.me?.color ?? ""
        if store.todoFilter == "anyone" {
            t.assignee = ""
        } else {
            let who = ["all", "mine"].contains(store.todoFilter) ? (store.me?.name ?? "") : store.todoFilter
            t.assignee = who
            t.assigneeColor = who.isEmpty ? "" : store.colorFor(who)
        }
        isNew = true
        draft = t
        titleFocused = true
    }

    private func open(_ t: Item) {
        isNew = false
        draft = t
    }

    /// Saves the open card if anything changed; a new one with no title is dropped.
    private func close() {
        guard var d = draft else { return }
        titleFocused = false
        d.name = d.name.trimmingCharacters(in: .whitespacesAndNewlines)
        d.notes = d.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let old = store.items[d.id]
        if d.name.isEmpty { d.name = isNew ? "" : (old?.name ?? "") }
        if !d.name.isEmpty, isNew || (old != nil && old != d) { store.save(d) }
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

    // MARK: Showing, grouping and sorting

    /// Everyone with a to-do, me first then A–Z.
    private var assignees: [String] {
        let myName = store.me?.name ?? ""
        var names: [String] = []
        for t in store.todoItems where !t.assignee.isEmpty && !names.contains(where: { sameName($0, t.assignee) }) {
            names.append(t.assignee)
        }
        return names.sorted { a, b in
            let am = !myName.isEmpty && sameName(a, myName), bm = !myName.isEmpty && sameName(b, myName)
            return am != bm ? am : a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
    }

    private var visible: [Item] {
        let all = store.todoItems
        let myName = store.me?.name ?? ""
        switch store.todoFilter {
        case "all": return all
        case "mine": return all.filter { $0.assignee.isEmpty || (!myName.isEmpty && sameName($0.assignee, myName)) }
        case "anyone": return all.filter { $0.assignee.isEmpty }
        case let name: return all.filter { sameName($0.assignee, name) }
        }
    }

    /// Sections from the Group control, each sorted by the Sort control; ticked-off to-dos always go in Done at the
    /// bottom, newest first.
    private var groups: [(title: String, items: [Item])] {
        let open = visible.filter { !$0.done }
        var out: [(title: String, items: [Item])] = []
        switch store.todoGroup {
        case "person":
            for n in assignees {
                let list = open.filter { sameName($0.assignee, n) }
                if !list.isEmpty { out.append((firstName(n), sorted(list))) }
            }
            let anyone = open.filter { $0.assignee.isEmpty }
            if !anyone.isEmpty { out.append(("Unassigned", sorted(anyone))) }
        case "due":
            for s in TodoSection.allCases where s != .done {
                let list = open.filter { TodoSection.of($0) == s }
                if !list.isEmpty { out.append((s.rawValue, sorted(list))) }
            }
        default:
            if !open.isEmpty { out.append(("To do", sorted(open))) }
        }
        let done = visible.filter(\.done).sorted { $0.updatedAt > $1.updatedAt }
        if !done.isEmpty { out.append(("Done", done)) }
        return out
    }

    private func sorted(_ list: [Item]) -> [Item] {
        let byName: (Item, Item) -> Bool = { $0.name.localizedCompare($1.name) == .orderedAscending }
        switch store.todoSort {
        case "added": return list.sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : byName($0, $1) }
        case "name": return list.sorted(by: byName)
        default:
            // Dated first by date, then Soon, then No rush, then nothing set.
            func key(_ t: Item) -> String { t.due.isEmpty ? (t.when == "soon" ? "a" : t.when == "norush" ? "b" : "c") : t.due }
            return list.sorted { key($0) != key($1) ? key($0) < key($1) : byName($0, $1) }
        }
    }
}

// MARK: - When

/// What a to-do's When control shows: an icon, a word or date, and a colour; nil when nothing is set.
struct WhenLabel {
    let icon: String
    let text: String
    let color: Color

    static let star = Color(red: 0.98, green: 0.80, blue: 0.18)

    init?(_ t: Item) {
        let today = Day.today()
        if !t.due.isEmpty {
            if t.due < today, !t.done { icon = "exclamationmark.circle.fill"; text = "Overdue · \(Day.label(t.due))"; color = .red }
            else if t.due == today { icon = "star.fill"; text = "Today"; color = Self.star }
            else if t.due == Day.addDays(1) { icon = "sunrise.fill"; text = "Tomorrow"; color = .orange }
            else { icon = "calendar"; text = Day.label(t.due); color = .secondary }
        } else if t.when == "soon" { icon = "clock.fill"; text = "Soon"; color = .blue }
        else if t.when == "norush" { icon = "tortoise.fill"; text = "No rush"; color = .green }
        else { return nil }
    }
}

// MARK: - Row and card

/// Things' square check box, green and ticked when done.
struct CheckBox: View {
    let done: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(done ? Look.green : Color(.tertiaryLabel), lineWidth: 1.8)
            if done {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Look.green)
                Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundStyle(.white)
            }
        }
        .frame(width: 22, height: 22)
        .contentShape(Rectangle().inset(by: -10))
        .animation(.easeOut(duration: 0.15), value: done)
    }
}

/// One to-do as a plain line: check box, title, a notes mark, then When and (when the section doesn't say) Who.
struct TodoRow: View {
    @EnvironmentObject var store: Store
    let item: Item
    let showWho: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button { store.toggle(item) } label: { CheckBox(done: item.done) }
                .buttonStyle(.plain)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
                .sensoryFeedback(.selection, trigger: item.done)
                .accessibilityLabel(item.done ? "Mark as not done" : "Mark as done")
            Flow(spacing: 6, lineSpacing: 3) {
                Text(item.name).font(.system(size: 17)).strikethrough(item.done)
                    .foregroundStyle(item.done ? .secondary : .primary)
                if !item.notes.isEmpty {
                    Image(systemName: "doc.text").font(.system(size: 13)).foregroundStyle(.secondary)
                        .padding(.top, 3)
                }
                if let w = WhenLabel(item), !item.done { WhenTag(label: w) }
                if showWho { WhoTag(item: item) }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .listRowInsets(EdgeInsets(top: 5, leading: 18, bottom: 5, trailing: 16))
        .listRowSeparator(.hidden)
    }
}

struct WhenTag: View {
    let label: WhenLabel

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: label.icon).font(.system(size: 10)).foregroundStyle(label.color)
            Text(label.text).font(.system(size: 12, weight: .medium))
                .foregroundStyle(label.color == .secondary ? Color.secondary : label.color)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.top, 2)
    }
}

struct WhoTag: View {
    @EnvironmentObject var store: Store
    let item: Item

    var body: some View {
        let c = item.assignee.isEmpty ? Catalog.anyoneColor
            : (item.assigneeColor.isEmpty ? store.colorFor(item.assignee) : item.assigneeColor)
        TagView(tag: Tag(text: item.assignee.isEmpty ? "Unassigned" : firstName(item.assignee), color: Color(hex: c)))
            .padding(.top, 2)
    }
}

/// The open to-do, as in Things: title, notes, then When and Who on the bottom line with delete at the end.
struct TodoCard: View {
    @EnvironmentObject var store: Store
    @Binding var item: Item
    var focus: FocusState<Bool>.Binding
    let onWhen: () -> Void
    let onWho: () -> Void
    let onDelete: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button { item.done.toggle() } label: { CheckBox(done: item.done) }
                    .buttonStyle(.plain)
                TextField("New To-Do", text: $item.name)
                    .font(.system(size: 18, weight: .medium))
                    .focused(focus)
                    .submitLabel(.done)
                    .onSubmit(onSubmit)
            }
            TextField("Notes", text: $item.notes, axis: .vertical)
                .font(.system(size: 16))
                .lineLimit(2...10)
                .foregroundStyle(.secondary)
                .padding(.leading, 34)
            HStack(spacing: 8) {
                chip(action: onWhen) {
                    if let w = WhenLabel(item) {
                        Image(systemName: w.icon).foregroundStyle(w.color)
                        Text(w.text)
                    } else {
                        Image(systemName: "calendar").foregroundStyle(.secondary)
                        Text("When").foregroundStyle(.secondary)
                    }
                }
                chip(action: onWho) {
                    let c = item.assignee.isEmpty ? Catalog.anyoneColor
                        : (item.assigneeColor.isEmpty ? store.colorFor(item.assignee) : item.assigneeColor)
                    Circle().fill(Color(hex: c)).frame(width: 9, height: 9)
                    Text(item.assignee.isEmpty ? "Unassigned" : firstName(item.assignee))
                }
                Spacer()
                Button(action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 17)).foregroundStyle(.red)
                        .frame(width: 40, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete to-do")
            }
            .padding(.leading, 28)
            ItemHistory(id: item.id).padding(.leading, 34).padding(.top, 2)
        }
        .padding(.horizontal, 14).padding(.vertical, 14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .listRowInsets(EdgeInsets(top: 6, leading: 4, bottom: 10, trailing: 4))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private func chip<L: View>(action: @escaping () -> Void, @ViewBuilder label: () -> L) -> some View {
        Button(action: action) {
            HStack(spacing: 6) { label() }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 10).frame(height: 34)
                .background(Color(.tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Pop-ups

/// The When and Who pop-ups: a full-width card in the middle of the screen over a dimmed app, shown by RootView so it
/// covers the tab bar too. `editing` points at the open card's draft, which the pop-ups change.
@MainActor final class Popups: ObservableObject {
    enum Kind: Equatable { case when(String), who(String) }
    @Published var kind: Kind?
    var editing: Binding<Item?>?

    func show(_ k: Kind) { withAnimation(.snappy(duration: 0.22)) { kind = k } }
    func hide() { withAnimation(.snappy(duration: 0.18)) { kind = nil } }
}

struct PopupHost: View {
    @EnvironmentObject var popups: Popups

    var body: some View {
        ZStack {
            if let kind = popups.kind, let draft = popups.editing {
                Color.black.opacity(0.45).ignoresSafeArea()
                    .onTapGesture { popups.hide() }
                    .transition(.opacity)
                Group {
                    switch kind {
                    case .when: WhenPopup(item: draft, close: popups.hide)
                    case .who: WhoPopup(item: draft, close: popups.hide)
                    }
                }
                .padding(.horizontal, 10)
                .transition(.scale(scale: 0.94).combined(with: .opacity))
            }
        }
    }
}

struct PopupCard<Content: View>: View {
    let title: String
    let close: () -> Void
    var back: (() -> Void)?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Text(title).font(.system(size: 17, weight: .semibold))
                HStack {
                    if let back { round("chevron.left", back).accessibilityLabel("Back") }
                    Spacer()
                    round("xmark", close).accessibilityLabel("Close")
                }
            }
            .padding(.bottom, 4)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
    }

    private func round(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background(Color(.tertiarySystemFill), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

/// One line in a pop-up list: icon, words, and a tick when it is the current choice.
struct PopupRow<Icon: View>: View {
    let text: String
    let on: Bool
    let action: () -> Void
    @ViewBuilder let icon: Icon

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                icon.frame(width: 26)
                Text(text).font(.system(size: 18, weight: .medium)).foregroundStyle(.primary)
                Spacer()
                if on { Image(systemName: "checkmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(.tint) }
            }
            .padding(.horizontal, 8).frame(height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct WhenPopup: View {
    @Binding var item: Item?
    let close: () -> Void
    /// Months ahead of this one shown in the calendar.
    @State private var page = 0

    var body: some View {
        let t = item ?? Item(id: "")
        PopupCard(title: "When?", close: close) {
            VStack(spacing: 0) {
                PopupRow(text: "Today", on: t.due == Day.today(), action: { set(Day.today(), "") }) {
                    Image(systemName: "star.fill").foregroundStyle(WhenLabel.star)
                }
                PopupRow(text: "Tomorrow", on: t.due == Day.addDays(1), action: { set(Day.addDays(1), "") }) {
                    Image(systemName: "sunrise.fill").foregroundStyle(.orange)
                }
                PopupRow(text: "Soon", on: t.due.isEmpty && t.when == "soon", action: { set("", "soon") }) {
                    Image(systemName: "clock.fill").foregroundStyle(.blue)
                }
                PopupRow(text: "No rush", on: t.due.isEmpty && t.when == "norush", action: { set("", "norush") }) {
                    Image(systemName: "tortoise.fill").foregroundStyle(.green)
                }
            }
            MonthGrid(page: $page, selected: t.due) { set($0, "") }
                .padding(.vertical, 4)
            if !t.due.isEmpty || !t.when.isEmpty {
                Button { set("", "") } label: {
                    Text("Clear").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .background(Color(red: 0.76, green: 0.20, blue: 0.32), in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .sensoryFeedback(.selection, trigger: page)
    }

    private func set(_ due: String, _ when: String) {
        item?.due = due
        item?.when = when
        close()
    }
}

/// One month at a time, Monday first, with the month and year between ‹ and › at the top. Days before today are
/// greyed out, today is a star, the chosen day is filled. It starts at this month (or the chosen day's) and cannot go
/// back before it.
struct MonthGrid: View {
    @Binding var page: Int
    let selected: String
    let pick: (String) -> Void

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2
        c.locale = Locale(identifier: "en_GB")
        return c
    }

    var body: some View {
        let month = self.month
        let today = Day.today()
        VStack(spacing: 2) {
            HStack {
                arrow("chevron.left", enabled: page > 0) { page -= 1 }.accessibilityLabel("Previous month")
                Spacer()
                Text(month.formatted(.dateTime.month(.wide).year())).font(.system(size: 17, weight: .semibold))
                    .contentTransition(.numericText())
                Spacer()
                arrow("chevron.right", enabled: page < 24) { page += 1 }.accessibilityLabel("Next month")
            }
            .padding(.bottom, 2)
            HStack(spacing: 0) {
                ForEach(["M", "T", "W", "T", "F", "S", "S"].indices, id: \.self) { i in
                    Text(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][i]).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 2)
            let cells = self.cells(month)
            ForEach(0..<(cells.count / 7), id: \.self) { w in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { d in cell(cells[w * 7 + d], today: today) }
                }
            }
        }
        .gesture(DragGesture(minimumDistance: 30).onEnded { v in
            if v.translation.width < -40, page < 24 { withAnimation(.snappy) { page += 1 } }
            if v.translation.width > 40, page > 0 { withAnimation(.snappy) { page -= 1 } }
        })
        .onAppear {
            // Open on the chosen day's month.
            if let d = Day.date(selected) {
                let now = cal.dateComponents([.year, .month], from: Date())
                let sel = cal.dateComponents([.year, .month], from: d)
                page = max(0, min(24, (sel.year! - now.year!) * 12 + sel.month! - now.month!))
            }
        }
    }

    private func arrow(_ icon: String, enabled: Bool, _ go: @escaping () -> Void) -> some View {
        Button { withAnimation(.snappy) { go() } } label: {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 36)
                .background(Color(.tertiarySystemFill), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .primary : .quaternary)
        .disabled(!enabled)
    }

    /// The first of the month on show.
    private var month: Date {
        let first = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
        return cal.date(byAdding: .month, value: page, to: first)!
    }

    /// Whole weeks covering the month; nil for days of the months either side.
    private func cells(_ month: Date) -> [Date?] {
        let count = cal.range(of: .day, in: .month, for: month)!.count
        let lead = (cal.component(.weekday, from: month) + 5) % 7 // Monday = 0
        var out: [Date?] = Array(repeating: nil, count: lead)
        out += (0..<count).map { cal.date(byAdding: .day, value: $0, to: month)! }
        while out.count % 7 != 0 { out.append(nil) }
        return out
    }

    @ViewBuilder private func cell(_ date: Date?, today: String) -> some View {
        if let date {
            let ymd = Day.ymd(date)
            let past = ymd < today
            let on = ymd == selected
            Button { pick(ymd) } label: {
                ZStack {
                    if on { Circle().fill(Color.accentColor).frame(width: 38, height: 38) }
                    if ymd == today {
                        Image(systemName: "star.fill").font(.system(size: 17)).foregroundStyle(on ? .white : WhenLabel.star)
                    } else {
                        Text("\(cal.component(.day, from: date))").font(.system(size: 17, weight: .medium))
                            .foregroundStyle(on ? AnyShapeStyle(.white) : past ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.primary))
                    }
                }
                .frame(maxWidth: .infinity).frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(past)
        } else {
            Color.clear.frame(maxWidth: .infinity).frame(height: 40)
        }
    }
}

struct WhoPopup: View {
    @EnvironmentObject var store: Store
    @Binding var item: Item?
    let close: () -> Void
    @State private var other = ""
    @FocusState private var otherFocused: Bool

    var body: some View {
        let t = item ?? Item(id: "")
        PopupCard(title: "Who?", close: close) {
            ViewThatFits(in: .vertical) {
                list(t)
                ScrollView { list(t) }.frame(maxHeight: 520)
            }
        }
    }

    private func list(_ t: Item) -> some View {
        VStack(spacing: 0) {
            ForEach(store.people(), id: \.name) { p in
                let mine = store.me.map { sameName($0.name, p.name) } == true
                PopupRow(text: firstName(p.name) + (mine ? " (me)" : ""), on: !t.assignee.isEmpty && sameName(t.assignee, p.name),
                         action: { set(p.name) }) {
                    Circle().fill(Color(hex: p.color.isEmpty ? store.colorFor(p.name) : p.color)).frame(width: 14, height: 14)
                }
            }
            PopupRow(text: "Unassigned", on: t.assignee.isEmpty, action: { set("") }) {
                Circle().fill(Color(hex: Catalog.anyoneColor)).frame(width: 14, height: 14)
            }
            HStack(spacing: 12) {
                Image(systemName: "plus").font(.system(size: 17, weight: .semibold)).foregroundStyle(.secondary).frame(width: 26)
                TextField("Someone else", text: $other)
                    .font(.system(size: 18, weight: .medium))
                    .focused($otherFocused)
                    .submitLabel(.done)
                    .onSubmit { addOther() }
                if !other.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button("Add", action: addOther).font(.system(size: 17, weight: .semibold))
                }
            }
            .padding(.horizontal, 8).frame(height: 46)
        }
    }

    private func addOther() {
        let n = other.split(separator: " ").joined(separator: " ")
        guard !n.isEmpty else { return }
        set(n)
    }

    private func set(_ name: String) {
        guard var t = item else { return close() }
        let keep = sameName(t.assignee, name) && !t.assigneeColor.isEmpty
        t.assigneeColor = name.isEmpty ? "" : (keep ? t.assigneeColor : store.colorFor(name))
        t.assignee = name
        item = t
        close()
    }
}
