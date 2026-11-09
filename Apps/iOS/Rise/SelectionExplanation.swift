import UIKit
import WebKit

/// Explain in Context: the selection menu's item that asks the chosen AI provider what the
/// selected text means where it appears, answering in a popover pointing at the selection.
@MainActor enum SelectionExplanation {
    static let menuIdentifier = UIMenu.Identifier("dev.bartosz.Rise.explainInContext")
    /// Off: an explanation should start at once, and short answers don't need it.
    static let reasoningEffort = "none"
    /// Either side of the selection, from the text around it.
    static let passageRadius = 600
    nonisolated static let systemPrompt = """
    You explain text a reader selected on a web page in Rise, a web browser. They want to know what it means where it appears, so read the passage around it and the rest of the page for the sense it's used in.

    Reply in one or two short sentences, about 35 words at most. Start straight with the meaning in plain words — never with "This means", "It means", "Here", "In this context", "The selected text" or the selection itself followed by "refers to". If the page uses it in a particular or unusual sense, explain that sense, not the dictionary one; if it's a whole sentence or more, say what it's getting at in plainer words. Add why it matters here only when that helps. Write in English. No headings, lists or quotation of the page; **bold** at most one key term.
    """

    static func build(_ builder: UIMenuBuilder, in page: WKWebView) {
        guard builder.system == .context, MobileAISettings.shared.enabled,
              !SelectionTimeMenu.selection(in: page).isEmpty else { return }
        let explain = UIAction(title: "Explain in Context", image: UIImage(systemName: "questionmark.square.dashed")) { [weak page] _ in
            if let page { present(from: page) }
        }
        let menu = UIMenu(identifier: menuIdentifier, options: .displayInline, children: [explain])
        // Beside Look Up and Translate, the system's other ways of understanding a selection.
        if builder.menu(for: .lookup) != nil { builder.insertSibling(menu, afterMenu: .lookup) }
        else { builder.insertChild(menu, atEndOfMenu: .root) }
    }

    static func present(from page: WKWebView) {
        let selection = SelectionTimeMenu.selection(in: page)
        guard !selection.isEmpty, var presenter = page.window?.rootViewController else { return }
        while let presented = presenter.presentedViewController, !presented.isBeingDismissed { presenter = presented }
        let popover = SelectionExplanationPopover(selection: selection, page: page)
        if let rect = nativeSelectionRect(in: page) {
            popover.show(from: presenter, pointingAt: rect)
            return
        }
        Task { [weak page, weak presenter] in
            guard let page, let presenter else { return }
            let rect = await scriptSelectionRect(in: page)
                ?? CGRect(x: page.bounds.midX, y: page.bounds.midY, width: 0, height: 0)
            popover.show(from: presenter, pointingAt: rect)
        }
    }

    /// WebKit's own selection, in the page's coordinates, from any frame and at any zoom.
    static func nativeSelectionRect(in page: WKWebView) -> CGRect? {
        guard let input = page.scrollView.subviews.first(where: { $0 is UITextInput }),
              let text = input as? UITextInput, let range = text.selectedTextRange, !range.isEmpty else { return nil }
        let rects = text.selectionRects(for: range).map(\.rect).filter { $0.width > 0 && $0.height > 0 }
        guard let first = rects.first else { return nil }
        let union = rects.dropFirst().reduce(first) { $0.union($1) }
        return input.convert(union, to: page).intersection(page.bounds).nonEmpty
    }

    /// The main frame's selection, for when WebKit's isn't available.
    private static func scriptSelectionRect(in page: WKWebView) async -> CGRect? {
        let script = """
        const selection = getSelection();
        if (!selection || !selection.rangeCount || selection.isCollapsed) return null;
        const rect = selection.getRangeAt(0).getBoundingClientRect();
        return [rect.left + scrollX, rect.top + scrollY, rect.width, rect.height];
        """
        guard let values = try? await page.runScript(script, arguments: [:], world: nil) as? [Double], values.count == 4 else { return nil }
        let scale = page.scrollView.zoomScale
        let rect = CGRect(x: values[0]*scale, y: values[1]*scale, width: values[2]*scale, height: values[3]*scale)
        return page.scrollView.convert(rect, to: page).intersection(page.bounds).nonEmpty
    }

