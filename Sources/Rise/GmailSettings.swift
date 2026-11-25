import AppKit

@MainActor extension BrowserController {
    static let gmailCategoryKey = "Rise.GmailHoverCategory"
    var gmailCategory: GmailCategory {
        GmailCategory(rawValue: preferences.string(forKey: Self.gmailCategoryKey) ?? "") ?? .updates
    }
    func selectGmailCategory(_ category: GmailCategory) {
        preferences.set(category.rawValue, forKey: Self.gmailCategoryKey)
        if let id = tabHoverCards.shownID, GmailAccount(url: hoverTab(id)?.url) != nil {
            showGmailTooltip(id)
        } else { preloadGmailInbox() }
    }
    func makeGmailCategoryMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Gmail Preview Category", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: item.title)
        for category in GmailCategory.allCases where category != .all {
            submenu.addItem(menuItem(category.title, checked: gmailCategory == category) { [weak self] in self?.selectGmailCategory(category) })
        }
        submenu.addItem(.separator())
        submenu.addItem(menuItem(GmailCategory.all.title, checked: gmailCategory == .all) { [weak self] in self?.selectGmailCategory(.all) })
        item.submenu = submenu; return item
    }
}
