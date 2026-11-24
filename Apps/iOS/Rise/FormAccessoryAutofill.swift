import UIKit
import WebKit

/// Autofill My Information's button in WebKit's bar above the keyboard, just after ↓, shown while
/// the focused field is one the person's card has something for (`FormAutofill`).
///
/// With one thing to fill, a tap fills it, and holding it shows what it would fill, in the system's
/// glass menu grown from the button (choosing it there fills it too). With several (three emails,
/// two addresses), the tap opens that menu with each of them. Once it's filled, the button's icon
/// swaps to Undo, as New Page's plus swaps for the waveform; tapping Undo puts back what the field
/// had and swaps back, so it can be filled again.
@MainActor final class FormAccessoryAutofill: UIButton {
    private static let installed = NSMapTable<UIView, FormAccessoryAutofill>.weakToStrongObjects()
    private static let size = CGSize(width: 40, height: 36)
    /// The glyphs nearer ↓, as ↑ and ↓ are to each other (`FormAccessoryDictation.itemShifts`).
    private static let glyphShift: CGFloat = -7

    private weak var webView: RiseWebView?
    private weak var toolbar: UIToolbar?
    let item: UIBarButtonItem
    /// The glyphs, dimmed together under the finger while each fades in and out on its own.
    private let glyphs = UIView()
    private let fillGlyph = UIImageView(image: UIImage(named: "FormAutofill"))
    private let undoGlyph = UIImageView(image: UIImage(named: "FormAutofillUndo"))
    private var showsUndo = false

    /// Adds the button to WebKit's bar, once, after its ↓ (iPhone's).
    static func install(in accessory: UIView, for webView: RiseWebView) {
        let button: FormAccessoryAutofill
        if let existing = installed.object(forKey: accessory) {
            button = existing
        } else {
            guard nextItem(in: accessory) != nil else { return }
            button = FormAccessoryAutofill()
            installed.setObject(button, forKey: accessory)
        }
        button.webView = webView
        webView.autofill.button = button
        button.insert(in: accessory)
        button.refresh(animated: false)
    }

    private static func nextItem(in accessory: UIView) -> (UIToolbar, Int)? {
        for toolbar in toolbars(in: accessory) {
            if let index = toolbar.items?.firstIndex(where: { $0.action.map(NSStringFromSelector) == "_nextTapped" }) {
                return (toolbar, index)
            }
        }
        return nil
    }

    private static func toolbars(in view: UIView) -> [UIToolbar] {
        view.subviews.flatMap { ($0 as? UIToolbar).map { [$0] } ?? toolbars(in: $0) }
    }

    private init() {
        item = UIBarButtonItem()
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        item.customView = self
        item.isHidden = true
        glyphs.isUserInteractionEnabled = false
        addSubview(glyphs)
        for glyph in [fillGlyph, undoGlyph] {
            glyph.tintColor = .label
            glyph.contentMode = .center
            glyphs.addSubview(glyph)
        }
        undoGlyph.alpha = 0
        isAccessibilityElement = true
        accessibilityTraits = .button
        addAction(UIAction { [weak self] _ in self?.tapped() }, for: .primaryActionTriggered)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { Self.size }

    private func insert(in accessory: UIView) {
        guard let (toolbar, next) = Self.nextItem(in: accessory), var items = toolbar.items else { return }
        self.toolbar = toolbar
        if items.firstIndex(where: { $0 === item }) != next+1 {
            items.removeAll { $0 === item }
            items.insert(item, at: next+1)
            toolbar.setItems(items, animated: false)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glyphs.frame = bounds
        // By bounds and center, as they scale as they swap.
        for glyph in [fillGlyph, undoGlyph] {
            glyph.bounds = bounds
            glyph.center = CGPoint(x: bounds.midX+Self.glyphShift, y: bounds.midY)
        }
    }

    /// Dims under the finger, as the bar's own buttons do.
    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            UIView.animate(withDuration: isHighlighted ? 0.05 : 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.glyphs.alpha = self.isHighlighted ? 0.3 : 1
            }
        }
    }

    private var autofill: FormAutofill? { webView?.autofill }

    /// Undo once the field's filled; otherwise what the focused field can take, if anything.
    func refresh(animated: Bool = true) {
        let undo = autofill?.canUndo ?? false
        let choices = autofill?.choices ?? []
        let kind = autofill?.field?.kind
        let hidden = !undo && choices.isEmpty
        if undo {
            accessibilityLabel = "Undo autofill"
            accessibilityValue = nil
            menu = nil
            showsMenuAsPrimaryAction = false
        } else {
            accessibilityLabel = kind.map { "Fill \(Self.name(of: $0))" } ?? "Fill"
            accessibilityValue = choices.count == 1 ? choices[0].title : nil
            // One thing: a hold shows it. Several: the tap offers them, each with its label.
            menu = choices.isEmpty ? nil : UIMenu(children: choices.map { choice in
                let action = UIAction(title: choice.title) { [weak self] _ in self?.autofill?.fill(choice) }
                if choices.count > 1 { action.subtitle = choice.subtitle }
                return action
            })
            showsMenuAsPrimaryAction = choices.count > 1
        }
        let animating = animated && window != nil && !item.isHidden && !hidden && !UIAccessibility.isReduceMotionEnabled
        show(undo: undo, animated: animating)
        guard item.isHidden != hidden else { return }
        guard animated, window != nil, !UIAccessibility.isReduceMotionEnabled else {
            item.isHidden = hidden
            alpha = 1
            return
        }
        if hidden {
            UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState]) { self.alpha = 0 } completion: { _ in
                if self.autofill.map({ !$0.canUndo && $0.choices.isEmpty }) ?? true { self.item.isHidden = true }
                self.alpha = 1
            }
        } else {
            alpha = 0
            item.isHidden = false
            toolbar?.layoutIfNeeded()
            UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) { self.alpha = 1 }
        }
    }

    /// The fill icon or Undo, swapped as the bar's microphone swaps for its waveform.
    private func show(undo: Bool, animated: Bool) {
        guard undo != showsUndo else { return }
        showsUndo = undo
        let next = undo ? undoGlyph : fillGlyph, previous = undo ? fillGlyph : undoGlyph
        BlurCrossfade.stop(in: glyphs)
        guard animated else {
            next.alpha = 1; next.transform = .identity
            previous.alpha = 0; previous.transform = .identity
            return
        }
        BlurCrossfade.swap(from: previous, to: next, style: .symbol)
    }

    private func tapped() {
        guard let autofill else { return }
        if autofill.canUndo { autofill.undo() }
        else if autofill.choices.count == 1, let choice = autofill.choices.first { autofill.fill(choice) }
    }

    private static func name(of kind: String) -> String {
        switch kind {
        case "name": "name"
        case "given-name": "first name"
        case "additional-name": "middle name"
        case "additional-name-initial": "middle initial"
        case "family-name": "last name"
        case "honorific-prefix": "title"
        case "honorific-suffix": "name suffix"
        case "nickname": "nickname"
        case "organization": "company"
        case "organization-title": "job title"
        case "email": "email"
        case "tel", "tel-national": "phone number"
        case "tel-country-code": "country code"
        case "house-number": "house number"
        case "address-level2": "town or city"
        case "address-level1": "state or region"
        case "address-level3": "district"
        case "county": "county"
        case "postal-code": "postcode"
        case "country": "country"
        case "bday", "bday-day", "bday-month", "bday-year": "birthday"
        case "age": "age"
        case "url-linkedin": "LinkedIn"
        case "url-github": "GitHub"
        case "url-x": "X profile"
        case "url": "website"
        default: "address"
        }
    }
}
