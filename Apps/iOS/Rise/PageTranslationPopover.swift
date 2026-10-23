import UIKit
import WebKit

/// A native popover anchored to the running spinner, without interrupting translation.
@MainActor final class PageTranslationPopover: UIViewController, UIPopoverPresentationControllerDelegate {
    weak var page: WKWebView?
    let documentID: String
    let spinner = AnimatedSymbolButton(symbol: "translate", pointSize: 14)
    let detailLabel = UILabel()
    private let sourceLanguage: String?
    private weak var anchor: UIView?
    private var appearanceObservation: (any UITraitChangeRegistration)?
    private let cancelTranslation: () -> Void
    private var dismissing = false
    private var afterDismiss: [() -> Void] = []

    init(page: WKWebView, documentID: String, sourceLanguage: String?, cancel: @escaping () -> Void) {
        self.page = page; self.documentID = documentID; self.sourceLanguage = sourceLanguage; cancelTranslation = cancel
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .popover
        popoverPresentationController?.delegate = self
        popoverPresentationController?.permittedArrowDirections = .down
    }
    required init?(coder: NSCoder) { fatalError() }

    func anchor(to source: UIView) {
        anchor = source
        popoverPresentationController?.sourceView = source
        popoverPresentationController?.sourceRect = source.bounds
        // The spinner remains holdable while its status popover is visible.
        popoverPresentationController?.passthroughViews = [source]
        followAppearance()
        appearanceObservation = source.registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            [weak self] (_: UIView, _: UITraitCollection) in self?.followAppearance()
        }
    }

    private func followAppearance() {
        guard let anchor else { return }
        let style = anchor.traitCollection.userInterfaceStyle
        overrideUserInterfaceStyle = style
        // The native glass/arrow live outside the content controller's view. Match
        // their presentation container too when the app overrides the system theme.
        popoverPresentationController?.containerView?.overrideUserInterfaceStyle = style
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        followAppearance()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        followAppearance()
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if let appearanceObservation { anchor?.unregisterForTraitChanges(appearanceObservation) }
        appearanceObservation = nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // UIKit owns the glass, corners and arrow. An opaque content/backdrop fill
        // covers that material and makes the arrow merge into More's panel below.
        view.backgroundColor = .clear
        let title = UILabel()
        title.text = "Translating page"
        title.font = PanelHeader.font("OpenRunde-Semibold", size: 17, fallbackWeight: .semibold)
        title.textColor = .label
        title.accessibilityTraits = .header
        title.numberOfLines = 0
        spinner.setLoading(name: "page-translation-loading")
        spinner.tintColor = .label
        spinner.accessibilityLabel = "Translation progress"
        spinner.accessibilityHint = "Hold to cancel translation"
        spinner.addGestureRecognizer(PageTranslationCancelHold { [weak self] in self?.cancelTranslation })
        spinner.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Cancel translation") { [weak self] _ in
            guard let self else { return false }
            cancelTranslation(); return true
        }]
        let heading = UIStackView(arrangedSubviews: [spinner, title])
        heading.axis = .horizontal; heading.alignment = .center; heading.spacing = 10
        spinner.widthAnchor.constraint(equalToConstant: 32).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let detail = detailLabel
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 3
        detail.attributedText = NSAttributedString(string: Self.subtitle(for: sourceLanguage)+"\nHold the spinner to cancel",
                                                   attributes: [.paragraphStyle: paragraph])
        detail.font = PanelHeader.font("OpenRunde-Medium", size: 14, fallbackWeight: .medium)
        detail.textColor = .secondaryLabel
        detail.numberOfLines = 0
        for label in [title, detail] { label.adjustsFontForContentSizeCategory = true }
        let stack = UIStackView(arrangedSubviews: [heading, detail])
        stack.axis = .vertical; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
        ])
        let width = min(280, max(240, (presentingViewController?.view.bounds.width ?? 340)-40))
        preferredContentSize = view.systemLayoutSizeFitting(CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        NotificationCenter.default.addObserver(self, selector: #selector(backgrounded),
            name: UIApplication.willResignActiveNotification, object: nil)
    }

    /// Reuses an in-flight dismissal so an error can be presented after the popover has left.
    func finish(animated: Bool = true, then completion: (() -> Void)? = nil) {
        if let completion { afterDismiss.append(completion) }
        guard !dismissing else { return }
        dismissing = true
        dismiss(animated: animated) { [self] in
            let completions = afterDismiss; afterDismiss.removeAll()
            completions.forEach { $0() }
        }
    }
    @objc private func backgrounded() { finish(animated: false) }
    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }

    static func subtitle(for language: String?) -> String {
        guard let language, let code = Locale.Language(identifier: language).languageCode?.identifier,
              let name = Locale(identifier: "en").localizedString(forLanguageCode: code) else {
            return "Translating this page into English."
        }
        return "Translating from \(name) to English."
    }
}

extension BrowserViewController {
    func addTranslationCancelHold(to spinner: UIView) {
        spinner.addGestureRecognizer(PageTranslationCancelHold { [weak self] in self?.prepareTranslationCancellation() })
        spinner.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Cancel translation") { [weak self] _ in
            guard let cancel = self?.prepareTranslationCancellation() else { return false }
            cancel(); return true
        }]
    }

    func prepareTranslationCancellation() -> (() -> Void)? {
        let page = webView, state = pageTranslation.state(for: webView)
        guard state.busy, let documentID = state.documentID else { return nil }
        return { [weak self, weak page] in
            guard let self, let page, page === webView else { return }
            let state = pageTranslation.state(for: page)
            guard state.documentID == documentID, state.busy else { return }
            bottomBar.showTranslationCancellation()
            pageTranslation.toggle(page)
        }
    }

    func pressTranslation() {
        if pageTranslation.state(for: webView).busy { showTranslationProgress(from: bottomBar.menu.address.translateButton) }
        else { pageTranslation.toggle(webView) }
    }

    func showTranslationProgress(from source: UIView) {
        let page = webView, state = pageTranslation.state(for: webView)
        guard state.busy, let documentID = state.documentID, source.window != nil,
              presentedViewController == nil else { return }
        guard let cancel = prepareTranslationCancellation() else { return }
        let popover = PageTranslationPopover(page: page, documentID: documentID, sourceLanguage: state.language, cancel: cancel)
        popover.anchor(to: source)
        present(popover, animated: true)
    }
}
