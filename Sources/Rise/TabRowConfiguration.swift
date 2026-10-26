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

        func attributedString(font: NSFont, defaultColor: NSColor) -> NSAttributedString {
            let value = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: defaultColor])
            if let color {
                let range = highlightRange ?? NSRange(location: 0, length: value.length)
                if range.location <= value.length && range.length <= value.length - range.location {
                    value.addAttribute(.foregroundColor, value: color, range: range)
                }
            }
            return value
        }
    }

    var subtitle: Subtitle? = nil
    var constructionBorder = false
    var subtitleAccessory: NSImage? = nil
    struct Peek {
        let favicon: NSImage?
        let title: String
    }
    var peek: Peek? = nil

    private static let hammer = TablerIcon.image(LucideIcon.hammer, size: 12, description: "Developer mode")

    static func forTab(_ tab: BrowserTab, theme: RiseTheme, peek: BrowserTab? = nil, developerLook: DeveloperTabLook = .init()) -> Self {
        var configuration = Self()
        if let peek { configuration.peek = Peek(favicon: peek.favicon(for: theme), title: peek.title) }
        if tab.developer {
            if developerLook.address {
                configuration.subtitle = Subtitle(text: AddressResolver.displayHost(tab.url) + (tab.url?.port.map { ":\($0)" } ?? ""))
            }
            configuration.constructionBorder = developerLook.border
            if developerLook.hammer { configuration.subtitleAccessory = hammer }
        }
        if tab.showsRepositorySubtitle, let request = PullRequest(url: tab.url), case .gitlab = request.forge {
            let repository = request.project as NSString
            let slash = repository.range(of: "/", options: .backwards)
            let start = slash.location == NSNotFound ? 0 : NSMaxRange(slash)
            configuration.subtitle = Subtitle(text: request.project,
                color: TabAppearance.repositoryColor(request.project, theme: theme),
                highlightRange: NSRange(location: start, length: repository.length - start))
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
