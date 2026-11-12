import AppKit

extension NSMenu {
    /// macOS 26 indents every item of a section (the items between dividers) whenever one of them
    /// has an icon, so items without one stand in from the rest with nothing to line up with. Where
    /// a section mixes them, a divider goes between the items with icons and those without, so
    /// each run lines up with its own; submenus too. Section headers and dividers start sections,
    /// and an alternate (shown in place of the item before it while a key's held) stays with it.
    @discardableResult func separatingIconSections() -> NSMenu {
        var index = 0, previous: Bool?
        while index < items.count {
            let item = items[index]
            item.submenu?.separatingIconSections()
            if item.isSeparatorItem || item.isSectionHeader { previous = nil; index += 1; continue }
            if item.isHidden || item.isAlternate { index += 1; continue }
            let shows = item.image != nil
            if let previous, previous != shows { insertItem(.separator(), at: index); index += 1 }
            previous = shows
            index += 1
        }
        return self
    }
    /// Whether a section shows items with icons beside ones without, which macOS would indent.
    var mixesIconsInASection: Bool {
        var previous: Bool?
        for item in items {
            if item.submenu?.mixesIconsInASection == true { return true }
            if item.isSeparatorItem || item.isSectionHeader { previous = nil; continue }
            if item.isHidden || item.isAlternate { continue }
            let shows = item.image != nil
            if let previous, previous != shows { return true }
            previous = shows
        }
        return false
    }
}
