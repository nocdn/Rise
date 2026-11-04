import AppKit
import RiseChromium

/// Rise's own settings, among Chrome's at rise://settings: the settings page asks Rise for each
/// section's rows, and changes them, through the `riseSettings` object Rise's script gives it.
/// Rows are described here, so a new setting needs no change to the engine.
@MainActor extension BrowserController {
    static let settingsHandler = "riseSettings"

    /// The rows Rise adds to a section of the settings page: `appearance`, `tabs`, `ai`, `system`
    /// or `privacy`.
    func riseSettingRows(_ section: String) -> [[String: Any]] {
        func toggle(_ key: String, _ label: String, _ sublabel: String? = nil, _ value: Bool) -> [String: Any] {
            ["key": key, "type": "toggle", "label": label, "sublabel": sublabel ?? "", "value": value]
        }
        func select(_ key: String, _ label: String, _ sublabel: String? = nil, _ value: String, _ options: [(String, String)]) -> [String: Any] {
            ["key": key, "type": "select", "label": label, "sublabel": sublabel ?? "", "value": value,
             "options": options.map { ["value": $0.0, "label": $0.1] }]
        }
        switch section {
        case "appearance":
            return [
                select("theme", "Theme", "The colours of Rise's window and its pages", automaticTheme ? "automatic" : theme.rawValue,
                       [("automatic", "Automatic"), (RiseTheme.neutral.rawValue, "Light"), (RiseTheme.dark.rawValue, "Dark")]),
                toggle("livePeekResize", "Live page while expanding Peek", "The page lays itself out at every size as a Peek grows into a tab", livePeekResize),
                toggle("animateDevTools", "Animate developer tools", "DevTools slide in and out from the right", animatesDevTools),
                toggle("highlightSummaryLinks", "Highlight links you summarise", "A soft grey breathes behind a link you hold ⌥ over while its summary comes", highlightsSummaryLinks),
                toggle("highlightPullRequestLinks", "Highlight pull request links", "A soft grey breathes behind a pull or merge request link while its card opens", highlightsPullRequestLinks),
                toggle("gitHubCardsNeedOption", "Hold ⌥ for pull request cards on GitHub", "GitHub shows its own card for its links, so Rise’s waits until you hold ⌥", gitHubLinkCardsNeedOption),
                toggle("hideAddressScheme", "Hide https:// in addresses", "Leave http:// and https:// off addresses in the address panel and link previews", hidesAddressScheme),
                toggle("hideAddressWWW", "Hide www. in addresses", "Show www.youtube.com as youtube.com. Pages still open at their own address", hidesAddressWWW),
            ]
        case "tabs":
            return [
                toggle("minimalNewTab", "Minimal New Tab button", "A plus beside the window buttons opens a new tab, in place of the New Tab row above your tabs", minimalNewTab),
                select("tabSwitcherLimit", "Tabs in the Control-Tab switcher", "The most it shows, the current tab first, five to a row",
                       "\(tabSwitcherLimit)", Self.tabSwitcherLimits.map { ("\($0)", "\($0)") }),
                select("gmailCategory", "Gmail preview category", "Which emails the Gmail tab's hover card shows", gmailCategory.rawValue,
                       GmailCategory.allCases.map { ($0.rawValue, $0.title) }),
                toggle("goToOpenTabs", "Go to tabs that are already open", "Clicking a link you have open in another tab switches to that tab. ⌘-click still opens it in a new one.", openTabLinks.enabled),
                toggle("showReopenedTabs", "Switch to reopened tabs", "⌘⇧T shows the tab it brings back, rather than keeping you where you are", showsReopenedTabs),
                toggle("hideNotificationCounts", "Hide notification counts", "Leave counts such as (3) out of tab titles and history", hidesNotificationCounts),
                toggle("repositorySubtitle", "Show repository under merge request tabs", nil, showsRepositorySubtitle),
                toggle("developerTabAddress", "Show the address under developer mode tabs", "The site and port, such as localhost:3000, under the tab's title", developerTabLook.address),
                toggle("developerTabBorder", "Yellow and black border on developer mode tabs", "Around the tab while it's the one you're on", developerTabLook.border),
                toggle("developerTabHammer", "Hammer on developer mode tabs", "At the tab's end, where its close button shows on hover", developerTabLook.hammer),
                toggle("calendarBadge", "Show upcoming events on Calendar tabs", "A badge such as “in 17m” after the tab’s title, for an event starting within the hour", showsCalendarBadge),
                toggle("youTubeAutoplay", "Autoplay YouTube videos", "When off, a video you open shows its play button and waits for you. Videos you pick on YouTube still play", youTubeAutoplay.isEnabled),
            ]
        case "ai":
            let provider = aiProvider
            let about = provider == .openCode ? "Through the OpenCode service on this Mac, with your own account"
                : "Answers questions about pages and summarises them"
            var rows = [select("aiProvider", "Provider", about, provider.rawValue, AIProvider.allCases.map { ($0.rawValue, $0.title) })]
            guard provider != .openCode else { return rows }
            let saved = hasAIKey(provider)
            var key: [String: Any] = ["key": "aiKey", "type": "text", "secret": true, "value": "", "label": "API key",
                                      "placeholder": saved ? "Saved" : provider == .openRouter ? "Optional" : "Not set",
                                      "sublabel": saved ? "Kept in your keychain. Type a new one to replace it"
                                          : provider == .openRouter ? "Without one, Rise uses its built-in key" : "From platform.openai.com, kept in your keychain"]
            if saved { key["button"] = "Remove"; key["buttonKey"] = "aiKeyRemove" }
            rows.append(key)
            rows.append(["key": "aiModel", "type": "text", "label": "Model", "value": aiModel(provider), "placeholder": provider.defaultModel,
                         "sublabel": provider == .openRouter ? "As OpenRouter names it, such as \(provider.defaultModel)" : "Such as \(provider.defaultModel)"])
            rows.append(select("aiEffort", "Reasoning effort", "How long the model thinks before answering", aiEffort(provider), provider.efforts))
            return rows
        case "system":
            var rows = [toggle("simulatedFullscreen", "Simulated full screen", "Pages go full screen inside Rise's window (⇧⌘F)", pageFullscreen.isSimulated)]
            if pageFullscreen.isSimulated {
                rows.append(toggle("collapseSidebar", "Collapse sidebar in simulated full screen", nil, collapsesSidebarInSimulatedFullscreen))
                rows.append(toggle("autoHideFullscreenNavigation", "Auto-hide URL bar in simulated full screen", "Hover over the top of the page to reveal it. Always shown while the sidebar is open", autoHidesFullscreenNavigation))
            }
            rows.append(toggle("savesCaptures", "Save page captures automatically",
                               "The camera button's JPEG and PDF go straight to the folder below; off asks where each time", savesCapturesAutomatically))
            rows.append(["key": "capturesFolder", "type": "button", "label": "Page captures folder",
                         "sublabel": (capturesFolder.path as NSString).abbreviatingWithTildeInPath, "button": "Change…"])
            rows.append(toggle("copiesCaptures", "Copy page captures to the clipboard", nil, copiesCaptures))
            return rows
        case "privacy":
            var rows: [[String: Any]] = [
                select("notificationPermission", "Website notifications", "Default for sites without a saved notification choice",
                       sitePermissions.defaultNotifications.rawValue, [("ask", "Sites can ask to send notifications"), ("block", "Don't allow sites to send notifications")]),
                ["key": "clearHistory", "type": "button", "label": "Clear address bar history",
                 "sublabel": "Pages and site searches Rise suggests as you type", "button": "Clear"]]
            for (origin, capability, permission) in sitePermissions.decidedSites {
                rows.append(select("permission|\(capability.rawValue)|\(origin)", URL(string: origin).flatMap(\.host) ?? origin, capability.title,
                                   permission.rawValue, [("ask", "Ask every time"), ("allow", "Allow"), ("block", "Block")]))
            }
            return rows
        default:
            return []
        }
    }

