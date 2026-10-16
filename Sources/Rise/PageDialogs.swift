import AppKit
import RiseCore
import RiseChromium

/// The sheets a page's `alert()`, `confirm()`, `prompt()` and file choosers open, the same for
/// either engine's pages. Each returns its sheet, or nil when there's no window to show it in,
/// having answered as if cancelled.
@MainActor extension BrowserController {
    @discardableResult
    func showPageAlert(_ message: String, from url: URL?, completion: @escaping () -> Void) -> NSWindow? {
        let alert = NSAlert(); alert.messageText = AddressResolver.displayHost(url); alert.informativeText = message
        guard let window else { completion(); return nil }
        alert.beginSheetModal(for: window) { _ in completion() }
        return alert.window
    }
    @discardableResult
    func showPageConfirm(_ message: String, from url: URL?, completion: @escaping (Bool) -> Void) -> NSWindow? {
        let alert = NSAlert(); alert.messageText = AddressResolver.displayHost(url); alert.informativeText = message
        alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
        guard let window else { completion(false); return nil }
        alert.beginSheetModal(for: window) { completion($0 == .alertFirstButtonReturn) }
        return alert.window
    }
    @discardableResult
    func showPagePrompt(_ prompt: String, defaultText: String?, completion: @escaping (String?) -> Void) -> NSWindow? {
        let alert = NSAlert(); alert.messageText = prompt
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 26)); input.stringValue = defaultText ?? ""; alert.accessoryView = input
        alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
        guard let window else { completion(nil); return nil }
        alert.beginSheetModal(for: window) { completion($0 == .alertFirstButtonReturn ? input.stringValue : nil) }
        return alert.window
    }
    /// A page with changes it hasn't saved, asking before it's left or reloaded.
    @discardableResult
    func showLeavePageConfirm(from url: URL?, reload: Bool, completion: @escaping (Bool) -> Void) -> NSWindow? {
        let alert = NSAlert()
        alert.messageText = reload ? "Reload this page?" : "Leave this page?"
        alert.informativeText = "Changes you made may not be saved."
        alert.addButton(withTitle: reload ? "Reload" : "Leave"); alert.addButton(withTitle: "Cancel")
        guard let window else { completion(false); return nil }
        alert.beginSheetModal(for: window) { completion($0 == .alertFirstButtonReturn) }
        return alert.window
    }
    @discardableResult
    func showPageOpenPanel(multiple: Bool, directories: Bool, files: Bool = true, completion: @escaping ([URL]?) -> Void) -> NSWindow? {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = multiple
        panel.canChooseDirectories = directories; panel.canChooseFiles = files
        guard let window else { completion(nil); return nil }
        panel.beginSheetModal(for: window) { completion($0 == .OK ? panel.urls : nil) }
        return panel
    }
    @discardableResult
    func showPageSavePanel(suggesting path: String, completion: @escaping ([URL]?) -> Void) -> NSWindow? {
        let panel = NSSavePanel()
        let suggested = URL(fileURLWithPath: path)
        if !path.isEmpty {
            panel.nameFieldStringValue = suggested.lastPathComponent
            var isFolder: ObjCBool = false
            let folder = suggested.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue { panel.directoryURL = folder }
        }
        guard let window else { completion(nil); return nil }
        panel.beginSheetModal(for: window) { completion($0 == .OK ? panel.url.map { [$0] } : nil) }
        return panel
    }
}

/// A dialog a Chromium page asks for.
struct PageDialog {
    let kind: RCDialogKind
    let message: String
    let defaultText: String
}

@MainActor extension BrowserController {
    /// Rise's sheet for a page's dialog.
    func showDialog(_ dialog: PageDialog, from page: ChromiumPage, finish: @escaping (Bool, String?) -> Void) -> NSWindow? {
        switch dialog.kind {
        case .alert: return showPageAlert(dialog.message, from: page.url) { finish(true, nil) }
        case .confirm: return showPageConfirm(dialog.message, from: page.url) { finish($0, nil) }
        case .prompt: return showPagePrompt(dialog.message, defaultText: dialog.defaultText) { finish($0 != nil, $0) }
        case .leave, .reload: return showLeavePageConfirm(from: page.url, reload: dialog.kind == .reload) { finish($0, nil) }
        @unknown default: finish(false, nil); return nil
        }
    }
    func chooseFiles(_ mode: RCFileChooserMode, defaultPath: String, finish: @escaping ([URL]?) -> Void) {
        switch mode {
        case .openMultiple: showPageOpenPanel(multiple: true, directories: false, completion: finish)
        case .openFolder: showPageOpenPanel(multiple: false, directories: true, files: false, completion: finish)
        case .save: showPageSavePanel(suggesting: defaultPath, completion: finish)
        default: showPageOpenPanel(multiple: false, directories: false, completion: finish)
        }
    }
}
