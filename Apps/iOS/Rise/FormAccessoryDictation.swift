import UIKit
import WebKit

/// A microphone in WebKit's bar above the keyboard, just before its ✓. WebKit's own bar stays as
/// it is, glass, ↑ ↓ and ✓ included (`WKFormAccessoryView`, a toolbar whose items WebKit only ever
/// edits as a copy of what's there, so an item added to it stays). Tapping the microphone listens
/// as holding New Page does, the microphone swapped for the same red waveform, with the same hum;
/// tapping again transcribes what was said with the same on-device model and types it into the
/// focused field at the caret. Holding it instead listens until let go.
@MainActor final class FormAccessoryDictation: UIControl {
    private enum Phase { case idle, listening, transcribing }

    private static let installed = NSMapTable<UIView, FormAccessoryDictation>.weakToStrongObjects()
    private static let size = CGSize(width: 44, height: 36)
    /// The microphone, and the waveform and spinner in its place, a little closer to ✓.
    private static let glyphShift: CGFloat = 3

    private weak var webView: RiseWebView?
    private weak var toolbar: UIToolbar?
    /// ↑ and ↓ a little closer together, the pair further in from the pill's left end, and ✓ a
    /// little closer to the microphone, in points.
    private static let itemShifts = ["_previousTapped": 4.0, "_nextTapped": -2.0, "_done": -3.0]
    private let item: UIBarButtonItem
    private let micGlyph = UIImageView(image: microphone)
    private let waveform = VoiceWaveform()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var phase = Phase.idle
    /// Started by holding, so letting go ends it.
    private var holding = false
    private var transcribing: Task<Void, Never>?
    private var leftWindow: Task<Void, Never>?

    /// Adds the microphone to WebKit's bar, once, when it has one with ✓ (iPhone's).
    static func install(in accessory: UIView, for webView: RiseWebView) {
        guard VoiceInput.isSupported else { return }
        if let existing = installed.object(forKey: accessory) {
            existing.webView = webView
            existing.insert(in: accessory)
            return
        }
        guard doneItem(in: accessory) != nil else { return }
        let dictation = FormAccessoryDictation(webView: webView)
        installed.setObject(dictation, forKey: accessory)
        dictation.insert(in: accessory)
    }

    private static func doneItem(in accessory: UIView) -> (UIToolbar, Int)? {
        for toolbar in toolbars(in: accessory) {
            if let index = toolbar.items?.firstIndex(where: { $0.action.map(NSStringFromSelector) == "_done" }) {
                return (toolbar, index)
            }
        }
        return nil
    }

    private static func toolbars(in view: UIView) -> [UIToolbar] {
        view.subviews.flatMap { ($0 as? UIToolbar).map { [$0] } ?? toolbars(in: $0) }
    }

