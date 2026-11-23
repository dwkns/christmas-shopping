import Foundation
import Observation
import SwiftUI
import UIKit

struct Release: Decodable, Equatable {
    let version: String
    let notes: String?
}

/// Over-the-air updates, copied from YouPods (~/Developer/youpods/ios/YouPods/Updates.swift): the same bar, banner,
/// install hand-off and What's New. The release lives on Netlify at /updates/ (netlify/functions/updates.mjs), where
/// scripts/release-ios.sh puts it.
@MainActor
@Observable
final class Updates {
    static let shared = Updates()

    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    private(set) var available: Release?
    private(set) var installing = false

    func check() async {
        var request = URLRequest(url: UpdateConfig.releaseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("MillHouse/\(version)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data) else { return }
        available = release.version.compare(version, options: .numeric) == .orderedDescending ? release : nil
        if let available, let notes = available.notes {
            UserDefaults.standard.set([available.version, notes], forKey: "pendingNotes")
        }
    }

    #if DEBUG
    /// Screenshots: pretend a newer version is waiting.
    func pretend(_ version: String) { available = Release(version: version, notes: "A pretend update, for the screenshot.") }
    #endif

    /// What's new in this version, once, on its first launch: the notes saved when the update was offered.
    func notesForFirstLaunch() -> String? {
        let defaults = UserDefaults.standard
        let last = defaults.string(forKey: "lastLaunchedVersion")
        defaults.set(version, forKey: "lastLaunchedVersion")
        guard let last, last != version,
              let saved = defaults.stringArray(forKey: "pendingNotes"), saved.count == 2, saved[0] == version else { return nil }
        defaults.removeObject(forKey: "pendingNotes")
        return saved[1]
    }

    /// Hand the install to iOS, then go to the Home Screen: iOS replaces the app only once it is off screen (as Lift
    /// does). The install prompt makes the app resign active and come back when it is answered; step aside at that
    /// moment. Listening for the notifications, not polling the state, so a quickly answered prompt is not missed
    /// (polling missed it and fell back to a 15 second wait, 0.1.3 to 0.1.6). If no prompt shows, step aside after 6s.
    func install() {
        installing = true
        UIApplication.shared.open(UpdateConfig.installURL)
        let nc = NotificationCenter.default
        var resigned = false
        var tokens: [NSObjectProtocol] = []
        let stepAside = { [weak self] in
            tokens.forEach(nc.removeObserver)
            tokens.removeAll()
            self?.installing = false
            guard UIApplication.shared.applicationState != .background else { return }
            UIControl().sendAction(#selector(URLSessionTask.suspend), to: UIApplication.shared, for: nil)
        }
        tokens.append(nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            resigned = true
        })
        tokens.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            if resigned { MainActor.assumeIsolated { stepAside() } }
        })
        tokens.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                tokens.forEach(nc.removeObserver)
                tokens.removeAll()
                self.installing = false
            }
        })
        Task {
            try? await Task.sleep(for: .seconds(6))
            if !tokens.isEmpty, !resigned { stepAside() }
        }
    }
}

/// "What's New", shown once after an update.
struct WhatsNewView: View {
    let version: String
    let notes: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.tint)
            Text("What’s New in \(version)").font(.title2.bold())
            VStack(alignment: .leading, spacing: 10) {
                ForEach(notes.split(separator: "\n").map(String.init), id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle().fill(.tint).frame(width: 6, height: 6).offset(y: -2)
                        Text(line).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 0)
            Button { dismiss() } label: { Text("Continue").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .padding(28)
        .presentationDetents([.medium, .large])
    }
}

/// The update offer, as a row: shown at the top of Settings when there is one.
struct UpdateBanner: View {
    @State private var updates = Updates.shared

    var body: some View {
        if let release = updates.available {
            Button { updates.install() } label: {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.app.fill").font(.title2).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Update to \(release.version)").font(.headline).foregroundStyle(.primary)
                        if let notes = release.notes, !notes.isEmpty {
                            Text(notes).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                    Spacer()
                    if updates.installing { ProgressView() } else { Text("Install").font(.subheadline.bold()) }
                }
            }
            .disabled(updates.installing)
        }
    }
}

/// The update offer on every screen: a full-width bar just above the tab bar while a newer version is waiting.
struct UpdateBar: View {
    @State private var updates = Updates.shared

    var body: some View {
        if let release = updates.available {
            Button { updates.install() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.app.fill").font(.title3)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Xmas List \(release.version) is ready").font(.subheadline.weight(.semibold))
                        Text("You’re on \(updates.version)").font(.caption).opacity(0.85)
                    }
                    Spacer(minLength: 8)
                    if updates.installing {
                        ProgressView().tint(.white)
                    } else {
                        Text("Install")
                            .font(.subheadline.weight(.bold))
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(.white.opacity(0.25), in: Capsule())
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(.tint, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(updates.installing)
            .padding(.horizontal, 14)
            .accessibilityLabel("Install Xmas List \(release.version)")
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

enum UpdateConfig {
    nonisolated static let releaseURL = Store.baseURL.appendingPathComponent("updates/release")
    nonisolated static let installURL = URL(string:
        "itms-services://?action=download-manifest&url=https://christmas-shopping-uovm.netlify.app/updates/manifest.plist")!
}

extension View {
    /// The update bar above the tab bar, on every tab, as in YouPods.
    func updateBar() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            UpdateBar()
                .padding(.bottom, 8)
                .animation(.snappy, value: Updates.shared.available)
        }
    }
}
