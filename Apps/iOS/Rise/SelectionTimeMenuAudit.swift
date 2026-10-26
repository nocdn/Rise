#if DEBUG
import UIKit
import WebKit

/// Isolated fixture for the real UIKit selection menu, without touching saved tabs.
/// Long-press the selected time, then test both the time item and the expand chevron.
@MainActor enum SelectionTimeMenuAudit {
    static let argument = "-RiseSelectionTimeMenuAudit"
    static func run(in browser: BrowserViewController) {
        let arguments = ProcessInfo.processInfo.arguments
        let sample: String
        if let index = arguments.firstIndex(of: "-RiseSelectionTimeMenuAuditText"), arguments.indices.contains(index+1) {
            sample = arguments[index+1]
        } else { sample = "10am PST" }
        let escaped = sample.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        browser.webView.loadHTMLString("""
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <body style="padding:25px;font:24px system-ui;background:#fff;color:#111">
        <h2>Selected time</h2><p id="time">\(escaped)</p><p>Select the time above.</p>
        <button style="font:20px system-ui" onclick="getSelection().selectAllChildren(document.getElementById('time'))">Select time</button>
        </body>
        """, baseURL: URL(string: "https://example.com/"))
        Task {
            for _ in 0..<100 {
                if (try? await browser.webView.evaluateJavaScript("document.getElementById('time') !== null")) as? Bool == true { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            _ = try? await browser.webView.evaluateJavaScript("getSelection().selectAllChildren(document.getElementById('time'))")
            var checks = checks()
            for _ in 0..<100 where SelectionTimeMenu.selection(in: browser.webView) != sample { try? await Task.sleep(for: .milliseconds(25)) }
            checks["webKitSelectionReceived"] = SelectionTimeMenu.selection(in: browser.webView) == sample
            let elements = SelectionTimeMenu.elements(for: sample, in: browser.webView)
            checks["selectedTextHasAMenu"] = !elements.isEmpty
            write(elements.compactMap { ($0 as? UIMenu).map { ["title": $0.title, "actions": $0.children.map(\.title)] } }, name: "selection-menu.json")
            write(checks, name: "checks.json")
        }
    }

    static func record(_ root: UIMenu) {
        guard ProcessInfo.processInfo.arguments.contains(argument) else { return }
        func describe(_ item: UIMenuElement) -> [String: Any] {
            var result: [String: Any] = ["title": item.title]
            if let menu = item as? UIMenu { result["id"] = menu.identifier.rawValue; result["children"] = menu.children.map(describe) }
            if let action = item as? UIAction { result["id"] = action.identifier.rawValue }
            return result
        }
        write(describe(root), name: "relocated-menu.json")
    }

    private static func write(_ value: Any, name: String) {
        let folder = URL.cachesDirectory.appendingPathComponent("SelectionTimeMenuAudit")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent(name))
    }

    private static func checks() -> [String: Bool] {
        let copy = UIAction(title: "Copy") { _ in }
        let fallback = UIAction(title: "Calendar fallback") { _ in }
        let time = UIMenu(title: "18:00", children: [copy, fallback])
        let rise = UIMenu(identifier: SelectionTimeMenu.menuIdentifier, options: .displayInline, children: [time])
        var invoked: [Int] = []
        let actions = ["DDCreateEventAction", "DDCreateReminderAction", "DDShowCalendarAction"].enumerated().map { index, kind in
            UIAction(title: "Localized action \(index)", image: UIImage(systemName: "calendar"),
                     identifier: .init("com.apple.datadetectors.\(kind).fixture")) { _ in invoked.append(index) }
        }
        let heading = UIAction(title: "Date", identifier: .init("com.apple.datadetectors.DDTimeZoneConversionAction.fixture"), attributes: .disabled) { _ in }
        let lookup = UIMenu(identifier: .lookup, children: [UIAction(title: "Look Up") { _ in }])
        let dates = UIMenu(identifier: .lookup, children: [heading] + actions)
        let root = UIMenu(children: [rise, lookup, dates])
        let result = SelectionTimeNativeMenu.relocatingDateActions(in: root)
        let children = ((result.children.first as? UIMenu)?.children.first as? UIMenu)?.children ?? []
        for action in children.dropFirst().compactMap({ $0 as? UIAction }) {
            let button = UIButton(); button.addAction(action, for: .touchUpInside); button.sendActions(for: .touchUpInside)
        }
        let incomplete = root.replacingChildren([rise, lookup, dates.replacingChildren([heading, actions[0]])])
        let own = SelectionTimeMenu.elements(for: "10am PST", in: nil).first as? UIMenu
        let zoneOnly = SelectionTimeMenu.elements(for: "UTC+14:00", in: nil).first as? UIMenu
        let zoneSection = UIMenu(identifier: SelectionTimeMenu.menuIdentifier, children: zoneOnly.map { [$0] } ?? [])
        let zoneRoot = root.replacingChildren([zoneSection, lookup, dates])
        return [
            "fourActions": children.count == 4,
            "copyPreserved": children.first === copy,
            "nativeObjectsAndIconsPreserved": zip(children.dropFirst(), actions).allSatisfy { $0 === $1 },
            "nativeHandlersPreserved": invoked == [0, 1, 2],
            "duplicateRemovedAndLookupPreserved": result.children.count == 2 && result.children.last === lookup,
            "idempotent": SelectionTimeNativeMenu.relocatingDateActions(in: result) === result,
            "incompleteNativeActionsPreserved": SelectionTimeNativeMenu.relocatingDateActions(in: incomplete) === incomplete,
            "directSubmenuHasAllActions": own?.children.count == 4,
            "zoneOnlyShowsCurrentTimeAndDifference": zoneOnly?.title.contains("there ·") == true,
            "zoneOnlyOffersOnlyCopy": zoneOnly?.children.count == 1 && zoneOnly?.children.first?.title.hasPrefix("Copy “") == true,
            "zoneOnlyKeepsNativeDateActionsSeparate": SelectionTimeNativeMenu.relocatingDateActions(in: zoneRoot) === zoneRoot,
            "noDateHasNoCustomMenu": SelectionTimeMenu.elements(for: "ordinary words", in: nil).isEmpty
        ]
    }
}
#endif