    /// Pikaicons' mic-on (Stroke, https://pikaicons.com), drawn a point to each of its 24 units,
    /// a little taller than the bar's 17-point symbols, but with their 1.6-point stroke, as ✓ has.
    private static let microphone: UIImage = {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 8, y: 7))
        path.addArc(withCenter: CGPoint(x: 12, y: 7), radius: 4, startAngle: .pi, endAngle: 0, clockwise: true)
        path.addLine(to: CGPoint(x: 16, y: 12))
        path.addArc(withCenter: CGPoint(x: 12, y: 12), radius: 4, startAngle: 0, endAngle: .pi, clockwise: true)
        path.close()
        path.move(to: CGPoint(x: 4, y: 12))
        path.addArc(withCenter: CGPoint(x: 12, y: 12), radius: 8, startAngle: .pi, endAngle: 0, clockwise: false)
        path.move(to: CGPoint(x: 12, y: 20))
        path.addLine(to: CGPoint(x: 12, y: 22))
        return icon(path, size: CGSize(width: 24, height: 24))
    }()

    /// ✓'s replacement: the tick from Pikaicons' check-tick-circle (Stroke), out of its circle,
    /// at 2.25 times its size, a little wider than the symbol it replaces, its stroke a touch heavier.
    private static let check: UIImage = {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 8.5, y: 12.51))
        path.addLine(to: CGPoint(x: 10.84, y: 14.85))
        path.addCurve(to: CGPoint(x: 15.4, y: 9.92), controlPoint1: CGPoint(x: 11.97, y: 12.88),
                      controlPoint2: CGPoint(x: 13.53, y: 11.19))
        path.addLine(to: CGPoint(x: 15.5, y: 9.85))
        // Its bounds' centre to the image's.
        let size = CGSize(width: 20, height: 20)
        path.apply(CGAffineTransform(translationX: size.width/2, y: size.height/2)
            .scaledBy(x: 2.25, y: 2.25).translatedBy(x: -12, y: -12.35))
        return icon(path, size: size, lineWidth: 1.8)
    }()

    /// Stroked as the bar's symbols are: 1.6 points, rounded, tinted as they are.
    private static func icon(_ path: UIBezierPath, size: CGSize, lineWidth: CGFloat = 1.6) -> UIImage {
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        return UIGraphicsImageRenderer(size: size).image { _ in
            UIColor.black.setStroke()
            path.stroke()
        }.withRenderingMode(.alwaysTemplate)
    }

    private init(webView: RiseWebView) {
        self.webView = webView
        item = UIBarButtonItem()
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        item.customView = self
        item.accessibilityLabel = "Dictate"
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "Dictate"
        micGlyph.tintColor = .label
        micGlyph.contentMode = .center
        spinner.hidesWhenStopped = false
        spinner.color = .secondaryLabel
        for glyph in [micGlyph, waveform, spinner] as [UIView] {
            glyph.isUserInteractionEnabled = false
            addSubview(glyph)
        }
        waveform.alpha = 0
        spinner.alpha = 0
        addAction(UIAction { [weak self] _ in self?.tapped() }, for: .touchUpInside)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held))
        hold.minimumPressDuration = 0.35
        addGestureRecognizer(hold)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { Self.size }

    /// Before ✓, unless it's already there, ✓ itself redrawn.
    private func insert(in accessory: UIView) {
        guard let (toolbar, done) = Self.doneItem(in: accessory), var items = toolbar.items else { return }
        self.toolbar = toolbar
        if items[done].image !== Self.check { items[done].image = Self.check }
        if !items.contains(where: { $0 === item }) {
            items.insert(item, at: done)
            toolbar.setItems(items, animated: false)
        }
        nudgeItems()
        // The items' views are made as the toolbar lays out.
        DispatchQueue.main.async { [weak self] in self?.nudgeItems() }
    }

    /// Moves WebKit's ↑, ↓ and ✓ where they're drawn; the toolbar only ever sets their frames.
    private func nudgeItems() {
        let view = NSSelectorFromString("view")
        for item in toolbar?.items ?? [] {
            guard let action = item.action, let shift = Self.itemShifts[NSStringFromSelector(action)],
                  item.responds(to: view), let itemView = item.perform(view)?.takeUnretainedValue() as? UIView else { continue }
            let moved = CGAffineTransform(translationX: shift, y: 0)
            if itemView.transform != moved { itemView.transform = moved }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // By bounds and center, as they scale as they swap.
        for glyph in [micGlyph, waveform, spinner] as [UIView] {
            glyph.bounds = bounds
            glyph.center = CGPoint(x: bounds.midX+Self.glyphShift, y: bounds.midY)
        }
        nudgeItems()
    }

    /// Dims under the finger, as the bar's own buttons do.
    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            dim(isHighlighted && phase == .idle)
        }
    }

    private func dim(_ dimmed: Bool) {
        UIView.animate(withDuration: dimmed ? 0.05 : 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.alpha = dimmed ? 0.3 : 1
        }
    }

    // MARK: Listening

    private var voice: VoiceInput? { webView?.browser?.voice }

    private func tapped() {
        switch phase {
        case .idle: start()
        case .listening: finish()
        case .transcribing: break
        }
    }

    @objc private func held(_ hold: UILongPressGestureRecognizer) {
        switch hold.state {
        case .began:
            switch phase {
            case .idle: start(); holding = phase == .listening
            case .listening: finish()
            case .transcribing: break
            }
        case .ended: if holding { holding = false; finish() }
        case .cancelled, .failed: if holding { holding = false; cancel() }
        default: break
        }
    }

    private func start() {
        guard let voice, voice.begin() else { return }
        phase = .listening
        dim(false)
        waveform.level = { [weak voice] in voice?.level ?? 0 }
        waveform.listen(true)
        accessibilityLabel = "Listening"
        swap(to: waveform)
    }

    /// Stops listening and types what was said into the focused field, a spinner standing in for
    /// the microphone meanwhile.
    private func finish() {
        guard phase == .listening, let voice else { return cancel() }
        let transcription = voice.finish()
        phase = .transcribing
        waveform.listen(false)
        accessibilityLabel = "Transcribing"
        spinner.startAnimating()
        swap(to: spinner)
        transcribing = Task { [weak self] in
            let text = await transcription.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let self, !Task.isCancelled else { return }
            if !text.isEmpty { await webView?.typeDictation(text) }
            reset()
        }
    }

    private func cancel() {
        if phase == .listening { voice?.cancel() }
        transcribing?.cancel()
        transcribing = nil
        reset()
    }

    private func reset() {
        guard phase != .idle else { return }
        phase = .idle
        holding = false
        transcribing = nil
        waveform.listen(false)
        accessibilityLabel = "Dictate"
        swap(to: micGlyph) { [weak self] in self?.spinner.stopAnimating() }
    }

    /// As New Page swaps its plus for the waveform.
    private func swap(to next: UIView, completion: (() -> Void)? = nil) {
        // Whatever an interrupted swap left partly shown, such as the waveform when the
        // transcription lands before it has faded, must leave with this swap.
        BlurCrossfade.stop(in: self)
        let shown = ([micGlyph, waveform, spinner] as [UIView]).filter { $0 !== next && $0.alpha > 0 }
        guard window != nil, !UIAccessibility.isReduceMotionEnabled, let previous = shown.first else {
            for view in [micGlyph, waveform, spinner] as [UIView] { view.alpha = view === next ? 1 : 0; view.transform = .identity }
            completion?()
            return
        }
        BlurCrossfade.swap(from: previous, to: next, alsoHiding: Array(shown.dropFirst()), style: .symbol, completion: completion)
    }

    /// The keyboard going away ends listening and drops what was said, as there's no field left
    /// to type it into. Moving between fields can briefly take the bar out of its window too.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { nudgeItems() }
        leftWindow?.cancel()
        leftWindow = nil
        guard window == nil, phase == .listening else { return }
        leftWindow = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled, window == nil else { return }
            cancel()
        }
    }
}

