import AppKit
import RiseCore

/// Optional presentation for the shared tab row. Layout stays in TabRow;
/// deciding which details a page exposes stays here.
@MainActor struct TabRowConfiguration {
    struct Subtitle {
        var text: String
        var color: NSColor? = nil
        /// With no range, the color applies to the entire subtitle.
        var highlightRange: NSRange? = nil
        /// Just before the text, in its own colors: a pull or merge request's state.
        var icon: NSImage? = nil
        /// Room between the icon and the text.
        static let iconGap: CGFloat = 4

        func attributedString(font: NSFont, defaultColor: NSColor) -> NSAttributedString {
            let value = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: defaultColor])
            if let color {
                let range = highlightRange ?? NSRange(location: 0, length: value.length)
                if range.location <= value.length && range.length <= value.length - range.location {
                    value.addAttribute(.foregroundColor, value: color, range: range)
                }
            }
            if let icon {
                let attachment = NSTextAttachment()
                attachment.image = icon
                // Centred on the text's lowercase, which a repository's name mostly is, to the half point.
                let y = (((font.xHeight-icon.size.height)/2)*2).rounded()/2
                attachment.bounds = NSRect(x: 0, y: y, width: icon.size.width, height: icon.size.height)
                // A space after it, widened to the gap: a label leaves an attachment's own kerning out.
                let mark = NSMutableAttributedString(attachment: attachment)
                let space = NSAttributedString(string: " ", attributes: [.font: font])
                mark.append(NSAttributedString(string: " ", attributes: [.font: font, .kern: max(0, Self.iconGap-space.size().width)]))
                value.insert(mark, at: 0)
            }
            return value
        }
    }

    var subtitle: Subtitle? = nil
    /// Read out with the subtitle, as its icon shows it.
    var pullRequestState: PullRequestDetails.State? = nil
    var constructionBorder = false
    var subtitleAccessory: NSImage? = nil
    struct Peek {
        let favicon: NSImage?
        let title: String
    }
    var peek: Peek? = nil

    private static let hammer = TablerIcon.image(LucideIcon.hammer, size: 12, description: "Developer mode")

    /// `pullRequestState`: a pull or merge request tab's state, shown by its repository.
    static func forTab(_ tab: BrowserTab, theme: RiseTheme, peek: BrowserTab? = nil, developerLook: DeveloperTabLook = .init(),
                       pullRequestState: (PullRequest) -> PullRequestDetails.State? = { _ in nil }) -> Self {
        var configuration = Self()
        if let peek { configuration.peek = Peek(favicon: peek.favicon(for: theme), title: peek.title) }
        if tab.developer {
            if developerLook.address {
                configuration.subtitle = Subtitle(text: AddressResolver.displayHost(tab.url) + (tab.url?.port.map { ":\($0)" } ?? ""))
            }
            configuration.constructionBorder = developerLook.border
            if developerLook.hammer { configuration.subtitleAccessory = hammer }
        }
        if tab.showsRepositorySubtitle, let request = tab.pullRequest {
            let repository = request.project as NSString
            let slash = repository.range(of: "/", options: .backwards)
            let start = slash.location == NSNotFound ? 0 : NSMaxRange(slash)
            let state = pullRequestState(request)
            configuration.subtitle = Subtitle(text: request.project,
                color: TabAppearance.repositoryColor(request.project, theme: theme),
                highlightRange: NSRange(location: start, length: repository.length - start),
                icon: state.flatMap { PullRequestStateIcon.image($0, forge: request.forge, dark: theme == .dark) })
            configuration.pullRequestState = state
        }
        return configuration
    }
}

/// What a tab in developer mode shows: its site and port under its title, the yellow and black
/// border while it's chosen, and the hammer. Each is on unless turned off in rise://settings.
struct DeveloperTabLook: Equatable {
    var address = true, border = true, hammer = true
}

@MainActor extension BrowserController {
    static let developerTabAddressKey = "Rise.DeveloperTabAddress", developerTabBorderKey = "Rise.DeveloperTabBorder",
               developerTabHammerKey = "Rise.DeveloperTabHammer"
    var developerTabLook: DeveloperTabLook {
        func on(_ key: String) -> Bool { preferences.object(forKey: key) as? Bool ?? true }
        return DeveloperTabLook(address: on(Self.developerTabAddressKey), border: on(Self.developerTabBorderKey), hammer: on(Self.developerTabHammerKey))
    }
    func setDeveloperTabLook(_ value: Bool, forKey key: String) {
        preferences.set(value, forKey: key)
        update()
    }
}
