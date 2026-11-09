import AppKit

/// A pull or merge request's state as its own site draws it: GitHub's Octicons (MIT, primer/octicons)
/// and GitLab's icons (MIT, gitlab-org/gitlab-svgs), in each site's colors for light and dark.
@MainActor enum PullRequestStateIcon {
    static let size: CGFloat = 11

    private enum Glyph { case githubOpen, githubDraft, githubMerged, githubClosed, gitlabOpen, gitlabMerged, gitlabClosed }
    private static func glyph(_ state: PullRequestDetails.State, forge: PullRequest.Forge) -> Glyph {
        switch (forge, state) {
        case (.github, .open): .githubOpen
        case (.github, .draft): .githubDraft
        case (.github, .merged): .githubMerged
        case (.github, .closed): .githubClosed
        // GitLab marks a draft as open, with the same icon and color.
        case (.gitlab, .open), (.gitlab, .draft): .gitlabOpen
        case (.gitlab, .merged): .gitlabMerged
        case (.gitlab, .closed): .gitlabClosed
        }
    }
    private static func path(_ glyph: Glyph) -> String {
        switch glyph {
        case .githubOpen: "M1.5 3.25a2.25 2.25 0 1 1 3 2.122v5.256a2.251 2.251 0 1 1-1.5 0V5.372A2.25 2.25 0 0 1 1.5 3.25Zm5.677-.177L9.573.677A.25.25 0 0 1 10 .854V2.5h1A2.5 2.5 0 0 1 13.5 5v5.628a2.251 2.251 0 1 1-1.5 0V5a1 1 0 0 0-1-1h-1v1.646a.25.25 0 0 1-.427.177L7.177 3.427a.25.25 0 0 1 0-.354ZM3.75 2.5a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Zm0 9.5a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Zm8.25.75a.75.75 0 1 0 1.5 0 .75.75 0 0 0-1.5 0Z"
        case .githubDraft: "M3.25 1A2.25 2.25 0 0 1 4 5.372v5.256a2.251 2.251 0 1 1-1.5 0V5.372A2.251 2.251 0 0 1 3.25 1Zm9.5 14a2.25 2.25 0 1 1 0-4.5 2.25 2.25 0 0 1 0 4.5ZM2.5 3.25a.75.75 0 1 0 1.5 0 .75.75 0 0 0-1.5 0ZM3.25 12a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Zm9.5 0a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5ZM14 7.5a1.25 1.25 0 1 1-2.5 0 1.25 1.25 0 0 1 2.5 0Zm0-4.25a1.25 1.25 0 1 1-2.5 0 1.25 1.25 0 0 1 2.5 0Z"
        case .githubMerged: "M5.45 5.154A4.25 4.25 0 0 0 9.25 7.5h1.378a2.251 2.251 0 1 1 0 1.5H9.25A5.734 5.734 0 0 1 5 7.123v3.505a2.25 2.25 0 1 1-1.5 0V5.372a2.25 2.25 0 1 1 1.95-.218ZM4.25 13.5a.75.75 0 1 0 0-1.5.75.75 0 0 0 0 1.5Zm8.5-4.5a.75.75 0 1 0 0-1.5.75.75 0 0 0 0 1.5ZM5 3.25a.75.75 0 1 0 0 .005V3.25Z"
        case .githubClosed: "M3.25 1A2.25 2.25 0 0 1 4 5.372v5.256a2.251 2.251 0 1 1-1.5 0V5.372A2.251 2.251 0 0 1 3.25 1Zm9.5 5.5a.75.75 0 0 1 .75.75v3.378a2.251 2.251 0 1 1-1.5 0V7.25a.75.75 0 0 1 .75-.75Zm-2.03-5.273a.75.75 0 0 1 1.06 0l.97.97.97-.97a.748.748 0 0 1 1.265.332.75.75 0 0 1-.205.729l-.97.97.97.97a.751.751 0 0 1-.018 1.042.751.751 0 0 1-1.042.018l-.97-.97-.97.97a.749.749 0 0 1-1.275-.326.749.749 0 0 1 .215-.734l.97-.97-.97-.97a.75.75 0 0 1 0-1.06ZM2.5 3.25a.75.75 0 1 0 1.5 0 .75.75 0 0 0-1.5 0ZM3.25 12a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Zm9.5 0a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Z"
        case .gitlabOpen: "M10.34 1.22a.75.75 0 0 0-1.06 0L7.53 2.97 7 3.5l.53.53 1.75 1.75a.75.75 0 1 0 1.06-1.06l-.47-.47h.63c.69 0 1.25.56 1.25 1.25v4.614a2.501 2.501 0 1 0 1.5 0V5.5a2.75 2.75 0 0 0-2.75-2.75h-.63l.47-.47a.75.75 0 0 0 0-1.06ZM13.5 12.5a1 1 0 1 1-2 0 1 1 0 0 1 2 0Zm-9 0a1 1 0 1 1-2 0 1 1 0 0 1 2 0Zm1.5 0a2.5 2.5 0 1 1-3.25-2.386V5.886a2.501 2.501 0 1 1 1.5 0v4.228A2.501 2.501 0 0 1 6 12.5Zm-1.5-9a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z"
        case .gitlabMerged: "M5.5 3.5a1 1 0 1 1-2 0 1 1 0 0 1 2 0Zm-.044 2.31a2.5 2.5 0 1 0-1.706.076v4.228a2.501 2.501 0 1 0 1.5 0V8.373a5.735 5.735 0 0 0 3.86 1.864 2.501 2.501 0 1 0 .01-1.504 4.254 4.254 0 0 1-3.664-2.922ZM11.5 10.5a1 1 0 1 0 0-2 1 1 0 0 0 0 2Zm-6 2a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z"
        case .gitlabClosed: "M1.22 1.22a.75.75 0 0 1 1.06 0L3.5 2.44l1.22-1.22a.75.75 0 0 1 1.06 1.06L4.56 3.5l1.22 1.22a.75.75 0 0 1-1.06 1.06L3.5 4.56 2.28 5.78a.75.75 0 0 1-1.06-1.06L2.44 3.5 1.22 2.28a.75.75 0 0 1 0-1.06ZM7.5 3.5a.75.75 0 0 1 .75-.75h2.25a2.75 2.75 0 0 1 2.75 2.75v4.614a2.501 2.501 0 1 1-1.5 0V5.5c0-.69-.56-1.25-1.25-1.25H8.25a.75.75 0 0 1-.75-.75Zm5 10a1 1 0 1 0 0-2 1 1 0 0 0 0 2Zm-8-1a1 1 0 1 1-2 0 1 1 0 0 1 2 0Zm1.5 0a2.5 2.5 0 1 1-3.25-2.386V7.75a.75.75 0 0 1 1.5 0v2.364A2.501 2.501 0 0 1 6 12.5Z"
        }
    }
    /// Primer's success, done, danger and muted foregrounds; GitLab's green, blue and red 500,
    /// lifted for its dark mode.
    static func color(_ state: PullRequestDetails.State, forge: PullRequest.Forge, dark: Bool) -> NSColor {
        let hex: UInt32 = switch glyph(state, forge: forge) {
        case .githubOpen: dark ? 0x3FB950 : 0x1A7F37
        case .githubDraft: dark ? 0x9198A1 : 0x59636E
        case .githubMerged: dark ? 0xA371F7 : 0x8250DF
        case .githubClosed: dark ? 0xF85149 : 0xD1242F
        case .gitlabOpen: dark ? 0x2DA160 : 0x108548
        case .gitlabMerged: dark ? 0x428FDC : 0x1F75CB
        case .gitlabClosed: dark ? 0xEC5941 : 0xDD2B0E
        }
        return NSColor(hex: hex)
    }

    private struct Key: Hashable { let glyph: Glyph, dark: Bool }
    private static var cache: [Key: NSImage] = [:]
    /// The same image each time for a state, forge and appearance, so rows see it unchanged.
    static func image(_ state: PullRequestDetails.State, forge: PullRequest.Forge, dark: Bool) -> NSImage? {
        let glyph = glyph(state, forge: forge), key = Key(glyph: glyph, dark: dark)
        if let image = cache[key] { return image }
        let fill = color(state, forge: forge, dark: dark).usingColorSpace(.sRGB) ?? .black
        let hex = String(format: "#%02X%02X%02X", Int(round(fill.redComponent*255)), Int(round(fill.greenComponent*255)), Int(round(fill.blueComponent*255)))
        // GitLab's are drawn even-odd; Primer's with the default nonzero rule.
        let rule = forge == .github ? "" : #" fill-rule="evenodd" clip-rule="evenodd""#
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16"><path\(rule) fill="\(hex)" d="\(path(glyph))"/></svg>
        """
        guard let image = NSImage(data: Data(svg.utf8)) else { return nil }
        image.size = NSSize(width: size, height: size)
        image.isTemplate = false
        image.accessibilityDescription = state.title
        cache[key] = image
        return image
    }
}