extension RiseWebView {
    var browser: BrowserViewController? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let browser = next as? BrowserViewController { return browser }
            responder = next
        }
        return nil
    }

    /// Types dictated text at the caret, as the keyboard would, after a space when it follows a word.
    func typeDictation(_ text: String) async {
        let before = try? await evaluateJavaScript(Self.characterBeforeCaret, in: nil, contentWorld: .defaultClient) as? String
        let typed = before.map { !$0.isEmpty && !$0.unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains) } == true
            ? " "+text : text
        let insert = NSSelectorFromString("insertText:")
        if let input = firstResponder(in: self), input.responds(to: insert) {
            input.perform(insert, with: typed)
        } else {
            let quoted = String(data: try! JSONEncoder().encode(typed), encoding: .utf8)!
            _ = try? await evaluateJavaScript("document.execCommand('insertText', false, \(quoted))", in: nil, contentWorld: .defaultClient)
        }
    }

    private func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for subview in view.subviews { if let found = firstResponder(in: subview) { return found } }
        return nil
    }

    private static let characterBeforeCaret = """
    (() => {
      const field = document.activeElement;
      try {
        if (field && typeof field.selectionStart === 'number')
          return field.value.slice(Math.max(0, field.selectionStart - 1), field.selectionStart);
      } catch {}
      const selection = getSelection();
      if (selection && selection.rangeCount) {
        const range = selection.getRangeAt(0);
        if (range.startContainer.nodeType === Node.TEXT_NODE)
          return range.startContainer.data.slice(Math.max(0, range.startOffset - 1), range.startOffset);
      }
      return '';
    })()
    """
}
