import AppKit

/// Browser actions offered after `/`, and only while they'd do something.
struct PaletteCommand {
    /// What runs it, the same whatever its title says now.
    let id: String
    let title: String
    let symbol: String
    /// Hidden search aliases; the row keeps its normal title.
    var keywords: [String] = []

    /// A leading slash switches the address palette to browser commands.
    static func query(in text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("/") else { return nil }
        return String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every word typed starts a word of its title or keywords: "close" finds Close Tab, "url"
    /// Copy Link.
    func matches(_ query: String) -> Bool {
        let typed = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard !typed.isEmpty else { return false }
        let words = ([title]+keywords).flatMap { $0.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) }
        return typed.allSatisfy { part in words.contains { $0.hasPrefix(part) } }
    }
}

/// Local command counts live beside the session and survive app restarts.
@MainActor final class PaletteCommandUsage {
    private let storageURL: URL
    private var counts: [String: Int] = [:]

    init(storageURL: URL) {
        self.storageURL = storageURL
        if let data = try? Data(contentsOf: storageURL), data.count <= 64_000,
           let saved = try? JSONDecoder().decode([String: Int].self, from: data) {
            counts = Dictionary(uniqueKeysWithValues: saved.filter { $0.key.count <= 128 && $0.value > 0 }
                .sorted { $0.key < $1.key }.prefix(128).map { ($0.key, $0.value) })
        }
    }
    func count(for command: String) -> Int { counts[command, default: 0] }
    func record(_ command: String) {
        counts[command] = min(count(for: command), Int.max-1)+1
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(counts).write(to: storageURL, options: .atomic)
        } catch { NSLog("Rise command usage couldn't be saved: %@", error.localizedDescription) }
    }
}

/// The zoom a page can take: Chrome's steps, from Chromium's least (25%) up.
enum PageZoom {
    static let levels: [CGFloat] = [0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]
    /// What the palette's Zoom offers.
    static let listed = levels.filter { $0 <= 2 }
    static func next(after zoom: CGFloat) -> CGFloat { levels.first { $0 > zoom+0.001 } ?? levels.last! }
    static func previous(before zoom: CGFloat) -> CGFloat { levels.last { $0 < zoom-0.001 } ?? levels.first! }
    static func text(_ zoom: CGFloat) -> String { "\(Int((zoom*100).rounded()))%" }
    static func isActual(_ zoom: CGFloat) -> Bool { abs(zoom-1) < 0.001 }
}

