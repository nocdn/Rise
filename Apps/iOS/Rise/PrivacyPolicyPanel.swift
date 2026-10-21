import UIKit
import WebKit

/// Settings grows into this surface. A native settings row and subtitle scroll above the policy.
final class PrivacyPolicyPanel: UIView, WKNavigationDelegate {
    static var height: CGFloat { AppSettingsPanel.height+100 }
    private let header = PanelHeader(title: "Privacy Policy")
    var closeButton: AnimatedSymbolButton { header.closeButton }
    let sharingRow = SettingsToggleRow("AI data sharing", icon: MenuIcons.aiSharing, colour: .systemBlue, iconSide: 26, on: false)
    private let detail = UILabel()
    private let settings: MobileAISettings
    private(set) var policyView: WKWebView?
    private var positionedHeader = false
    private let bottomFade = CAGradientLayer()
    var openLink: ((URL) -> Void)?
    var buttons: [UIButton] { [closeButton, sharingRow] }

    init(settings: MobileAISettings = .shared) {
        self.settings = settings
        super.init(frame: .zero)
        addSubview(header)
        closeButton.accessibilityLabel = "Back to Settings"
        sharingRow.layer.cornerCurve = .continuous
        sharingRow.layer.cornerRadius = MenuPanel.cornerRadius
        sharingRow.clipsToBounds = true
        sharingRow.toggle.onTintColor = SiteSettingsPanel.switchBlue
        sharingRow.onChanged = { [weak self] allowed in
            guard let self else { return }
            if allowed, settings.enabled {
                // The policy and the provider named below the switch disclose the transfer;
                // deliberately turning it on is permission, never merely opening this panel.
                settings.allowSharing(with: settings.provider)
            } else { settings.revokeSharingConsent() }
            refresh()
        }
        addSubview(sharingRow)
        detail.font = PanelHeader.font("OpenRunde-Regular", size: 13, fallbackWeight: .regular)
        detail.adjustsFontForContentSizeCategory = true
        detail.textColor = .secondaryLabel
        detail.numberOfLines = 0
        addSubview(detail)
        let steps = SummariseMotion.followUpFade.steps
        bottomFade.colors = [UIColor.black.cgColor]+steps.map { UIColor(white: 0, alpha: $0.alpha).cgColor }+[UIColor.clear.cgColor]
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Lazily start the local document; ordinary browser startup creates no extra WebKit process.
    func prepare() {
        if policyView == nil {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            let policy = WKWebView(frame: .zero, configuration: configuration)
            policy.navigationDelegate = self
            policy.isOpaque = false
            policy.backgroundColor = .clear
            policy.scrollView.backgroundColor = .clear
            policy.scrollView.contentInsetAdjustmentBehavior = .never
            policyView = policy
            addSubview(policy)
            // A native header in WebKit's own scroll view avoids nested scrollers and
            // keeps the policy's rendering viewport small, however long its text is.
            policy.scrollView.addSubview(sharingRow)
            policy.scrollView.addSubview(detail)
            if let url = Bundle.main.url(forResource: "PrivacyPolicy", withExtension: "html"),
               let html = try? String(contentsOf: url, encoding: .utf8) {
                // The native panel header supplies the title, just as on Settings.
                let document = html.replacingOccurrences(of: "<h1>Rise for iOS Privacy Policy</h1>", with: "")
                    .replacingOccurrences(of: "margin:24px auto", with: "margin:0 auto")
                    .replacingOccurrences(of: "padding:0 20px", with: "padding:0 \(MenuPanel.inset+16)px")
                policy.loadHTMLString(document, baseURL: nil)
            }
        }
        refresh()
        layoutIfNeeded()
        scrollToStart()
    }

    func refresh() {
        sharingRow.toggle.setOn(settings.enabled && settings.hasSharingConsent(for: settings.provider), animated: window != nil)
        sharingRow.isEnabled = settings.enabled
        sharingRow.toggle.isEnabled = settings.enabled
        sharingRow.updateIcon()
        detail.text = settings.enabled
            ? "Share with \(settings.provider.title). Turn off to withdraw permission."
            : "AI features are off. Enable them in Settings to allow sharing."
        sharingRow.toggle.accessibilityHint = "\(detail.text ?? "") Turning off withdraws permission for all AI providers."
        setNeedsLayout()
    }

    func canPullToClose(at point: CGPoint, velocity: CGPoint) -> Bool {
        guard let scroll = policyView?.scrollView,
              scroll.bounds.contains(convert(point, to: scroll)) else { return true }
        return velocity.y > abs(velocity.x) && scroll.contentOffset.y <= -scroll.adjustedContentInset.top+1
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: PanelHeader.height)
        let width = 4*MenuPanel.tileSize(width: bounds.width).width+3*MenuPanel.spacing
        let textWidth = max(0, width-32)
        let caption = detail.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude))
        let headerHeight = MenuPanel.top+SiteSettingsPanel.rowHeight+12+caption.height+SiteSettingsPanel.groupGap
        let top = PanelHeader.height+8
        policyView?.frame = CGRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height-top))
        sharingRow.bounds = CGRect(x: 0, y: 0, width: width, height: SiteSettingsPanel.rowHeight)
        sharingRow.center = CGPoint(x: bounds.midX, y: -headerHeight+MenuPanel.top+SiteSettingsPanel.rowHeight/2)
        detail.frame = CGRect(x: bounds.midX-width/2+16, y: sharingRow.frame.maxY+12, width: textWidth, height: caption.height)
        if let scroll = policyView?.scrollView {
            let wasAtStart = !positionedHeader || abs(scroll.contentOffset.y+scroll.adjustedContentInset.top) < 1
            scroll.contentInset.top = headerHeight
            // Let the final line scroll above the fade, with a little clear space after it.
            scroll.contentInset.bottom = SummariseMotion.followUpFade.height+16
            scroll.verticalScrollIndicatorInsets.bottom = SummariseMotion.followUpFade.height
            positionedHeader = true
            if wasAtStart { scrollToStart() }
        }
        if let policy = policyView {
            // Mask the fixed viewport, not its scrolling content. Reuse the summary's exact
            // height and opacity curve, without implicit layer animations as the panel grows.
            let height = max(1, policy.bounds.height)
            let fade = min(CGFloat(SummariseMotion.followUpFade.height), height)/height
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bottomFade.frame = policy.bounds
            bottomFade.locations = [0]+SummariseMotion.followUpFade.steps.map { NSNumber(value: 1-fade+$0.at*fade) }+[1]
            policy.layer.mask = bottomFade
            CATransaction.commit()
        }
    }

    private func scrollToStart() {
        guard let scroll = policyView?.scrollView else { return }
        scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { scrollToStart() }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.scheme == "about" { decisionHandler(.allow); return }
        decisionHandler(.cancel)
        guard navigationAction.navigationType == .linkActivated,
              ["https", "mailto"].contains(url.scheme) else { return }
        openLink?(url)
    }
}
