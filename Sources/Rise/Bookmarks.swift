import AppKit
import RiseCore

/// A page kept to open again: its address, its title, and its icons as they were when it was
/// kept, as the bar and the sidebar show them, in the order they show them. No folders yet.
struct Bookmark: Codable, Equatable, Identifiable {
    let id: UUID
    var url: URL
    var title: String
    var icon: Data?
    var darkIcon: Data?

    /// The same page, as far as bookmarking goes: its address without the part after `#`, and
    /// without a trailing slash, its scheme and host in any case.
    static func key(_ url: URL?) -> String? {
        guard let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme != nil else { return nil }
        parts.fragment = nil; parts.scheme = parts.scheme?.lowercased(); parts.host = parts.host?.lowercased()
        var text = parts.string ?? url.absoluteString
        while text.hasSuffix("/") && text.count > 1 { text.removeLast() }
        return text
    }
    /// What it's called where there's no title: its site.
    var shownTitle: String {
        let words = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? AddressDisplay.text(url.absoluteString) : words
    }
}

/// The bookmarks, kept in a file beside the session's.
@MainActor final class BookmarkStore {
    private(set) var items: [Bookmark] = []
    private let storageURL: URL
    private var images: [UUID: (light: NSImage?, dark: NSImage?)] = [:]
    var onChange: (() -> Void)?

    init(storageURL: URL) {
        self.storageURL = storageURL
        if let data = try? Data(contentsOf: storageURL), let saved = try? JSONDecoder().decode([Bookmark].self, from: data) {
            items = saved
        }
    }
    func bookmark(for url: URL?) -> Bookmark? {
        guard let key = Bookmark.key(url) else { return nil }
        return items.first { Bookmark.key($0.url) == key }
    }
    func index(of id: UUID) -> Int? { items.firstIndex { $0.id == id } }
    func icon(for bookmark: Bookmark, dark: Bool) -> NSImage? {
        if images[bookmark.id] == nil {
            images[bookmark.id] = (bookmark.icon.flatMap(FaviconSnapshot.decode), bookmark.darkIcon.flatMap(FaviconSnapshot.decode))
        }
        let saved = images[bookmark.id]
        return dark ? saved?.dark ?? saved?.light : saved?.light
    }
    /// The site's own icon for dark backgrounds, if it was kept.
    func darkIcon(for bookmark: Bookmark) -> NSImage? {
        _ = icon(for: bookmark, dark: true); return images[bookmark.id]?.dark
    }
    @discardableResult func add(url: URL, title: String, icon: Data?, darkIcon: Data?, at index: Int? = nil) -> Bookmark {
        if let existing = bookmark(for: url) { return existing }
        let bookmark = Bookmark(id: UUID(), url: url, title: title, icon: icon, darkIcon: darkIcon)
        insert(bookmark, at: index ?? items.count)
        return bookmark
    }
    func insert(_ bookmark: Bookmark, at index: Int) {
        guard self.index(of: bookmark.id) == nil else { return }
        items.insert(bookmark, at: min(max(0, index), items.count)); changed()
    }
    /// Takes it out, saying where it was so it can go back there.
    @discardableResult func remove(_ id: UUID) -> (bookmark: Bookmark, index: Int)? {
        guard let index = index(of: id) else { return nil }
        let removed = items.remove(at: index); images[id] = nil; changed()
        return (removed, index)
    }
    func move(_ id: UUID, to index: Int) {
        guard let from = self.index(of: id) else { return }
        let target = min(max(0, index), items.count-1)
        guard target != from else { return }
        items.insert(items.remove(at: from), at: target); changed()
    }
    func rename(_ id: UUID, to title: String) {
        guard let index = index(of: id), items[index].title != title else { return }
        items[index].title = title; changed()
    }
    /// A bookmarked page that loads with a sharper icon than the one kept gives it that one.
    func refreshIcons(from tab: BrowserTab) {
        guard let key = Bookmark.key(tab.url), let index = items.firstIndex(where: { Bookmark.key($0.url) == key }) else { return }
        var item = items[index]
        func better(_ data: Data?, than old: Data?) -> Data? {
            guard let data, data != old, let image = FaviconSnapshot.decode(data) else { return old }
            guard let old, let known = FaviconSnapshot.decode(old) else { return data }
            return FaviconImage.pixels(image) > FaviconImage.pixels(known) ? data : old
        }
        item.icon = better(tab.faviconData, than: item.icon)
        item.darkIcon = better(tab.darkFaviconData, than: item.darkIcon)
        guard item != items[index] else { return }
        items[index] = item; images[item.id] = nil; changed()
    }
    private func changed() {
        if let data = try? JSONEncoder().encode(items) {
            try? FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: storageURL, options: .atomic)
        }
        onChange?()
    }
}