    /// The text around the selection in the main frame, so the model knows which use it is.
    static func passage(in page: WKWebView) async -> String {
        let script = """
        const selection = getSelection();
        if (!selection || !selection.rangeCount || selection.isCollapsed) return '';
        const range = selection.getRangeAt(0), chosen = String(selection).trim();
        let block = range.commonAncestorContainer;
        if (block.nodeType !== 1) block = block.parentElement;
        while (block && block !== document.body && block.parentElement
               && (getComputedStyle(block).display.startsWith('inline') || (block.innerText || '').length < 200)) block = block.parentElement;
        const all = block ? block.innerText || '' : '', at = all.indexOf(chosen);
        return at < 0 ? all.slice(0, radius * 2) : all.slice(Math.max(0, at - radius), at + chosen.length + radius);
        """
        return (try? await page.runScript(script, arguments: ["radius": passageRadius], world: nil) as? String) ?? ""
    }

    static func messages(selection: String, passage: String, page: PageAssistant.Page) -> [[String: Any]] {
        let context = "Title: \(page.title)\nURL: \(page.url)\n\n<page>\n\(page.text)\n</page>"
        var question = "Selected text: \(selection)"
        if !passage.isEmpty { question += "\n\nWhere it appears:\n<passage>\n\(passage)\n</passage>" }
        let values = ["selection": selection, "passage": passage, "title": page.title, "address": page.url, "text": page.text]
        return [["role": "system", "content": AIPrompt.explain.system(context: context, values: values)], ["role": "user", "content": question]]
    }
}

private extension CGRect {
    var nonEmpty: CGRect? { isNull || isEmpty ? nil : self }
}

/// A native popover pointing at the selection: a mini spinner while the model starts, then the
/// explanation streaming in as Ask's answers do, under a small title.
@MainActor final class SelectionExplanationPopover: UIViewController, UIPopoverPresentationControllerDelegate {
    static let inset: CGFloat = 18
    /// Above the title or explanation, and again below.
    static let top: CGFloat = 16
    static let headerHeight: CGFloat = 18
    static let headerGap: CGFloat = 8
    /// The least room either side of the popover on a narrow phone.
    static let screenMargin: CGFloat = 16
    let selection: String
    private weak var page: WKWebView?
    let spinner = MiniSpinnerView()
    let titleLabel = TorphTextView()
    let answerView = AskAnswerView()
    private var task: Task<Void, Never>?
    private var appearanceObservation: (any UITraitChangeRegistration)?
    private var answering = false
    /// Only while it's still explaining, or to say it couldn't; an explanation stands alone.
    private var showsTitle = true
    private var dismissing = false

    init(selection: String, page: WKWebView) {
        self.selection = selection; self.page = page
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .popover
        popoverPresentationController?.delegate = self
        popoverPresentationController?.permittedArrowDirections = [.up, .down]
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(from presenter: UIViewController, pointingAt rect: CGRect) {
        guard let page else { return }
        popoverPresentationController?.sourceView = page
        popoverPresentationController?.sourceRect = rect
        followAppearance()
        appearanceObservation = page.registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            [weak self] (_: UIView, _: UITraitCollection) in self?.followAppearance()
        }
        presenter.present(self, animated: true)
        explain()
    }

