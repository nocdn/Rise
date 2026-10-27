import UIKit
import WebKit

@MainActor extension BrowserViewController {
    func submitAssistantPrompt(_ request: AssistantPrompt, in page: WKWebView) {
        let key = ObjectIdentifier(page)
        assistantSubmissions.removeValue(forKey: key)?.cancel()
        let submission = AssistantPromptSubmission()
        assistantSubmissions[key] = submission
        submission.start(request, url: { [weak page] in page?.isLoading == true ? nil : page?.url }, evaluate: { [weak page] script, arguments in
            guard let page else { return nil }
            return try? await page.runScript(script, arguments: arguments, world: AssistantPromptSubmission.world) as? String
        }, completion: { [weak self, weak page] outcome in
            guard let self else { return }
            assistantSubmissions[key] = nil
            guard page === webView, outcome == .draft || outcome == .unavailable else { return }
            let alert = UIAlertController(title: outcome == .draft ? "Kept your \(request.service.name) draft" : "Couldn’t send to \(request.service.name)",
                                          message: "You can copy your prompt and send it when the chat is ready.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Copy Prompt", style: .default) { _ in UIPasteboard.general.string = request.text })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            present(alert, animated: true)
        })
    }
}