/// Where bookmarks show: in a bar under the page's bar, or in the sidebar in the tabs' place.
enum BookmarkPlacement: String, CaseIterable {
    case bar, sidebar
    var title: String { self == .bar ? "Bar under the address" : "In the sidebar" }
}

@MainActor extension BrowserController {
    static let bookmarkPlacementKey = "Rise.BookmarkPlacement"
    static let autoHideBookmarksBarKey = "Rise.AutoHideBookmarksBar"
    var bookmarkPlacement: BookmarkPlacement {
        preferences.string(forKey: Self.bookmarkPlacementKey).flatMap(BookmarkPlacement.init) ?? .bar
    }
    var autoHidesBookmarksBar: Bool { preferences.bool(forKey: Self.autoHideBookmarksBarKey) }
    func setBookmarkPlacement(_ placement: BookmarkPlacement) {
        preferences.set(placement.rawValue, forKey: Self.bookmarkPlacementKey)
        if placement == .bar { returnToTabs(animated: false) }
        bookmarksChanged()
    }
    func setAutoHidesBookmarksBar(_ hides: Bool) {
        preferences.set(hides, forKey: Self.autoHideBookmarksBarKey)
        bookmarksBar.slide.setShown(!hides, animated: false)
        layoutChrome()
    }

    /// Settings' rows for bookmarks: where they show, and, in the bar, whether it hides itself.
    func bookmarkSettingRows(select: (String, String, String?, String, [(String, String)]) -> [String: Any],
                             toggle: (String, String, String?, Bool) -> [String: Any]) -> [[String: Any]] {
        func shortcut(_ id: String) -> String { keyboardShortcuts.bindings(id).first?.display ?? "" }
        let add = shortcut("bookmarkCurrentPage")
        let about = bookmarkPlacement == .bar
            ? "Pages you bookmark\(add.isEmpty ? "" : " with \(add)") show in a bar under the address, once there's one"
            : "\(shortcut("toggleSidebarBookmarks")) shows them in the tabs' place, or hold \(shortcut("holdSidebarBookmarks")) to see them until you let go"
        var rows = [select("bookmarkPlacement", "Bookmarks", about, bookmarkPlacement.rawValue,
                           BookmarkPlacement.allCases.map { ($0.rawValue, $0.title) })]
        if bookmarkPlacement == .bar {
            rows.append(toggle("autoHideBookmarksBar", "Auto-hide the bookmarks bar",
                               "It comes down when the pointer reaches the bar with the address, and goes back up when it leaves", autoHidesBookmarksBar))
        }
        return rows
    }

    /// The bar and the sidebar's list show the bookmarks as they are now.
    func bookmarksChanged(layout: Bool = true) {
        bookmarksBar.update(bookmarks.items, icon: { [weak self] in self?.bookmarkIcon($0, dark: $1) })
        sidebar.bookmarksPane.update(bookmarks.items, theme: theme, icon: { [weak self] in self?.bookmarkIcon($0) })
        if layout { layoutChrome() }
    }
    /// A bookmark's icon for a dark or light background (the theme's, unless said): the site's
    /// dark icon on a dark one where it has one, as a black logo would vanish there.
    func bookmarkIcon(_ bookmark: Bookmark, dark: Bool? = nil) -> NSImage? {
        let dark = dark ?? (theme == .dark)
        if dark, let icon = bookmarks.darkIcon(for: bookmark) ?? suggestionFavicons.darkImage(for: bookmark.url) { return icon }
        return bookmarks.icon(for: bookmark, dark: false) ?? suggestionFavicons.image(for: bookmark.url, fetch: true, dark: dark)
    }