    /// The app can override the system's theme; the popover's glass lives outside this view.
    private func followAppearance() {
        guard let page else { return }
        let style = page.traitCollection.userInterfaceStyle
        overrideUserInterfaceStyle = style
        popoverPresentationController?.containerView?.overrideUserInterfaceStyle = style
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        spinner.tintColor = .secondaryLabel
        titleLabel.font = PanelHeader.font("OpenRunde-Medium", size: 13, fallbackWeight: .medium)
        titleLabel.textColor = .secondaryLabel
        titleLabel.setText("Generating explanation in context", animated: false)
        titleLabel.isAccessibilityElement = true
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityLabel = "Generating explanation in context"
        answerView.accessibilityLabel = "Explanation"
        answerView.isScrollEnabled = true
        answerView.showsVerticalScrollIndicator = false
        answerView.onHeightChanged = { [weak self] in self?.resize() }
        for subview in [spinner, titleLabel, answerView] { view.addSubview(subview) }
        resize()
    }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); followAppearance() }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); followAppearance() }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Sharing's permission alert covers the popover without dismissing it.
        guard isBeingDismissed || presentingViewController == nil else { return }
        task?.cancel(); task = nil
        if let appearanceObservation { page?.unregisterForTraitChanges(appearanceObservation) }
        appearanceObservation = nil
    }

    private var width: CGFloat {
        min(320, (page?.window?.bounds.width ?? 390)-2*Self.screenMargin)
    }
    private var answerWidth: CGFloat { width-2*Self.inset }
    private var maximumAnswerHeight: CGFloat { max(120, (page?.window?.bounds.height ?? 800)*0.4) }
    private var answerTop: CGFloat { Self.top+(showsTitle ? Self.headerHeight+Self.headerGap : 0) }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let spinnerSide: CGFloat = 16
        spinner.frame = CGRect(x: Self.inset, y: Self.top+(Self.headerHeight-spinnerSide)/2, width: spinnerSide, height: spinnerSide)
        let titleX = answering ? Self.inset : spinner.frame.maxX+7
        titleLabel.frame = CGRect(x: titleX, y: Self.top, width: max(0, view.bounds.width-titleX-Self.inset), height: Self.headerHeight)
        let answerHeight = min(maximumAnswerHeight, answerView.revealedHeight(for: answerWidth))
        answerView.frame = CGRect(x: Self.inset, y: answerTop, width: answerWidth, height: answerHeight)
    }

    /// Grows with each revealed line, scrolling once it's as tall as it gets.
    private func resize() {
        let answer = min(maximumAnswerHeight, answerView.revealedHeight(for: answerWidth))
        let content = showsTitle ? Self.headerHeight+(answer > 0 ? Self.headerGap+answer : 0) : answer
        let size = CGSize(width: width, height: ceil(Self.top+content+Self.top))
        guard preferredContentSize != size else { return }
        preferredContentSize = size
        view.setNeedsLayout()
    }

    private func explain() {
        guard let page else { return }
        let selection = selection
        task = Task { [weak self, weak page] in
            do {
                guard let page else { throw CancellationError() }
                let passage = await SelectionExplanation.passage(in: page)
                let snapshot = try await PageAssistant.snapshot(of: page)
                let messages = SelectionExplanation.messages(selection: selection, passage: passage, page: snapshot)
                var choice = MobileAISettings.shared.modelChoice
                choice.effort = SelectionExplanation.reasoningEffort
                var text = ""
                try await ModelService.run(messages, provider: choice) { event in
                    guard case .text(let token) = event, let self else { return }
                    text += token
                    self.show(text, finished: false)
                }
                try Task.checkCancellation()
                self?.show(text.isEmpty ? "No explanation came back. Try again." : text, finished: true)
            } catch is CancellationError {
                // Declined sharing, or the popover went away.
                self?.close()
            } catch {
                guard !Task.isCancelled, let self else { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.show(message, finished: true, title: "Couldn’t explain")
            }
        }
    }

    /// With a title, a failure says so above its reason; otherwise the explanation takes its place.
    private func show(_ text: String, finished: Bool, title: String? = nil) {
        guard !dismissing, !text.isEmpty else { return }
        let titled = title != nil
        if !answering || showsTitle != titled {
            answering = true; showsTitle = titled
            if let title { titleLabel.setText(title); titleLabel.accessibilityLabel = title }
            titleLabel.isAccessibilityElement = titled
            UIView.animate(springDuration: 0.35, bounce: 0, initialSpringVelocity: 0, delay: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.spinner.alpha = 0
                self.spinner.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
                self.titleLabel.alpha = titled ? 1 : 0
                self.view.setNeedsLayout(); self.view.layoutIfNeeded()
            }
        }
        answerView.show(text, finished: finished)
        resize()
        if finished { UIAccessibility.post(notification: .layoutChanged, argument: answerView) }
    }

    private func close() {
        guard !dismissing else { return }
        dismissing = true
        if presentingViewController != nil, !isBeingDismissed { dismiss(animated: true) }
    }

    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }
}
