import AppKit

/// The tab hover cards that can be turned off in Settings, each on until it is. A card that's
/// off leaves its tabs with the title card every other tab has, and its page isn't read.
enum HoverCard: String, CaseIterable {
    case gmail, protonMail, googleChat, calendar, github, gitlab
    init?(url: URL?) {
        if GmailAccount(url: url) != nil { self = .gmail }
        else if ProtonMailAccount(url: url) != nil { self = .protonMail }
        else if GoogleChatAccount(url: url) != nil { self = .googleChat }
        else if CalendarAccount(url: url) != nil { self = .calendar }
        else if let pr = PullRequest(url: url) { self.init(pr) }
        else { return nil }
    }
    init(_ pr: PullRequest) { self = pr.forge == .github ? .github : .gitlab }
    var settingKey: String { "hoverCard." + rawValue }
    var label: String {
        switch self {
        case .gmail: "Gmail hover card"
        case .protonMail: "Proton Mail hover card"
        case .googleChat: "Google Chat hover card"
        case .calendar: "Google Calendar hover card"
        case .github: "GitHub pull request cards"
        case .gitlab: "GitLab merge request cards"
        }
    }
    var sublabel: String {
        switch self {
        case .gmail: "Your newest emails, on hovering over a Gmail tab"
        case .protonMail: "Your newest emails, on hovering over a Proton Mail tab"
        case .googleChat: "Your newest conversations, on hovering over a Google Chat tab"
        case .calendar: "Your day, on hovering over a Google Calendar tab"
        case .github: "A pull request's status, checks and files, on hovering over its tab or a link to it"
        case .gitlab: "A merge request's status, pipeline and files, on hovering over its tab or a link to it"
        }
    }
}

/// What the Google Chat card lists: people's messages, or every conversation, spaces included.
enum GoogleChatCardContent: String, CaseIterable {
    case directMessages, everything
    var title: String { self == .directMessages ? "Direct messages" : "Everything, spaces included" }
}

@MainActor extension BrowserController {
    static let disabledHoverCardsKey = "Rise.DisabledHoverCards"
    static let googleChatCardContentKey = "Rise.GoogleChatHoverContent"
    func showsHoverCard(_ card: HoverCard) -> Bool {
        !(preferences.stringArray(forKey: Self.disabledHoverCardsKey) ?? []).contains(card.rawValue)
    }
    /// A tab's page has a card of its own, and it's turned on.
    func hasHoverPreview(_ url: URL?) -> Bool { HoverCard(url: url).map(showsHoverCard) ?? false }
    func setShowsHoverCard(_ card: HoverCard, _ on: Bool) {
        var off = Set(preferences.stringArray(forKey: Self.disabledHoverCardsKey) ?? [])
        if on { off.remove(card.rawValue) } else { off.insert(card.rawValue) }
        preferences.set(off.sorted(), forKey: Self.disabledHoverCardsKey)
        if !on {
            if let id = tabHoverCards.shownID, HoverCard(url: hoverTab(id)?.url) == card { hideTabHoverCard() }
            if let shown = linkPullRequests.shown?.pullRequest, HoverCard(shown) == card { hideLinkCard() }
        }
        update()
    }

    var googleChatCardContent: GoogleChatCardContent {
        GoogleChatCardContent(rawValue: preferences.string(forKey: Self.googleChatCardContentKey) ?? "") ?? .directMessages
    }
    func selectGoogleChatCardContent(_ content: GoogleChatCardContent) {
        preferences.set(content.rawValue, forKey: Self.googleChatCardContentKey)
        if let id = tabHoverCards.shownID, GoogleChatAccount(url: hoverTab(id)?.url) != nil { hideTabHoverCard() }
        preloadChatInbox()
    }
}
