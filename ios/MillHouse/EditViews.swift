import AppUpdates
import SwiftUI

// MARK: - Shopping item

struct ItemSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let item: Item?
    @State private var name = ""
    @State private var qty = ""
    @State private var day = "All"
    @State private var meal = ""
    @State private var notes = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Item", text: $name).focused($focused).submitLabel(.done).onSubmit(submit)
                    TextField("Quantity (optional)", text: $qty)
                    TextField("Notes (brand, size, where to get it…)", text: $notes, axis: .vertical).lineLimit(4...12)
                }
                Section("Day") {
                    Picker("Day", selection: $day) {
                        ForEach(Catalog.days, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("Meal (optional)") {
                    ChipRow(options: Catalog.meals, selection: $meal)
                }
                if let item {
                    Section {
                        Button("Delete Item", role: .destructive) {
                            store.remove(item)
                            dismiss()
                        }
                    } footer: {
                        ItemHistory(id: item.id).padding(.top, 8)
                    }
                }
            }
            .navigationTitle(item == nil ? "New Item" : "Edit Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(item == nil ? "Add" : "Save", action: submit).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let item {
                    name = item.name
                    qty = item.qty
                    day = Catalog.days.contains(item.dayKey) ? item.dayKey : "All"
                    meal = item.meal
                    notes = item.notes
                } else {
                    focused = true
                }
            }
        }
        .presentationDetents([.large])
    }

    private func submit() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        var base: Item
        if let item, let current = store.items[item.id] {
            base = current
        } else {
            base = Item(id: newID())
            base.createdAt = nowMillis()
            base.by = store.me?.name ?? ""
            base.color = store.me?.color ?? ""
        }
        base.name = n
        base.qty = qty.trimmingCharacters(in: .whitespaces)
        base.day = day
        base.meal = meal
        base.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        store.save(base)
        if item == nil { store.toast = .init(message: "Added “\(n)”") }
        dismiss()
    }
}

