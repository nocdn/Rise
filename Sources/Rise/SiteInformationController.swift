import AppKit
import RiseCore

/// Standard AppKit popover content; connection details come from the current URL.
final class SiteInformationController: NSViewController {
    let url: URL
    let host: NSTextField
    let address: NSTextField
    let connection: NSTextField
    let engine = NSTextField(labelWithString: "Rendering engine: Chromium")

    init(url: URL) {
        self.url = url
        host = NSTextField(wrappingLabelWithString: AddressResolver.displayHost(url))
        address = NSTextField(wrappingLabelWithString: url.absoluteString)
        connection = NSTextField(wrappingLabelWithString: url.scheme == "https"
            ? "This page uses an encrypted HTTPS connection."
            : "This page does not use HTTPS.")
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        view = NSView()
        host.font = .systemFont(ofSize: 15, weight: .semibold)
        address.font = .systemFont(ofSize: 12); address.textColor = .secondaryLabelColor
        address.isSelectable = true; address.toolTip = url.absoluteString
        connection.font = .systemFont(ofSize: 13)
        engine.font = .systemFont(ofSize: 12); engine.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [host, address, connection, engine])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(equalToConstant: 300)
        ])
        for field in [host, address, connection] {
            field.preferredMaxLayoutWidth = 300
            field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }
}
