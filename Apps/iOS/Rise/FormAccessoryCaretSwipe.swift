import UIKit
import WebKit

/// The empty stretch of WebKit's bar above the keyboard, between ↑ ↓ and the microphone (or ✓),
/// as a trackpad for the caret: swiping across it moves the focused field's caret a character
/// for each character's width the finger travels, as if dragging the caret itself. It moves as
/// the keyboard's own trackpad does (`moveByOffset:`, so a character is what the field counts as
/// one, emoji and all), from the moment the finger first moves, every step sent as the finger
/// gets there rather than queued behind a reply. Against either end of the field the caret
/// stops and waits there, so turning back moves it again at once. A second finger down anywhere
/// on the bar while swiping selects instead, from where the caret was, as far as the first finger
/// goes on; the bar's buttons do nothing while a swipe is on, so it can land on them too.
@MainActor final class FormAccessoryCaretSwipe: NSObject, UIGestureRecognizerDelegate {
    private static let installed = NSMapTable<UIToolbar, FormAccessoryCaretSwipe>.weakToStrongObjects()
    /// Kept clear of the buttons either side, so a tap just off one still reaches it.
    static let buttonMargin: CGFloat = 4

    private weak var toolbar: UIToolbar?
    private let pan = TouchDownPanGestureRecognizer()
    let caret: CaretSwipe
    /// The bar's buttons, turned off while a swipe is on.
    private var stilled: [UIView] = []

    /// Adds the swipe to WebKit's bar, once for each bar.
    static func install(in accessory: UIView, for webView: RiseWebView) {
        for toolbar in toolbars(in: accessory) where toolbar.items?.contains(where: { $0.action.map(NSStringFromSelector) == "_nextTapped" }) == true {
            if let existing = installed.object(forKey: toolbar) {
                existing.caret.webView = webView
            } else {
                installed.setObject(FormAccessoryCaretSwipe(toolbar: toolbar, in: accessory, webView: webView), forKey: toolbar)
            }
        }
    }

    static func installed(on toolbar: UIToolbar) -> FormAccessoryCaretSwipe? { installed.object(forKey: toolbar) }

    private static func toolbars(in view: UIView) -> [UIToolbar] {
        view.subviews.flatMap { ($0 as? UIToolbar).map { [$0] } ?? toolbars(in: $0) }
    }

    /// On the whole bar, its strips above and below the toolbar too, so a second finger can land
    /// anywhere on it.
    private init(toolbar: UIToolbar, in accessory: UIView, webView: RiseWebView) {
        self.toolbar = toolbar
        caret = CaretSwipe(webView: webView)
        super.init()
        pan.addTarget(self, action: #selector(panned))
        pan.delegate = self
        pan.maximumNumberOfTouches = 2
        // The bar's buttons outside the gap keep their touches; inside it there are none to keep.
        pan.cancelsTouchesInView = true
        pan.onTouchDown = { [weak self] in self?.caret.prepare() }
        pan.onSecondTouch = { [weak self] in self?.caret.startSelecting() }
        pan.onPrimaryChanged = { [weak self] in
            guard let self, let toolbar = self.toolbar, let x = self.pan.primaryLocation(in: toolbar)?.x else { return }
            self.caret.rebase(at: x)
        }
        accessory.addGestureRecognizer(pan)
    }

    private static func view(of item: UIBarButtonItem) -> UIView? {
        if let custom = item.customView { return custom }
        let selector = NSSelectorFromString("view")
        guard item.responds(to: selector) else { return nil }
        return item.perform(selector)?.takeUnretainedValue() as? UIView
    }

    /// Between ↓ and the microphone, or ✓ where there's no microphone, in the toolbar's space.
    var gap: ClosedRange<CGFloat>? {
        guard let toolbar, let items = toolbar.items else { return nil }
        let view = Self.view(of:)
        func frame(_ action: String) -> CGRect? {
            items.first { $0.action.map(NSStringFromSelector) == action }.flatMap(view).flatMap { $0.superview?.convert($0.frame, to: toolbar) }
        }
        let microphone = items.first { $0.customView is FormAccessoryDictation }.flatMap(view).flatMap { $0.superview?.convert($0.frame, to: toolbar) }
        guard let next = frame("_nextTapped"), let end = microphone ?? frame("_done") else { return nil }
        let start = next.maxX+Self.buttonMargin, finish = end.minX-Self.buttonMargin
        return start < finish ? start...finish : nil
    }

    /// The first finger in the gap; once swiping, a second anywhere on the bar.
    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if pan.state == .began || pan.state == .changed { return true }
        guard let toolbar, let gap else { return false }
        return gap.contains(touch.location(in: toolbar).x)
    }

    /// While swiping, ↑ ↓, the microphone and ✓ take no touches: one landing on them is the bar's,
    /// and so the swipe's.
    var isSwiping: Bool { !stilled.isEmpty }
    func stillButtons(_ still: Bool) {
        for view in stilled { view.isUserInteractionEnabled = true }
        stilled = []
        guard still else { return }
        stilled = (toolbar?.items ?? []).compactMap(Self.view(of:)).filter(\.isUserInteractionEnabled)
        for view in stilled { view.isUserInteractionEnabled = false }
    }

