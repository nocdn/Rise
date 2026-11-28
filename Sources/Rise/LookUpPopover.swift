import AppKit
import ObjectiveC
import RiseChromium

/// Look Up, from a force click on a word or the menu's Look Up: the word marked on the page as the
/// system marks it, and a popover under it with the dictionary's definition and, below a
/// hairline, what the word means on this page, from the chosen AI provider. Outside a tab's page,
/// the system's own panel shows instead.
@MainActor final class LookUpPopover: NSObject, NSPopoverDelegate {
    /// Off: the explanation should come at once, and it's short.
    static let reasoningEffort = "none"
    /// Either side of the word, from the text around it.
    static let passageRadius = 600
    /// Enough of the page for its subject; the passage gives the sense.
    static let pageCharacterLimit = 24_000
    static let systemPrompt = """
    You explain a word or phrase a reader looked up on a web page in Rise, a web browser. The dictionary's definition already shows above your answer, so explain what it means where it appears: read the passage around it and the rest of the page for the sense it's used in.

    Reply in one or two short sentences, about 35 words at most. Start straight with the meaning in plain words — never with "This means", "It means", "Here", "In this context", "The selected text" or the word itself followed by "refers to". Don't repeat the dictionary's definition; if the page uses the word in a particular or technical sense, explain that sense. Add why it matters here only when that helps. Write in English. No headings, lists or quotation of the page; **bold** at most one key term.
    """

    // MARK: Taking over the system's Look Up

    private static var installed = false
    /// The one showing; it keeps itself until it closes.
    private static var current: LookUpPopover?
    /// Ones replaced or dismissed, until their popovers have closed.
    private static var closing: [LookUpPopover] = []

