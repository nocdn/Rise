#if DEBUG
import UIKit
import UniformTypeIdentifiers
import WebKit

/// Copy and Save to Photos on a real page's image inside a link, from WebKit's own menu: only the
/// image reaches the pasteboard or the library, and a toast shows it. With `-RiseAuditPage <url>`
/// naming the page, served from the Mac; it holds each toast up for a screenshot (`toast-*.txt`).
@MainActor enum PageImageActionsAudit {
    static let argument = "-RisePageImageActionsAudit"
    struct Failure: Error { let name: String }
    static func run(in browser: BrowserViewController) {
        Task {
            let folder = URL.cachesDirectory.appendingPathComponent("PageImageActionsAudit")
            try? FileManager.default.removeItem(at: folder)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try await exercise(in: browser, folder: folder)
                try "Passed".write(to: folder.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
            } catch { try? String(describing: error).write(to: folder.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8) }
        }
    }
    private static func exercise(in browser: BrowserViewController, folder: URL) async throws {
        var checks: [String: Any] = [:]
        func note(_ name: String, _ value: Any) throws {
            checks[name] = value
            try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("checks.json"))
        }
        func check(_ name: String, _ valid: Bool) throws { try note(name, valid); if !valid { throw Failure(name: name) } }
        func wait(_ name: String, seconds: Double = 8, _ ready: () async throws -> Bool) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if try await ready() { try check(name, true); return }
                try await Task.sleep(for: .milliseconds(25))
            }
            try check(name, false)
        }
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-RiseAuditPage"), index+1 < arguments.count, let address = URL(string: arguments[index+1]) else {
            throw Failure(name: "page-address-given")
        }
        let page = browser.webView
        page.load(URLRequest(url: address))
        try await wait("linked-image-loaded", seconds: 15) {
            try await page.evaluateJavaScript("document.querySelector('#photo')?.complete && document.querySelector('#photo').naturalWidth > 0") as? Bool == true
        }
        try await Task.sleep(for: .milliseconds(400))

        // A real long press's menu, from WebKit.
        let box = try await page.evaluateJavaScript("(() => { const r = document.querySelector('#photo').getBoundingClientRect(); return [r.left, r.top, r.width, r.height]; })()") as? [Double] ?? []
        try check("image-has-a-place", box.count == 4)
        let point = page.convert(CGPoint(x: box[0]+box[2]/2, y: box[1]+box[3]/2), from: nil)
        _ = try await page.callAsyncJavaScript("""
        const image = document.querySelector('#photo'), r = image.getBoundingClientRect();
        const touch = new Touch({identifier:1, target:image, clientX:r.left+r.width/2, clientY:r.top+r.height/2});
        image.dispatchEvent(new TouchEvent('touchstart', {bubbles:true, composed:true, touches:[touch]}));
        """, arguments: [:], in: nil, contentWorld: ImageContextMenus.world)
        try await wait("image-is-seen-under-the-finger") { ImageContextMenus.hasImage(in: page) }
        // WebKit names its own actions: its private element action class says which kind each
        // identifier is (2 is Copy, 3 Save Image), as it does for Safari's menus.
        let actionClass: AnyClass? = NSClassFromString("_WKElementAction")
        let lookup = NSSelectorFromString("elementActionTypeForUIActionIdentifier:")
        guard let actionClass, let meta = object_getClass(actionClass), class_respondsToSelector(meta, lookup) else { throw Failure(name: "webkit-element-actions") }
        typealias Lookup = @convention(c) (AnyClass, Selector, NSString) -> Int
        let kind = unsafeBitCast(method_getImplementation(class_getClassMethod(actionClass, lookup)!), to: Lookup.self)
        let copyKind = kind(actionClass, lookup, ImageContextMenus.copyIdentifier.rawValue as NSString)
        let saveKind = kind(actionClass, lookup, ImageContextMenus.saveIdentifier.rawValue as NSString)
        try note("webkit-kinds", [copyKind, saveKind])
        try check("webkits-copy-and-save-are-the-ones-replaced", copyKind == 2 && saveKind == 3)

        // The menu WebKit's suggested actions become: its Copy and Save, and a way to copy the link.
        let copy = UIAction(title: "Copy", identifier: ImageContextMenus.copyIdentifier) { _ in }
        let save = UIAction(title: "Save to Photos", identifier: ImageContextMenus.saveIdentifier) { _ in }
        let share = UIAction(title: "Share…", identifier: UIAction.Identifier("WKElementActionTypeShare")) { _ in }
        let built = ImageContextMenus.menu(in: page, actions: [UIMenu(options: .displayInline, children: [share, copy, save])], link: URL(string: "https://example.com/result"))
        func titles(_ elements: [UIMenuElement]) -> [String] {
            elements.flatMap { ($0 as? UIMenu).map { titles($0.children) } ?? [($0 as? UIAction).map { "\($0.title)\($0.identifier == copy.identifier || $0.identifier == save.identifier ? " (WebKit's)" : "")" } ?? ""] }
        }
        try note("rise-menu", titles(built.children))
        try check("webkits-copy-and-save-are-replaced-in-place", titles(built.children) == ["Share…", "Copy", "Save to Photos", "Copy Link"])

        guard let target = ImageContextMenus.lastTarget else { throw Failure(name: "menu-keeps-its-image") }
        try check("target-is-the-image-file", target.source?.lastPathComponent == "photo.jpg")
        UIPasteboard.general.items = []
        await PageImageActions.perform(.copy, on: target, in: page)
        let types = UIPasteboard.general.types
        try note("pasteboard-types", types)
        try check("only-the-image-is-copied", types.contains(UTType.jpeg.identifier) && !types.contains { UTType($0)?.conforms(to: .url) == true || UTType($0)?.conforms(to: .text) == true })
        try check("the-copied-image-is-the-file", UIPasteboard.general.data(forPasteboardType: UTType.jpeg.identifier).flatMap(UIImage.init(data:))?.cgImage?.width == 1200)
        try await wait("copied-toast-shows") { browser.toast?.label.text == "Copied image" }
        try await Task.sleep(for: .milliseconds(600))
        try "copied".write(to: folder.appendingPathComponent("toast-copied.txt"), atomically: true, encoding: .utf8)
        try await Task.sleep(for: .seconds(2.5))

        await PageImageActions.perform(.save, on: target, in: page)
        try await wait("saved-toast-shows") { browser.toast?.label.text == "Saved image" }
        try await Task.sleep(for: .milliseconds(600))
        try "saved".write(to: folder.appendingPathComponent("toast-saved.txt"), atomically: true, encoding: .utf8)
        try await Task.sleep(for: .seconds(2.5))

        // A data address, decoded.
        _ = try await page.callAsyncJavaScript("""
        const image = document.querySelector('#inline'), r = image.getBoundingClientRect();
        const touch = new Touch({identifier:1, target:image, clientX:r.left+2, clientY:r.top+2});
        image.dispatchEvent(new TouchEvent('touchstart', {bubbles:true, composed:true, touches:[touch]}));
        """, arguments: [:], in: nil, contentWorld: ImageContextMenus.world)
        try await wait("inline-image-is-seen") { ImageContextMenus.hasImage(in: page) }
        let inline = ImageContextMenus.menu(in: page, actions: [])
        _ = inline
        guard let inlineTarget = ImageContextMenus.lastTarget, inlineTarget.source?.scheme == "data" else { throw Failure(name: "inline-target") }
        let picture = await PageImageActions.picture(of: inlineTarget, in: page)
        try check("data-images-decode", picture?.type == .png && picture?.image.cgImage?.width == 64)
    }
}
#endif
