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
        try check("site-row-appears-immediately", panel.offeredSite?.name == "Lamp Shop" && !panel.siteRow.isHidden && panel.siteRow.alpha == 1)
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
        panel.layoutIfNeeded()
        let visibleRows = panel.resultRows
        visibleRows.forEach { $0.layoutIfNeeded() }
        try check("all-suggestion-rows-share-the-taller-height", visibleRows.allSatisfy { $0.bounds.height == 56 })
        try check("suggestion-titles-use-the-standard-ios-font", visibleRows.allSatisfy {
            $0.titleLabelView.font.fontName == UIFont.systemFont(ofSize: 17, weight: .medium).fontName
        })
        try check("url-subtitles-use-the-reference-size-and-standard-font", visibleRows.allSatisfy {
            $0.addressLabel.font.pointSize == 12 && $0.addressLabel.font.fontName == UIFont.systemFont(ofSize: 12, weight: .medium).fontName
        })
        for (url, expected) in [
            ("https://www.apple.com/", "apple.com"),
            ("HTTP://WWW.example.com/path?q=https://www.other.example/#fragment", "example.com/path?q=https://www.other.example/#fragment"),
            ("https://example.com/?q=lamp", "example.com/?q=lamp"),
            ("https://www2.example.com/docs/", "www2.example.com/docs/")
        ] {
            try check("display-url-\(expected)", AddressSuggestionRow.displayAddress(url) == expected)
        }
        let reference = UIView(frame: CGRect(x: 0, y: 0, width: 393, height: 56))
        reference.backgroundColor = .white
        let referenceRow = AddressSuggestionRow(frame: reference.bounds.insetBy(dx: SearchPanel.inset, dy: 0))
        reference.addSubview(referenceRow)
        referenceRow.show(AddressCandidate(title: "Apple", subtitle: "https://www.apple.com/", url: URL(string: "https://www.apple.com/")), image: nil)
        referenceRow.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat(); format.scale = 3
        let referenceImage = UIGraphicsImageRenderer(size: reference.bounds.size, format: format).image { _ in
            reference.drawHierarchy(in: reference.bounds, afterScreenUpdates: true)
        }
        try referenceImage.pngData()?.write(to: folder.appendingPathComponent("reference-typography-row.png"))
        try check("pressed-background-widens-without-widening-the-row", visibleRows.allSatisfy {
            $0.pressBackground.frame.minX == -6 && $0.pressBackground.bounds.width == $0.bounds.width+12
                && !$0.point(inside: CGPoint(x: -2, y: $0.bounds.midY), with: nil)
        })
        try check("single-line-rows-stay-centred", visibleRows.filter { ($0.addressLabel.text ?? "").isEmpty }.allSatisfy {
            $0.titleLabelView.frame.midY == $0.bounds.midY
        })
        try check("link-title-and-subtitle-stay-centred-together", visibleRows.filter { !($0.addressLabel.text ?? "").isEmpty }.allSatisfy {
            abs(($0.titleLabelView.frame.minY+$0.addressLabel.frame.maxY)/2-$0.bounds.midY) < 0.5
        })
        var fullHeight = browser.bottomBar.bounds.height
        let fullPageScale = browser.content.transform.a
        let rowBounds = panel.siteRow.bounds, rowCentreBeforePress = panel.siteRow.center
        panel.siteRow.sendActions(for: .touchDown)
        try await Task.sleep(for: .milliseconds(250))
        try check("row-press-keeps-fill-scale-and-layout", panel.siteRow.pressBackground.backgroundColor == SearchPanel.pressedFill
                  && panel.siteRow.bounds == rowBounds && panel.siteRow.center == rowCentreBeforePress
                  && abs(panel.siteRow.transform.a-SearchPanel.pressedScale) < 0.001)
        try capture("pressed-site-row")
        panel.siteRow.sendActions(for: .touchCancel)
        try await Task.sleep(for: .milliseconds(350))
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
        try check("site-row-disappears-immediately", panel.siteRow.isHidden && panel.siteRow.alpha == 0)
        panel.clearButton.sendActions(for: .primaryActionTriggered)
        for character in "lamps.example/d" { field.insertText(String(character)) }
        try check("path-completion-keeps-full-path", field.text == "lamps.example/d" && field.inlineCompletion == "lamps.example/docs/lighting")
        panel.clearButton.sendActions(for: .primaryActionTriggered)
        field.insertText("lamps.example")
        try check("pasted-address-is-not-rewritten", field.text == "lamps.example" && panel.completionPrefix == nil)
        try await Task.sleep(for: .milliseconds(300))
        let retainedRows = panel.resultRows
        let retainedFrames = retainedRows.map(\.frame)
        let retainedTitles = retainedRows.map { $0.titleLabelView.bounds }
        let siteColour = panel.siteRow.titleLabelView.attributedText?.attribute(.foregroundColor, at: "Search in ".utf16.count,
                                                                              effectiveRange: nil) as? UIColor
        panel.siteRow.sendActions(for: .primaryActionTriggered)
        try check("tap-enters-site-search", panel.siteSearch?.name == "Lamp Shop" && field.text == "" && field.placeholder == "Search in Lamp Shop")
        let placeholder = field.attributedPlaceholder
        try check("site-placeholder-keeps-the-input-font", (placeholder?.attribute(.font, at: 0, effectiveRange: nil) as? UIFont) == field.font)
        try check("site-placeholder-mutes-the-favicon-brand-colour", (placeholder?.attribute(.foregroundColor, at: "Search in ".utf16.count,
            effectiveRange: nil) as? UIColor) == siteColour?.withAlphaComponent(0.45))
        try check("site-placeholder-prefix-keeps-native-placeholder-colour", (placeholder?.attribute(.foregroundColor, at: 0,
            effectiveRange: nil) as? UIColor) == .placeholderText)
        try await Task.sleep(for: .milliseconds(350))
        try check("site-search-shrinks-the-sheet-without-resizing-results", panel.bounds.height == SearchPanel.height
                  && browser.bottomBar.bounds.height < fullHeight-80 && !panel.siteRow.isHidden)
        try check("compact-site-search-keeps-every-row-and-its-geometry", retainedRows.allSatisfy { $0.superview === panel.list }
                  && zip(retainedRows,retainedFrames).allSatisfy { $0.frame == $1 }
                  && zip(retainedRows,retainedTitles).allSatisfy { $0.titleLabelView.bounds == $1 })
        try check("covered-results-cannot-be-tapped-or-read-by-voiceover", retainedRows.allSatisfy {
            !$0.isUserInteractionEnabled && $0.accessibilityElementsHidden
        })
        let placeholderImage = UIGraphicsImageRenderer(bounds: field.bounds).image { _ in
            field.drawHierarchy(in: field.bounds, afterScreenUpdates: true)
        }
        try placeholderImage.pngData()?.write(to: folder.appendingPathComponent("site-placeholder-light.png"))
        try check("site-search-resize-keeps-keyboard-focus", field.isFirstResponder)
        try check("page-scales-forward-with-the-smaller-panel", browser.content.transform.a > fullPageScale)
        // Use the real keyboard-frame handler to check both docked and hardware keyboards.
        func keyboardFrame(_ height: CGFloat) async throws {
            let frame = browser.view.convert(CGRect(x: 0, y: browser.view.bounds.height-height,
                width: browser.view.bounds.width, height: height), to: browser.view.window!.screen.coordinateSpace)
            NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
                userInfo: [UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: frame),
                           UIResponder.keyboardAnimationDurationUserInfoKey: 0.12])
            try await Task.sleep(for: .milliseconds(180))
        }
        try await keyboardFrame(350)
        let inputBottom = field.convert(field.bounds, to: browser.view).maxY
        try check("site-search-input-sits-just-above-the-keyboard", abs(browser.view.bounds.height-350-inputBottom-12) < 1)
        try await keyboardFrame(0)
        try check("site-search-fits-with-a-hardware-keyboard", abs(browser.bottomBar.bounds.height
                  - BottomBar.findHeight(keyboard: 0, safeBottom: browser.view.window!.safeAreaInsets.bottom)) < 1)
        try await keyboardFrame(350)
        // Full search now follows the keyboard too, keeping four rows above its edge.
        fullHeight = BottomBar.searchTop+SearchPanel.height+350
        try capture("compact-site-search")
        var opened: URL?
        let onOpen = panel.onOpen
        panel.onOpen = { opened = $0 }
        field.insertText("floor lamp & café")
        _ = panel.textFieldShouldReturn(field)
        let result = opened.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        try check("site-search-submits-unicode-and-special-characters", result?.host == "lamps.example"
                  && result?.queryItems?.first?.value == "floor lamp & café")
        panel.onOpen = onOpen
        panel.clearButton.sendActions(for: .primaryActionTriggered)
        try check("clear-exits-site-search-even-with-terms", panel.siteSearch == nil && field.text == "lamps.example")
        for _ in 0..<24 {
            try check("expanding-results-keep-full-width-and-title-size", zip(retainedRows,retainedFrames).allSatisfy { row, frame in
                abs((row.layer.presentation()?.bounds.width ?? row.bounds.width)-frame.width) < 0.5
            } && zip(retainedRows,retainedTitles).allSatisfy { row, title in
                abs((row.titleLabelView.layer.presentation()?.bounds.width ?? row.titleLabelView.bounds.width)-title.width) < 0.5
            })
            try await Task.sleep(for: .milliseconds(8))
        }
        try check("x-restores-the-original-row-identities-and-native-placeholder", retainedRows.allSatisfy {
            $0.superview === panel.list && $0.isUserInteractionEnabled && !$0.accessibilityElementsHidden
        } && field.placeholder == "Search or enter URL"
          && (field.attributedPlaceholder == nil || field.attributedPlaceholder?.string == "Search or enter URL"))
        try await Task.sleep(for: .milliseconds(350))
        try check("clear-restores-the-full-panel-and-suggestions", abs(browser.bottomBar.bounds.height-fullHeight) < 1
                  && panel.bounds.height == SearchPanel.height && !panel.candidates.isEmpty && field.isFirstResponder)
        for _ in 0..<3 {
            field.text = "lamps.example"; field.sendActions(for: .editingChanged)
            panel.siteRow.sendActions(for: .primaryActionTriggered)
            try await Task.sleep(for: .milliseconds(20))
            panel.clearButton.sendActions(for: .primaryActionTriggered)
        }
        try await Task.sleep(for: .milliseconds(350))
        try check("rapid-site-search-resizes-settle-back-to-the-full-panel", panel.siteSearch == nil
                  && abs(browser.bottomBar.bounds.height-fullHeight) < 1
                  && panel.bounds.height == SearchPanel.height && !panel.candidates.isEmpty)
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
        field.insertText("lamps.example")
        try await Task.sleep(for: .milliseconds(350))
        fullHeight = browser.bottomBar.bounds.height
        panel.siteRow.sendActions(for: .primaryActionTriggered)
        try await Task.sleep(for: .milliseconds(350))
        try check("url-editor-also-shrinks-for-site-search", panel.siteSearch != nil && panel.bounds.height == SearchPanel.height
                  && browser.bottomBar.bounds.height < fullHeight-80)
        browser.bottomBar.menu.address.reloadButton.sendActions(for: .primaryActionTriggered)
        try await Task.sleep(for: .milliseconds(350))
        try check("url-editor-x-restores-the-panel-instead-of-closing-it", browser.isPanelOpen
                  && panel.siteSearch == nil && abs(browser.bottomBar.bounds.height-fullHeight) < 1)
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
        for character in "amazo" { field.insertText(String(character)) }
        let previousCompletion = field.inlineCompletion
        let previousCursor = field.offset(from: field.beginningOfDocument, to: field.selectedTextRange!.start)
        panel.siteRow.sendActions(for: .primaryActionTriggered)
        field.insertText("costume")
        panel.clearButton.sendActions(for: .primaryActionTriggered)
        try check("site-search-x-restores-the-amazo-prefix-and-completion", field.text == "amazo"
                  && field.inlineCompletion == previousCompletion && panel.completionPrefix == "amazo")
        try check("site-search-x-restores-the-cursor-and-offered-site", panel.offeredSite?.name == "Amazon"
                  && field.offset(from: field.beginningOfDocument, to: field.selectedTextRange!.start) == previousCursor)
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
        let darkBrand = panel.siteRow.titleLabelView.attributedText?.attribute(.foregroundColor, at: "Search in ".utf16.count,
                                                                             effectiveRange: nil) as? UIColor
        panel.siteRow.sendActions(for: .primaryActionTriggered)
        // Compare at selection: a favicon arriving later may legitimately replace the
        // catalogue fallback in the placeholder while the old result rows remain frozen.
        try check("dark-site-placeholder-also-mutes-the-same-brand-colour", (field.attributedPlaceholder?.attribute(.foregroundColor,
            at: "Search in ".utf16.count, effectiveRange: nil) as? UIColor) == darkBrand?.withAlphaComponent(0.45))
        try await Task.sleep(for: .milliseconds(350))
        let darkPlaceholder = UIGraphicsImageRenderer(bounds: field.bounds).image { _ in
            field.drawHierarchy(in: field.bounds, afterScreenUpdates: true)
        }
        try darkPlaceholder.pngData()?.write(to: folder.appendingPathComponent("site-placeholder-dark.png"))
        panel.clearButton.sendActions(for: .primaryActionTriggered)
        try await Task.sleep(for: .milliseconds(350))
        panel.overrideUserInterfaceStyle = .unspecified
        for index in 0..<10 {
            source.history.record(URL(string: "https://www.scroll-fixture.example/page/\(index)?ref=kept")!, title: "Scrollable result \(index)")
        }
        field.text = "scroll-fixture.example"; field.sendActions(for: .editingChanged)
        try await keyboardFrame(350)
        panel.layoutIfNeeded()
        try check("more-than-four-results-exist-in-the-scroll-list", panel.resultRows.count > 4 && panel.isScrollable)
        let fifth = panel.resultRows[4]
        let keyboardTop = browser.view.bounds.height-350
        let fifthTitle = fifth.titleLabelView.convert(fifth.titleLabelView.bounds, to: browser.view)
        let listFrame = panel.list.convert(panel.list.bounds, to: browser.view)
        try check("the-fifth-result-starts-just-behind-the-keyboard", abs(listFrame.maxY-keyboardTop) < 1
                  && fifthTitle.minY > keyboardTop && fifthTitle.minY < keyboardTop+20)
        try check("all-results-keep-the-normal-row-spacing", zip(panel.resultRows, panel.resultRows.dropFirst()).allSatisfy {
            abs($1.frame.minY-$0.frame.minY-SearchPanel.rowHeight) < 0.1
        })
        let inputFrame = field.convert(field.bounds, to: browser.view), sheetHeight = browser.bottomBar.bounds.height
        panel.list.setContentOffset(CGPoint(x: 0, y: SearchPanel.rowHeight*2), animated: false)
        let revealed = fifth.titleLabelView.convert(fifth.titleLabelView.bounds, to: browser.view)
        try check("scrolling-reveals-the-fifth-result-without-moving-the-input-or-panel", revealed.maxY < keyboardTop
                  && revealed.minY > inputFrame.maxY && field.convert(field.bounds, to: browser.view) == inputFrame
                  && browser.bottomBar.bounds.height == sheetHeight && field.isFirstResponder)
        let offset = panel.list.contentOffset
        panel.refresh(); panel.layoutIfNeeded()
        try check("late-results-and-icons-keep-the-scroll-position", panel.list.contentOffset == offset && panel.resultRows[4] === fifth)
        panel.list.setContentOffset(CGPoint(x: 0, y: panel.list.contentSize.height-panel.list.bounds.height), animated: false)
        let lastRow = panel.resultRows.last!
        try check("the-final-result-can-scroll-fully-above-the-keyboard", lastRow.convert(lastRow.bounds, to: browser.view).maxY <= keyboardTop+0.5)
        var chosen: URL?
        let normalOpen = panel.onOpen
        panel.onOpen = { chosen = $0 }
        fifth.sendActions(for: .primaryActionTriggered)
        let fifthCandidate = panel.candidates.filter { !$0.isAutofill }[4]
        try check("scrolled-results-keep-the-original-complete-navigation-url", chosen == fifthCandidate.url
                  && chosen?.host == "www.scroll-fixture.example" && chosen?.query == "ref=kept")
        panel.onOpen = normalOpen
        field.text = "scroll-fixture.example/p"; field.sendActions(for: .editingChanged); panel.layoutIfNeeded()
        try check("editing-the-query-resets-results-to-the-top", panel.list.contentOffset == .zero)
        try await keyboardFrame(620)
        try check("short-visible-areas-use-a-shorter-scroll-viewport", panel.list.bounds.height < SearchPanel.rowHeight*4)
        panel.list.setContentOffset(CGPoint(x: 0, y: panel.list.contentSize.height-panel.list.bounds.height), animated: false)
        try check("the-final-result-is-reachable-with-a-taller-keyboard", panel.resultRows.last!.convert(panel.resultRows.last!.bounds,
            to: browser.view).maxY <= browser.view.bounds.height-620+0.5)
        try await keyboardFrame(350)
        panel.beginEditingAddress(browser.bottomBar.menu.address, url: fixture)
        panel.focusAddress(); panel.finishAddressTransition()
        field.text = "scroll-fixture.example"; field.sendActions(for: .editingChanged); panel.layoutIfNeeded()
        try check("url-editing-also-has-the-full-scrollable-result-list", panel.resultRows.count > 4 && panel.list.isScrollEnabled)
        panel.releaseAddress()
        field.text = "scroll-fixture.example"; field.sendActions(for: .editingChanged); panel.layoutIfNeeded()
        try capture("scrollable-suggestions")
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
