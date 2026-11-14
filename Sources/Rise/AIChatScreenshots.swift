import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The chat's model looking at a page, for what its text misses: charts, pictures, layout, colour,
/// maps and pages drawn rather than written. A screenful at a time, as the user would see it: an
/// open tab where it's scrolled to or at any screen of it, out of sight if it isn't showing, or
/// any page loaded out of sight, at most `maxWidth` pixels across.
enum AIChatScreenshot {
    static let maxWidth = 1280
    struct Shot { let jpeg: Data; let screen: Int; let screens: Int; let top: Int; let bottom: Int; let height: Int }

    /// Which part of the page to take: the `screen`th screenful from the top, or with none, what
    /// shows where it's scrolled to. The page's own height decides how many there are.
    static func clip(_ metrics: PageLayoutMetrics, screen: Int?) -> (clip: CGRect, screen: Int, screens: Int, beyondViewport: Bool) {
        let viewport = max(1, metrics.viewportHeight), total = max(viewport, metrics.contentHeight)
        let screens = max(1, Int(ceil(total/viewport-0.01)))
        let top: Double
        if let screen { top = Double(min(max(1, screen), screens)-1)*viewport } else { top = min(max(0, metrics.scrollY), max(0, total-viewport)) }
        let height = min(viewport, total-top)
        let shown = min(screens, Int(top/viewport)+1)
        let visible = top >= metrics.scrollY-0.5 && top+height <= metrics.scrollY+viewport+0.5
        return (CGRect(x: 0, y: top, width: max(1, metrics.viewportWidth), height: max(1, height)), shown, screens, !visible)
    }

    @MainActor static func take(_ page: WebPage, screen: Int?) async throws -> Shot {
        guard let metrics = await page.layoutMetrics(), metrics.viewportWidth > 0, metrics.viewportHeight > 0 else {
            throw AIChatToolFailure(message: "The page couldn't be measured to take its picture.")
        }
        let part = clip(metrics, screen: screen)
        guard let data = await page.screenshot(clip: part.clip, scale: 1, beyondViewport: part.beyondViewport), let jpeg = fit(data) else {
            throw AIChatToolFailure(message: "The page's picture couldn't be taken.")
        }
        return Shot(jpeg: jpeg, screen: part.screen, screens: part.screens, top: Int(part.clip.minY), bottom: Int(part.clip.maxY),
                    height: Int(max(metrics.contentHeight, metrics.viewportHeight)))
    }

    /// At most `maxWidth` pixels across, as a JPEG.
    static func fit(_ data: Data, maxWidth: Int = maxWidth) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        guard width > maxWidth else { return data }
        let longest = Int((Double(max(width, height))*Double(maxWidth)/Double(width)).rounded())
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                            kCGImageSourceThumbnailMaxPixelSize: longest,
                                                                            kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    /// What the model's told with the picture: where on the page it is, and how to see more.
    static func caption(_ shot: Shot, title: String, url: String) -> String {
        var text = "Screenshot of \(title.isEmpty ? url : title) (\(url)): screen \(shot.screen) of \(shot.screens), from \(shot.top) to \(shot.bottom) px down a page \(shot.height) px tall."
        if shot.screens > 1 { text += " For another part, call view_page again with screen 1 to \(shot.screens)." }
        return text
    }
}

extension AIChatPageReader {
    /// A screenful of a page loaded out of sight.
    func view(_ url: URL, screen: Int?) async throws -> (shot: AIChatScreenshot.Shot, title: String, url: String) {
        try await withLoadedPage(url) { page in
            let shot = try await HiddenAccessibilityView.reading(page) { try await AIChatScreenshot.take(page, screen: screen ?? 1) }
            return (shot, page.title ?? "", page.url?.absoluteString ?? url.absoluteString)
        }
    }
}