    /// Across, not down: a swipe down the bar is left to the keyboard.
    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let toolbar else { return false }
        let velocity = pan.velocity(in: toolbar), moved = pan.translation(in: toolbar)
        return abs(velocity.x)+abs(moved.x) >= abs(velocity.y)+abs(moved.y)
    }

    /// By the first finger alone: a second only says to select.
    @objc private func panned() {
        guard let toolbar else { return }
        let x = pan.primaryLocation(in: toolbar)?.x ?? pan.location(in: toolbar).x
        switch pan.state {
        // From where the finger came down, so the caret has already gone as far as the finger has.
        case .began:
            stillButtons(true)
            caret.begin(from: pan.primaryStart(in: toolbar)?.x ?? x-pan.translation(in: toolbar).x, at: x)
        case .changed: caret.move(to: x)
        default:
            stillButtons(false)
            caret.end()
        }
    }
}

/// A pan that also says when the finger comes down, before it has moved far enough to begin,
/// so the caret's whereabouts are read by the time it does, and when a second finger joins it.
/// It follows its first finger, not the middle of its fingers as a pan does, so another landing
/// or lifting doesn't move it; if the first lifts first, it follows the other from there.
final class TouchDownPanGestureRecognizer: UIPanGestureRecognizer {
    var onTouchDown: (() -> Void)?
    var onSecondTouch: (() -> Void)?
    var onPrimaryChanged: (() -> Void)?
    private var touches: [UITouch] = []
    private var primary: UITouch?
    private var start: CGPoint?

    func primaryLocation(in view: UIView) -> CGPoint? { primary?.location(in: view) }
    func primaryStart(in view: UIView) -> CGPoint? { start.map { view.convert($0, from: nil) } }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        self.touches += touches.filter { !self.touches.contains($0) }
        if primary == nil, let first = touches.first {
            primary = first
            start = first.location(in: nil)
            if state == .possible { onTouchDown?() }
        } else if state == .began || state == .changed {
            onSecondTouch?()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        lift(touches)
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        lift(touches)
        super.touchesCancelled(touches, with: event)
    }

    private func lift(_ lifted: Set<UITouch>) {
        touches.removeAll { lifted.contains($0) }
        guard let primary, lifted.contains(primary), let next = touches.first else { return }
        self.primary = next
        onPrimaryChanged?()
    }

    override func reset() {
        super.reset()
        touches = []; primary = nil; start = nil
    }
}

/// Moves the focused field's caret by how far a finger has travelled, a character for each
/// character's width on screen.
@MainActor final class CaretSwipe {
    /// What the swipe needs to know of the field as it starts.
    struct Field: Equatable {
        /// A character's width in the field's font, in the page's points.
        var characterWidth: CGFloat
        /// Characters before and after the caret, where the field can say.
        var before: Int?, after: Int?
        /// Where a selection collapses to before the caret moves, as the field counts.
        var collapse: Int?
    }

    weak var webView: WKWebView?
    /// On screen, however small or large the field's text: too narrow and it races, too wide and it drags.
    static let stepRange: ClosedRange<CGFloat> = 6...18
    /// A little more than a character's width for each character, so it's a touch less eager than
    /// dragging the caret itself.
    static let stepScale: CGFloat = 1.15

    /// Which read is the latest, so an earlier one's late reply is dropped.
    private var reading = 0
    private var prepared = false
    private(set) var field: Field?
    private var swiping = false
    /// Extending a selection from where the caret was, rather than moving it.
    private(set) var selecting = false
    private let selectionTick = UIImpactFeedbackGenerator(style: .light)
    private var origin: CGFloat = 0, latest: CGFloat = 0
    /// The swipe so far, in characters from where the caret started, and where it's counted from.
    private var anchorX: CGFloat = 0, anchorCount = 0
    private(set) var sent = 0
    #if DEBUG
    /// Each move sent, for checks.
    private(set) var moves: [Int] = []
    #endif

    init(webView: WKWebView) { self.webView = webView }