    /// ⌘D: adds the page in front at the end of the bookmarks, where they show, with its title
    /// chosen to type over, as a tab's is when it's renamed: Enter keeps it, Escape takes the
    /// bookmark away again. A page that's kept already has its title chosen in the same way.
    @objc func bookmarkCurrentPage() {
        guard let tab = commandTab, let url = tab.url, Self.canBookmark(url) else { return }
        if let edit = bookmarkEdit { finishBookmarkEdit(edit.id, title: bookmarks.items.first { $0.id == edit.id }?.title) }
        if let existing = bookmarks.bookmark(for: url) { beginBookmarkEdit(existing.id, isNew: false); return }
        let title = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let added = bookmarks.add(url: url, title: title.isEmpty ? AddressResolver.displayHost(url) : title,
                                  icon: tab.faviconData, darkIcon: tab.darkFaviconData)
        beginBookmarkEdit(added.id, isNew: true)
    }
    func beginBookmarkEdit(_ id: UUID, isNew: Bool) {
        switch bookmarkPlacement {
        case .sidebar:
            let wasShown = sidebarBookmarks.isShown
            bookmarkEdit = (id, isNew, !wasShown)
            showSidebarBookmarks()
            sidebar.bookmarksPane.beginEditing(id)
        case .bar:
            layoutChrome()
            // Where the bar can't show, as over a page in simulated full screen, the page bar says so instead.
            guard showsBookmarksBar else {
                bookmarkEdit = nil
                guard isNew else { return }
                selectedBar.showNotice("Bookmarked", image: BarNotice.bookmarkImage,
                                       action: BarNotice.Link(text: "Undo") { [weak self] in
                                           self?.bookmarks.remove(id); self?.selectedBar.hideNotice()
                                       }, hold: 2.5)
                return
            }
            bookmarkEdit = (id, isNew, false)
            // A bar that hides itself comes down for it, and stays while it's named.
            refreshBookmarksBar()
            bookmarksBar.beginEditing(id)
        }
    }
    /// Typing done: `title` kept, or nil for Escape, which takes a bookmark just added away again.
    func finishBookmarkEdit(_ id: UUID, title: String?) {
        guard let edit = bookmarkEdit, edit.id == id else { return }
        bookmarkEdit = nil
        if let title, !title.isEmpty { bookmarks.rename(id, to: title) }
        else if title == nil, edit.isNew { bookmarks.remove(id) }
        if edit.returnsToTabs { returnToTabs(animated: true) }
        // Kept, a bar that hides itself stays down a moment so you see it there.
        if bookmarkPlacement == .bar, autoHidesBookmarksBar, title != nil { revealBookmarksBar(for: 0.9) } else { refreshBookmarksBar() }
        // Enter and Escape give the page its keys back; a click elsewhere keeps what it chose.
        if let window, window.firstResponder === window || window.firstResponder == nil, let page = commandTab?.page.view {
            window.makeFirstResponder(page)
        }
    }
    static func canBookmark(_ url: URL) -> Bool {
        !["about", "data", "javascript", "blob"].contains(url.scheme?.lowercased() ?? "")
    }

    /// Opens a bookmark in a new tab beside the one you're on, or at the top of the sidebar with ⌘.
    /// An empty new tab takes it itself.
    func openBookmark(_ id: UUID, atTop: Bool) {
        guard let bookmark = bookmarks.items.first(where: { $0.id == id }) else { return }
        if !atTop, let tab = selectedTab, tab.url == nil, tab.requestedURL == nil, !tab.isLoading, !tab.pinned {
            tab.load(bookmark.url); select(tab.id); return
        }
        addTab(url: bookmark.url, opener: atTop ? nil : selectedID)
    }
    func showBookmarkMenu(_ id: UUID, event: NSEvent, in view: NSView) {
        guard let bookmark = bookmarks.items.first(where: { $0.id == id }) else { return }
        let menu = NSMenu()
        menu.addItem(menuItem("Open in New Tab") { [weak self] in self?.openBookmark(id, atTop: false) })
        menu.addItem(menuItem("Open at Top of Sidebar") { [weak self] in self?.openBookmark(id, atTop: true) })
        menu.addItem(.separator())
        menu.addItem(menuItem("Copy Link") {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(bookmark.url.absoluteString, forType: .string)
        })
        menu.addItem(menuItem("Rename…") { [weak self] in self?.renameBookmark(id) })
        menu.addItem(.separator())
        menu.addItem(menuItem("Remove Bookmark") { [weak self] in self?.bookmarks.remove(id) })
        bookmarksMenuOpen = true
        NSMenu.popUpContextMenu(menu, with: event, for: view)
        bookmarksMenuOpen = false
        refreshBookmarksBar()
    }
    func renameBookmark(_ id: UUID) {
        guard let window, let bookmark = bookmarks.items.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Bookmark"; alert.informativeText = AddressDisplay.text(bookmark.url.absoluteString)
        let field = NSTextField(string: bookmark.title); field.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { self?.bookmarks.rename(id, to: title) }
        }
    }
}
