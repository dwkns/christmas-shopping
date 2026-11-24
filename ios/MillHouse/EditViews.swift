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
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Item", text: $name).focused($focused).submitLabel(.done).onSubmit(submit)
                    TextField("Quantity (optional)", text: $qty)
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
                if item != nil {
                    Section {
                        Button("Delete Item", role: .destructive) {
                            if let item { store.remove(item) }
                            dismiss()
                        }
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
        store.save(base)
        if item == nil { store.toast = .init(message: "Added “\(n)”") }
        dismiss()
    }
}

/// Tap to pick, tap again to clear.
struct ChipRow: View {
    let options: [String]
    @Binding var selection: String

    var body: some View {
        HStack {
            ForEach(options, id: \.self) { o in
                Button(o) { selection = selection == o ? "" : o }
                    .buttonStyle(.bordered)
                    .tint(selection == o ? .accentColor : .secondary)
                    .font(.subheadline)
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
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
    @State private var name = ""
    @State private var color = ""
    @State private var confirmShop = false
    @State private var confirmTodos = false

    var body: some View {
        Form {
            if AppUpdater.shared.available != nil {
                Section { UpdateRow(AppUpdater.shared) }
            }
            NameAndColour(name: $name, color: $color)
            Section {
                switch push.status {
                case .denied:
                    Text("Notifications are blocked. Allow them for Xmas List in the Settings app.")
                    Button("Open Settings") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                case .authorized, .provisional, .ephemeral:
                    Button("Send a Test Notification") {
                        Task { store.toast = .init(message: await push.test() ?? "Test sent") }
                    }
                    Button("Turn Off Notifications", role: .destructive) {
                        Task { await push.disable(); store.toast = .init(message: "Notifications off") }
                    }
                default:
                    Button("Turn On Notifications") {
                        Task { if await push.enable(store: store) { store.toast = .init(message: "Notifications on") } }
                    }
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("Get told when someone adds shopping, when someone gives you a to-do, and at 8am when your to-dos are due.")
            }
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
            }
            Section {
                LabeledContent("Version", value: AppInfo.version)
            }
        }
        .navigationTitle("Settings")
        .onAppear {
            name = store.me?.name ?? ""
            color = store.me?.color ?? store.colorFor(name)
            Task { await push.refreshStatus() }
        }
        .onChange(of: color) { _, c in
            if store.me != nil, c != store.me?.color, !name.isEmpty { store.setMe(name: name, color: c) }
        }
        .onSubmit {
            if !name.trimmingCharacters(in: .whitespaces).isEmpty { store.setMe(name: name, color: color); store.toast = .init(message: "Name saved") }
        }
    }
}