extension AIChatBrowserTools {
    /// `body` with the tab's page drawing: as it is if it's showing, or else out of sight behind
    /// the page shown, muted and taking no hover, as Control-Tab's pictures are taken.
    func withTabDrawing<T>(_ tab: BrowserTab, _ body: (WebPage) async throws -> T) async throws -> T {
        let page = tab.page
        guard page.view.superview == nil, let browser else { return try await body(page) }
        let host = pictureHost
        host.alphaValue = 0
        if host.superview == nil { browser.root.addSubview(host, positioned: .below, relativeTo: browser.pageShadow) }
        host.frame = browser.pageShadow.frame
        browser.setCovered(true, tab)
        let held = tab.heldSinceBackgroundPicture
        if !held { tab.heldSinceBackgroundPicture = true; page.setAudioMuted(true) }
        page.view.frame = host.bounds; host.addSubview(page.view)
        defer {
            // Unless the tab was chosen meanwhile, it goes back to where it was.
            if page.view.superview === host {
                page.view.removeFromSuperview()
                if browser.tabs.contains(where: { $0 === tab }), tab.page === page {
                    if !held { browser.releaseBackgroundPicturePage(tab); page.setMediaSuspended(true) }
                    browser.setCovered(browser.peekTab != nil, tab)
                }
            }
        }
        // Its first paint.
        try? await Task.sleep(for: .milliseconds(400))
        return try await body(page)
    }

    func step(looking tab: BrowserTab) -> AIChatStep {
        var step = step("Looking at \(Self.title(tab))", tab: tab); step.symbol = "eye"; return step
    }

    var viewPage: AIChatTool {
        AIChatTool(name: "view_page", description: """
            Looks at a page as the user sees it, as a screenshot: for what its text misses, such as charts and graphs, pictures and product photos, layout, colours and design, maps, and pages drawn rather than written. Give tab for an open tab, which shows where it's scrolled to unless you give screen, or url for any other page, loaded out of sight. screen is which screenful from the top, 1 being the top; the result says how many there are. To know what a page says, read it with read_tab or read_url; use this when how it looks matters or its text didn't answer.
            """,
                   parameters: ["type": "object", "additionalProperties": false, "required": [],
                                "properties": ["tab": ["type": "string", "description": "An open tab's id, such as \"3f9a1c2e\"."],
                                               "url": ["type": "string", "description": "A page's full http or https address, when it isn't open."],
                                               "screen": ["type": "integer", "description": "Which screenful from the top, from 1; leave it out for where an open tab is scrolled to."]]],
                   step: { [weak self] arguments in
            if let self, let tab = try? self.tab(arguments["tab"]) { return self.step(looking: tab) }
            if let url = (arguments["url"] as? String).flatMap(Self.webURL) {
                if let self, let tab = self.browser?.openTab(for: url) { return self.step(looking: tab) }
                return AIChatStep(text: "Looking at \(Self.host(url))", symbol: "eye", target: .url(url))
            }
            return AIChatStep(text: "Looking at a page", symbol: "eye")
        }, run: { [weak self] arguments, step in
            guard let self, let browser = self.browser else { throw AIChatToolFailure(message: "The window has closed.") }
            let screen = (arguments["screen"] as? Int).map { max(1, $0) }
            let url = (arguments["url"] as? String).flatMap(Self.webURL)
            // A page that's open is looked at in its tab, as the user has it.
            let tab = try arguments["tab"] != nil ? self.tab(arguments["tab"]) : url.flatMap(browser.openTab(for:))
            let shot: AIChatScreenshot.Shot, title: String, address: String
            if let tab {
                guard let url = tab.url, ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else {
                    throw AIChatToolFailure(message: "That tab isn't a web page Rise can show.", step: "Couldn’t look at \(Self.title(tab))")
                }
                let page = await self.loadedPage(of: tab)
                try Task.checkCancellation()
                // A tab out of sight shows from its top unless a screen's asked for.
                let showing = page.view.superview != nil
                shot = try await self.withTabDrawing(tab) { try await AIChatScreenshot.take($0, screen: screen ?? (showing ? nil : 1)) }
                title = Self.title(tab); address = url.absoluteString
            } else if let url {
                (shot, title, address) = try await self.reader.view(url, screen: screen)
            } else {
                throw AIChatToolFailure(message: "Give an open tab's id or a page's full http or https address.")
            }
            let caption = AIChatScreenshot.caption(shot, title: title, url: address)
            return AIChatToolResult(output: caption+" The picture follows.",
                                    step: step.done("Looked at \(title.isEmpty ? (URL(string: address).map(Self.host) ?? "the page") : title)"),
                                    images: [AIChatImage(jpeg: shot.jpeg, caption: caption)])
        })
    }
}
