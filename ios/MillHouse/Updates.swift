import AppUpdates
import SwiftUI

/// Over-the-air updates: the shared AppUpdates package (~/Developer/AppUpdates), as in YouPods and Lifts. The release
/// lives on Netlify at /updates/ (netlify/functions/updates.mjs), where scripts/release-ios.sh puts it.
extension AppUpdater {
    /// "Xmas List", the public name for now (docs/ios-plan.md), so the bar names the app as the Home Screen does.
    @MainActor static let shared = AppUpdater(.init(appName: "Xmas List", releaseURL: UpdateConfig.releaseURL,
                                                    installURL: UpdateConfig.installURL))
}

enum UpdateConfig {
    static let releaseURL = Store.baseURL.appendingPathComponent("updates/release")
    static let installURL = URL(string:
        "itms-services://?action=download-manifest&url=https://christmas-shopping-uovm.netlify.app/updates/manifest.plist")!
}

extension View {
    /// The update bar just above the tab bar on every tab (a system TabView, so the bar goes inside each tab).
    func updateBar() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            UpdateBar(AppUpdater.shared)
                .padding(.bottom, 8)
                .animation(.snappy, value: AppUpdater.shared.available)
        }
    }
}
