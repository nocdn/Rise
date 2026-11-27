import AppIntents
import UIKit

struct GetCurrentTabURLIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Current Tab URL"
    static let description = IntentDescription("Returns the full web address of the current tab while Rise is onscreen.")

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<URL?> {
        let browser = UIApplication.shared.connectedScenes.lazy.compactMap { scene -> BrowserViewController? in
            guard let windowScene = scene as? UIWindowScene,
                  windowScene.activationState == .foregroundActive || windowScene.activationState == .foregroundInactive
            else { return nil }

            return windowScene.keyWindow?.rootViewController as? BrowserViewController
        }.first

        return .result(value: browser?.shareableURL)
    }
}

struct RiseAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetCurrentTabURLIntent(),
            phrases: ["Get the current tab URL in \(.applicationName)"],
            shortTitle: "Current Tab URL",
            systemImageName: "link"
        )
    }
}
