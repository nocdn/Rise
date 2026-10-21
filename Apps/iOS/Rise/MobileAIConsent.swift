import UIKit

/// Explicit permission at the network boundary, independently of the default-on AI toggle.
@MainActor final class MobileAIConsent {
    typealias Prompt = @MainActor (AIProvider) async throws -> Bool
    static let shared = MobileAIConsent()
    private let settings: MobileAISettings
    private let prompt: Prompt

    init(settings: MobileAISettings = .shared, prompt: Prompt? = nil) {
        self.settings = settings
        self.prompt = prompt ?? { provider in try await AISharingPrompt(provider: provider).show() }
    }

    func authorize(_ provider: AIProvider) async throws {
        try Task.checkCancellation()
        guard settings.enabled else { throw CancellationError() }
        if settings.hasSharingConsent(for: provider) { return }
        let revision = settings.consentRevision
        guard try await prompt(provider) else { throw CancellationError() }
        try Task.checkCancellation()
        // A setting changed while the prompt was open in another window, or permission
        // was withdrawn. That older prompt must never silently grant it again.
        guard settings.enabled, settings.consentRevision == revision else { throw CancellationError() }
        settings.allowSharing(with: provider)
    }

    static func disclosure(for provider: AIProvider) -> String {
        let recipient = provider == .openRouter ? "OpenRouter and the model provider it routes to (currently OpenAI)" : "OpenAI"
        return "When you use Ask or Summarise, Rise sends this page’s readable text, selection, title and full URL, plus your questions and conversation context, to \(recipient) to generate an answer. This may include personal or sensitive information, including on private tabs.\n\nYour API key authenticates requests to \(provider.title). The provider’s privacy and retention policies apply.\n\nAllow future AI requests to this provider? You can withdraw permission in Settings → Privacy Policy, or by turning AI features off."
    }
}

/// One prompt owns its continuation and dismisses itself if its requesting task goes away.
/// If another alert already occupies the window, fail closed instead of sending anything.
@MainActor private final class AISharingPrompt {
    private let provider: AIProvider
    private var continuation: CheckedContinuation<Bool, Error>?
    private var alert: UIAlertController?
    private var cancelled = false

    init(provider: AIProvider) { self.provider = provider }

    func show() async throws -> Bool {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard let presenter = Self.presenter(), !(presenter is UIAlertController),
                      !presenter.isBeingDismissed else {
                    continuation.resume(throwing: CancellationError()); return
                }
                self.continuation = continuation
                let alert = UIAlertController(title: "Share page data with \(provider.title)?",
                    message: MobileAIConsent.disclosure(for: provider), preferredStyle: .alert)
                self.alert = alert
                alert.addAction(UIAlertAction(title: "Don’t Allow", style: .cancel) { [self] _ in finish(false) })
                alert.addAction(UIAlertAction(title: "Privacy Policy", style: .default) { [self, weak presenter, weak alert] _ in
                    finish(false)
                    alert?.dismiss(animated: true) {
                        let browser = presenter as? BrowserViewController
                            ?? presenter?.view.window?.rootViewController as? BrowserViewController
                        browser?.showPrivacyPolicy()
                    }
                })
                alert.addAction(UIAlertAction(title: "Allow", style: .default) { [self] _ in finish(true) })
                presenter.present(alert, animated: true) { [self, weak alert] in
                    // UIKit ignores a dismissal partway through presentation. If the
                    // request was cancelled then, finish dismissing after it settles.
                    if cancelled { alert?.dismiss(animated: true) }
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.cancelled = true
                if self.alert?.isBeingPresented == false { self.alert?.dismiss(animated: true) }
                self.finish(false)
            }
        }
    }

    private func finish(_ allowed: Bool) {
        let waiting = continuation
        continuation = nil
        alert = nil
        waiting?.resume(returning: allowed)
    }

    private static func presenter() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive && $0.windows.contains(where: \.isKeyWindow) }),
              var top = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}