@MainActor extension BrowserController {
    var paletteCommands: [PaletteCommand] {
        let tab = selectedTab, hasPage = tab?.url != nil
        var commands: [PaletteCommand?] = [
            tab != nil ? PaletteCommand(id: "Close Tab", title: "Close Tab", symbol: "xmark", keywords: ["dismiss", "remove tab"]) : nil,
            !closedTabs.isEmpty ? PaletteCommand(id: "Reopen Closed Tab", title: "Reopen Closed Tab", symbol: "arrow.uturn.backward",
                                                keywords: ["undo", "restore", "recover", "bring back"]) : nil,
            !archivedTabs.entries.isEmpty ? PaletteCommand(id: "Archived Tabs", title: "Archived Tabs", symbol: "archivebox",
                                                           keywords: ["unused", "auto closed", "restore", "recover", "bring back"]) : nil,
            hasPage ? PaletteCommand(id: "Duplicate Tab", title: "Duplicate Tab", symbol: "plus.square.on.square", keywords: ["copy", "clone"]) : nil,
            tab.flatMap { tab in tab.pinned || canPinTab && !splitGroups.contains { $0.contains(tab.id) }
                ? PaletteCommand(id: "Toggle Pin", title: tab.pinned ? "Unpin Tab" : "Pin Tab", symbol: tab.pinned ? "pin.slash" : "pin",
                                 keywords: tab.pinned ? ["release tab"] : ["keep open", "sticky tab"]) : nil },
            tab.map { PaletteCommand(id: "Toggle Mute", title: $0.isAudioMuted ? "Unmute Tab" : "Mute Tab", symbol: $0.isAudioMuted ? "speaker.wave.2" : "speaker.slash",
                                     keywords: ["sound", "audio"] + ($0.isAudioMuted ? ["enable sound", "turn on sound", "unsilence"] : ["silence", "quiet", "turn off sound"])) },
            !closableTabsBelow.isEmpty ? PaletteCommand(id: "Close Tabs Below", title: "Close Tabs Below", symbol: "arrow.down.to.line",
                                                       keywords: ["close tabs after", "close following tabs"]) : nil,
            !closableTabsAbove.isEmpty ? PaletteCommand(id: "Close Tabs Above", title: "Close Tabs Above", symbol: "arrow.up.to.line",
                                                       keywords: ["close tabs before", "close previous tabs"]) : nil,
            tabs.count > 1 ? PaletteCommand(id: "Sort Tabs by Domain", title: "Sort Tabs by Domain", symbol: "arrow.up.arrow.down",
                                           keywords: ["clean", "organise", "organize", "tidy", "group by site", "group websites"]) : nil,
            PaletteCommand(id: "Split View", title: "Split View", symbol: "rectangle.split.2x1",
                           keywords: ["side by side", "split screen", "compare pages", "two panes"]
                            + (activeSplitGroup != nil ? ["unsplit", "single pane", "exit split"] : [])),
            activeSplitGroup != nil ? PaletteCommand(id: "Swap Sides", title: "Swap Sides", symbol: "arrow.left.arrow.right",
                                                     keywords: ["split", "switch panes", "reverse sides", "flip sides"]) : nil,
            tab != nil ? PaletteCommand(id: "Reload", title: "Reload", symbol: "arrow.clockwise", keywords: ["refresh", "update page"]) : nil,
            hasPage ? PaletteCommand(id: "Copy Link", title: "Copy Link", symbol: "link", keywords: ["url", "address", "clipboard"]) : nil,
            tab != nil ? PaletteCommand(id: "Find in Page", title: "Find in Page", symbol: "text.magnifyingglass", keywords: ["search", "text", "locate"]) : nil,
            hasPage ? PaletteCommand(id: "Capture Page", title: "Capture Page", symbol: "camera",
                                     keywords: ["screenshot", "screen shot", "snapshot", "save page", "export page", "image", "jpeg", "pdf"]) : nil,
            (commandTab?.page as? ChromiumPage)?.browserView.canPrint == true
                ? PaletteCommand(id: "Print", title: "Print…", symbol: "printer", keywords: ["printer", "paper", "pdf", "save as pdf", "print preview"]) : nil,
            tab != nil ? PaletteCommand(id: "Zoom", title: "Zoom", symbol: "plus.magnifyingglass",
                                        keywords: ["in", "out", "bigger", "smaller", "magnify", "enlarge", "shrink", "scale", "text size"]) : nil,
            tab.flatMap { PageZoom.isActual($0.page.zoom) ? nil : PaletteCommand(id: "Actual Size", title: "Actual Size", symbol: "1.magnifyingglass",
                                                                             keywords: ["zoom", "reset", "normal size", "default size", "100%", "100 percent"]) },
            PaletteCommand(id: "Change Theme", title: "Change Theme", symbol: "paintbrush",
                           keywords: ["appearance", "dark", "light", "night mode", "day mode", "colour", "color", "automatic"]),
            PaletteCommand(id: "Toggle Sidebar", title: "Toggle Sidebar", symbol: "sidebar.left",
                           keywords: ["tab list", "tabs panel"] + (sidebarVisible ? ["hide", "collapse"] : ["show", "expand"])),
            PaletteCommand(id: "Open Settings", title: "Open Settings", symbol: "gearshape",
                           keywords: ["preferences", "options", "configure", "configuration", "customise", "customize"]),
            PaletteCommand(id: "Extensions", title: "Extensions", symbol: "puzzlepiece.extension", keywords: ["add ons", "addons", "plugins", "plug ins"]),
            PaletteCommand(id: "Downloads", title: "Downloads", symbol: "arrow.down.circle", keywords: ["files", "downloaded files", "transfers"]),
        ]
        if let tab {
            commands.append(PaletteCommand(id: "Toggle Developer Mode", title: tab.developer ? "Disable Developer Mode" : "Enable Developer Mode",
                                           symbol: "hammer", keywords: ["develop", "devtools", "toggle", "advanced controls", "developer toolbar"]))
        }
        return commands.compactMap { $0 }
    }
    /// Matching actions ordered by use count, then title prefix and catalog order.
    func paletteCommands(matching query: String) -> [PaletteCommand] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return paletteCommands.enumerated().filter { query.isEmpty || $0.element.matches(query) }.sorted { left, right in
            let a = paletteCommandUsage.count(for: left.element.id), b = paletteCommandUsage.count(for: right.element.id)
            if a != b { return a > b }
            let aStarts = left.element.title.lowercased().hasPrefix(query), bStarts = right.element.title.lowercased().hasPrefix(query)
            if aStarts != bStarts { return aStarts }
            return left.offset < right.offset
        }.map(\.element)
    }

    /// The lists some commands open in place of running: the themes, capture formats and zooms.
    func paletteChoice(for command: String) -> AddressPalette.Choice? {
        func row(_ title: String, _ symbol: String, _ command: String) -> AddressSuggestion {
            AddressSuggestion(title: title, subtitle: "", symbol: symbol, url: nil, tabID: nil, command: command)
        }
        switch command {
        case "Change Theme":
            let themes: [(String, RiseTheme?)] = [("Light", .neutral), ("Dark", .dark), ("Automatic", nil)]
            return .init(placeholder: "Choose a theme…", symbol: "paintbrush",
                         rows: themes.map { row($0.0, "paintbrush", AddressPalette.themeCommandPrefix+($0.1?.rawValue ?? "automatic")) },
                         picked: themes.firstIndex { automaticTheme ? $0.1 == nil : $0.1 == theme })
        case "Capture Page":
            return .init(placeholder: "Capture as…", symbol: "camera", rows: [row("JPEG", "photo", "Capture:jpeg"), row("PDF", "doc.richtext", "Capture:pdf")], picked: 0)
        case "Zoom":
            let zoom = commandTab?.page.zoom ?? 1
            return .init(placeholder: "Zoom to…", symbol: "plus.magnifyingglass",
                         rows: PageZoom.listed.map { row(PageZoom.text($0), "plus.magnifyingglass", "Zoom:\($0)") },
                         picked: PageZoom.listed.firstIndex { abs($0-zoom) < 0.001 })
        default: return nil
        }
    }

    func runPaletteCommand(_ command: String) {
        // Count a completed choice under its parent action; opening and cancelling a
        // submenu doesn't count as using it.
        let action = command.hasPrefix(AddressPalette.themeCommandPrefix) ? "Change Theme"
            : command.hasPrefix("Capture:") ? "Capture Page" : command.hasPrefix("Zoom:") ? "Zoom" : command
        if paletteCommands.contains(where: { $0.id == action }) { paletteCommandUsage.record(action) }
        if command.hasPrefix(AddressPalette.themeCommandPrefix) {
            let choice = String(command.dropFirst(AddressPalette.themeCommandPrefix.count))
            chooseTheme(choice == "automatic" ? nil : RiseTheme(rawValue: choice) ?? theme); return
        }
        if command.hasPrefix("Capture:") { captureWholePage(command.hasSuffix("pdf") ? .pdf : .jpeg); return }
        if command.hasPrefix("Zoom:"), let zoom = Double(command.dropFirst("Zoom:".count)) { setPageZoom(CGFloat(zoom)); return }
        switch command {
        case "Close Tab": closeSelectedTab(confirmingPinned: false)
        case "Reopen Closed Tab": reopenTab()
        case "Archived Tabs": showArchivedTabs()
        case "Duplicate Tab": duplicateCurrentTab()
        case "Toggle Pin": pinCurrentTab()
        case "Toggle Mute": if let tab = commandTab { tab.setAudioMuted(!tab.isAudioMuted) }
        case "Close Tabs Below": closeTabsBelow()
        case "Close Tabs Above": closeTabsAbove()
        case "Sort Tabs by Domain": cleanUpTabs()
        case "Split View": toggleSplit()
        case "Swap Sides": swapSplitSides()
        case "Reload": reload()
        case "Copy Link": copyURL()
        case "Print": printPage()
        case "Find in Page": showFind()
        case "Actual Size": actualSize()
        case "Change Theme": toggleTheme()
        case "Toggle Sidebar": toggleSidebar()
        case "Open Settings": showSettings()
        case "Extensions": showExtensions()
        case "Downloads": showDownloads()
        case "Toggle Developer Mode": toggleDeveloper()
        default: break
        }
    }

    var closableTabsAbove: [BrowserTab] {
        guard let firstVisible = tabs.firstIndex(where: { visibleTabIDs.contains($0.id) }) else { return [] }
        return tabs.prefix(firstVisible).filter { !$0.pinned }
    }
    @objc func closeTabsAbove() { for tab in closableTabsAbove { closeTab(tab.id) } }
}
