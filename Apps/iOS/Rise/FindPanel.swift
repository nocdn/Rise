import SwiftUI
import UIKit

/// More's Find field also hosts page questions and streamed answers, using the desktop assistant.
final class FindPanel: UIView, UITextFieldDelegate {
    enum Mode { case find, ask }
    private(set) var mode = Mode.find
    let field = SearchField()
    let modeButton = UIButton(type: .custom)
    var askButton: UIButton { modeButton }
    let sendButton = AnimatedSymbolButton(symbol: "arrow.up.circle.fill")
    var findButton: UIButton { modeButton }
    let answerView = AskAnswerView()
    let shimmer = QuestionShimmer()
    private let modeAccessory = UIView()
    private let modeTitle: ModeButtonTitleState
    private let modeHost: UIHostingController<ModeButtonTitle>
    private let counterHost: UIHostingController<FindCountView>
    private var answerTask: Task<Void, Never>?
    private(set) var isAnswering = false
    /// The question in the field has been answered, and not edited since: sending it again would
    /// repeat the answer, so Send waits for a change, and tapping the field selects it to replace.
    private(set) var isAnswered = false
    private var conversation: [PageAssistant.Turn] = []
    var answer: ((String, [PageAssistant.Turn]) -> AsyncThrowingStream<String, Error>)?
    var clearPassage: (() -> Void)?
    var onHeightChanged: (() -> Void)?
    var maximumAnswerHeight: CGFloat = 280
    static let answerTopPadding: CGFloat = 16
    static let answerBottomPadding: CGFloat = 20
    var answerHeight: CGFloat {
        guard mode == .ask, !answerView.answer.isEmpty else { return 0 }
        let width = max(1, bounds.width-2*SearchPanel.inset-12)
        let height = answerView.revealedHeight(for: width)
        guard height > 0 else { return 0 }
        return Self.answerTopPadding+Self.answerBottomPadding
            + min(maximumAnswerHeight, height)
    }
    let previousButton = FindPanel.button("chevron.up", label: "Previous Match")
    let nextButton = FindPanel.button("chevron.down", label: "Next Match")
    var buttons: [UIButton] { [previousButton, nextButton] }
    /// Which match is showing, of how many.
    let count: FindCount
    private let counter: UIView
    private let controls = UIView()
    /// Searches the page, steps through its matches, or clears them for an empty query.
    var find: ((String, PageFind.Direction) async -> PageFind.Matches)?
    /// Takes the highlights off the page, leaving it where it was scrolled to.
    var clear: (() -> Void)?
    /// Counts searches, so only the latest shows its matches.
    private var generation = 0
    private var matchedQuery: String?
    private var queryHasNoMatches: Bool {
        let query = field.text ?? ""
        return !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && matchedQuery == query && count.total == 0
    }
    private static let counterWidth: CGFloat = 60
    /// Between the count and Previous.
    private static let counterGap: CGFloat = 8
    private static let sendGap: CGFloat = 4
    private static let sendWidth: CGFloat = 36
    /// A subtle inset button in light mode too; dark mode keeps its existing translucent fill.
    private static let modeButtonFill = UIColor { traits in
        traits.userInterfaceStyle == .dark ? SearchPanel.fill.resolvedColor(with: traits)
            : UIColor(red: 242/255, green: 243/255, blue: 246/255, alpha: 1)
    }
    private static func titleWidth(_ title: String) -> CGFloat {
        ceil((title as NSString).size(withAttributes: [.font:
            SearchPanel.roundedFont(ofSize: 15, weight: .semibold, scaled: false)]).width)+20
    }