    /// Chromium shows Look Up, from a force click or `RCContextMenu.lookUp()`, through its page
    /// view's `showDefinition(for:at:)`, with the word in the page's font and where its baseline
    /// starts. Rise's popover answers it there, and the system's panel anywhere it can't.
    static func install() {
        guard !installed, let page = NSClassFromString("RenderWidgetHostViewCocoa") else { return }
        installed = true
        let selector = #selector(NSView.showDefinition(for:at:))
        guard let method = class_getInstanceMethod(page, selector) else { return }
        typealias Show = @convention(c) (NSView, Selector, NSAttributedString?, NSPoint) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Show.self)
        let replacement: @convention(block) (NSView, NSAttributedString?, NSPoint) -> Void = { view, string, point in
            let shown = MainActor.assumeIsolated { string.map { present($0, at: point, in: view) } ?? false }
            if !shown { original(view, selector, string, point) }
        }
        // Added to the page view's class alone, so every other view keeps the system's.
        class_replaceMethod(page, selector, imp_implementationWithBlock(replacement), method_getTypeEncoding(method))
    }

    /// Whether Rise showed it: only for a tab's page in a browser window. Without an AI provider
    /// to explain the word, it shows the dictionary's entry alone, and where the dictionary has
    /// none either, the system's panel shows instead.
    private static func present(_ string: NSAttributedString, at baseline: NSPoint, in view: NSView) -> Bool {
        let term = string.string.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !term.isEmpty, term.count <= 300,
              let host = sequence(first: view, next: \.superview).first(where: { $0 is RCBrowserView }) as? RCBrowserView,
              let page = host.delegate as? ChromiumPage,
              let browser = view.window?.windowController as? BrowserController else { return false }
        let explains = browser.aiProvider == .openCode || browser.hasAIKey(browser.aiProvider)
        let entry = dictionaryEntry(for: term)
        guard explains || entry != nil else { return false }
        current?.close()
        let popover = LookUpPopover(term: term, string: string, entry: entry, explains: explains, page: page, browser: browser)
        current = popover
        popover.show(at: baseline, in: view, host: host)
        return true
    }

    // MARK: Explanations kept

    /// Explanations by page and word, so looking the same word up again on the page has it at
    /// once, and asking again while one is coming waits for that one. Kept until Rise quits.
    private static var explained: [String: String] = [:], explainedOrder: [String] = []
    private static var explaining: [String: Task<String, Error>] = [:]
    static let keptLimit = 300

    /// The page without its fragment, and the word in any case.
    static func key(term: String, page url: URL?) -> String {
        var address = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        address?.fragment = nil
        return (address?.string ?? url?.absoluteString ?? "")+"\n"+term.lowercased()
    }

    private static func keep(_ answer: String, for key: String) {
        if explained.updateValue(answer, forKey: key) == nil { explainedOrder.append(key) }
        while explainedOrder.count > keptLimit { explained[explainedOrder.removeFirst()] = nil }
    }

    // MARK: One look-up

    private let term: String, string: NSAttributedString
    private weak var page: ChromiumPage?
    private weak var browser: BrowserController?
    private let entry: DictionaryEntry?
    private let popover = NSPopover()
    private let content = LookUpContentView()
    private var highlight: LookUpHighlight?
    private var task: Task<Void, Never>?
    private var monitors: [Any] = []
    private var closed = false
    private var key: String { Self.key(term: term, page: page?.url) }

    private let explains: Bool

    private init(term: String, string: NSAttributedString, entry: DictionaryEntry?, explains: Bool, page: ChromiumPage, browser: BrowserController) {
        self.term = term; self.string = string; self.entry = entry; self.explains = explains; self.page = page; self.browser = browser
        super.init()
    }

    /// The dictionary's entry for a word or short phrase, in lower case or as written.
    static func dictionaryEntry(for term: String) -> DictionaryEntry? {
        let lower = term.lowercased()
        guard term.split(separator: " ").count <= 4 else { return nil }
        return AddressQuickAnswer.dictionaryEntry(for: lower) ?? (lower == term ? nil : AddressQuickAnswer.dictionaryEntry(for: term))
    }

    private func show(at baseline: NSPoint, in view: NSView, host: NSView) {
        let font = string.length > 0 ? string.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil
        let size = string.size()
        let ascent = font?.ascender ?? size.height*0.8, descent = -(font?.descender ?? -size.height*0.2)
        // The word's box in the page view, from its baseline's start.
        let top = view.isFlipped ? baseline.y-ascent : baseline.y+ascent
        let box = NSRect(x: baseline.x, y: view.isFlipped ? top : baseline.y-descent, width: size.width, height: ascent+descent)
        let marked = LookUpHighlight(string: string, font: font)
        // One line that fits is marked as the system marks it; a long selection is pointed at.
        let rect = host.convert(box, from: view)
        let fits = !string.string.contains(where: \.isNewline) && rect.width <= host.bounds.width*0.9
        marked.frame = fits ? rect.insetBy(dx: -LookUpHighlight.padding.width, dy: -LookUpHighlight.padding.height).integral
            : NSRect(x: min(max(rect.minX, 0), host.bounds.maxX), y: rect.minY, width: 1, height: rect.height)
        host.addSubview(marked)
        if fits { marked.appear() }
        highlight = marked

        // Where the word is, in the page's own coordinates, to find the passage it's in.
        let zoom = max(page?.zoom ?? 1, 0.01), fontSize = font?.pointSize ?? 14
        let point = CGPoint(x: (baseline.x+min(size.width, 400)/2)/zoom,
                            y: ((view.isFlipped ? baseline.y : view.bounds.height-baseline.y)-fontSize*0.35)/zoom)

        content.configure(entry: entry, openDictionary: { [weak self] in self?.openDictionary() })
        let controller = NSViewController(); controller.view = content
        popover.contentViewController = controller
        popover.behavior = .transient; popover.animates = true; popover.delegate = self
        let kept = Self.explained[key]
        // Without a provider, the entry shows at once, saying why there's no explanation.
        guard explains else {
            content.setUnavailable("No API key set for explanations")
            popover.contentSize = content.size
            popover.show(relativeTo: marked.bounds, of: marked, preferredEdge: marked.isFlipped ? .maxY : .minY)
            watch()
            return
        }
        task = Task { [weak self] in
            guard let self, let page = self.page else { return }
            // A page busy with script mustn't hold Look Up back; the passage is only a help.
            let found = await withTaskGroup(of: Passage?.self) { group in
                group.addTask { @MainActor in await Self.passage(of: self.term, at: point, in: page) }
                group.addTask { try? await Task.sleep(for: .milliseconds(350)); return nil }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            guard !self.closed, marked.superview != nil else { return }
            self.content.setQuote(found.map(Self.quote))
            if let kept { self.content.reveal(kept, failed: false) }
            self.popover.contentSize = self.content.size
            self.popover.show(relativeTo: marked.bounds, of: marked, preferredEdge: marked.isFlipped ? .maxY : .minY)
            // Once it's open, the explanation takes the waiting line's place at once.
            self.popover.animates = false
            self.watch()
            if kept == nil { await self.explain(passage: found.map { $0.before+$0.word+$0.after } ?? "") }
        }
    }

    /// Waits for the word's explanation, asking for it unless it's already coming. Closing the
    /// popover leaves the request going, so the answer is kept for the next time.
    private func explain(passage: String) async {
        guard let page, let browser else { return }
        let key = key, term = term, entry = entry
        let request = Self.explaining[key] ?? Task { @MainActor in
            defer { Self.explaining[key] = nil }
            let text = String((await PageFind.visibleText(in: page) ?? "").prefix(Self.pageCharacterLimit))
            var choice = browser.modelChoice
            choice.effort = Self.reasoningEffort
            var answer = ""
            try await ModelService.run(Self.messages(term: term, entry: entry, passage: passage, title: page.title ?? "",
                                                     url: page.url?.absoluteString ?? "", text: text), provider: choice) { event in
                if case .text(let token) = event { answer += token }
            }
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw PageAssistant.Failure.service("No explanation came back. Try again.") }
            Self.keep(trimmed, for: key)
            return trimmed
        }
        Self.explaining[key] = request
        do { reveal(try await request.value, failed: false) }
        catch { reveal((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, failed: true) }
    }

    static func messages(term: String, entry: DictionaryEntry?, passage: String, title: String, url: String, text: String) -> [[String: Any]] {
        let system = systemPrompt+"\n\nTitle: \(title)\nURL: \(url)\n\n<page>\n\(text)\n</page>"
        var question = "Looked up: \(term)"
        if let entry { question += "\n\nThe dictionary shows: \([entry.wordClass].compactMap { $0 }.joined()) \(entry.sense)" }
        if !passage.isEmpty { question += "\n\nWhere it appears:\n<passage>\n\(passage)\n</passage>" }
        return [["role": "system", "content": system], ["role": "user", "content": question]]
    }

    /// The explanation takes the waiting line's place, and the popover grows to fit it.
    private func reveal(_ text: String, failed: Bool) {
        guard !Task.isCancelled else { return }
        guard !closed else { return }
        content.reveal(text, failed: failed)
        popover.contentSize = content.size
    }

    private func openDictionary() {
        let word = (entry?.headword.replacingOccurrences(of: "·", with: "") ?? term)
        if let query = word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), let url = URL(string: "dict://"+query) {
            NSWorkspace.shared.open(url)
        }
        close()
    }

    /// Scrolling the page or typing in it leaves the word, so the popover goes as the system's does.
    private func watch() {
        let window = highlight?.window
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown], handler: { [weak self] event in
            guard let self else { return event }
            let inPopover = event.window != nil && event.window === self.content.window
            if event.type == .scrollWheel ? event.window === window : (!inPopover || event.keyCode == 53) { self.close() }
            return event
        }) { monitors.append(monitor) }
    }

    /// The word is unmarked at once; the popover is kept until it has animated away.
    func close() {
        guard !closed else { return }
        let shown = popover.isShown
        finish()
        if shown { Self.closing.append(self); popover.animates = true; popover.performClose(nil) }
    }
    func popoverDidClose(_ notification: Notification) {
        finish()
        Self.closing.removeAll { $0 === self }
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        task?.cancel(); task = nil
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        highlight?.disappear(); highlight = nil
        if Self.current === self { Self.current = nil }
    }

    // MARK: The passage

    struct Passage: Equatable { let before: String, word: String, after: String }

    /// The text around the word under `point`: the selection when it's the word looked up, or else
    /// the occurrence nearest the point, in the block it's in. Nil where it can't be found, as in
    /// another frame's page.
    static func passage(of term: String, at point: CGPoint, in page: ChromiumPage) async -> Passage? {
        let script = """
        const wanted = term.trim(), lower = wanted.toLowerCase();
        let node = null, offset = 0;
        const selection = getSelection();
        if (selection && selection.rangeCount && !selection.isCollapsed && String(selection).trim().toLowerCase() === lower) {
          const range = selection.getRangeAt(0); node = range.startContainer; offset = range.startOffset;
        } else if (document.caretPositionFromPoint) {
          const caret = document.caretPositionFromPoint(x, y); if (caret) { node = caret.offsetNode; offset = caret.offset; }
        } else if (document.caretRangeFromPoint) {
          const range = document.caretRangeFromPoint(x, y); if (range) { node = range.startContainer; offset = range.startOffset; }
        }
        if (!node) return null;
        let block = node.nodeType === 1 ? node : node.parentElement;
        while (block && block !== document.body && block.parentElement
               && (getComputedStyle(block).display.startsWith('inline') || (block.textContent || '').length < 200)) block = block.parentElement;
        if (!block) return null;
        const before = document.createRange();
        before.setStart(block, 0);
        try { before.setEnd(node, offset); } catch { return null; }
        const all = block.textContent || '', at = before.toString().length, text = all.toLowerCase();
        let best = -1, distance = Infinity;
        for (let i = text.indexOf(lower); i >= 0; i = text.indexOf(lower, i + 1)) {
          const d = at < i ? i - at : at > i + lower.length ? at - i - lower.length : 0;
          if (d < distance) { best = i; distance = d; }
        }
        if (best < 0) return null;
        const tidy = s => s.replace(/\\s+/g, ' ');
        return [tidy(all.slice(Math.max(0, best - radius), best)), all.slice(best, best + lower.length),
                tidy(all.slice(best + lower.length, best + lower.length + radius))];
        """
        let parts = try? await page.runScript(script, arguments: ["term": term, "x": point.x, "y": point.y, "radius": passageRadius],
                                              world: "Rise.LookUp") as? [String]
        guard let parts, parts.count == 3 else { return nil }
        return Passage(before: parts[0], word: parts[1], after: parts[2])
    }

    /// A line of the passage to show: the word in its sentence, cut to a little either side.
    static func quote(_ passage: Passage) -> Passage {
        let reach = (before: 70, after: 45)
        var before = Substring(passage.before), after = Substring(passage.after)
        // From the start of its sentence, or where the passage was cut.
        var cutBefore = passage.before.count >= passageRadius
        if let stop = before.range(of: #"[.!?]["”’)]?\s"#, options: [.regularExpression, .backwards]) {
            before = before[stop.upperBound...]; cutBefore = false
        }
        before = before.drop { $0 == " " }
        if before.count > reach.before {
            before = before.suffix(reach.before); cutBefore = true
            // At a clause, where one starts near enough: "…but a good API is…".
            if let clause = before.range(of: #"[,;:—–] "#, options: .regularExpression),
               before.distance(from: clause.upperBound, to: before.endIndex) >= 25 {
                before = before[clause.upperBound...]
            } else if let space = before.firstIndex(of: " ") { before = before[before.index(after: space)...] }
        }
        // To the end of its sentence, if that's near.
        var cutAfter = false
        if let stop = after.range(of: #"[.!?](?=["”’)]?(\s|$))"#, options: .regularExpression),
           after.distance(from: after.startIndex, to: stop.lowerBound) <= reach.after {
            after = after[..<stop.upperBound]
        } else if after.count > reach.after {
            after = after.prefix(reach.after)
            if let space = after.lastIndex(of: " ") { after = after[..<space] }
            while let last = after.last, " ,;:—–-".contains(last) { after = after.dropLast() }
            cutAfter = true
        }
        return Passage(before: (cutBefore ? "…" : "")+before, word: passage.word, after: after+(cutAfter ? "…" : ""))
    }
}

// MARK: - The word, marked

/// The word drawn again over the page in a yellow box, as the system's Look Up marks it, with a
/// quick bounce as it appears.
final class LookUpHighlight: NSView {
    static let padding = NSSize(width: 1.5, height: 1.5)
    private let badge = CALayer()
    private let string: NSAttributedString, font: NSFont?

    init(string: NSAttributedString, font: NSFont?) {
        let black = NSMutableAttributedString(attributedString: string)
        let whole = NSRange(location: 0, length: black.length)
        black.removeAttribute(.backgroundColor, range: whole)
        black.removeAttribute(.underlineStyle, range: whole)
        black.addAttribute(.foregroundColor, value: NSColor.black, range: whole)
        self.string = black; self.font = font
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        badge.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        badge.cornerRadius = 4
        badge.backgroundColor = NSColor(srgbRed: 1, green: 0.9, blue: 0.32, alpha: 1).cgColor
        badge.borderColor = NSColor(srgbRed: 0.6, green: 0.48, blue: 0, alpha: 0.35).cgColor
        badge.borderWidth = 0.5
        badge.shadowColor = NSColor.black.cgColor
        badge.shadowOpacity = 0.3; badge.shadowRadius = 1.5; badge.shadowOffset = CGSize(width: 0, height: -1)
        badge.opacity = 0
        layer?.addSublayer(badge)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        badge.bounds = bounds
        badge.position = CGPoint(x: bounds.midX, y: bounds.midY)
        badge.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 4, cornerHeight: 4, transform: nil)
        let scale = window?.backingScaleFactor ?? 2
        let image = NSImage(size: bounds.size, flipped: false) { [string, font] _ in
            let descent = -(font?.descender ?? 0)
            string.draw(with: NSRect(x: Self.padding.width, y: Self.padding.height+descent, width: 10_000, height: 0), options: [])
            return true
        }
        badge.contents = image.layerContents(forContentsScale: scale)
        badge.contentsScale = scale
        CATransaction.commit()
    }

    func appear() {
        needsLayout = true; layoutSubtreeIfNeeded()
        badge.opacity = 1
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.08
        let bounce = CASpringAnimation(keyPath: "transform.scale")
        bounce.fromValue = 1.18; bounce.toValue = 1
        bounce.mass = 1; bounce.stiffness = 520; bounce.damping = 22
        bounce.duration = bounce.settlingDuration
        badge.add(fade, forKey: "fade"); badge.add(bounce, forKey: "bounce")
    }

    func disappear() {
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.removeFromSuperview() }
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = badge.presentation()?.opacity ?? badge.opacity; fade.toValue = 0
        fade.duration = 0.18
        badge.opacity = 0
        badge.add(fade, forKey: "fade")
        CATransaction.commit()
    }
}

