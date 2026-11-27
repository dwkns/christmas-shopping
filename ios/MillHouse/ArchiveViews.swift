import SwiftUI

/// The link at the bottom of a list to its archived items.
struct ArchiveLink: View {
    @EnvironmentObject var store: Store
    let todos: Bool

    var body: some View {
        let n = store.archivedItems(todos: todos).count
        NavigationLink {
            ArchiveView(todos: todos)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "archivebox").foregroundStyle(.secondary)
                Text("Archived").foregroundStyle(.secondary)
                if n > 0 { Text("\(n)").foregroundStyle(.tertiary) }
            }
            .font(.system(size: 15, weight: .medium))
        }
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 14, leading: 18, bottom: 90, trailing: 16)) // clear of the + and the tab bar
    }
}

/// Everything this phone has archived from one list, newest ticked-off first, with search and a Recent or month filter.
struct ArchiveView: View {
    @EnvironmentObject var store: Store
    let todos: Bool
    @State private var search = ""
    /// "recent" (last 30 days) or "yyyy-MM".
    @State private var period = "recent"

    var body: some View {
        List {
            if shown.isEmpty {
                Text(search.isEmpty ? (period == "recent" ? "Nothing archived in the last 30 days." : "Nothing archived this month.")
                                    : "Nothing matches “\(search)”.")
                    .foregroundStyle(.secondary).listRowSeparator(.hidden)
            }
            ForEach(byDay, id: \.day) { g in
                Section {
                    ForEach(g.items) { row($0) }
                } header: {
                    Text(g.day).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search archived")
        .safeAreaInset(edge: .top, spacing: 0) { periodPicker.padding(.horizontal, 16).padding(.bottom, 6).background(.bar) }
        .navigationTitle(todos ? "Archived To-dos" : "Archived Shopping")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Filter

    private var periodPicker: some View {
        HStack(spacing: 8) {
            pill("Recent", on: period == "recent") { period = "recent" }
            Menu {
                Picker("Month", selection: $period) {
                    ForEach(months, id: \.self) { Text(Self.monthName($0)).tag($0) }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "calendar").font(.system(size: 12, weight: .semibold))
                    Text(period == "recent" ? "Month" : Self.monthName(period))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 12).frame(height: 32)
                .background(period == "recent" ? Color(.tertiarySystemFill) : Color(.systemGray3), in: Capsule())
            }
            .disabled(months.isEmpty)
            Spacer()
            Text("\(shown.count) item\(shown.count == 1 ? "" : "s")").font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }

    private func pill(_ text: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.system(size: 14, weight: on ? .semibold : .medium)).foregroundStyle(.primary)
                .padding(.horizontal, 14).frame(height: 32)
                .background(on ? Color(.systemGray3) : Color(.tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var all: [Item] { store.archivedItems(todos: todos).sorted { Self.doneTime($0) > Self.doneTime($1) } }

    /// The months with archived items, newest first.
    private var months: [String] {
        var out: [String] = []
        for i in all { let m = Self.ymd(Self.doneTime(i)).prefix(7); if !out.contains(String(m)) { out.append(String(m)) } }
        return out
    }

    private var shown: [Item] {
        let cutoff = nowMillis() - 30 * 24 * 3600 * 1000
        let q = search.trimmingCharacters(in: .whitespaces)
        return all.filter { i in
            let t = Self.doneTime(i)
            let inPeriod = period == "recent" ? t >= cutoff : Self.ymd(t).hasPrefix(period)
            let matches = q.isEmpty || [i.name, i.notes, i.qty, i.meal, i.whoText, i.doneBy].contains { $0.localizedCaseInsensitiveContains(q) }
            // A search looks through everything archived, not just the chosen period.
            return q.isEmpty ? inPeriod : matches
        }
    }

    private var byDay: [(day: String, items: [Item])] {
        var out: [(day: String, items: [Item])] = []
        for i in shown {
            let d = Self.dayName(Self.doneTime(i))
            if let k = out.firstIndex(where: { $0.day == d }) { out[k].items.append(i) } else { out.append((d, [i])) }
        }
        return out
    }

    // MARK: Rows

    private func row(_ i: Item) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                Text(i.name).font(.system(size: 16))
                if !i.qty.isEmpty { Text(" · \(i.qty)").font(.system(size: 16)).foregroundStyle(.secondary) }
            }
            if !i.notes.isEmpty { Text(i.notes).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2) }
            Text(detail(i)).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { store.remove(i) } label: { Label("Delete", systemImage: "trash") }
            Button { withAnimation { store.unarchive(i) } } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                .tint(.blue)
        }
        .contextMenu {
            Button { withAnimation { store.unarchive(i) } } label: { Label("Restore to List", systemImage: "arrow.uturn.backward") }
            Button(role: .destructive) { store.remove(i) } label: { Label("Delete for Everyone", systemImage: "trash") }
        }
    }

    private func detail(_ i: Item) -> String {
        var parts: [String] = []
        let word = todos ? "Done" : "Bought"
        let t = Self.doneTime(i)
        parts.append("\(word) \(ItemHistory.when(t))" + (i.doneBy.isEmpty ? "" : " by \(firstName(i.doneBy))"))
        if todos { parts.append("for \(i.whoText)") }
        else {
            if Catalog.days.contains(i.dayKey), i.dayKey != "All" { parts.append(Catalog.dayNames[i.dayKey] ?? i.day) }
            if !i.meal.isEmpty { parts.append(i.meal) }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Dates

    /// When it was ticked off; older items without that use their last change.
    static func doneTime(_ i: Item) -> Int64 { i.doneAt > 0 ? i.doneAt : i.updatedAt }

    static func ymd(_ ms: Int64) -> String { Day.ymd(Date(timeIntervalSince1970: TimeInterval(ms) / 1000)) }

    static func dayName(_ ms: Int64) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        if Calendar.current.isDateInToday(d) { return "Today" }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year) ? "EEEE d MMMM" : "EEEE d MMMM yyyy"
        return f.string(from: d)
    }

    static func monthName(_ ym: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "yyyy-MM"
        guard let d = f.date(from: ym) else { return ym }
        f.dateFormat = "MMMM yyyy"
        return f.string(from: d)
    }
}
