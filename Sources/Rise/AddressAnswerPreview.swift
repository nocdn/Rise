import AppKit

/// The one inline answer follows the focused search row, even when suggestions are refreshed.
/// Hovering the answer names its source.
@MainActor final class AddressAnswerPreview: HoverHintView {
    private let spinner = NSProgressIndicator()
    private let answer = NSTextField(labelWithString: "")
    private let fetchAge: (String) async -> String?
    private let define: (String) -> String?
    private var focused: AddressQuickAnswer?
    private var lookup: Task<Void, Never>?
    private var cache: [AddressQuickAnswer: (text: String?, expires: Date)] = [:]
    private var theme = RiseTheme.neutral

    init(fetchAge: @escaping (String) async -> String? = { try? await AddressQuickAnswer.age(of: $0) },
         define: @escaping (String) -> String? = AddressQuickAnswer.definition(for:)) {
        self.fetchAge = fetchAge; self.define = define
        super.init(frame: .zero)
        spinner.style = .spinning; spinner.controlSize = .mini
        answer.font = CenteredPaletteStyle.detailFont
        answer.lineBreakMode = .byTruncatingTail
        for view in [spinner, answer] { view.wantsLayer = true; addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let height = answer.intrinsicContentSize.height
        answer.frame = NSRect(x: 0, y: (bounds.height-height)/2, width: bounds.width, height: height)
        spinner.frame = NSRect(x: 0, y: (bounds.height-12)/2, width: 12, height: 12)
        updateTrackingAreas()
    }
    /// The answer's words, as far as they show.
    override var hintRect: NSRect {
        guard answer.alphaValue > 0, !answer.stringValue.isEmpty else { return .zero }
        return NSRect(x: answer.frame.minX, y: answer.frame.minY,
                      width: min(answer.intrinsicContentSize.width, answer.frame.width), height: answer.frame.height)
    }

    func focus(_ query: AddressQuickAnswer?, row: NSButton?, theme: RiseTheme) {
        self.theme = theme
        answer.textColor = CenteredPaletteStyle.detail(theme)
        if let parent = superview as? NSButton, parent !== row || focused != query {
            parent.setAccessibilityValue(nil)
            parent.superview?.needsLayout = true
            removeFromSuperview()
        }
        guard let query, let row else {
            if focused != nil { reset() }
            focused = nil
            return
        }
        if superview !== row { row.addSubview(self) }
        row.superview?.needsLayout = true
        if focused == query {
            if !isHidden && answer.alphaValue > 0 { row.setAccessibilityValue(answer.stringValue) }
            return
        }

        reset()
        focused = query
        if let saved = cache[query], saved.expires > .now {
            show(saved.text, in: row)
            return
        }
        switch query {
        case .definition(let term):
            let text = define(term)
            remember(text, for: query)
            show(text, in: row)
        case .synonyms(let term):
            let text = WordNetSynonyms.lookup(term)
            remember(text, for: query)
            show(text, in: row)
        case .age(let name):
            // Rapid keyboard navigation or a pointer passing through a row starts no request.
            lookup = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled, let self else { return }
                self.isHidden = false
                self.spinner.alphaValue = 1; self.spinner.startAnimation(nil)
                self.superview?.superview?.needsLayout = true
                let text = await self.fetchAge(name)
                guard !Task.isCancelled, let row = self.superview as? NSButton else { return }
                self.remember(text, for: query)
                self.show(text, in: row)
                if text != nil, PlainNavBar.exchangeRows(self.spinner, for: self.answer) {
                    try? await Task.sleep(for: .seconds(PlainNavBar.Notice.exitDuration))
                    guard !Task.isCancelled else { return }
                }
                self.spinner.alphaValue = 0; self.spinner.stopAnimation(nil)
            }
        }
    }

    private func reset() {
        lookup?.cancel(); lookup = nil
        isHidden = true
        hoverHint?.setHovered(false)
        for view in [spinner, answer] {
            view.layer?.removeAnimation(forKey: "notice")
            view.alphaValue = 0
        }
        spinner.stopAnimation(nil)
    }

    private func remember(_ text: String?, for query: AddressQuickAnswer) {
        if cache.count >= 64 { cache.removeAll(keepingCapacity: true) }
        cache[query] = (text, Date().addingTimeInterval(text == nil ? 30 : 300))
    }

    private func show(_ text: String?, in row: NSButton) {
        answer.alphaValue = text == nil ? 0 : 1
        answer.stringValue = text ?? ""
        let source: String?
        switch focused {
        case .age: source = "Wikidata"
        case .definition: source = "Dictionary"
        case .synonyms: source = "WordNet"
        case nil: source = nil
        }
        setHoverHint(text == nil ? nil : source.map { "Source: \($0)" }, theme: theme)
        isHidden = text == nil
        row.setAccessibilityValue(text)
        needsLayout = true
        row.superview?.needsLayout = true
    }
}
