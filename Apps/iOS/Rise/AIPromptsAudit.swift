#if DEBUG
import UIKit

/// Walks Settings → AI options → each prompt in the real toolbar: saving, leaving without saving,
/// and Hold to reset, let go early and held through. Prompts the device already had come back after.
@MainActor enum AIPromptsAudit {
    static let argument = "-RiseAIPromptsAudit"
    struct Failure: Error { let name: String }
    static func run(in browser: BrowserViewController) {
        Task {
            let folder = URL.cachesDirectory.appendingPathComponent("AIPromptsAudit")
            try? FileManager.default.removeItem(at: folder)
            let saved = AIPrompt.allCases.map { ($0, $0.isCustom ? $0.text : nil) }
            defer { for (prompt, text) in saved { if let text { prompt.save(text) } else { prompt.reset() } } }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try await exercise(browser, folder: folder)
                try "Passed".write(to: folder.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
            } catch {
                try? String(describing: error).write(to: folder.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8)
            }
        }
    }

    private static func exercise(_ browser: BrowserViewController, folder: URL) async throws {
        var checks: [String: Bool] = [:]
        func check(_ name: String, _ valid: Bool) throws {
            checks[name] = valid
            try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("checks.json"))
            if !valid { throw Failure(name: name) }
        }
        func settle(_ milliseconds: Int = 650) async throws { try await Task.sleep(for: .milliseconds(milliseconds)) }
        func capture(_ name: String) throws {
            guard let window = browser.view.window else { return }
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            try image.pngData()?.write(to: folder.appendingPathComponent(name+".png"))
        }
        AIPrompt.allCases.forEach { $0.reset() }
        // Placeholders, as Snap reads them.
        let known = AIPrompt.summarise.placeholders
        func problems(_ text: String) -> [String?] { PromptPlaceholder.scan(text, known: known).map(\.problem) }
        try check("known-placeholders-are-valid", problems("Sum up {title} at {address}: {text}") == [nil, nil, nil])
        try check("malformed-placeholders-say-why", problems("{nope} {} {a b} {title x}") == [
            "Unknown placeholder {nope}.", "Placeholder names can’t be empty.", "Placeholders can’t contain spaces.",
            "Placeholders can’t contain spaces."]
            && problems("{title") == ["Close the placeholder with }."]
            && problems("{ti{text}") == ["Close the placeholder before starting another one.", nil]
            && problems("a } b") == ["Remove the unmatched }."])
        try check("placeholders-fill-in", AIPrompt.fill("On {title}: {text}", values: ["title": "T", "text": "B"], known: known) == "On T: B"
                  && AIPrompt.fill("No placeholders", values: [:], known: known) == nil)
        let bar = browser.bottomBar, panel = bar.aiPrompt
        for style in [UIUserInterfaceStyle.light, .dark] {
            browser.overrideUserInterfaceStyle = style
            let name = style == .dark ? "dark" : "light"
            browser.openPanel(.menu); try await settle()
            browser.openSiteSettings(); try await settle()
            browser.openAppSettings(); try await settle()
            try check("app-settings-has-an-ai-options-row", bar.appSettings.aiOptionsRow.superview != nil
                      && bar.aiOptions.ai.superview !== bar.appSettings)
            try capture("app-settings-"+name)
            bar.appSettings.aiOptionsRow.sendActions(for: .primaryActionTriggered); try await settle()
            try check("ai-options-opens-from-settings", bar.panel == .aiOptions && bar.shown === bar.aiOptions)
            try capture("ai-options-"+name)
            bar.aiOptions.promptRows[0].sendActions(for: .primaryActionTriggered); try await settle()
            try check("summarise-prompt-opens-with-the-shipped-prompt", bar.panel == .aiPrompt
                      && panel.editor.text == PageSummary.systemPrompt && !panel.resetButton.isEnabled)
            try capture("summarise-prompt-"+name)
            browser.returnFromPanel(); try await settle()
            browser.returnFromPanel(); try await settle()
            try check("x-returns-a-level-at-a-time", bar.panel == .appSettings)
            browser.closePanel(); try await settle()
        }
        browser.overrideUserInterfaceStyle = .light
        browser.openPanel(.menu); try await settle()
        browser.openSiteSettings(); try await settle()
        browser.openAppSettings(); try await settle()
        browser.openAIOptions(); try await settle()
        // Each shipped prompt opens whole, with nothing to scroll.
        for prompt in AIPrompt.allCases {
            browser.openAIPrompt(prompt); try await settle()
            try check("\(prompt.rawValue)-opens-with-the-whole-prompt-in-sight",
                      panel.editor.contentSize.height <= panel.editor.bounds.height+0.5)
            if prompt == .explain { try capture("explain-prompt") }
            browser.returnFromPanel(); try await settle()
        }
        // The keyboard lifts the buttons over it and grows the sheet to keep the whole prompt in sight.
        browser.openAIPrompt(.summarise); try await settle()
        panel.editor.text = "Write in the page's language.\n\nHh"; panel.editor.delegate?.textViewDidChange?(panel.editor)
        try await settle(400)
        let window = browser.view.window!, keyboard = CGRect(x: 0, y: window.bounds.height-336, width: window.bounds.width, height: 336)
        func keyboardTo(_ frame: CGRect) {
            NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil, userInfo: [
                UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: frame),
                UIResponder.keyboardAnimationDurationUserInfoKey: 0.25])
        }
        let resting = bar.bounds.height
        keyboardTo(keyboard); try await settle()
        try capture("keyboard")
        let buttonsBottom = panel.saveButton.convert(panel.saveButton.bounds, to: window).maxY
        try check("the-keyboard-lifts-the-buttons-over-it", abs(buttonsBottom-(keyboard.minY-12)) < 1.5)
        try check("the-keyboard-grows-the-sheet", bar.bounds.height > resting+200)
        try check("the-subtitle-stays-under-the-field", panel.subviews.contains { $0 is UILabel && $0.frame.minY >= panel.editor.frame.maxY+11.5 })
        try check("the-whole-prompt-shows-over-the-keyboard", panel.editor.contentSize.height <= panel.editor.bounds.height+0.5)
        keyboardTo(CGRect(x: 0, y: window.bounds.height, width: window.bounds.width, height: 336)); try await settle()
        try check("the-sheet-settles-back-as-the-keyboard-goes", abs(bar.bounds.height-resting) < 1)
        browser.returnFromPanel(); try await settle()
        // Leaving without saving keeps the shipped prompt.
        browser.openAIPrompt(.ask); try await settle()
        try check("ask-shows-only-its-editable-instructions", panel.editor.text == PageAssistant.instructions)
        panel.editor.text = "Answer like a pirate."; panel.editor.delegate?.textViewDidChange?(panel.editor)
        try check("an-edit-enables-hold-to-reset", panel.resetButton.isEnabled)
        browser.returnFromPanel(); try await settle()
        try check("x-discards-the-edit", !AIPrompt.ask.isCustom && bar.panel == .aiOptions)
        // Saving keeps it, and the request uses it with the fixed answer format after.
        browser.openAIPrompt(.ask); try await settle()
        panel.editor.text = "Answer like a pirate."; panel.editor.delegate?.textViewDidChange?(panel.editor)
        panel.saveButton.sendActions(for: .primaryActionTriggered); try await settle()
        let page = PageAssistant.Page(title: "T", url: "https://example.com", selection: "", text: "Body")
        let system = PageAssistant.messages(question: "Q", history: [], page: page, instructions: AIPrompt.ask.text).first?["content"] as? String ?? ""
        try check("save-keeps-the-prompt-and-returns-to-ai-options", AIPrompt.ask.text == "Answer like a pirate." && bar.panel == .aiOptions)
        try check("ask-requests-keep-the-answer-format", system.hasPrefix("Answer like a pirate.\n\n"+PageAssistant.answerFormat))
        browser.openAIPrompt(.ask); try await settle()
        try check("a-saved-prompt-shows-again", panel.editor.text == "Answer like a pirate." && panel.resetButton.isEnabled)
        // Let go early: nothing resets.
        let reset = panel.resetButton
        func shown() -> CGFloat { reset.shownFraction }
        try check("hold-to-reset-words-are-plain-until-the-red-passes", reset.textLabel.textColor == .label
                  && reset.textLabel.font.fontName.hasPrefix("OpenRunde") && panel.saveButton.textLabel.font.fontName.hasPrefix("OpenRunde"))
        reset.sendActions(for: .touchDown)
        try await settle(500)
        let early = shown()
        try capture("reset-held-light")
        try? "\(early)".write(to: folder.appendingPathComponent("early.txt"), atomically: true, encoding: .utf8)
        try check("red-fills-from-the-left-while-held", early > 0.15 && early < 0.6)
        reset.sendActions(for: .touchUpInside)
        try await settle(120)
        try check("letting-go-runs-the-red-back", shown() < early)
        try check("letting-go-early-keeps-the-prompt", AIPrompt.ask.isCustom && panel.resetButton.isEnabled)
        try await settle(300)
        try check("the-red-runs-back-to-the-left", shown() < 0.01)
        // Held through: it resets and disables.
        reset.sendActions(for: .touchDown)
        try await settle(1800)
        try check("holding-to-the-end-resets", !AIPrompt.ask.isCustom && panel.editor.text == PageAssistant.instructions
                  && !panel.resetButton.isEnabled)
        panel.resetButton.sendActions(for: .touchUpInside)
        try await settle()
        // Placeholders colour as typed; a malformed one can't be saved.
        let base = bar.bounds.height
        panel.editor.text = "Explain {title} at {address}, not {nope}"; panel.editor.delegate?.textViewDidChange?(panel.editor)
        try await settle(400)
        let storage = panel.editor.textStorage
        func colour(at index: Int) -> UIColor? { storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? UIColor }
        try check("valid-placeholders-are-blue", colour(at: 8) == AIPromptPanel.placeholderBlue && colour(at: 0) == .label)
        try check("malformed-placeholders-are-red", colour(at: storage.length-2) == .systemRed && !panel.saveButton.isEnabled)
        try capture("placeholders")
        // Lines more grow the sheet, up to its limit, the field scrolling past it.
        panel.editor.text = "Explain {title}."; panel.editor.delegate?.textViewDidChange?(panel.editor)
        try await settle(400)
        let short = bar.bounds.height
        try check("a-short-prompt-shrinks-the-sheet", short < base && panel.saveButton.isEnabled)
        panel.editor.text = Array(repeating: "Another line of the prompt.", count: 8).joined(separator: "\n")
        panel.editor.delegate?.textViewDidChange?(panel.editor)
        try await settle(400)
        let taller = bar.bounds.height
        try check("lines-grow-the-sheet", taller > short+100)
        panel.editor.text = Array(repeating: "Another line of the prompt.", count: 80).joined(separator: "\n")
        panel.editor.delegate?.textViewDidChange?(panel.editor)
        try await settle(400)
        let cap = browser.view.bounds.height-browser.view.safeAreaInsets.top-12
        try check("the-sheet-stops-at-its-limit", abs(bar.bounds.height-cap) < 1.5 && panel.editor.contentSize.height > panel.editor.bounds.height)
        try capture("long-prompt")
        // The keyboard shortens the field and lifts the buttons rather than growing the sheet.
        let field = panel.editor.bounds.height, buttons = panel.saveButton.center.y
        panel.keyboardOverlap = 300; panel.layoutIfNeeded()
        try check("the-keyboard-shortens-the-field", abs(panel.editor.bounds.height-(field-300)) < 1
                  && abs(panel.saveButton.center.y-(buttons-300)) < 1 && abs(bar.bounds.height-cap) < 1.5)
        panel.keyboardOverlap = 0
        browser.overrideUserInterfaceStyle = .dark; try await settle(300)
        reset.sendActions(for: .touchDown); try await settle(300)
        try capture("reset-held-dark")
        reset.sendActions(for: .touchUpInside); try await settle(400)
        browser.overrideUserInterfaceStyle = .light
        browser.returnFromPanel(); try await settle()
        browser.closePanel(); try await settle()
    }
}
#endif