    func setRiseSetting(_ key: String, _ value: Any) {
        let on = value as? Bool ?? false, text = value as? String ?? ""
        switch key {
        case "theme": chooseTheme(text == "automatic" ? nil : RiseTheme(rawValue: text) ?? .neutral)
        case "livePeekResize": setLivePeekResize(on)
        case "animateDevTools": setAnimatesDevTools(on)
        case "highlightSummaryLinks": setHighlightsSummaryLinks(on)
        case "highlightPullRequestLinks": setHighlightsPullRequestLinks(on)
        case "gitHubCardsNeedOption": setGitHubLinkCardsNeedOption(on)
        case "hideAddressScheme": setHidesAddressScheme(on)
        case "hideAddressWWW": setHidesAddressWWW(on)
        case "minimalNewTab": setMinimalNewTab(on)
        case "tabSwitcherLimit": if let limit = Int(text) { setTabSwitcherLimit(limit) }
        case "gmailCategory": if let category = GmailCategory(rawValue: text) { selectGmailCategory(category) }
        case "goToOpenTabs": openTabLinks.setEnabled(on); openTabLinks.refresh(shownPages)
        case "showReopenedTabs": setShowsReopenedTabs(on)
        case "hideNotificationCounts": setHidesNotificationCounts(on)
        case "repositorySubtitle": setShowsRepositorySubtitle(on)
        case "developerTabAddress": setDeveloperTabLook(on, forKey: Self.developerTabAddressKey)
        case "developerTabBorder": setDeveloperTabLook(on, forKey: Self.developerTabBorderKey)
        case "developerTabHammer": setDeveloperTabLook(on, forKey: Self.developerTabHammerKey)
        case "calendarBadge": setShowsCalendarBadge(on)
        case "youTubeAutoplay": youTubeAutoplay.setEnabled(on)
        case "aiProvider": if let provider = AIProvider(rawValue: text) { selectAIProvider(provider) }
        case "aiKey": if !text.isEmpty { setAIKey(text, for: aiProvider) }
        case "aiModel": setAIModel(text, for: aiProvider)
        case "aiEffort": setAIEffort(text, for: aiProvider)
        case "simulatedFullscreen":
            if on != pageFullscreen.isSimulated { pageFullscreen.setSimulated(on, in: tabs.map(\.page) + (peekTab.map { [$0.page] } ?? [])) }
        case "collapseSidebar": setCollapsesSidebarInSimulatedFullscreen(on)
        case "autoHideFullscreenNavigation": setAutoHidesFullscreenNavigation(on)
        case "savesCaptures": setSavesCapturesAutomatically(on)
        case "copiesCaptures": setCopiesCaptures(on)
        case "notificationPermission":
            sitePermissions.defaultNotifications = text == "block" ? .block : .ask
            refreshPermissionScripts()
        default:
            let parts = key.split(separator: "|", maxSplits: 2).map(String.init)
            guard parts.count == 3, parts[0] == "permission", let capability = SiteCapability(rawValue: parts[1]),
                  let permission = SitePermission(rawValue: text) else { return }
            setSitePermission(permission, for: capability, origin: parts[2])
        }
    }

