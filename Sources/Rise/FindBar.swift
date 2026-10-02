import AppKit
import WebKit

@MainActor final class FindBar: Surface, NSSearchFieldDelegate {
    let input = NSSearchField()
    let previous: ChromeButton
    let next: ChromeButton
    let close: ChromeButton
    var search: ((String, Bool) -> Void)?
    var dismiss: (() -> Void)?
    init() {
        previous = ChromeButton(symbol: "chevron.up", size: 11, title: "Previous match (⇧⌘G)", action: {})
        next = ChromeButton(symbol: "chevron.down", size: 11, title: "Next match (⌘G)", action: {})
        close = ChromeButton(symbol: "xmark", size: 11, title: "Close Find", action: {})
        super.init(color: NSColor(hex: 0xF8F8F8), radius: 9)
        layer?.shadowColor = NSColor.black.cgColor; layer?.shadowOpacity = 0.16
        layer?.shadowRadius = 8; layer?.shadowOffset = NSSize(width: 0, height: -2)
        input.placeholderString = "Find on page"; input.font = .systemFont(ofSize: 12)
        input.sendsSearchStringImmediately = true; input.target = self; input.action = #selector(changed)
        input.setAccessibilityLabel("Find on page"); input.delegate = self
        previous.actionBlock = { [weak self] in self?.run(backwards: true) }
        next.actionBlock = { [weak self] in self?.run(backwards: false) }
        close.actionBlock = { [weak self] in self?.dismiss?() }
        [input, previous, next, close].forEach(addSubview); isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        input.frame = NSRect(x: 8, y: 9, width: bounds.width-110, height: 24)
        previous.frame = NSRect(x: bounds.width-97, y: 7, width: 27, height: 28)
        next.frame = NSRect(x: bounds.width-68, y: 7, width: 27, height: 28)
        close.frame = NSRect(x: bounds.width-36, y: 7, width: 27, height: 28)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { dismiss?(); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) { run(backwards: false); return true }
        return false
    }
    @objc func changed() { run(backwards: false) }
    func run(backwards: Bool) { search?(input.stringValue, backwards) }
}
@MainActor extension BrowserController {
    @objc func showFind() {
        findBar.isHidden = false; window?.makeFirstResponder(findBar.input); findBar.input.selectText(nil)
        layoutChrome()
    }
    @objc func findNext() { findBar.run(backwards: false) }
    @objc func findPrevious() { findBar.run(backwards: true) }
    func hideFind() {
        findBar.isHidden = true; selectedTab?.webView.find("", configuration: WKFindConfiguration()) { _ in }
        window?.makeFirstResponder(selectedTab?.webView)
    }
}
