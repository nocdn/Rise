#if DEBUG
import UIKit
import WebKit

/// Autofill My Information in the real app, with a made-up card: Settings' rows in each state, light
/// and dark, then a form with the keyboard's bar, filling through the keyboard's own typing, Undo,
/// the hold's menu and several emails' menu. Each state holds a few seconds with a marker file
/// written, so the whole screen, keyboard and all, can be captured from outside
/// (`xcrun simctl io … screenshot`). The device's own setting and card come back after.
@MainActor enum AutofillAudit {
    static let argument = "-RiseAutofillAudit"
    struct Failure: Error { let name: String }

    static func run(in browser: BrowserViewController) {
        Task {
            let folder = URL.cachesDirectory.appendingPathComponent("AutofillAudit")
            try? FileManager.default.removeItem(at: folder)
            let store = AutofillStore.shared
            let enabled = store.isEnabled, card = store.profile
            defer {
                store.isEnabled = enabled
                if let card { try? store.save(card) } else { store.revoke() }
            }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try await exercise(browser, store: store, folder: folder)
                try "Passed".write(to: folder.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
            } catch {
                try? String(describing: error).write(to: folder.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8)
            }
        }
    }

    static var profile: AutofillProfile {
        var profile = AutofillProfile()
        profile.givenName = "Ada"; profile.familyName = "Lovelace"; profile.organization = "Analytical Engines"
        profile.emails = [.init(label: "Home", value: "ada@example.com"), .init(label: "Work", value: "ada@engines.example"),
                          .init(label: "School", value: "ada@uni.example")]
        profile.phones = [.init(label: "Mobile", number: "+44 7700 900123", region: "gb")]
        profile.addresses = [.init(label: "Home", street: "12 Example Avenue\nLittle Testing", subLocality: "", city: "Chelmsford",
                                   subAdministrativeArea: "", state: "Essex", postalCode: "CM1 1AA", country: "United Kingdom",
                                   isoCountryCode: "gb")]
        profile.birthday = .init(day: 7, month: 3, year: 1990)
        return profile
    }

    static let form = """
    <!doctype html><meta name=viewport content='width=device-width'>
    <style>body{font:17px -apple-system;margin:24px} label{display:block;margin:14px 0 4px} input{font:17px -apple-system;width:100%;padding:10px;box-sizing:border-box}</style>
    <h2>Delivery</h2>
    <form><label for=first>First name</label><input id=first value="Someone">
    <label for=email>Email</label><input id=email type=email>
    <label for=phone>Phone</label><input id=phone type=tel>
    <label for=postcode>Postcode</label><input id=postcode>
    <label for=coupon>Discount code</label><input id=coupon></form>
    """

    /// Lets the page's own focus bring up the keyboard, as a tap would.
    private final class InputDelegate: NSObject {
        @objc(_webView:focusShouldStartInputSession:) func focusShouldStart(_ webView: WKWebView, _ info: AnyObject) -> Bool { true }
        @objc(_webView:decidePolicyForFocusedElement:) func decide(_ webView: WKWebView, _ info: AnyObject) -> Int { 1 }
    }
    private static let inputDelegate = InputDelegate()