    func runRiseSetting(_ key: String) {
        switch key {
        case "clearHistory": confirmClearBrowsingHistory()
        case "aiKeyRemove": setAIKey(nil, for: aiProvider)
        case "capturesFolder":
            chooseCapturesFolder { [weak self] in
                guard let self else { return }
                // The settings page shows the new folder.
                for tab in self.tabs where tab.url?.scheme == "rise" || tab.url?.scheme == "chrome" {
                    tab.page.evaluate("dispatchEvent(new Event('rise-settings-ready'))", arguments: [:], in: nil, world: .page) { _ in }
                }
            }
        default: break
        }
    }

    /// Lets Chrome's settings, and only them, reach Rise's.
    func installRiseSettings(on page: WebPage) {
        page.addMessageHandler(Self.settingsHandler, world: .page) { [weak self] message, reply in
            guard let self, message.frame.isMain, Self.isSettings(message.frame),
                  let body = message.body as? [String: Any], let kind = body["kind"] as? String else { reply(nil, "Not settings"); return }
            switch kind {
            case "rows": reply(self.riseSettingRows(body["section"] as? String ?? ""), nil)
            case "set":
                if let key = body["key"] as? String, let value = body["value"] { self.setRiseSetting(key, value) }
                reply(true, nil)
            case "run":
                if let key = body["key"] as? String { self.runRiseSetting(key) }
                reply(true, nil)
            case "siteSearch": self.handleSiteSearchRequest(body, from: message.page, reply: reply)
            case "shortcuts": self.handleKeyboardShortcutsRequest(body, from: message.page, reply: reply)
            case "defaultBrowser": self.handleDefaultBrowserRequest(body, reply: reply)
            default: reply(nil, "Unknown request")
            }
        }
        page.addUserScript(Self.settingsScript, world: .page, mainFrameOnly: true, handlers: [Self.settingsHandler])
    }

    /// Only Chrome's settings page itself, which `PageFrame.origin` leaves out as it isn't a website.
    private static func isSettings(_ frame: PageFrame) -> Bool {
        return (frame.handle as? RCFrame)?.origin == "chrome://settings"
    }

    static let settingsScript = """
    (() => {
      if (location.origin !== 'chrome://settings' || window.riseSettings) return;
      const send = body => riseHandlers.riseSettings.postMessage(body);
      window.riseSettings = Object.freeze({
        rows: section => send({kind: 'rows', section}),
        set: (key, value) => send({kind: 'set', key, value}),
        run: key => send({kind: 'run', key}),
        // Requests for sections with their own controls, such as Site search.
        request: (kind, body) => send({...body, kind}),
      });
      dispatchEvent(new Event('rise-settings-ready'));
    })();
    """
}