    /// The finger is down: reads the field while it starts to move.
    func prepare() {
        reading += 1
        let read = reading
        field = nil
        prepared = true
        guard let webView else { return }
        webView.evaluateJavaScript(Self.readField, in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, read == self.reading else { return }
                let values = (try? result.get()) as? [String: Any]
                let width = (values?["width"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 8
                self.field = Field(characterWidth: width > 0 ? width : 8,
                                   before: (values?["before"] as? NSNumber)?.intValue, after: (values?["after"] as? NSNumber)?.intValue,
                                   collapse: (values?["collapse"] as? NSNumber)?.intValue)
                if self.swiping { self.started() }
            }
        }
    }

    /// The swipe has begun, the finger having come down at `origin` and now at `x`.
    func begin(from origin: CGFloat, at x: CGFloat) {
        if !prepared { prepare() }
        swiping = true
        self.origin = origin; latest = x
        anchorX = origin; anchorCount = 0; sent = 0
        selecting = false
        selectionTick.prepare()
        #if DEBUG
        moves = []
        #endif
        if field != nil { started() }
    }

    private func started() {
        if let collapse = field?.collapse {
            webView?.evaluateJavaScript(Self.collapseScript(collapse), in: nil, in: .defaultClient, completionHandler: nil)
        }
        move(to: latest)
    }

    func move(to x: CGFloat) {
        latest = x
        guard swiping, let field else { return }
        let step = Self.step(for: field.characterWidth, zoom: (webView?.scrollView.zoomScale).map { $0 > 0 ? $0 : 1 } ?? 1)
        var target = anchorCount+Int(((x-anchorX)/step).rounded())
        // Held at either end, a character's turn short of moving back.
        if let after = field.after, target > after {
            anchorCount = after; anchorX = x-step*0.49; target = after
        } else if let before = field.before, target < -before {
            anchorCount = -before; anchorX = x+step*0.49; target = -before
        }
        send(target-sent)
    }

    /// A second finger: from here on the swipe selects, from where the caret is.
    func startSelecting() {
        guard swiping, !selecting else { return }
        selecting = true
        selectionTick.impactOccurred(intensity: 0.7)
    }

    /// The finger it follows changed: counted from where the new one is, so the caret doesn't jump.
    func rebase(at x: CGFloat) {
        anchorCount = sent; anchorX = x; latest = x
    }

    func end() {
        swiping = false
        selecting = false
        prepared = false
        field = nil
    }

    static func step(for characterWidth: CGFloat, zoom: CGFloat) -> CGFloat {
        min(max(characterWidth*zoom*stepScale, stepRange.lowerBound), stepRange.upperBound)
    }

    private func send(_ offset: Int) {
        guard offset != 0, let webView, let content = Self.contentView(of: webView) else { return }
        if selecting {
            // A character at a time, as Shift and an arrow extend it, its start staying put; forward
            // and back as the caret moves, whichever way the text runs.
            let selector = NSSelectorFromString("_executeEditCommand:argument:completion:")
            guard webView.responds(to: selector) else { return }
            typealias Command = @convention(c) (AnyObject, Selector, NSString, NSString?, AnyObject?) -> Void
            let command = unsafeBitCast(webView.method(for: selector), to: Command.self)
            let name = (offset > 0 ? "MoveForwardAndModifySelection" : "MoveBackwardAndModifySelection") as NSString
            for _ in 0..<abs(offset) { command(webView, selector, name, nil, nil) }
        } else {
            let selector = NSSelectorFromString("moveByOffset:")
            guard content.responds(to: selector) else { return }
            typealias Move = @convention(c) (AnyObject, Selector, Int) -> Void
            unsafeBitCast(content.method(for: selector), to: Move.self)(content, selector, offset)
        }
        sent += offset
        #if DEBUG
        moves.append(offset)
        #endif
    }

    private static func contentView(of webView: WKWebView) -> UIView? {
        webView.scrollView.subviews.first { NSStringFromClass(type(of: $0)) == "WKContentView" }
    }

    /// The focused field, through any frames it's in that the page can reach.
    private static let focusedField = """
    const focused = () => {
      let el = document.activeElement;
      while (el && (el.tagName === 'IFRAME' || el.tagName === 'FRAME')) {
        try { el = el.contentDocument.activeElement; } catch { return null; }
      }
      return el;
    };
    """

    /// How wide its characters are, and how many there are either side of the caret, counted as
    /// the caret moves over them: a whole emoji, or a letter and its accents, is one.
    private static let readField = """
    (() => {
      \(focusedField)
      const el = focused();
      if (!el) return null;
      const count = s => { try { return [...new Intl.Segmenter().segment(s)].length; } catch { return [...s].length; } };
      const style = getComputedStyle(el);
      const context = document.createElement('canvas').getContext('2d');
      context.font = style.font || `${style.fontStyle} ${style.fontWeight} ${style.fontSize} ${style.fontFamily}`;
      const text = typeof el.value === 'string' ? el.value : el.textContent || '';
      let sample = text.slice(0, 400);
      if (el.type === 'password') sample = '•'.repeat(Math.max(1, count(sample)));
      if (!sample.trim()) sample = 'abcdefghijklmnopqrstuvwxyz';
      const spacing = parseFloat(style.letterSpacing) || 0;
      const width = context.measureText(sample).width/count(sample)+spacing;
      const result = { width };
      try {
        if (typeof el.selectionStart === 'number' && typeof el.value === 'string') {
          const start = el.selectionStart, end = el.selectionEnd;
          const at = el.selectionDirection === 'backward' ? start : end;
          result.before = count(el.value.slice(0, at));
          result.after = count(el.value.slice(at));
          if (start !== end) result.collapse = at;
        }
      } catch {}
      return result;
    })()
    """

    private static func collapseScript(_ at: Int) -> String {
        """
        (() => {
          \(focusedField)
          const el = focused();
          try { el.setSelectionRange(\(at), \(at)); } catch {}
        })()
        """
    }
}
