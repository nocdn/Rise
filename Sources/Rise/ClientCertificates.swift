import AppKit
import SecurityInterface

/// macOS's certificate chooser, for a site that asks for a certificate to identify the person
/// (TLS client authentication), as Safari shows it: a sheet on the window, listing the keychain's
/// identities that suit the site. Continue sends the one chosen; Cancel goes on without one.
@MainActor final class ClientCertificateChooser: NSObject {
    let panel = SFChooseIdentityPanel()
    let identities: [SecIdentity]
    /// The index of the identity chosen, or nil for none; called once.
    private var finish: ((Int?) -> Void)?
    private let ended: () -> Void
    /// The window it's a sheet on, and the sheet: macOS's chooser shows in a window of its own.
    private(set) weak var parent: NSWindow?
    private(set) weak var sheet: NSWindow?

    init(identities: [SecIdentity], finish: @escaping (Int?) -> Void, ended: @escaping () -> Void) {
        self.identities = identities; self.finish = finish; self.ended = ended
    }

    func show(on window: NSWindow, host: String) {
        parent = window
        let before = window.sheets
        panel.setDefaultButtonTitle("Continue")
        panel.setAlternateButtonTitle("Cancel")
        panel.setInformativeText("This website needs a certificate to confirm who you are. Choose one from your keychain.")
        panel.beginSheet(for: window, modalDelegate: self, didEnd: #selector(chooserEnded(_:returnCode:contextInfo:)),
                         contextInfo: nil, identities: identities, message: "Choose a certificate to identify yourself to “\(host)”.")
        sheet = window.sheets.first { !before.contains($0) }
    }

    @objc private func chooserEnded(_ sheet: NSWindow, returnCode: Int, contextInfo: UnsafeMutableRawPointer?) {
        let chosen = returnCode == NSApplication.ModalResponse.OK.rawValue ? panel.identity()?.takeUnretainedValue() : nil
        let index = chosen.flatMap { chosen in identities.firstIndex { CFEqual($0, chosen) } }
        finish?(index); finish = nil
        ended()
    }

    /// The site's request went away before a certificate was chosen: the chooser closes, unanswered.
    func cancel() {
        finish = nil
        if let parent, let sheet { parent.endSheet(sheet, returnCode: .cancel) } else { ended() }
    }
}

@MainActor extension BrowserController {
    /// A site in `page` asks for a certificate: the chooser shows on the page's window, over its
    /// tab, which comes forward first.
    func chooseClientCertificate(_ identities: [SecIdentity], host: String, for page: ChromiumPage, finish: @escaping (Int?) -> Void) {
        if let tab = tabs.first(where: { $0.page === page }), tab.id != selectedID { select(tab.id) }
        guard let window = page.view.window ?? window else { finish(nil); return }
        let key = ObjectIdentifier(page)
        clientCertificateChoosers[key]?.cancel()
        let chooser = ClientCertificateChooser(identities: identities, finish: finish) { [weak self] in
            self?.clientCertificateChoosers[key] = nil
        }
        clientCertificateChoosers[key] = chooser
        chooser.show(on: window, host: host)
    }

    /// The page's request went away before a certificate was chosen.
    func cancelClientCertificate(for page: ChromiumPage) {
        clientCertificateChoosers[ObjectIdentifier(page)]?.cancel()
    }
}
