#if DEBUG
import UIKit
import WebKit
import OSLog

/// Opt-in, same-signature comparison. No credential requests are synthesized and
/// no credential options, responses, usernames or challenge bytes are logged.
@MainActor final class PasskeyDiagnostic: UIViewController, WKNavigationDelegate {
    static let argument = "-RisePasskeyDiagnostic"
    static var requested: Bool { ProcessInfo.processInfo.arguments.contains(argument) }
    static var keepsAwake: Bool {
        requested || ProcessInfo.processInfo.arguments.contains("-RiseKeepAwake")
    }
    private static let log = Logger(subsystem: "dev.bartosz.Rise.iOS", category: "PasskeyDiagnostic")
    private let page = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let label = UILabel()
        label.text = "Passkey diagnostic · plain WKWebView"
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textAlignment = .center
        let reload = UIButton(type: .system)
        reload.setTitle("Reload", for: .normal)
        reload.addAction(UIAction { [weak self] _ in self?.page.reload() }, for: .touchUpInside)
        let header = UIStackView(arrangedSubviews: [label, reload])
        header.spacing = 12
        for item in [header, page] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            header.heightAnchor.constraint(equalToConstant: 44),
            page.topAnchor.constraint(equalTo: header.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            page.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
        page.navigationDelegate = self
        page.isInspectable = true
        Self.log.notice("plain-view-started persistent=\(self.page.configuration.websiteDataStore.isPersistent)")
        page.load(URLRequest(url: URL(string: "https://webauthn.io")!))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Self.log.notice("plain-view-loaded window=\(self.page.window != nil)")
        // Read feature availability only. A real tap must start each ceremony.
        Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await page.callAsyncJavaScript("""
                    return JSON.stringify({secure: isSecureContext,
                      platform: await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable(),
                      conditional: await PublicKeyCredential.isConditionalMediationAvailable()});
                    """, arguments: [:], in: nil, contentWorld: .page)
                Self.log.notice("plain-view-availability \(String(describing: value), privacy: .public)")
            } catch {
                Self.log.error("plain-view-availability-error \(String(describing: error), privacy: .public)")
            }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Self.log.error("plain-view-navigation-error \((error as NSError).code)")
    }
}
#endif
