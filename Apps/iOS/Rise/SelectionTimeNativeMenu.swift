import UIKit
import WebKit

/// Data Detectors append their date section *after* buildMenu and UITextInput's menu
/// callback. Update the completed native menu instead, retaining the original actions:
/// their icons, localized titles, handlers and Calendar/Reminders permission behavior.
@MainActor final class SelectionTimeNativeMenu {
    private weak var page: WKWebView?
    private var link: CADisplayLink?

    init(page: WKWebView) { self.page = page }

    func begin() {
        stop()
        let link = CADisplayLink(target: FrameTicker { [weak self] in self?.update() }, selector: #selector(FrameTicker.tick))
        link.add(to: .main, forMode: .common)
        self.link = link
        update()
    }

    func stop() { link?.invalidate(); link = nil }
    isolated deinit { link?.invalidate() }

    private func update() {
        guard let page, page.window != nil else { stop(); return }
        var updated = false
        func visit(_ view: UIView) {
            for interaction in view.interactions.compactMap({ $0 as? UIContextMenuInteraction }) {
                NativeMenuLoading.withoutAnimation {
                    interaction.updateVisibleMenu { menu in
                        if menu.identifier.rawValue.hasPrefix(SelectionTimeMenu.menuIdentifier.rawValue + ".") {
                            // Opening a compact-menu submenu directly exposes only
                            // that submenu. Its four fallback actions already work.
                            updated = true
                            return menu
                        }
                        let result = Self.relocatingDateActions(in: menu)
                        updated = updated || result !== menu
                        #if DEBUG
                        if result !== menu { SelectionTimeMenuAudit.record(result) }
                        #endif
                        return result
                    }
                }
            }
            view.subviews.forEach(visit)
        }
        // The compact edit menu only exposes its completed hierarchy when it expands
        // (including opening the converted-time submenu directly). Check on the next
        // display frame until then; stop after one update or when the menu dismisses.
        visit(page)
        if updated { stop() }
    }

    private static let conversion = "com.apple.datadetectors.DDTimeZoneConversionAction."
    private static let actionKinds = [
        "com.apple.datadetectors.DDCreateEventAction.",
        "com.apple.datadetectors.DDCreateReminderAction.",
        "com.apple.datadetectors.DDShowCalendarAction."
    ]

    /// Match opaque action identifiers rather than translated display titles. If iOS
    /// changes its identifiers, preserve the system menu instead of dropping actions.
    static func relocatingDateActions(in root: UIMenu) -> UIMenu {
        var riseSections: [UIMenu] = [], dateSections: [UIMenu] = []
        func collect(_ menu: UIMenu) {
            if menu.identifier == SelectionTimeMenu.menuIdentifier { riseSections.append(menu); return }
            if menu.children.contains(where: { ($0 as? UIAction)?.identifier.rawValue.hasPrefix(conversion) == true }) {
                dateSections.append(menu)
            }
            menu.children.compactMap { $0 as? UIMenu }.forEach(collect)
        }
        collect(root)
        guard riseSections.count == 1, !dateSections.isEmpty else { return root }
        let timeMenus = riseSections[0].children.compactMap { $0 as? UIMenu }
        guard !timeMenus.isEmpty, timeMenus.count == riseSections[0].children.count else { return root }
        let nativeGroups = dateSections.map { section in
            let actions = section.children.compactMap { $0 as? UIAction }
            return actionKinds.compactMap { kind in actions.first { $0.identifier.rawValue.hasPrefix(kind) } }
        }
        guard nativeGroups.allSatisfy({ $0.count == actionKinds.count }) else { return root }
        // A native action carries an opaque date payload. Reuse it for an unambiguous
        // single date; multiple dates keep their individual, fully functional actions.
        let replacement: UIMenu
        if timeMenus.count == 1, nativeGroups.count == 1, let copy = timeMenus[0].children.first as? UIAction {
            replacement = riseSections[0].replacingChildren([timeMenus[0].replacingChildren([copy] + nativeGroups[0])])
        } else {
            guard timeMenus.allSatisfy({ $0.children.count == 4 }) else { return root }
            replacement = riseSections[0]
        }
        let moved = Set(nativeGroups.flatMap { $0 }.map(\.identifier))
        func rewrite(_ menu: UIMenu) -> UIMenu {
            if menu === riseSections[0] {
                return replacement
            }
            let children: [UIMenuElement] = menu.children.compactMap { child in
                if let action = child as? UIAction,
                   moved.contains(action.identifier) || (dateSections.contains(where: { $0 === menu }) && action.identifier.rawValue.hasPrefix(conversion)) { return nil }
                if let submenu = child as? UIMenu {
                    let result = rewrite(submenu)
                    return result.children.isEmpty && !submenu.children.isEmpty ? nil : result
                }
                return child
            }
            if children.count == menu.children.count, zip(children, menu.children).allSatisfy({ $0 === $1 }) { return menu }
            return menu.replacingChildren(children)
        }
        return rewrite(root)
    }
}
