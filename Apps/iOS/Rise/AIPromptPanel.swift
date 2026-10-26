import UIKit
import CoreHaptics

/// One AI feature's prompt, in full, to rewrite: a field as tall as the prompt, up to what the
/// sheet allows, its placeholders in blue or, malformed, red; then Hold to reset and Save
/// prompt, the size of More's Settings and Downloads. The keyboard grows the sheet to keep the
/// whole prompt in sight above it, as far as the sheet goes; past that the field shortens.
final class AIPromptPanel: UIView, UITextViewDelegate {
    static var editorFont: UIFont { UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 16)) }
    static let editorInsets = UIEdgeInsets(top: 14, left: 11, bottom: 14, right: 11)
    /// The field's least height, two lines, so it stays usable over the keyboard.
    static var minimumEditorHeight: CGFloat { ceil(editorFont.lineHeight*2)+editorInsets.top+editorInsets.bottom }
    static let placeholderBlue = UIColor(red: 0, green: 137/255, blue: 243/255, alpha: 1)
    private let header = PanelHeader(title: "")
    var closeButton: AnimatedSymbolButton { header.closeButton }
    let editor = UITextView()
    private let detail = UILabel()
    let resetButton = HoldToResetButton(title: "Hold to reset")
    let saveButton = PanelTextButton(title: "Save prompt", colour: .systemBlue)
    private(set) var prompt = AIPrompt.summarise
    var buttons: [UIButton] { [closeButton, resetButton, saveButton] }
    /// How far the keyboard reaches up into the panel.
    var keyboardOverlap: CGFloat = 0 {
        didSet { guard keyboardOverlap != oldValue else { return }; setNeedsLayout() }
    }
    /// The prompt grew or shrank by a line: the sheet follows.
    var onHeightChange: () -> Void = {}
    private var lastNaturalHeight: CGFloat = 0
    private var problem: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        header.closeButton.accessibilityLabel = "Back to AI Options"
        addSubview(header)
        editor.font = Self.editorFont
        editor.adjustsFontForContentSizeCategory = true
        editor.textColor = .label
        editor.backgroundColor = SearchPanel.fill
        editor.layer.cornerCurve = .continuous
        editor.layer.cornerRadius = MenuPanel.cornerRadius
        editor.textContainerInset = Self.editorInsets
        editor.alwaysBounceVertical = false
        editor.smartQuotesType = .no
        editor.smartDashesType = .no
        editor.delegate = self
        addSubview(editor)
        detail.font = PanelHeader.font("OpenRunde-Regular", size: 13, fallbackWeight: .regular)
        detail.adjustsFontForContentSizeCategory = true
        detail.numberOfLines = 0
        addSubview(detail)
        resetButton.onReset = { [weak self] in
            guard let self else { return }
            prompt.reset()
            editor.text = prompt.defaultText
            editor.setContentOffset(.zero, animated: false)
            textChanged()
        }
        addSubview(resetButton)
        addSubview(saveButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Fills the panel with a prompt as it's in use now.
    func show(_ prompt: AIPrompt) {
        self.prompt = prompt
        header.title = prompt.title
        editor.accessibilityLabel = prompt.title
        editor.text = prompt.text
        editor.setContentOffset(.zero, animated: false)
        resetButton.settle()
        textChanged(resizing: false)
        lastNaturalHeight = 0
    }

    func save() {
        editor.resignFirstResponder()
        prompt.save(editor.text)
    }

    func textViewDidChange(_ textView: UITextView) { textChanged() }

    private func textChanged(resizing: Bool = true) {
        let text = editor.text ?? ""
        let found = PromptPlaceholder.scan(text, known: prompt.placeholders)
        problem = found.first { !$0.isValid }?.problem
        highlight(found)
        // Only a prompt that differs from Rise's own has anything to reset; a malformed one
        // can't be saved until it's fixed.
        resetButton.isEnabled = text.trimmingCharacters(in: .whitespacesAndNewlines) != prompt.defaultText
        saveButton.isEnabled = problem == nil
        saveButton.accessibilityHint = problem
        updateDetail()
        setNeedsLayout()
        guard resizing, bounds.width > 0 else { return }
        let natural = naturalHeight(width: bounds.width, keyboardOverlap: keyboardOverlap)
        if abs(natural-lastNaturalHeight) > 0.5 { lastNaturalHeight = natural; onHeightChange() }
    }

    /// Colours the placeholders in place, keeping the selection and what's being typed.
    private func highlight(_ found: [PromptPlaceholder]) {
        guard editor.markedTextRange == nil else { return }
        let storage = editor.textStorage, whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: Self.editorFont, .foregroundColor: UIColor.label], range: whole)
        for placeholder in found where NSMaxRange(placeholder.range) <= storage.length {
            storage.addAttribute(.foregroundColor, value: placeholder.isValid ? Self.placeholderBlue : UIColor.systemRed,
                                 range: placeholder.range)
        }
        storage.endEditing()
        editor.typingAttributes = [.font: Self.editorFont, .foregroundColor: UIColor.label]
    }

    /// What Rise sends with the prompt, its placeholders in blue, or what's wrong, in red.
    private func updateDetail() {
        let font = detail.font!
        if let problem {
            detail.attributedText = NSAttributedString(string: problem, attributes: [.font: font, .foregroundColor: UIColor.systemRed])
            return
        }
        let text = NSMutableAttributedString(string: prompt.detail, attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel])
        for placeholder in PromptPlaceholder.scan(prompt.detail, known: prompt.placeholders) where placeholder.isValid {
            text.addAttribute(.foregroundColor, value: Self.placeholderBlue, range: placeholder.range)
        }
        detail.attributedText = text
    }

    // MARK: Height

    private func contentWidth(_ width: CGFloat) -> CGFloat { 4*MenuPanel.tileSize(width: width).width+3*MenuPanel.spacing }

    private func detailHeight(width: CGFloat) -> CGFloat {
        ceil(detail.sizeThatFits(CGSize(width: max(0, contentWidth(width)-32), height: .greatestFiniteMagnitude)).height)
    }

    /// Everything but the field.
    private func chromeHeight(width: CGFloat) -> CGFloat {
        PanelHeader.height+MenuPanel.top+12+detailHeight(width: width)+SiteSettingsPanel.groupGap+MenuPanel.settingsButtonHeight
    }

    /// The whole prompt's height in the field. Measured from the text itself, since the field's
    /// own measure only estimates lines it hasn't laid out yet, and comes up short.
    private func editorHeight(width: CGFloat) -> CGFloat {
        let inner = contentWidth(width)-Self.editorInsets.left-Self.editorInsets.right-2*editor.textContainer.lineFragmentPadding
        let text = NSMutableAttributedString(string: editor.text ?? "", attributes: [.font: Self.editorFont])
        // A last empty line, after a return, still takes a line.
        if text.string.isEmpty || text.string.hasSuffix("\n") { text.append(NSAttributedString(string: " ", attributes: [.font: Self.editorFont])) }
        let fits = text.boundingRect(with: CGSize(width: max(1, inner), height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height
        return max(Self.minimumEditorHeight, ceil(fits)+Self.editorInsets.top+Self.editorInsets.bottom+1)
    }

    /// As tall as the whole prompt, above a keyboard reaching this far into the panel; the sheet's
    /// own limit cuts it short.
    func naturalHeight(width: CGFloat, keyboardOverlap: CGFloat = 0) -> CGFloat {
        chromeHeight(width: width)+editorHeight(width: width)+keyboardOverlap
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: PanelHeader.height)
        let width = contentWidth(bounds.width), x = (bounds.width-width)/2
        // From the bottom up, over the keyboard: the buttons, the subtitle, then the field takes
        // what's left.
        let height = MenuPanel.settingsButtonHeight, bottom = bounds.height-keyboardOverlap
        let half = 2*MenuPanel.tileSize(width: bounds.width).width+MenuPanel.spacing
        for (index, button) in ([resetButton, saveButton] as [PanelTextButton]).enumerated() {
            // By bounds and center, as pressed buttons are scaled.
            button.bounds = CGRect(x: 0, y: 0, width: half, height: height)
            button.center = CGPoint(x: x+CGFloat(index)*(half+MenuPanel.spacing)+half/2, y: bottom-height/2)
        }
        let detailHeight = detailHeight(width: bounds.width)
        detail.frame = CGRect(x: x+16, y: bottom-height-SiteSettingsPanel.groupGap-detailHeight, width: max(0, width-32), height: detailHeight)
        let top = PanelHeader.height+MenuPanel.top
        let wasShorter = editor.frame.height
        editor.frame = CGRect(x: x, y: top, width: width, height: max(0, detail.frame.minY-12-top))
        if editor.isFirstResponder, editor.frame.height < wasShorter-0.5 {
            editor.scrollRangeToVisible(editor.selectedRange)
        }
    }
}

