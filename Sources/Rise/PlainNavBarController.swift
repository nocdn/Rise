import AppKit

@MainActor extension BrowserController {
    /// The page bar follows the selected page: its address and title, its zoom, and its colour.
    func updatePlainBar() {
        let tab = selectedTab
        navBar.show(url: tab?.url, title: tab?.title ?? "")
        navBar.pageZoom = tab?.page.zoom ?? 1
        if plainBarTabID != tab?.id {
            // Another page's colour at once, as last seen, then as it is now; its load where it's got.
            plainBarTabID = tab?.id
            navBar.resetLoading(tab?.isLoading == true, progress: tab?.page.estimatedProgress ?? 0, hard: tab?.isHardReloading == true)
            navBar.setColor(tab.flatMap { plainBarColors[$0.id] } ?? theme.page, animated: false)
            if plainBarColors.count > tabs.count+8 {
                let ids = Set(tabs.map(\.id)); plainBarColors = plainBarColors.filter { ids.contains($0.key) }
            }
            samplePlainBarColor()
        } else {
            navBar.setLoading(tab?.isLoading == true, progress: tab?.page.estimatedProgress ?? 0, hard: tab?.isHardReloading == true)
        }
        if plainBarTimer == nil {
            // Pages scroll and restyle their tops as they're used; a cheap look 3.5 times a second keeps up.
            let timer = Timer(timeInterval: 1/3.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.samplePlainBarColor() } }
            RunLoop.main.add(timer, forMode: .common); plainBarTimer = timer
        }
    }

    func samplePlainBarColor() {
        guard !plainBarSampling, let tab = selectedTab, window?.occlusionState.contains(.visible) == true else { return }
        guard tab.url != nil, tab.page is ChromiumPage else { navBar.setColor(theme.page, animated: true); return }
        plainBarSampling = true
        let id = tab.id, page = tab.page
        Task { [weak self] in
            let color = await (page as? ChromiumPage)?.topColor()
            guard let self else { return }
            self.plainBarSampling = false
            // Nothing drawn to look at, as a hidden page: the bar keeps the colour it has.
            guard let color else { return }
            self.plainBarColors[id] = color
            guard self.selectedID == id else { return }
            self.navBar.setColor(color, animated: true)
        }
    }
}

/// The colour along a page's top edge, from what the page really draws there rather than its CSS,
/// which a canvas, a see-through tint or a picture can hide: the most common one in a strip of it.
enum PageTopColor {
    /// The strip looked at, in points from the page's top, and the pixels it's shrunk to as it's
    /// copied: enough to tell a background from the text and icons on it.
    static let strip = (top: 1.0, height: 2.0), pixels = (width: 240.0, height: 2.0)

    /// The most common colour in `image`, near shades counted together and averaged, in sRGB.
    static func dominant(in image: CGImage) -> NSColor? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: width*height*4)
        var groups: [Int: (count: Int, red: Int, green: Int, blue: Int)] = [:]
        for index in stride(from: 0, to: width*height*4, by: 4) where bytes[index+3] > 250 {
            let red = Int(bytes[index]), green = Int(bytes[index+1]), blue = Int(bytes[index+2])
            let key = (red >> 2) << 12 | (green >> 2) << 6 | blue >> 2
            let group = groups[key] ?? (0, 0, 0, 0)
            groups[key] = (group.count+1, group.red+red, group.green+green, group.blue+blue)
        }
        guard let best = groups.values.max(by: { $0.count < $1.count }) else { return nil }
        let count = CGFloat(best.count)
        return NSColor(srgbRed: CGFloat(best.red)/count/255, green: CGFloat(best.green)/count/255, blue: CGFloat(best.blue)/count/255, alpha: 1)
    }
}
