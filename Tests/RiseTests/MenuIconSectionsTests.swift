import XCTest
import AppKit
@testable import Rise

final class MenuIconSectionsTests: XCTestCase {
    @MainActor func testItemsWithoutIconsGetTheirOwnSectionAndAlternatesStayWithTheirItem() {
        let icon = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        func item(_ title: String, _ image: NSImage? = nil, alternate: Bool = false) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.image = image
            if alternate { item.isAlternate = true; item.keyEquivalentModifierMask = .option }
            return item
        }
        let menu = NSMenu()
        [item("Download Linked File"), item("Copy Link"), item("Share…", icon), item("AirDrop", icon), item("AirDrop Again", alternate: true),
         .separator(), item("Encode", icon)].forEach(menu.addItem)
        let submenu = NSMenu(); [item("Plain"), item("With", icon)].forEach(submenu.addItem); menu.items.last?.submenu = submenu
        XCTAssertTrue(menu.mixesIconsInASection)
        menu.separatingIconSections().separatingIconSections()
        XCTAssertEqual(menu.items.map { $0.isSeparatorItem ? "—" : $0.title },
                       ["Download Linked File", "Copy Link", "—", "Share…", "AirDrop", "AirDrop Again", "—", "Encode"], "Once, however often it runs")
        XCTAssertEqual(submenu.items.map { $0.isSeparatorItem ? "—" : $0.title }, ["Plain", "—", "With"])
        XCTAssertFalse(menu.mixesIconsInASection)
    }

    @MainActor func testRisesOwnMenusDontIndentItemsWithoutIcons() throws {
        _ = NSApplication.shared
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"), restore: false)
        defer { browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil) }
        let old = NSApp.mainMenu; defer { NSApp.mainMenu = old }
        let delegate = AppDelegate(); delegate.browser = browser; delegate.buildMenu()
        let tab = browser.addTab(url: URL(string: "https://example.com")!)
        XCTAssertFalse(try XCTUnwrap(NSApp.mainMenu).mixesIconsInASection, "The menu bar's menus")
        XCTAssertFalse(try XCTUnwrap(browser.makeTabMenu(tab.id)).separatingIconSections().mixesIconsInASection, "A tab's menu")
    }
}
