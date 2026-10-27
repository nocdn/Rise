import AppKit
import RiseCore

@MainActor extension BrowserController {
    func submitAssistantPrompt(_ request: AssistantPrompt) {
        let tab = addTab(url: request.service.entryURL)
        assistantSubmissions.removeValue(forKey: tab.id)?.cancel()
        let submission = AssistantPromptSubmission()
        assistantSubmissions[tab.id] = submission
        let page = tab.page, id = tab.id
        submission.start(request, url: { [weak page] in page?.isLoading == true ? nil : page?.url }, evaluate: { [weak page] script, arguments in
            guard let page else { return nil }
            return try? await page.evaluate(script, arguments: arguments, in: nil, world: .named(AssistantPromptSubmission.world)) as? String
        }, completion: { [weak self] outcome in
            guard let self else { return }
            assistantSubmissions[id] = nil
            guard outcome == .unavailable || outcome == .draft else { return }
            let copy = BarNotice.Link(text: "Copy prompt") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(request.text, forType: .string)
            }
            selectedBar.showNotice(outcome == .draft ? "Kept your \(request.service.name) draft" : "Couldn’t send to \(request.service.name)",
                                   image: BarNotice.warningImage, link: copy, hold: 8)
        })
    }
}
