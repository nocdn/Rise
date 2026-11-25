import UIKit
import WebKit

/// Data Detectors append their date section *after* buildMenu and UITextInput's menu
/// callback. Update the completed native menu instead, retaining the original actions:
/// their icons, localized titles, handlers and Calendar/Reminders permission behavior.
/// The same pass takes out the system's conversion of an amount or a measurement where Rise reads it itself, and
/// WebKit's Copy Link with Highlight.
@MainActor final class SelectionTimeNativeMenu {
    private weak var page: WKWebView?
    private var link: CADisplayLink?
    private var relocatesDates = false, replacesConversion = false

    init(page: WKWebView) { self.page = page }

    func begin(relocatesDates: Bool, replacesConversion: Bool) {
        stop()
        self.relocatesDates = relocatesDates; self.replacesConversion = replacesConversion
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
                        if menu.identifier.rawValue.hasPrefix(SelectionTimeMenu.menuIdentifier.rawValue + ".")
                            || menu.identifier.rawValue.hasPrefix(SelectionCurrencyMenu.menuIdentifier.rawValue + ".")
                            || menu.identifier.rawValue.hasPrefix(SelectionMeasurementMenu.menuIdentifier.rawValue + ".") {
                            // Opening a compact-menu submenu directly exposes only
                            // that submenu. Its four fallback actions already work.
                            updated = true
                            return menu
                        }
                        let withoutHighlight = Self.removing(in: menu, conversion: false)
                        let tidied = replacesConversion ? Self.removing(in: withoutHighlight, conversion: true) : withoutHighlight
                        let result = relocatesDates ? Self.relocatingDateActions(in: tidied) : tidied
                        // Done once what this menu needed has been done; with nothing else to
                        // do, once Copy Link with Highlight has gone.
                        let datesDone = !relocatesDates || result !== tidied
                        let conversionDone = !replacesConversion || tidied !== withoutHighlight
                        updated = updated || datesDone && conversionDone && (relocatesDates || replacesConversion || withoutHighlight !== menu)
                        #if DEBUG
                        if result !== menu { SelectionTimeMenuAudit.record(result) }
                        #endif
                        // UIKit can add commands when the compact menu expands.
                        return SelectionMenuIcons.applying(to: result)
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

    static let copyLinkWithHighlight = "WKMenuItemIdentifierCopyLinkWithHighlight"
    /// The system's conversion of an amount (or a measurement) into the person's units.
    static let unitConversion = "com.apple.datadetectors.DDConversion"

    /// WebKit's Copy Link with Highlight, wherever buildMenu finds it.
    static func removeCopyLinkWithHighlight(from builder: UIMenuBuilder) {
        func visit(_ menu: UIMenu) {
            if menu.children.contains(where: isCopyLinkWithHighlight) {
                builder.replaceChildren(ofMenu: menu.identifier) { $0.filter { !isCopyLinkWithHighlight($0) } }
            }
            menu.children.compactMap { $0 as? UIMenu }.forEach(visit)
        }
        builder.menu(for: .root).map(visit)
    }

    private static func isCopyLinkWithHighlight(_ element: UIMenuElement) -> Bool {
        // By WebKit's identifier, or its title should the identifier differ.
        if element.title == "Copy Link with Highlight" || element.title == "Copy Link With Highlight" { return true }
        if let action = element as? UIAction { return action.identifier.rawValue.contains("CopyLinkWithHighlight") }
        if let command = element as? UICommand { return NSStringFromSelector(command.action).localizedCaseInsensitiveContains("LinkWithHighlight") }
        return false
    }

    /// `root` without Copy Link with Highlight and, where Rise converts the amount itself, the
    /// system's conversion; a section left empty goes too. The same menu when there's neither.
    static func removing(in root: UIMenu, conversion: Bool) -> UIMenu {
        func removed(_ element: UIMenuElement) -> Bool {
            if isCopyLinkWithHighlight(element) { return true }
            return conversion && (element as? UIAction)?.identifier.rawValue.hasPrefix(unitConversion) == true
        }
        func rewrite(_ menu: UIMenu) -> UIMenu {
            let children: [UIMenuElement] = menu.children.compactMap { child in
                if removed(child) { return nil }
                guard let submenu = child as? UIMenu else { return child }
                let result = rewrite(submenu)
                return result.children.isEmpty && !submenu.children.isEmpty ? nil : result
            }
            if children.count == menu.children.count, zip(children, menu.children).allSatisfy({ $0 === $1 }) { return menu }
            return menu.replacingChildren(children)
        }
        return rewrite(root)
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
        func has(_ menu: UIMenu, _ prefix: String) -> Bool {
            menu.children.contains { ($0 as? UIAction)?.identifier.rawValue.hasPrefix(prefix) == true }
        }
        func collect(_ menu: UIMenu) {
            if menu.identifier == SelectionTimeMenu.menuIdentifier { riseSections.append(menu); return }
            if has(menu, conversion) || has(menu, actionKinds[0]) { dateSections.append(menu) }
            menu.children.compactMap { $0 as? UIMenu }.forEach(collect)
        }
        collect(root)
        // Rise's event, with its place and title, stands for any date the system found; without one,
        // only a time converted from another zone is Rise's to take.
        let hasEvent = riseSections.first?.children.contains { ($0 as? UIMenu)?.identifier == SelectionTimeMenu.eventIdentifier } ?? false
        if !hasEvent { dateSections = dateSections.filter { has($0, conversion) } }
        guard riseSections.count == 1, !dateSections.isEmpty else { return root }
        let timeMenus = riseSections[0].children.compactMap { $0 as? UIMenu }
        guard !timeMenus.isEmpty, timeMenus.count == riseSections[0].children.count else { return root }
        // A zone-only selection offers a current-time snapshot and Copy. It does
        // not name a calendar date whose native actions could be relocated here.
        guard hasEvent || timeMenus.allSatisfy({ $0.children.count > 1 }) else { return root }
        let nativeGroups = dateSections.map { section in
            let actions = section.children.compactMap { $0 as? UIAction }
            return actionKinds.compactMap { kind in actions.first { $0.identifier.rawValue.hasPrefix(kind) } }
        }
        guard nativeGroups.allSatisfy({ $0.count == actionKinds.count }) else { return root }
        // A native action carries an opaque date payload. Reuse it for an unambiguous
        // single date; multiple dates keep their individual, fully functional actions.
        let replacement: UIMenu
        if hasEvent {
            // Rise's own actions fill in what the system's leave out, so they're the ones kept.
            replacement = riseSections[0]
        } else if timeMenus.count == 1, nativeGroups.count == 1, let copy = timeMenus[0].children.first as? UIAction {
            let extra = timeMenus[0].children.filter { ($0 as? UIAction)?.identifier.rawValue == "dev.bartosz.Rise.replaceTimes" }
            replacement = riseSections[0].replacingChildren([timeMenus[0].replacingChildren([copy] + extra + nativeGroups[0])])
        } else {
            guard timeMenus.allSatisfy({ $0.children.count >= 4 }) else { return root }
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
