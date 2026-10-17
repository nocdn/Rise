import AppKit
import RiseCore

/// Settings' Site search section: the sites Tab searches from the address bar, set up by hand or
/// learned from searching on them. The page asks through `riseSettings.request("siteSearch", …)`.
@MainActor extension BrowserController {
    func handleSiteSearchRequest(_ body: [String: Any], from page: WebPage?, reply: @escaping (Any?, String?) -> Void) {
        let searches = siteSearchLearner.searches
        switch body["action"] as? String {
        case "list":
            reply(siteSearchList(), nil)
        case "defaults":
            // What a new site starts with, once its address is typed: the search Rise knows for
            // it and its icon's colour, waiting a moment for an icon not loaded yet.
            guard let defaults = searches.defaults(forSite: body["site"] as? String ?? "") else { reply(NSNull(), nil); return }
            let home = URL(string: "https://" + defaults.domain)!
            let known = PopularSites.site(forAddress: defaults.domain)
            waitForIcon(home, tries: 16) { [weak self] icon in
                guard let self else { return }
                reply(["site": defaults.domain, "name": defaults.name, "template": defaults.template.replacingOccurrences(of: "{q}", with: "%s"),
                       "color": self.iconColor(icon, fallback: known?.color) ?? "", "icon": icon.flatMap(Self.dataURL) ?? ""], nil)
            }
        case "save":
            do {
                let color = (body["color"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                try searches.save(site: body["site"] as? String ?? "", name: body["name"] as? String ?? "",
                                  template: body["template"] as? String ?? "", color: color, replacing: body["original"] as? String)
                siteSearchesChanged()
                reply(siteSearchList(), nil)
            } catch let error as LearnedSearches.EditError {
                reply(["error": error.description, "field": error.field], nil)
            } catch { reply(nil, error.localizedDescription) }
        case "pickColor":
            // Chrome's colour chooser isn't Rise's: macOS's colour panel picks, each change
            // going back to the page.
            SiteSearchColorPanel.shared.show(NSColor(hex: LearnedSearches.colorValue(body["color"] as? String ?? "") ?? 0x0090FF), for: page)
            reply(true, nil)
        case "closeColor":
            SiteSearchColorPanel.shared.close()
            reply(true, nil)
        case "remove":
            searches.remove(site: body["site"] as? String ?? "")
            siteSearchesChanged()
            reply(siteSearchList(), nil)
        default:
            reply(nil, "Unknown request")
        }
    }

    /// Both lists, hand-set first, each site with its icon and the colour its name takes.
    private func siteSearchList() -> [String: Any] {
        var missing = false
        func entry(_ domain: String, _ search: LearnedSearches.Search) -> [String: Any] {
            let icon = suggestionFavicons.image(for: URL(string: "https://" + domain), dark: false)
            if icon == nil { missing = true }
            let color = search.color ?? iconColor(icon, fallback: PopularSites.site(forAddress: domain)?.color) ?? ""
            return ["site": domain, "name": search.name, "template": search.template.replacingOccurrences(of: "{q}", with: "%s"),
                    "color": color, "customColor": search.color != nil, "icon": icon.flatMap(Self.dataURL) ?? ""]
        }
        let all = siteSearchLearner.searches.searches
        let custom = all.filter { $0.value.isManual }.sorted { $0.value.name.localizedCaseInsensitiveCompare($1.value.name) == .orderedAscending }
        let learned = all.filter { !$0.value.isManual }.sorted { $0.value.learned > $1.value.learned }
        let result: [String: Any] = ["custom": custom.map { entry($0.key, $0.value) }, "learned": learned.map { entry($0.key, $0.value) }]
        return result.merging(["missingIcons": missing]) { $1 }
    }
    private func siteSearchesChanged() {
        scheduleSave()
        tabSync?.captureSearches()
        if palette.isPresented { palette.refresh() }
    }
    /// An icon's main colour as "#RRGGBB", or the site's brand colour.
    private func iconColor(_ icon: NSImage?, fallback: UInt32?) -> String? {
        if let icon, let color = FaviconColor.dominant(icon)?.usingColorSpace(.sRGB) {
            return String(format: "#%02X%02X%02X", Int(round(color.redComponent*255)), Int(round(color.greenComponent*255)), Int(round(color.blueComponent*255)))
        }
        return fallback.map { String(format: "#%06X", $0) }
    }
    /// Calls back with the site's icon once it's loaded, or with nil after a few tries.
    private func waitForIcon(_ url: URL, tries: Int, _ done: @escaping (NSImage?) -> Void) {
        if let icon = suggestionFavicons.image(for: url, dark: false) { done(icon); return }
        guard tries > 0 else { done(nil); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { done(nil); return }
            self.waitForIcon(url, tries: tries-1, done)
        }
    }
    private static func dataURL(_ image: NSImage) -> String? {
        let size = 32
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]).map { "data:image/png;base64," + $0.base64EncodedString() }
    }
}

/// macOS's colour panel for Settings' site colours, sending each pick to the settings page.
@MainActor final class SiteSearchColorPanel: NSObject {
    static let shared = SiteSearchColorPanel()
    private weak var page: WebPage?
    func show(_ color: NSColor, for page: WebPage?) {
        self.page = page
        let panel = NSColorPanel.shared
        panel.showsAlpha = false; panel.isContinuous = true
        panel.setTarget(nil); panel.color = color
        panel.setTarget(self); panel.setAction(#selector(changed(_:)))
        panel.orderFront(nil)
    }
    func close() {
        guard NSColorPanel.sharedColorPanelExists, page != nil else { return }
        NSColorPanel.shared.setTarget(nil); NSColorPanel.shared.orderOut(nil); page = nil
    }
    @objc private func changed(_ panel: NSColorPanel) {
        guard let page, let color = panel.color.usingColorSpace(.sRGB) else { return }
        let hex = String(format: "#%02X%02X%02X", Int(round(color.redComponent*255)), Int(round(color.greenComponent*255)), Int(round(color.blueComponent*255)))
        page.evaluate("dispatchEvent(new CustomEvent('rise-site-search-color', {detail: color}))", arguments: ["color": hex], in: nil, world: .page) { _ in }
    }
}
