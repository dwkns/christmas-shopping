import SwiftUI
import UIKit
import UserNotifications

/// APNs: asks permission, registers the device token with POST /api/apns, opens the right tab when a notification is
/// tapped. The server sends the same three events as web push (netlify/lib/push.mjs).
@MainActor
final class Push: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = Push()

    @Published private(set) var status: UNAuthorizationStatus = .notDetermined
    @Published private(set) var token: String?
    weak var store: Store?

    /// Which notifications this phone wants, saved on the phone and sent to the server with the device token.
    /// New shopping is off unless turned on; to-dos (given to you, and the 8am due reminder) are on unless turned off.
    @Published var shopping: Bool = UserDefaults.standard.bool(forKey: "notify.shopping") {
        didSet { UserDefaults.standard.set(shopping, forKey: "notify.shopping"); sendPrefs() }
    }
    @Published var todos: Bool = UserDefaults.standard.object(forKey: "notify.todos") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(todos, forKey: "notify.todos")
            sendPrefs()
            if let store { Task { await DueReminders.reschedule(todos: store.todoItems, me: store.me?.name ?? "") } }
        }
    }
    nonisolated static var todosWanted: Bool { UserDefaults.standard.object(forKey: "notify.todos") as? Bool ?? true }

    private func sendPrefs() {
        guard let token, let name = store?.me?.name else { return }
        Task { _ = try? await post(register(token, name)) }
    }

    private func register(_ token: String, _ name: String) -> [String: Any] {
        ["action": "register", "token": token, "name": name, "env": Self.environment, "shopping": shopping, "todos": todos]
    }

    /// "sandbox" for development-signed builds (all of ours), "production" for App Store ones: read from the
    /// provisioning profile, which the simulator does not have.
    static let environment: String = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let r = text.range(of: #"<key>aps-environment</key>\s*<string>(\w+)</string>"#, options: .regularExpression)
        else { return "sandbox" }
        return text[r].contains("production") ? "production" : "sandbox"
    }()

    func refreshStatus() async {
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Ask (the Turn On button). Returns whether notifications are allowed.
    func enable(store: Store) async -> Bool {
        self.store = store
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshStatus()
        if granted {
            UIApplication.shared.registerForRemoteNotifications()
            await DueReminders.reschedule(todos: store.todoItems, me: store.me?.name ?? "")
        }
        return granted
    }

    /// On launch and after a name change: re-register when already allowed, so the server has the current name.
    func registerIfAllowed(store: Store) async {
        self.store = store
        await refreshStatus()
        if status == .authorized || status == .provisional { UIApplication.shared.registerForRemoteNotifications() }
    }

    func disable() async {
        if let token { _ = try? await post(["action": "unregister", "token": token]) }
        UIApplication.shared.unregisterForRemoteNotifications()
        token = nil
        // Off means off: the morning reminders go too (the system permission stays, so remove them here).
        let center = UNUserNotificationCenter.current()
        let due = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(DueReminders.prefix) }
        center.removePendingNotificationRequests(withIdentifiers: due)
    }

    func didRegister(_ deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        token = hex
        guard let name = store?.me?.name else { return }
        Task { _ = try? await post(register(hex, name)) }
    }

    /// Sends a test notification to this phone. Returns the server's message when it fails.
    func test() async -> String? {
        guard let token else { return "This phone has no notification token yet. Turn notifications off and on." }
        do {
            let (ok, error) = try await post(["action": "test", "token": token])
            return ok ? nil : (error ?? "The test failed.")
        } catch {
            return "Could not reach the server."
        }
    }

    private func post(_ body: [String: Any]) async throws -> (Bool, String?) {
        var req = URLRequest(url: Store.baseURL.appendingPathComponent("/api/apns"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return ((json?["ok"] as? Bool) ?? false, json?["error"] as? String)
    }

    // Show notifications while the app is open too.
    nonisolated func userNotificationCenter(_: UNUserNotificationCenter, willPresent _: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound, .list] }

    nonisolated func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let view = response.notification.request.content.userInfo["view"] as? String
        await MainActor.run {
            if let view, let tab = Store.Tab(rawValue: view) { store?.tab = tab }
            Task { await store?.sync() }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = Push.shared
        return true
    }

    func application(_: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in Push.shared.didRegister(deviceToken) }
    }

    func application(_: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("APNs registration failed:", error.localizedDescription)
    }
}

@main
struct MillHouseApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = Store()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(Push.shared)
                .task { await Push.shared.registerIfAllowed(store: store) }
        }
        .onChange(of: phase) { _, p in
            if p == .active { store.startPolling() } else { store.stopPolling(); store.persist() }
        }
    }
}

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt64(s, radix: 16) ?? 0x8E8E93
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

enum AppInfo {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
}
