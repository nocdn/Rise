import AppKit

/// What the address palette can do besides open pages: a row each, offered as their words are
/// typed, and only while they'd do something.
struct PaletteCommand {
    /// What runs it, the same whatever its title says now.
    let id: String
    let title: String
    let symbol: String
    /// More words it answers to, beside its title's.
    var keywords: [String] = []

    /// Every word typed starts a word of its title or keywords: "close" finds Close Tab, "url"
    /// Copy Link.
    func matches(_ query: String) -> Bool {
        let typed = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !typed.isEmpty else { return false }
        let words = ([title]+keywords).flatMap { $0.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) }
        return typed.allSatisfy { part in words.contains { $0.hasPrefix(part) } }
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
            tab != nil ? PaletteCommand(id: "Close Tab", title: "Close Tab", symbol: "xmark") : nil,
            !closedTabs.isEmpty ? PaletteCommand(id: "Reopen Closed Tab", title: "Reopen Closed Tab", symbol: "arrow.uturn.backward", keywords: ["undo", "restore"]) : nil,
            hasPage ? PaletteCommand(id: "Duplicate Tab", title: "Duplicate Tab", symbol: "plus.square.on.square", keywords: ["copy"]) : nil,
            tab.flatMap { tab in tab.pinned || canPinTab && !splitGroups.contains { $0.contains(tab.id) }
                ? PaletteCommand(id: "Toggle Pin", title: tab.pinned ? "Unpin Tab" : "Pin Tab", symbol: tab.pinned ? "pin.slash" : "pin") : nil },
            tab.map { PaletteCommand(id: "Toggle Mute", title: $0.isAudioMuted ? "Unmute Tab" : "Mute Tab", symbol: $0.isAudioMuted ? "speaker.wave.2" : "speaker.slash",
                                     keywords: ["sound", "audio"]) },
            !closableTabsBelow.isEmpty ? PaletteCommand(id: "Close Tabs Below", title: "Close Tabs Below", symbol: "arrow.down.to.line") : nil,
            !closableTabsAbove.isEmpty ? PaletteCommand(id: "Close Tabs Above", title: "Close Tabs Above", symbol: "arrow.up.to.line") : nil,
            tabs.count > 1 ? PaletteCommand(id: "Sort Tabs by Domain", title: "Sort Tabs by Domain", symbol: "arrow.up.arrow.down", keywords: ["clean", "organise", "organize"]) : nil,
            PaletteCommand(id: "Split View", title: "Split View", symbol: "rectangle.split.2x1"),
            activeSplitGroup != nil ? PaletteCommand(id: "Swap Sides", title: "Swap Sides", symbol: "arrow.left.arrow.right", keywords: ["split"]) : nil,
            tab != nil ? PaletteCommand(id: "Reload", title: "Reload", symbol: "arrow.clockwise", keywords: ["refresh"]) : nil,
            hasPage ? PaletteCommand(id: "Copy Link", title: "Copy Link", symbol: "link", keywords: ["url", "address"]) : nil,
            tab != nil ? PaletteCommand(id: "Find in Page", title: "Find in Page", symbol: "text.magnifyingglass", keywords: ["search"]) : nil,
            hasPage ? PaletteCommand(id: "Capture Page", title: "Capture Page", symbol: "camera", keywords: ["screenshot", "jpeg", "pdf"]) : nil,
            tab != nil ? PaletteCommand(id: "Zoom", title: "Zoom", symbol: "plus.magnifyingglass", keywords: ["in", "out", "bigger", "smaller"]) : nil,
            tab.flatMap { PageZoom.isActual($0.page.zoom) ? nil : PaletteCommand(id: "Actual Size", title: "Actual Size", symbol: "1.magnifyingglass", keywords: ["zoom", "reset"]) },
            PaletteCommand(id: "Change Theme", title: "Change Theme", symbol: "paintbrush", keywords: ["appearance", "dark", "light"]),
            PaletteCommand(id: "Toggle Sidebar", title: "Toggle Sidebar", symbol: "sidebar.left"),
            PaletteCommand(id: "Open Settings", title: "Open Settings", symbol: "gearshape", keywords: ["preferences"]),
            PaletteCommand(id: "Extensions", title: "Extensions", symbol: "puzzlepiece.extension"),
            PaletteCommand(id: "Downloads", title: "Downloads", symbol: "arrow.down.circle"),
        ]
        if let tab {
            commands.append(PaletteCommand(id: "Toggle Developer Mode", title: tab.developer ? "Disable Developer Mode" : "Enable Developer Mode",
                                           symbol: "hammer", keywords: ["develop", "devtools", "toggle"]))
        }
        return commands.compactMap { $0 }
    }
    /// The commands answering to `query`, those whose title starts with it first.
    func paletteCommands(matching query: String) -> [PaletteCommand] {
        let matches = paletteCommands.filter { $0.matches(query) }
        let lead = matches.filter { $0.title.lowercased().hasPrefix(query.lowercased()) }
        return Array((lead+matches.filter { lead.map(\.id).contains($0.id) == false }).prefix(Self.paletteCommandLimit))
    }
    /// So the pages and searches typed for still show beside them.
    static let paletteCommandLimit = 4

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
            let zoom = selectedTab?.page.zoom ?? 1
            return .init(placeholder: "Zoom to…", symbol: "plus.magnifyingglass",
                         rows: PageZoom.listed.map { row(PageZoom.text($0), "plus.magnifyingglass", "Zoom:\($0)") },
                         picked: PageZoom.listed.firstIndex { abs($0-zoom) < 0.001 })
        default: return nil
        }
    }

    func runPaletteCommand(_ command: String) {
        if command.hasPrefix(AddressPalette.themeCommandPrefix) {
            let choice = String(command.dropFirst(AddressPalette.themeCommandPrefix.count))
            chooseTheme(choice == "automatic" ? nil : RiseTheme(rawValue: choice) ?? theme); return
        }
        if command.hasPrefix("Capture:") { captureWholePage(command.hasSuffix("pdf") ? .pdf : .jpeg); return }
        if command.hasPrefix("Zoom:"), let zoom = Double(command.dropFirst("Zoom:".count)) { setPageZoom(CGFloat(zoom)); return }
        switch command {
        case "Close Tab": closeSelectedTab(confirmingPinned: false)
        case "Reopen Closed Tab": reopenTab()
        case "Duplicate Tab": duplicateCurrentTab()
        case "Toggle Pin": pinCurrentTab()
        case "Toggle Mute": if let tab = selectedTab { tab.setAudioMuted(!tab.isAudioMuted) }
        case "Close Tabs Below": closeTabsBelow()
        case "Close Tabs Above": closeTabsAbove()
        case "Sort Tabs by Domain": cleanUpTabs()
        case "Split View": toggleSplit()
        case "Swap Sides": swapSplitSides()
        case "Reload": reload()
        case "Copy Link": copyURL()
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
    /// The split's pages trade places, each keeping its share of the room.
    func swapSplitSides() {
        guard let group = activeSplitGroup, let index = splitGroups.firstIndex(where: { $0.id == group.id }) else { return }
        splitGroups[index].leftID = group.rightID; splitGroups[index].rightID = group.leftID
        splitGroups[index].fraction = 1-group.fraction
        attachVisiblePages(); update(); scheduleSave()
    }
}