    private static func button(_ symbol: String, label: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: symbol, withConfiguration:
            UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)), for: .normal)
        button.tintColor = .label
        button.accessibilityLabel = label
        button.shrinksWhenPressed(to: AddressBar.pressedScale)
        return button
    }

    override init(frame: CGRect) {
        let count = FindCount()
        self.count = count
        let titleState = ModeButtonTitleState()
        modeTitle = titleState
        let host = UIHostingController(rootView: FindCountView(count: count))
        host.safeAreaRegions = []
        counterHost = host
        counter = host.view
        counter.backgroundColor = .clear
        counter.isUserInteractionEnabled = false
        let titleHost = UIHostingController(rootView: ModeButtonTitle(state: titleState))
        titleHost.safeAreaRegions = []
        modeHost = titleHost
        super.init(frame: frame)
        field.backgroundColor = SearchPanel.fill
        field.layer.cornerCurve = .continuous
        field.layer.cornerRadius = SearchPanel.cornerRadius
        field.placeholder = "Find on Page"
        field.font = SearchPanel.fieldFont
        field.adjustsFontForContentSizeCategory = true
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 18, height: 1))
        field.leftViewMode = .always
        field.returnKeyType = .next
        field.enablesReturnKeyAutomatically = true
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.delegate = self
        field.addAction(UIAction { [weak self] _ in self?.edited() }, for: .editingChanged)
        controls.addSubview(counter)
        buttons.forEach(controls.addSubview)
        field.rightView = controls
        field.rightViewMode = .always
        previousButton.addAction(UIAction { [weak self] _ in self?.search(.previous) }, for: .primaryActionTriggered)
        nextButton.addAction(UIAction { [weak self] _ in self?.search(.next) }, for: .primaryActionTriggered)
        modeButton.layer.cornerCurve = .continuous
        modeButton.layer.cornerRadius = (SearchPanel.cornerRadius*30/SearchPanel.fieldHeight).rounded()
        modeButton.shrinksWhenPressed(to: BottomBar.pressedScale, filled: true, restingFill: Self.modeButtonFill)
        modeButton.accessibilityLabel = "Ask about the Page"
        titleHost.view.backgroundColor = .clear
        titleHost.view.isUserInteractionEnabled = false
        titleHost.view.accessibilityElementsHidden = true
        titleHost.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        modeButton.addSubview(titleHost.view)
        modeAccessory.bounds = CGRect(x: 0, y: 0,
            width: Self.titleWidth("Find")+Self.sendGap+Self.sendWidth+16, height: SearchPanel.fieldHeight)
        modeAccessory.addSubview(modeButton)
        modeAccessory.addSubview(sendButton)
        sendButton.accessibilityLabel = "Ask about the Page"
        sendButton.shrinksWhenPressed(to: AddressBar.pressedScale)
        sendButton.alpha = 0
        sendButton.isUserInteractionEnabled = false
        sendButton.accessibilityElementsHidden = true
        modeButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if mode == .find { enterAsk() } else { returnToFind() }
        }, for: .primaryActionTriggered)
        sendButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if isAnswering { cancelAnswer() } else { submitQuestion() }
        }, for: .primaryActionTriggered)
        answerView.onHeightChanged = { [weak self] in self?.onHeightChanged?() }
        addSubview(field)
        addSubview(answerView)
        layoutModeAccessory()
        updateSend()
        show(nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Inline SwiftUI views use the field's bounds, without inheriting the window's bottom insets.
    func attachHosts(to parent: UIViewController) {
        for host in [counterHost as UIViewController, modeHost as UIViewController] where host.parent == nil {
            parent.addChild(host)
            host.didMove(toParent: parent)
        }
    }

    private func layoutModeAccessory() {
        let width = Self.titleWidth(mode == .ask ? "Find" : "Ask")
        modeButton.bounds = CGRect(x: 0, y: 0, width: width, height: 30)
        modeButton.center = CGPoint(x: mode == .ask ? 8+width/2 : modeAccessory.bounds.width-8-width/2,
                                    y: SearchPanel.fieldHeight/2)
        modeHost.view.frame = modeButton.bounds
        sendButton.bounds = CGRect(x: 0, y: 0, width: Self.sendWidth, height: SearchPanel.fieldHeight)
        sendButton.center = CGPoint(x: modeAccessory.bounds.width-8-Self.sendWidth/2, y: SearchPanel.fieldHeight/2)
    }

    private func setMode(_ next: Mode) {
        guard next != mode else { return }
        mode = next
        let animate = window != nil && !UIAccessibility.isReduceMotionEnabled
        modeButton.accessibilityLabel = next == .ask ? "Return to Find on Page" : "Ask about the Page"
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { modeTitle.asking = next == .ask }
        if animate {
            UIView.animate(springDuration: 0.25, bounce: 0.12, initialSpringVelocity: 0, delay: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction]) { self.layoutModeAccessory() }
            BlurCrossfade.swap(from: next == .find ? sendButton : nil,
                               to: next == .ask ? sendButton : nil, style: .symbol)
        } else {
            layoutModeAccessory()
            BlurCrossfade.stop(in: modeAccessory)
            sendButton.alpha = next == .ask ? 1 : 0
            sendButton.transform = .identity
        }
        sendButton.isUserInteractionEnabled = next == .ask
        sendButton.accessibilityElementsHidden = next != .ask
        updateSend()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        field.frame = CGRect(x: SearchPanel.inset, y: 0, width: bounds.width-2*SearchPanel.inset, height: SearchPanel.fieldHeight)
        // As Back and Forward sit in the address: the outer one as far in as Reload, the inner close by.
        let width = AddressBar.buttonWidth, height = SearchPanel.fieldHeight
        let outer = AddressBar.outerCentre, inner = outer+AddressBar.pairSpacing
        // UITextField owns each accessory's origin. Only set its size here; resetting its frame
        // to zero moves the buttons over the question whenever the sheet relayouts.
        controls.bounds = CGRect(x: 0, y: 0, width: Self.counterWidth+Self.counterGap+inner+width/2, height: height)
        let right = controls.bounds.width
        for (button, centre) in [(previousButton, inner), (nextButton, outer)] {
            button.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            button.center = CGPoint(x: right-centre, y: height/2)
        }
        counter.frame = CGRect(x: 0, y: 0, width: Self.counterWidth, height: height)
        answerView.frame = CGRect(x: SearchPanel.inset+6, y: height+Self.answerTopPadding,
            width: max(0, bounds.width-2*SearchPanel.inset-12),
            height: max(0, bounds.height-height-Self.answerTopPadding-Self.answerBottomPadding))
        answerView.isHidden = mode != .ask || answerView.answer.isEmpty
    }

    /// Each time the panel opens, the field starts empty and focused.
    func begin() {
        resetAsk()
        generation += 1
        field.text = ""
        show(nil)
        _ = field.becomeFirstResponder()
    }

    /// Takes the matches off the page as the panel closes.
    func end() {
        let wasAsking = mode == .ask
        resetAsk()
        generation += 1
        _ = field.resignFirstResponder()
        field.text = ""
        show(nil)
        clear?()
        if wasAsking { clearPassage?() }
    }

    /// Typing searches again, its count changing at once; stepping moves the current match, its
    /// number rolling over to the next.
    func search(_ direction: PageFind.Direction) {
        guard let find else { return }
        let query = field.text ?? ""
        generation += 1
        matchedQuery = nil
        let generation = generation
        // Restore the empty field immediately, without waiting for WebKit to clear its highlights.
        if query.isEmpty || count.total == nil { show(nil) }
        Task { [weak self] in
            let matches = await find(query, query.isEmpty ? .restart : direction)
            guard let self, self.generation == generation else { return }
            matchedQuery = query
            show(query.isEmpty ? nil : matches, stepping: direction != .restart)
        }
    }

    private func show(_ matches: PageFind.Matches?, stepping: Bool = false) {
        let index = max(0, matches?.index ?? 0), total = matches?.count
        if stepping, total == count.total, index != count.index, !UIAccessibility.isReduceMotionEnabled {
            withAnimation(.snappy(duration: 0.3)) { count.index = index }
        } else {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                count.index = index
                count.total = total
            }
        }
        // No matches turns the text red, as on the Mac.
        field.textColor = total == 0 ? .systemRed : .label
        let empty = (field.text ?? "").isEmpty
        controls.isHidden = empty
        field.rightView = empty ? modeAccessory : controls
        field.rightViewMode = .always
        let steps = (total ?? 0) > 0
        for button in buttons { button.isEnabled = steps }
        field.accessibilityValue = total.map { $0 == 0 ? "No matches" : "\(index+1) of \($0)" }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if mode == .ask { if !isAnswering, !isAnswered { submitQuestion() } }
        else if (count.total ?? 0) > 0 { search(.next) }
        else if queryHasNoMatches { enterAsk() }
        return false
    }

    private func edited() {
        isAnswered = false
        if mode == .find { search(.restart) }
        else { cancelAnswer(); updateSend() }
    }

    /// After an answer, a tap on the field selects the question, ready to type the next one.
    func textFieldDidBeginEditing(_ textField: UITextField) {
        guard mode == .ask, isAnswered else { return }
        // After the tap has placed its caret.
        DispatchQueue.main.async { [weak self] in
            guard let self, isAnswered, field.isFirstResponder else { return }
            field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
        }
    }

    func enterAsk() {
        guard mode == .find, (field.text ?? "").isEmpty || queryHasNoMatches else { return }
        generation += 1
        setMode(.ask)
        clear?()
        field.placeholder = "Ask about the Page"
        field.textColor = .label
        field.accessibilityValue = nil
        field.returnKeyType = .send
        field.rightView = modeAccessory
        field.rightViewMode = .always
        updateSend()
        _ = field.becomeFirstResponder()
    }

    func returnToFind() {
        clearPassage?()
        begin()
        onHeightChanged?()
    }

    private func resetAsk() {
        isAnswered = false
        cancelAnswer()
        conversation = []
        answerView.reset()
        setMode(.find)
        field.placeholder = "Find on Page"
        field.returnKeyType = .next
    }

    private func updateSend() {
        sendButton.isEnabled = mode == .ask && (isAnswering || (!isAnswered
            && !(field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
        sendButton.setSymbol(isAnswering ? "stop.circle.fill" : "arrow.up.circle.fill")
        sendButton.accessibilityLabel = isAnswering ? "Stop Answer" : "Ask about the Page"
    }

    func cancelAnswer() {
        generation += 1
        answerTask?.cancel(); answerTask = nil
        isAnswering = false
        shimmer.stop()
        if !answerView.answer.isEmpty { answerView.show(answerView.answer, finished: true) }
        updateSend()
    }

    func submitQuestion() {
        let question = (field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard mode == .ask, !question.isEmpty, let answer else { return }
        isAnswered = false
        cancelAnswer()
        let request = generation
        answerView.reset()
        isAnswering = true
        updateSend()
        _ = field.resignFirstResponder()
        shimmer.start(on: field)
        let tokens = answer(question, conversation)
        answerTask = Task { [weak self] in
            var text = ""
            do {
                for try await token in tokens {
                    guard !Task.isCancelled, let self, self.generation == request else { return }
                    text += token
                    if !token.isEmpty { answerView.show(text) }
                }
                guard !Task.isCancelled, let self, self.generation == request else { return }
                let answered = !text.isEmpty
                if text.isEmpty { text = "No answer came back. Try asking again." }
                else { conversation.append(PageAssistant.Turn(question: question, answer: text)) }
                answerView.show(text, finished: true)
                finishQuestion(answered: answered)
            } catch {
                guard !Task.isCancelled, let self, self.generation == request else { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                answerView.show(text.isEmpty ? message : text+"\n\n"+message, finished: true)
                finishQuestion(answered: false)
            }
        }
    }

    /// A failed or empty answer leaves Send ready to try the same question again.
    private func finishQuestion(answered: Bool) {
        answerTask = nil
        isAnswering = false
        isAnswered = answered
        shimmer.finish()
        updateSend()
    }
}

/// Which match is showing, of how many; nil for no search.
@Observable final class FindCount {
    var index = 0
    var total: Int?
}

/// "4/5": the current match's number rolls to the next as it steps; the count just changes.
struct FindCountView: View {
    let count: FindCount

    var body: some View {
        // A little air either side of the slash.
        HStack(spacing: 1.5) {
            if let total = count.total {
                let number = total == 0 ? 0 : count.index+1
                Text("\(number)")
                    .contentTransition(.numericText(value: Double(number)))
                Text("/")
                Text("\(total)")
            }
        }
        .font(Font(SearchPanel.roundedFont(ofSize: 15, weight: .medium, scaled: false)))
        .monospacedDigit()
        .foregroundStyle(Color(uiColor: SearchPanel.iconColor))
        .lineLimit(1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }
}

@Observable final class ModeButtonTitleState {
    var asking = false
}

/// The title changes immediately while UIKit springs the button's width and position.
struct ModeButtonTitle: View {
    let state: ModeButtonTitleState
    var body: some View {
        Text(state.asking ? "Find" : "Ask")
            .font(Font(SearchPanel.roundedFont(ofSize: 15, weight: .semibold, scaled: false)))
            .foregroundStyle(Color(uiColor: BottomBar.plusTint))
            .lineLimit(1)
            .fixedSize()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