// MARK: - The popover's content

/// The dictionary's entry, a hairline inset from both edges, then the line of the page the word is
/// in and the explanation of it, a mini spinner and "Generating explanation in context" until it
/// comes. Laid out by hand, so its height is known for the popover to grow to.
final class LookUpContentView: NSView {
    static let width: CGFloat = 360, inset: CGFloat = 18
    private let dictionary = LookUpDictionaryView()
    private let headword = LookUpContentView.label(), pronunciation = LookUpContentView.label(), definition = LookUpContentView.label()
    private let rule = LookUpRule()
    private let quoteBar = LookUpRule(), quote = LookUpContentView.label()
    private let spinner = NSProgressIndicator()
    private let waiting = LookUpContentView.label()
    private let answer = LookUpContentView.label()
    private var hasEntry = false, hasQuote = false, answered = false, unavailable = false
    private(set) var size = NSSize(width: LookUpContentView.width, height: 80)

    override var isFlipped: Bool { true }

    private static func label() -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byWordWrapping; field.maximumNumberOfLines = 0
        field.cell?.wraps = true; field.cell?.truncatesLastVisibleLine = false
        return field
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 80))
        for view in [dictionary, rule, quoteBar, quote, spinner, waiting, answer] as [NSView] { addSubview(view) }
        for view in [headword, pronunciation, definition] { dictionary.addSubview(view) }
        spinner.style = .spinning; spinner.controlSize = .mini; spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        waiting.attributedStringValue = NSAttributedString(string: "Generating explanation in context", attributes: [
            .font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: NSColor.secondaryLabelColor])
        answer.isSelectable = true
        answer.isHidden = true
        quoteBar.thickness = 2; quoteBar.vertical = true
        setAccessibilityRole(.group); setAccessibilityLabel("Look Up")
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(entry: DictionaryEntry?, openDictionary: @escaping () -> Void) {
        hasEntry = entry != nil
        dictionary.isHidden = !hasEntry; rule.isHidden = !hasEntry
        dictionary.open = openDictionary
        if let entry {
            headword.attributedStringValue = NSAttributedString(string: entry.headword, attributes: [
                .font: NSFont.systemFont(ofSize: 20, weight: .bold), .foregroundColor: NSColor.labelColor, .kern: -0.2])
            pronunciation.attributedStringValue = NSAttributedString(string: entry.pronunciation, attributes: [
                .font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: NSColor.secondaryLabelColor])
            definition.attributedStringValue = Self.definition(entry)
        }
        spinner.startAnimation(nil)
        layoutContent()
    }

    /// "adjective MATHEMATICS denoting an element of a set…": the class in italics, its labels in
    /// small capitals, then the sense.
    static func definition(_ entry: DictionaryEntry) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 2.5
        let body = NSFont.systemFont(ofSize: 13)
        let text = NSMutableAttributedString()
        if let wordClass = entry.wordClass {
            let italic = NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask)
            text.append(NSAttributedString(string: wordClass+" ", attributes: [.font: italic, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        for label in entry.labels {
            text.append(NSAttributedString(string: label.uppercased(), attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor, .kern: 0.5]))
            text.append(NSAttributedString(string: " ", attributes: [.font: body]))
        }
        text.append(NSAttributedString(string: entry.sense+".", attributes: [.font: body, .foregroundColor: NSColor.labelColor]))
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        return text
    }

    func setQuote(_ passage: LookUpPopover.Passage?) {
        hasQuote = passage != nil
        quote.isHidden = !hasQuote; quoteBar.isHidden = !hasQuote
        if let passage {
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 2
            let plain: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph]
            let text = NSMutableAttributedString(string: "“"+passage.before, attributes: plain)
            var strong = plain; strong[.font] = NSFont.systemFont(ofSize: 12, weight: .semibold); strong[.foregroundColor] = NSColor.labelColor
            text.append(NSAttributedString(string: passage.word, attributes: strong))
            text.append(NSAttributedString(string: passage.after+"”", attributes: plain))
            quote.attributedStringValue = text
        }
        layoutContent()
    }

    /// What's said in the waiting line's place, with no spinner, when there won't be an explanation.
    func setUnavailable(_ text: String) {
        waiting.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: NSColor.secondaryLabelColor])
        unavailable = true
        spinner.stopAnimation(nil); spinner.isHidden = true
        layoutContent()
    }

    /// The explanation in the waiting line's place.
    func reveal(_ text: String, failed: Bool) {
        answer.attributedStringValue = Self.styled(text, color: failed ? .secondaryLabelColor : .labelColor)
        answered = true
        answer.isHidden = false
        waiting.isHidden = true
        spinner.stopAnimation(nil); spinner.isHidden = true
        layoutContent()
        NSAccessibility.post(element: answer, notification: .layoutChanged)
    }

    /// Plain sentences, with **bold** for the key term.
    static func styled(_ text: String, color: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 2.5
        let body = NSFont.systemFont(ofSize: 13)
        let base: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: color, .paragraphStyle: paragraph]
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let markdown = try? AttributedString(markdown: text, options: options) else { return NSAttributedString(string: text, attributes: base) }
        let result = NSMutableAttributedString()
        for run in markdown.runs {
            var attributes = base
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.stronglyEmphasized) { attributes[.font] = NSFont.systemFont(ofSize: 13, weight: .semibold) }
            if intent.contains(.emphasized) { attributes[.font] = NSFontManager.shared.convert(attributes[.font] as? NSFont ?? body, toHaveTrait: .italicFontMask) }
            result.append(NSAttributedString(string: String(markdown[run.range].characters), attributes: attributes))
        }
        return result
    }

    private func height(of field: NSTextField, width: CGFloat) -> CGFloat {
        ceil(field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height ?? 0)
    }

    private func layoutContent() {
        let inset = Self.inset, inner = Self.width-inset*2
        var y: CGFloat = hasEntry ? 13 : 14
        if hasEntry {
            var top: CGFloat = 0
            let headHeight = height(of: headword, width: inner)
            headword.frame = NSRect(x: 0, y: top, width: inner, height: headHeight); top += headHeight
            let pronunciationHeight = height(of: pronunciation, width: inner)
            pronunciation.frame = NSRect(x: 0, y: top+1, width: inner, height: pronunciationHeight); top += pronunciationHeight+7
            let definitionHeight = height(of: definition, width: inner)
            definition.frame = NSRect(x: 0, y: top, width: inner, height: definitionHeight); top += definitionHeight
            dictionary.frame = NSRect(x: inset, y: y, width: inner, height: top)
            y += top+12
            rule.frame = NSRect(x: inset, y: y, width: inner, height: 1)
            y += 1+12
        }
        if hasQuote {
            let quoteHeight = height(of: quote, width: inner-11)
            quoteBar.frame = NSRect(x: inset, y: y+1, width: 2, height: quoteHeight-2)
            quote.frame = NSRect(x: inset+11, y: y, width: inner-11, height: quoteHeight)
            y += quoteHeight+9
        }
        let line: CGFloat = 18
        spinner.frame = NSRect(x: inset, y: y+(line-12)/2, width: 12, height: 12)
        let indent: CGFloat = unavailable ? 0 : 19
        let waitingHeight = height(of: waiting, width: inner-indent)
        waiting.frame = NSRect(x: inset+indent, y: y+(line-waitingHeight)/2, width: inner-indent, height: waitingHeight)
        var bottom = y+line
        if answered {
            let answerHeight = height(of: answer, width: inner)
            answer.frame = NSRect(x: inset, y: y-1, width: inner, height: answerHeight)
            bottom = y-1+answerHeight
        }
        size = NSSize(width: Self.width, height: ceil(bottom+15))
        setFrameSize(size)
    }
}

/// The dictionary's part: clicking it opens the entry in Dictionary.
final class LookUpDictionaryView: NSView {
    var open: (() -> Void)?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); toolTip = "Open in Dictionary" }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { open?() } }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "Open in Dictionary" }
    override func accessibilityPerformPress() -> Bool { open?(); return true }
}

/// A faint hairline, or the quote's bar beside it, in the separator's colour.
final class LookUpRule: NSView {
    var thickness: CGFloat = 0
    var vertical = false
    override func draw(_ dirtyRect: NSRect) {
        let scale = window?.backingScaleFactor ?? 2
        let line = thickness > 0 ? thickness : 1/scale
        (vertical ? NSColor.tertiaryLabelColor.withAlphaComponent(0.35) : NSColor.separatorColor).setFill()
        let rect = vertical ? NSRect(x: 0, y: 0, width: line, height: bounds.height)
            : NSRect(x: 0, y: (bounds.height-line)/2, width: bounds.width, height: line)
        NSBezierPath(roundedRect: rect, xRadius: vertical ? line/2 : 0, yRadius: vertical ? line/2 : 0).fill()
    }
}
