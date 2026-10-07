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

    private static let hammer = TablerIcon.image(LucideIcon.hammer, size: 12, description: "Developer mode")

    static func forTab(_ tab: BrowserTab, theme: RiseTheme) -> Self {
        var configuration = Self()
        if tab.developer {
            configuration.subtitle = Subtitle(text: AddressResolver.displayHost(tab.url) + (tab.url?.port.map { ":\($0)" } ?? ""))
            configuration.constructionBorder = true
            configuration.subtitleAccessory = hammer
        }
        if let request = PullRequest(url: tab.url), case .gitlab = request.forge {
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