/// A button in a panel that's just words, filled and pressed as More's Settings and Downloads.
class PanelTextButton: UIButton {
    static var font: UIFont { PanelHeader.font("OpenRunde-Semibold", size: 16, fallbackWeight: .semibold) }
    let textLabel = UILabel()

    init(title text: String, colour: UIColor) {
        super.init(frame: .zero)
        layer.cornerCurve = .continuous
        layer.cornerRadius = MenuPanel.cornerRadius
        clipsToBounds = true
        textLabel.text = text
        textLabel.font = Self.font
        textLabel.adjustsFontForContentSizeCategory = true
        textLabel.textColor = colour
        textLabel.textAlignment = .center
        textLabel.isUserInteractionEnabled = false
        textLabel.isAccessibilityElement = false
        addSubview(textLabel)
        accessibilityLabel = text
        shrinksWhenPressed(to: MenuPanel.pressedScale, filled: true)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.textLabel.alpha = self.isEnabled ? 1 : 0.35
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        textLabel.frame = bounds.insetBy(dx: 12, dy: 0)
    }
}

/// Resets only when held: red fills it from the left while it hums, as dictating does, its words
/// turning red as the red passes under them. Let go early, the red runs quickly back to the
/// left; held to the end, it resets with a success haptic and the red fades away.
final class HoldToResetButton: PanelTextButton {
    static let holdDuration: TimeInterval = 1.5
    /// A solid pastel red, leaning pink.
    static let progressColour = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 1, green: 0.71, blue: 0.76, alpha: 1) : UIColor(red: 1, green: 0.84, blue: 0.86, alpha: 1) }
    /// The words over the red, in an intense pinkish red.
    static let progressTextColour = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.78, green: 0, blue: 0.2, alpha: 1) : UIColor(red: 0.88, green: 0.02, blue: 0.24, alpha: 1) }
    var onReset: () -> Void = {}
    /// The red fill, which clips a red copy of the words to itself.
    private let progress = UIView()
    private let redLabel = UILabel()
    /// 0 empty, 1 full, as laid out; animations run between the two.
    private var fraction: CGFloat = 0
    private var holding = false
    private var hold = 0
    private let hum = HoldHum()

    init(title text: String) {
        super.init(title: text, colour: .label)
        progress.backgroundColor = Self.progressColour
        progress.isUserInteractionEnabled = false
        progress.clipsToBounds = true
        redLabel.text = text
        redLabel.font = Self.font
        redLabel.adjustsFontForContentSizeCategory = true
        redLabel.textColor = Self.progressTextColour
        redLabel.textAlignment = .center
        redLabel.isAccessibilityElement = false
        progress.addSubview(redLabel)
        // Over the plain words, so the red ones cover them where the fill has reached.
        addSubview(progress)
        accessibilityHint = "Resets to Rise’s own prompt."
        addAction(UIAction { [weak self] _ in self?.begin() }, for: .touchDown)
        addAction(UIAction { [weak self] _ in self?.cancel() }, for: [.touchUpInside, .touchUpOutside, .touchDragExit, .touchCancel])
    }

    required init?(coder: NSCoder) { fatalError() }

    var shownFraction: CGFloat {
        guard bounds.width > 0 else { return fraction }
        return (progress.layer.presentation()?.bounds.width ?? progress.bounds.width)/bounds.width
    }

    private func begin() {
        guard isEnabled else { return }
        holding = true
        hold += 1
        let id = hold, shown = shownFraction
        stopProgress(at: shown)
        progress.alpha = 1
        hum.start()
        fraction = 1
        // Carries on from wherever a quick release left the red, at the same pace.
        UIView.animate(withDuration: Self.holdDuration*Double(1-shown), delay: 0, options: [.curveLinear, .allowUserInteraction]) {
            self.layoutProgress()
        } completion: { [weak self] finished in
            guard let self, finished, holding, hold == id else { return }
            complete()
        }
    }

    private func cancel() {
        guard holding else { return }
        holding = false
        hold += 1
        hum.stop()
        stopProgress(at: shownFraction)
        fraction = 0
        UIView.animate(springDuration: 0.28, bounce: 0, initialSpringVelocity: 0, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.layoutProgress()
        }
    }

    private func complete() {
        holding = false
        hold += 1
        let id = hold
        hum.stop()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onReset()
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            self.progress.alpha = 0
        } completion: { [weak self] _ in
            guard let self, hold == id else { return }
            fraction = 0
            layoutProgress()
            progress.alpha = 1
        }
    }

    /// Empty, at once, as a different prompt shows.
    func settle() {
        holding = false
        hold += 1
        hum.stop()
        stopProgress(at: 0)
        progress.alpha = 1
    }

    private func stopProgress(at shown: CGFloat) {
        progress.layer.removeAllAnimations()
        fraction = min(1, max(0, shown))
        UIView.performWithoutAnimation { layoutProgress() }
    }

    private func layoutProgress() {
        progress.frame = CGRect(x: 0, y: 0, width: bounds.width*fraction, height: bounds.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The red words sit exactly over the plain ones, whatever the fill's width.
        redLabel.frame = textLabel.frame
        if progress.layer.animationKeys() == nil { layoutProgress() }
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        complete()
        return true
    }
}

/// The soft, constant hum of dictating, while something is held.
@MainActor final class HoldHum {
    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?

    func start() {
        guard player == nil, CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let engine = try engine ?? CHHapticEngine()
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = false
            try engine.start()
            self.engine = engine
            let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.22),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0),
            ], relativeTime: 0, duration: 30)
            let player = try engine.makeAdvancedPlayer(with: CHHapticPattern(events: [event], parameters: []))
            player.loopEnabled = true
            try player.start(atTime: CHHapticTimeImmediate)
            self.player = player
        } catch {
            player = nil
        }
    }

    func stop() {
        guard let player else { return }
        try? player.stop(atTime: CHHapticTimeImmediate)
        self.player = nil
        engine?.stop()
    }
}