/// A one-line segmented track like the Day picker, except nothing need be chosen: tap to pick, tap again to clear.
struct ChipRow: View {
    let options: [String]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { o in
                let on = selection == o
                Button { withAnimation(.snappy(duration: 0.2)) { selection = on ? "" : o } } label: {
                    Text(o)
                        .font(.system(size: 13, weight: on ? .semibold : .medium))
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity).frame(height: 30)
                        .background(on ? Color(.systemGray3) : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color(.tertiarySystemFill), in: Capsule())
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// What has happened to an item, in small grey lines at the bottom of its screen: when and by whom it was added,
/// ticked off and last changed, which aisle it is in, and whether the change has reached the server yet.
struct ItemHistory: View {
    @EnvironmentObject var store: Store
    let id: String

    var body: some View {
        if let i = store.items[id], !i.deleted {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(lines(i), id: \.self) { Text($0) }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func lines(_ i: Item) -> [String] {
        var out: [String] = []
        let doneWord = i.isTodo ? "Done" : "Bought"
        if i.createdAt > 0 { out.append("Added \(Self.when(i.createdAt))\(by(i.by))") }
        if i.done {
            out.append(i.doneAt > 0 ? "\(doneWord) \(Self.when(i.doneAt))\(by(i.doneBy))"
                                    : "\(doneWord) (before times were recorded)")
        }
        // Last change, when it is not just the adding or the ticking off.
        let last = max(i.createdAt, i.doneAt)
        if i.updatedAt - last > 60_000 { out.append("Last changed \(Self.when(i.updatedAt))\(by(i.editedBy))") }
        if !i.isTodo, let aisle = store.aisle(of: i) { out.append("Aisle: \(aisle)") }
        if store.outbox[i.id] != nil { out.append("Not synced yet: saved on this phone, sends when online") }
        return out
    }

    private func by(_ name: String) -> String { name.isEmpty ? "" : " by \(firstName(name))" }

    /// "today at 14:02", "yesterday at 09:10", "Mon 23 Nov at 14:02"
    static func when(_ ms: Int64) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "HH:mm"
        let time = f.string(from: d)
        if Calendar.current.isDateInToday(d) { return "today at \(time)" }
        if Calendar.current.isDateInYesterday(d) { return "yesterday at \(time)" }
        f.dateFormat = Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year) ? "EEE d MMM" : "EEE d MMM yyyy"
        return "\(f.string(from: d)) at \(time)"
    }
}

// MARK: - To-do

// MARK: - Settings and welcome

struct NameAndColour: View {
    @EnvironmentObject var store: Store
    @Binding var name: String
    @Binding var color: String

    var body: some View {
        Section("Your name") {
            TextField("Name", text: $name).textContentType(.givenName)
        }
        Section("Your colour") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                ForEach(Catalog.colors, id: \.self) { c in
                    Circle().fill(Color(hex: c)).frame(width: 36, height: 36)
                        .overlay(Circle().strokeBorder(.primary, lineWidth: c == color ? 3 : 0))
                        .onTapGesture { color = c }
                        .accessibilityLabel("Colour \(c)")
                }
            }
            .padding(.vertical, 6)
            .sensoryFeedback(.selection, trigger: color)
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject var store: Store
    @State private var name = ""
    @State private var color = ""

    var body: some View {
        Form {
            Section {
                Text("Your name shows next to the things you add, so everyone knows who added what.")
                    .foregroundStyle(.secondary)
            }
            NameAndColour(name: $name, color: $color)
        }
        .navigationTitle("Welcome 🎄")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { store.setMe(name: name, color: color) }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear { if color.isEmpty { color = store.colorFor("") } }
        .onChange(of: name) { _, n in color = store.colorFor(n) }
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var push: Push
    /// Whether the Netlify server has its APNs keys (GET /api/apns); nil until known.
    @State private var serverReady: Bool?

    var body: some View {
        Form {
            if AppUpdater.shared.available != nil {
                Section { UpdateRow(AppUpdater.shared) }
            }
            Section {
                NavigationLink { AccountView() } label: {
                    HStack(spacing: 12) {
                        Circle().fill(Color(hex: store.me?.color ?? Catalog.anyoneColor)).frame(width: 28, height: 28)
                            .overlay(Text(String((store.me?.name ?? "?").prefix(1))).font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Account")
                            Text(store.me?.name ?? "Not set").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                if push.status == .denied {
                    LabeledContent("Notifications", value: "Blocked")
                    Button("Allow in the Settings app") {
                        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                    }
                } else {
                    Toggle("Notifications", isOn: notificationsOn)
                    if notificationsOn.wrappedValue {
                        Toggle(isOn: $push.shopping) {
                            Text("Shopping")
                            Text("When someone adds to the list")
                        }
                        Toggle(isOn: $push.todos) {
                            Text("To-dos")
                            Text("When someone gives you one, and at 8am when yours are due")
                        }
                    }
                }
            } header: {
                Text("Notifications")
            } footer: {
                if serverReady == false {
                    Text("The server can't send iPhone notifications yet: its Apple push key (APNs) isn't set up in Netlify. The 8am due reminders still work, because the phone schedules those itself.")
                        .foregroundStyle(.orange)
                }
            }
            Section {
                NavigationLink { DebugView() } label: { Label("Debug", systemImage: "ladybug") }
                LabeledContent("Version", value: AppInfo.version)
            }
        }
        .navigationTitle("Settings")
        .task {
            await push.refreshStatus()
            struct Status: Decodable { let configured: Bool }
            serverReady = (try? await API.get("/api/apns") as Status)?.configured
        }
    }

    private var notificationsOn: Binding<Bool> {
        Binding(
            get: { [.authorized, .provisional, .ephemeral].contains(push.status) },
            set: { on in
                Task {
                    if on {
                        if await push.enable(store: store) { store.toast = .init(message: "Notifications on") }
                    } else {
                        await push.disable()
                        store.toast = .init(message: "Notifications off")
                    }
                }
            })
    }
}

/// Your name and colour, which mark what you add and the to-dos given to you.
struct AccountView: View {
    @EnvironmentObject var store: Store
    @State private var name = ""
    @State private var color = ""

    var body: some View {
        Form {
            NameAndColour(name: $name, color: $color)
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            name = store.me?.name ?? ""
            color = store.me?.color ?? store.colorFor(name)
        }
        .onChange(of: color) { _, c in
            if store.me != nil, c != store.me?.color, !name.isEmpty { store.setMe(name: name, color: c) }
        }
        .onSubmit(saveName)
        .onDisappear(perform: saveName)
    }

    private func saveName() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n != store.me?.name else { return }
        store.setMe(name: n, color: color)
        store.toast = .init(message: "Name saved")
    }
}

/// Housekeeping and numbers: clearing ticked-off items, sync state, and the Claude API usage of the aisle sorter.
struct DebugView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var push: Push
    @State private var confirmShop = false
    @State private var confirmTodos = false
    @State private var usage: Usage?
    @State private var usageError = false

    struct Totals: Decodable {
        let calls: Int
        let input: Int
        let output: Int
        let cacheRead: Int
        let cacheWrite: Int
        let cost: Double
        let since: Double?
        let lastModel: String?
    }
    struct Usage: Decodable {
        let month: Totals
        let all: Totals
        let monthKey: String
    }

    var body: some View {
        Form {
            Section {
                let shopDone = store.shopItems.filter(\.done).count
                let todoDone = store.todoItems.filter(\.done).count
                Button(shopDone > 0 ? "Clear \(shopDone) Bought Item\(shopDone > 1 ? "s" : "")" : "No Bought Items", role: .destructive) {
                    confirmShop = true
                }
                .disabled(shopDone == 0)
                .confirmationDialog("Remove \(shopDone) bought item\(shopDone > 1 ? "s" : "") from the list for everyone?",
                                    isPresented: $confirmShop, titleVisibility: .visible) {
                    Button("Remove", role: .destructive) { store.clearDone(todos: false) }
                }
                Button(todoDone > 0 ? "Clear \(todoDone) Done To-do\(todoDone > 1 ? "s" : "")" : "No Done To-dos", role: .destructive) {
                    confirmTodos = true
                }
                .disabled(todoDone == 0)
                .confirmationDialog("Remove \(todoDone) done to-do\(todoDone > 1 ? "s" : "") for everyone?",
                                    isPresented: $confirmTodos, titleVisibility: .visible) {
                    Button("Remove", role: .destructive) { store.clearDone(todos: true) }
                }
            } header: {
                Text("List")
            } footer: {
                Text("Removes them for everyone, on every phone and the web.")
            }

            Section {
                if let u = usage {
                    totals("This month", u.month)
                    totals("All time", u.all)
                } else if usageError {
                    Text("Couldn't load usage from the server.").foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            } header: {
                Text("Claude API usage")
            } footer: {
                Text("Tokens the server spends sorting shopping into Sainsbury's aisles (Claude Opus 5.5, $4 in / $20 out per million tokens). Costs are estimates from list prices. Counted since this screen was added.")
            }

            Section {
                Button("Send a Test Notification") {
                    Task { store.toast = .init(message: await push.test() ?? "Test sent") }
                }
                .disabled(![.authorized, .provisional, .ephemeral].contains(push.status))
            } header: {
                Text("Notifications")
            } footer: {
                Text("Sends a notification to this phone through the server and Apple, to check the whole path works.")
            }

            Section("Sync") {
                LabeledContent("Status", value: "\(store.syncState)")
                LabeledContent("Waiting to send", value: "\(store.outbox.count)")
                LabeledContent("Items on this phone", value: "\(store.live.count)")
            }
        }
        .navigationTitle("Debug")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            usage = try await API.get("/api/usage")
            usageError = false
        } catch {
            usageError = true
        }
    }

    @ViewBuilder private func totals(_ title: String, _ t: Totals) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(t.cost, format: .currency(code: "USD").precision(.fractionLength(2...4))).font(.headline)
            }
            Text("\(t.calls) call\(t.calls == 1 ? "" : "s") · \(fmt(t.input)) in · \(fmt(t.output)) out")
                .font(.footnote).foregroundStyle(.secondary)
            if t.cacheRead + t.cacheWrite > 0 {
                Text("Cache: \(fmt(t.cacheRead)) read · \(fmt(t.cacheWrite)) written").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func fmt(_ n: Int) -> String { n.formatted(.number.notation(.compactName)) + " tokens" }
}