    /// Autofill Information, from Source's Edit: its rows light and dark, adding an email, a name changed.
    private static func auditInfo(_ browser: BrowserViewController, store: AutofillStore, check: (String, Bool) throws -> Void,
                                  settle: (Int) async throws -> Void, capture: (String) throws -> Void,
                                  hold: (String) async throws -> Void) async throws {
        let info = browser.bottomBar.autofillInfo
        func views<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
            view.subviews.flatMap { ($0 as? T).map { [$0] } ?? [] + views(type, in: $0) }
        }
        func field(_ label: String) -> UITextField? { views(UITextField.self, in: info).first { $0.accessibilityLabel == label } }
        func button(_ label: String) -> UIButton? { views(UIButton.self, in: info).first { $0.accessibilityLabel == label } }
        let scroll = views(UIScrollView.self, in: info).first
        for style in [UIUserInterfaceStyle.light, .dark] {
            browser.overrideUserInterfaceStyle = style
            let name = style == .dark ? "dark" : "light"
            store.isEnabled = true
            try store.save(profile)
            browser.openPanel(.menu); try await settle(700)
            browser.openSiteSettings(); try await settle(700)
            browser.openAppSettings(); try await settle(900)
            if style == .light {
                // Source's menu: Edit, Refresh, Revoke.
                let source = browser.bottomBar.appSettings.autofill.sourceButton
                let titles = (source.menu?.children ?? []).compactMap { ($0 as? UIAction)?.title }
                try check("source-offers-edit-first", titles == ["Edit", "Refresh", "Revoke"])
                source.contextMenuInteraction?.perform(NSSelectorFromString("_presentMenuAtLocation:"), with: NSValue(cgPoint: CGPoint(x: 40, y: 20)))
                try await hold("source-menu")
                source.contextMenuInteraction?.dismissMenu(); try await settle(600)
            }
            browser.bottomBar.appSettings.autofill.onEdit?(); try await settle(1000)
            try check("edit-opens-autofill-information-\(name)", browser.bottomBar.panel == .autofillInfo && field("First name")?.text == "Ada")
            try capture("info-top-\(name)")
            if let scroll {
                scroll.setContentOffset(CGPoint(x: 0, y: 520), animated: false); try await settle(300)
                try capture("info-middle-\(name)")
                scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height-scroll.bounds.height)), animated: false)
                try await settle(300)
                try capture("info-bottom-\(name)")
            }
            if style == .light {
                // Another email: a row where Add was, ready to type in.
                let emails = store.profile?.emails.count ?? 0
                button("Add another email")?.sendActions(for: .primaryActionTriggered); try await settle(900)
                let new = views(UITextField.self, in: info).first { $0.isFirstResponder }
                try check("add-gives-a-row-to-type-in", new != nil && new?.text == "")
                try await hold("info-adding")
                new?.text = "ada@new.example"
                new?.resignFirstResponder(); try await settle(500)
                try check("the-email-is-kept-as-added", store.profile?.emails.count == emails+1
                          && store.profile?.emails.last?.value == "ada@new.example" && store.profile?.emails.last?.added == true)
                try capture("info-added")
                // Emptied, it's gone.
                let added = views(UITextField.self, in: info).first { $0.text == "ada@new.example" }
                added?.becomeFirstResponder(); added?.text = ""; added?.resignFirstResponder(); try await settle(600)
                try check("emptied-it-goes", store.profile?.emails.count == emails)
                // A name changed is kept, and remembered as typed here.
                scroll?.setContentOffset(.zero, animated: false)
                let first = field("First name")
                first?.becomeFirstResponder(); first?.text = "Addie"; first?.resignFirstResponder(); try await settle(400)
                try check("a-name-changed-is-kept", store.profile?.givenName == "Addie" && store.profile?.edited.contains("givenName") == true)
                // Title's menu, grown from its row.
                button("Title")?.contextMenuInteraction?.perform(NSSelectorFromString("_presentMenuAtLocation:"), with: NSValue(cgPoint: CGPoint(x: 20, y: 20)))
                try await hold("info-title-menu")
                button("Title")?.contextMenuInteraction?.dismissMenu(); try await settle(500)
            }
            browser.returnFromPanel(); try await settle(900)
            try check("x-returns-to-settings-\(name)", browser.bottomBar.panel == .appSettings)
            browser.returnFromPanel(); try await settle(700)
            browser.returnFromPanel(); try await settle(700)
            browser.closePanel(); try await settle(700)
        }
        browser.overrideUserInterfaceStyle = .unspecified
    }

    private static func exercise(_ browser: BrowserViewController, store: AutofillStore, folder: URL) async throws {
        var checks: [String: Bool] = [:]
        func check(_ name: String, _ valid: Bool) throws {
            checks[name] = valid
            try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("checks.json"))
            if !valid { throw Failure(name: name) }
        }
        func settle(_ milliseconds: Int = 700) async throws { try await Task.sleep(for: .milliseconds(milliseconds)) }
        func capture(_ name: String) throws {
            guard let window = browser.view.window else { return }
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            try image.pngData()?.write(to: folder.appendingPathComponent(name+".png"))
        }
        /// Marks a state for an outside capture, and holds it long enough to take one.
        func hold(_ name: String) async throws {
            try name.write(to: folder.appendingPathComponent("state.txt"), atomically: true, encoding: .utf8)
            try await settle(3500)
        }
        let settings = browser.bottomBar.appSettings

        // Settings, in each state, light and dark.
        let barOnly = ProcessInfo.processInfo.arguments.contains("-RiseAutofillAuditBarOnly")
        let infoOnly = ProcessInfo.processInfo.arguments.contains("-RiseAutofillAuditInfoOnly")
        if !barOnly { try await auditInfo(browser, store: store, check: check, settle: settle, capture: capture, hold: hold) }
        if infoOnly { return }
        for style in barOnly ? [] : [UIUserInterfaceStyle.light, .dark] {
            browser.overrideUserInterfaceStyle = style
            let name = style == .dark ? "dark" : "light"
            store.isEnabled = false; store.revoke()
            browser.openPanel(.menu); try await settle()
            browser.openSiteSettings(); try await settle()
            browser.openAppSettings(); try await settle(900)
            try check("settings-has-the-row-\(name)", settings.autofill.superview != nil && !settings.autofill.enabledRow.toggle.isOn)
            try capture("settings-off-\(name)")
            settings.autofill.enabledRow.sendActions(for: .primaryActionTriggered); try await settle()
            try check("turning-it-on-shows-source-\(name)", store.isEnabled && settings.autofill.rowsHeight == 2*SiteSettingsPanel.rowHeight)
            try capture("settings-on-\(name)")
            try store.save(profile); try await settle()
            try check("a-card-turns-source-grey-\(name)", settings.autofill.sourceButton.showsMenuAsPrimaryAction)
            try capture("settings-card-\(name)")
            if let scroll = settings.subviews.compactMap({ $0 as? UIScrollView }).first {
                scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height-scroll.bounds.height)), animated: false)
                try await settle(300)
                try capture("settings-bottom-\(name)")
                scroll.setContentOffset(.zero, animated: false)
            }
            browser.returnFromPanel(); try await settle()
            browser.returnFromPanel(); try await settle()
            browser.closePanel(); try await settle()
        }
        browser.overrideUserInterfaceStyle = .unspecified

        // A form, with the keyboard up.
        store.isEnabled = true
        // A card naming only the nation, as Apple's address search writes it, gets its county from Apple's maps.
        var nation = profile
        nation.addresses[0].state = "England"
        try store.save(nation)
        store.lookUpCounties()
        for _ in 0..<60 where store.profile?.addresses.first?.lookedUpCounty == nil { try await settle(250) }
        let county = store.profile?.addresses.first?.lookedUpCounty
        try check("a-uk-card-finds-its-county", county == "Essex" && store.profile?.addresses.first?.region == "Essex")
        try store.save(profile)
        guard let page = browser.webView as? RiseWebView else { throw Failure(name: "page") }
        page.perform(NSSelectorFromString("_setInputDelegate:"), with: inputDelegate)
        page.loadHTMLString(form, baseURL: URL(string: "https://shop.example/"))
        for _ in 0..<150 where (try? await page.evaluateJavaScript("document.readyState")) as? String != "complete" { try await settle(50) }
        func focus(_ id: String) async throws {
            page.becomeFirstResponder()
            _ = try await page.callAsyncJavaScript("document.getElementById(id).focus()", arguments: ["id": id], contentWorld: .page)
            try await settle(1200)
        }
        func value(_ id: String) async throws -> String {
            try await page.callAsyncJavaScript("return document.getElementById(id).value", arguments: ["id": id], contentWorld: .page) as? String ?? ""
        }
        try await focus("first")
        func responder(in view: UIView) -> UIView? {
            if view.isFirstResponder { return view }
            for subview in view.subviews { if let found = responder(in: subview) { return found } }
            return nil
        }
        let diagnostics = ["field": page.autofill.field?.kind ?? "none", "choices": "\(page.autofill.choices.count)",
                           "responder": responder(in: page).map { NSStringFromClass(type(of: $0)) } ?? "none",
                           "accessory": page.inputAccessoryView.map { NSStringFromClass(type(of: $0)) } ?? "none"]
        try JSONSerialization.data(withJSONObject: diagnostics).write(to: folder.appendingPathComponent("diagnostics.json"))
        let button = page.autofill.button
        try check("the-bar-has-the-button", button != nil && button?.item.isHidden == false)
        try check("one-name-to-fill", page.autofill.choices.map(\.title) == ["Ada"])
        try await hold("first-name")
        // The hold's menu: what it'd fill.
        button?.contextMenuInteraction?.perform(NSSelectorFromString("_presentMenuAtLocation:"), with: NSValue(cgPoint: CGPoint(x: 20, y: 18)))
        try await hold("first-name-hold")
        button?.contextMenuInteraction?.dismissMenu(); try await settle()
        button?.sendActions(for: .primaryActionTriggered)
        try await settle(1200)
        let filled = try await value("first")
        try check("a-tap-fills-it-typed", filled == "Ada")
        try check("the-button-turns-to-undo", page.autofill.canUndo && button?.accessibilityLabel == "Undo autofill")
        try await hold("first-name-undo")
        button?.sendActions(for: .primaryActionTriggered)
        try await settle(1200)
        let undone = try await value("first")
        try check("undo-puts-it-back", undone == "Someone" && !page.autofill.canUndo && page.autofill.choices.count == 1)
        try await hold("first-name-undone")

        try await focus("email")
        try check("three-emails-in-a-menu", page.autofill.choices.count == 3 && button?.showsMenuAsPrimaryAction == true)
        try await hold("email")
        button?.contextMenuInteraction?.perform(NSSelectorFromString("_presentMenuAtLocation:"), with: NSValue(cgPoint: CGPoint(x: 20, y: 18)))
        try await hold("email-menu")
        button?.contextMenuInteraction?.dismissMenu(); try await settle()
        page.autofill.fill(page.autofill.choices[1]); try await settle(1200)
        let email = try await value("email")
        try check("a-chosen-email-fills", email == "ada@engines.example")

        try await focus("phone")
        button?.sendActions(for: .primaryActionTriggered); try await settle(1200)
        let phone = try await value("phone")
        try check("the-phone-fills", phone == "+44 7700 900123")
        try await focus("postcode")
        try await hold("postcode")
        try await focus("coupon")
        try check("no-button-on-a-coupon", button?.item.isHidden == true)
        try await hold("coupon")
        _ = try await page.callAsyncJavaScript("document.activeElement.blur()", contentWorld: .page)
        try await settle()
    }
}
#endif
