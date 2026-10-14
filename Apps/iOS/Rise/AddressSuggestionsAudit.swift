#if DEBUG
import UIKit
import WebKit

/// Exercises the real input and WebKit bridge, with isolated history and no phone interaction.
@MainActor enum AddressSuggestionsAudit {
    static let argument = "-RiseAddressSuggestionsAudit"
    static func makeBrowser() -> BrowserViewController {
        BrowserViewController(startURL: nil, suggestionsDirectory: URL.temporaryDirectory
            .appendingPathComponent("RiseAddressAudit-\(UUID())"))
    }
    struct Failure: Error { let check: String }
    static func exercise(_ browser: BrowserViewController, folder: URL) async throws -> [String: Bool] {
        var checks: [String: Bool] = [:]
        func check(_ name: String, _ condition: Bool) throws {
            checks[name] = condition
            try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted,.sortedKeys])
                .write(to: folder.appendingPathComponent("checks.json"))
            if !condition {
                let panel = browser.bottomBar.search
                let state: [String: Any] = ["text": panel.field.text ?? "", "query": panel.query,
                    "prefix": panel.completionPrefix ?? "none", "site": panel.offeredSite?.name ?? "none",
                    "suffixX": panel.field.inlineCompletionFrame.minX,
                    "nativeCaretX": panel.field.caretRect(for: panel.field.endOfDocument).minX,
                    "inputInset": panel.field.editingRect(forBounds: panel.field.bounds).minX]
                try JSONSerialization.data(withJSONObject: state).write(to: folder.appendingPathComponent("state.json"))
                let image = UIGraphicsImageRenderer(bounds: panel.bounds).image { _ in panel.drawHierarchy(in: panel.bounds, afterScreenUpdates: true) }
                try image.pngData()?.write(to: folder.appendingPathComponent("failure.png"))
                throw Failure(check: name)
            }
        }
        func wait(_ predicate: @MainActor () -> Bool) async throws {
            for _ in 0..<300 {
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw Failure(check: "timed out")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func capture(_ name: String) throws {
            let panel = browser.bottomBar.search
            let background = panel.backgroundColor
            panel.backgroundColor = BottomBar.background
            defer { panel.backgroundColor = background }
            let image = UIGraphicsImageRenderer(bounds: panel.bounds).image { _ in
                panel.drawHierarchy(in: panel.bounds, afterScreenUpdates: true)
            }
            try image.pngData()?.write(to: folder.appendingPathComponent(name+".png"))
        }
        let source = browser.addressSuggestions
        let fixture = URL(string: "https://lamps.example/docs/lighting")!
        for _ in 0..<8 { source.history.record(fixture, title: "Lighting handbook") }
        let icon = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            UIColor.systemOrange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            UIColor.white.setFill(); UIBezierPath(roundedRect: CGRect(x: 9, y: 5, width: 14, height: 22), cornerRadius: 4).fill()
        }
        source.icons.remember(icon, for: fixture)
        browser.webView.loadHTMLString(#"""
        <!doctype html><meta property="og:site_name" content="Lamp Shop"><title>Lighting handbook</title>
        <form><input name=user value=someone><input type=search name=find><button>Search</button></form>
        <script>document.querySelector('form').addEventListener('submit', event => {
          event.preventDefault(); history.pushState({}, '', '/results/?sort=new&term=' + encodeURIComponent(event.target.find.value));
        })</script>
        """#, baseURL: URL(string: "https://lamps.example/"))
        try await wait { !browser.webView.isLoading && browser.webView.title == "Lighting handbook" }
        _ = try await browser.webView.evaluateJavaScript("document.querySelector('[name=find]').value='desk lamp';document.querySelector('form').requestSubmit()")
        try await wait { source.learner.searches.site(forAddress: "lamps.example") != nil }
        try check("learns-real-page-form-and-spa-url", source.learner.searches.site(forAddress: "lamps.example")?.name == "Lamp Shop")
        try check("learned-template-drops-unrelated-state", source.learner.searches.site(forAddress: "lamps.example")?.searchURL(for: "floor lamp")?.absoluteString == "https://lamps.example/results/?term=floor%20lamp")
        source.save()
        source.icons.flush()
        let restored = MobileAddressSuggestions(directory: source.history.storageURL.deletingLastPathComponent())
        try check("favicons-persist-without-network", restored.icons.image(for: fixture, fetch: false) != nil)
        try check("history-persists", restored.history.entries.contains { $0.title == "Lighting handbook" })
        try check("learned-search-persists", restored.learner.searches.searches == source.learner.searches.searches)
        browser.openPanel()
        try await Task.sleep(for: .milliseconds(650))
        let panel = browser.bottomBar.search, field = panel.field
        try check("empty-query-offers-links", panel.candidates.contains { $0.url == fixture })
        let rest = field.editingRect(forBounds: field.bounds).minX
        field.insertText("l"); field.insertText("a")
        try await Task.sleep(for: .milliseconds(350))
        try check("completion-is-immediate-and-keeps-typed-text", field.text == "la" && field.inlineCompletion == "lamps.example")
        let selected = field.selectedTextRange!
        try check("completion-has-no-native-selection-handles", selected.isEmpty && field.offset(from: field.beginningOfDocument, to: selected.start) == 2)
        let prefixEdge = field.editingRect(forBounds: field.bounds).minX+("la" as NSString).size(withAttributes: [.font: field.font!]).width
        try check("completion-suffix-clears-the-typed-prefix", abs(field.inlineCompletionFrame.minX-prefixEdge) < 1)
        try check("completion-does-not-shift-input", field.editingRect(forBounds: field.bounds).minX == rest)
        try check("input-has-no-favicon", field.leftView?.subviews.isEmpty == true)
        try check("learned-site-row-appears", panel.offeredSite?.name == "Lamp Shop" && panel.siteRow.alpha == 1 && !panel.siteRow.isHidden)
        let attributed = panel.siteRow.titleLabelView.attributedText!
        try check("site-row-matches-result-typography", attributed.string == "Search in Lamp Shop"
                  && (attributed.attribute(.font, at: 0, effectiveRange: nil) as? UIFont) == SearchPanel.font
                  && (attributed.attribute(.font, at: "Search in ".utf16.count, effectiveRange: nil) as? UIFont) == SearchPanel.font)
        try check("site-row-uses-favicon", panel.siteRow.icon.image === icon)
        let selectionBefore = field.offset(from: field.beginningOfDocument, to: field.selectedTextRange!.start)
        panel.refresh()
        try check("late-results-preserve-text-and-selection", field.text == "la" && field.inlineCompletion == "lamps.example"
                  && field.offset(from: field.beginningOfDocument, to: field.selectedTextRange!.start) == selectionBefore)
        try capture("learned-site")
        field.deleteBackward()
        try await Task.sleep(for: .milliseconds(350))
        try check("backspace-does-not-reinsert-completion", field.text == "la" && panel.completionPrefix == nil)
        try check("backspace-keeps-a-still-matching-site-row", panel.offeredSite?.name == "Lamp Shop" && !panel.siteRow.isHidden)
        field.insertText("n")
        try check("replacing-prefix-stays-natural", field.text == "lan" && field.inlineCompletion == nil)
        try check("site-row-leaves-on-a-different-query", panel.offeredSite == nil)
        panel.clearButton.sendActions(for: .primaryActionTriggered)
        for character in "lamps.example/d" { field.insertText(String(character)) }
        try check("path-completion-keeps-full-path", field.text == "lamps.example/d" && field.inlineCompletion == "lamps.example/docs/lighting")
        panel.clearButton.sendActions(for: .primaryActionTriggered)
        field.insertText("lamps.example")
        try check("pasted-address-is-not-rewritten", field.text == "lamps.example" && panel.completionPrefix == nil)
        try await Task.sleep(for: .milliseconds(300))
        panel.siteRow.sendActions(for: .primaryActionTriggered)
        try check("tap-enters-site-search", panel.siteSearch?.name == "Lamp Shop" && field.text == "" && field.placeholder == "Search in Lamp Shop")
        var opened: URL?
        let onOpen = panel.onOpen
        panel.onOpen = { opened = $0 }
        field.insertText("floor lamp & café")
        _ = panel.textFieldShouldReturn(field)
        let result = opened.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        try check("site-search-submits-unicode-and-special-characters", result?.host == "lamps.example"
                  && result?.queryItems?.first?.value == "floor lamp & café")
        panel.onOpen = onOpen
        field.text = ""; field.sendActions(for: .editingChanged)
        panel.clearButton.sendActions(for: .primaryActionTriggered)
        try check("clear-exits-empty-site-search", panel.siteSearch == nil)
        panel.end(); panel.begin()
        field.setMarkedText("am", selectedRange: NSRange(location: 2, length: 0))
        field.sendActions(for: .editingChanged)
        try check("ime-composition-is-not-autocompleted", field.text == "am" && field.markedTextRange != nil && panel.completionPrefix == nil)
        field.unmarkText(); panel.clearButton.sendActions(for: .primaryActionTriggered)
        field.insertText("unrelated phrase")
        try check("search-query-has-no-url-completion", panel.completionPrefix == nil && field.text == "unrelated phrase")
        panel.end(); let textBefore = field.text; panel.refresh()
        try check("closed-panel-ignores-late-updates", field.text == textBefore)
        panel.beginEditingAddress(browser.bottomBar.menu.address, url: URL(string: "https://lamps.example/"))
        panel.focusAddress(); panel.finishAddressTransition()
        field.insertText("https://different.example/path")
        try check("url-editor-replaces-selected-address", field.text == "https://different.example/path")
        panel.clearAddress()
        try check("url-editor-clear-preserves-focus", field.text == "" && field.isFirstResponder)
        panel.end(); browser.bottomBar.restoreAddress(); panel.begin(); panel.focus()
        try check("address-return-leaves-no-overlay", browser.bottomBar.menu.address.superview === browser.bottomBar.menu)
        for character in "ama" { field.insertText(String(character)) }
        try await Task.sleep(for: .milliseconds(350))
        let rowCentre = panel.siteRow.center
        let rowStarts = Dictionary(uniqueKeysWithValues: (panel.siteRow.layer.animationKeys() ?? []).compactMap { key in
            panel.siteRow.layer.animation(forKey: key).map { (key, $0.beginTime) }
        })
        field.insertText("z")
        try check("same-site-row-stays-still-after-next-key", panel.offeredSite?.name == "Amazon" && panel.siteRow.center == rowCentre && panel.siteRow.transform == .identity)
        try check("next-key-does-not-restart-the-site-row-animation", (panel.siteRow.layer.animationKeys() ?? []).allSatisfy { key in
            rowStarts[key] == panel.siteRow.layer.animation(forKey: key)?.beginTime
        })
        field.insertText("o"); field.insertText("n")
        try check("suffix-alignment-updates-immediately-with-each-key", abs(field.inlineCompletionFrame.minX-(field.editingRect(forBounds: field.bounds).minX+("amazon" as NSString).size(withAttributes: [.font: field.font!]).width)) < 1)
        try check("popular-site-search-is-offered", panel.offeredSite?.name == "Amazon")
        let title = panel.siteRow.titleLabelView.attributedText!
        let brandColour = title.attribute(.foregroundColor, at: "Search in ".utf16.count, effectiveRange: nil) as? UIColor
        let faviconColour = MobileSuggestionFavicons.color(in: panel.siteRow.icon.image)
        try check("brand-name-uses-favicon-primary-color", faviconColour.map { brandColour == $0 } ?? (brandColour != .secondaryLabel))
        try capture("amazon-site")
        let completion = field.inlineCompletion
        field.acceptCompletion?()
        try check("completion-can-be-accepted-for-editing", field.text == completion && field.inlineCompletion == nil)
        panel.clearButton.sendActions(for: .primaryActionTriggered)
        for character in "amazon" { field.insertText(String(character)) }
        var completedDestination: URL?
        let completionOpen = panel.onOpen, completionSwitch = panel.onSwitchToTab
        panel.onOpen = { completedDestination = $0 }
        panel.onSwitchToTab = { _ in }
        _ = panel.textFieldShouldReturn(field)
        try check("go-opens-the-completed-address", completedDestination?.host == panel.offeredSite?.domain)
        panel.onOpen = completionOpen; panel.onSwitchToTab = completionSwitch
        let switchHandler = panel.onSwitchToTab
        var switched: UUID?
        panel.onSwitchToTab = { switched = $0 }
        let currentID = browser.tabs[browser.tabIndex].id
        panel.choose(AddressCandidate(title: "Open tab", url: browser.webView.url, tabID: currentID))
        try check("link-row-reuses-existing-tab", switched == currentID)
        panel.onSwitchToTab = switchHandler
        for _ in 0..<6 {
            field.text = "amazon.com"; field.sendActions(for: .editingChanged)
            field.text = "a different phrase"; field.sendActions(for: .editingChanged)
        }
        try await Task.sleep(for: .milliseconds(350))
        try check("rapid-row-entry-and-exit-leaves-no-remnant", panel.offeredSite == nil && panel.siteRow.isHidden && panel.siteRow.alpha == 0)
        panel.overrideUserInterfaceStyle = .dark
        field.text = "amazon.com"; field.sendActions(for: .editingChanged)
        try await Task.sleep(for: .milliseconds(350))
        try check("site-row-works-in-dark-mode", panel.offeredSite?.name == "Amazon" && panel.siteRow.alpha == 1)
        try capture("amazon-dark")
        panel.overrideUserInterfaceStyle = .unspecified
        field.text = "amazon.com"; field.sendActions(for: .editingChanged)
        return checks
    }
    static func run(in browser: BrowserViewController) {
        Task {
            let folder = URL.cachesDirectory.appendingPathComponent("AddressSuggestionsAudit")
            try? FileManager.default.removeItem(at: folder)
            do {
                let checks = try await exercise(browser, folder: folder)
                try "Passed \(checks.count) native checks\n".write(to: folder.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
            } catch {
                try? String(describing: error).write(to: folder.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8)
            }
        }
    }
}
#endif
