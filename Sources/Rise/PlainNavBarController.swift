import AppKit

@MainActor extension BrowserController {
    /// The page bar follows the selected page, or each of a split's its own (`SplitNavBar.swift`):
    /// its address and title, its zoom, its load and its colour.
    func updatePlainBar() {
        let bars = pageBarTabs
        let before = (plainBarTabID, splitBarTabID)
        showPageBar(navBar, tab: bars.first?.tab, shown: &plainBarTabID)
        if bars.count == 2 { showPageBar(splitBar, tab: bars[1].tab, shown: &splitBarTabID) } else if splitBar.superview === pageClip { splitBarTabID = nil }
        if before != (plainBarTabID, splitBarTabID) {
            if plainBarColors.count > tabs.count+8 {
                let ids = Set(tabs.map(\.id)); plainBarColors = plainBarColors.filter { ids.contains($0.key) }
            }
            samplePlainBarColor()
        }
        if plainBarTimer == nil {
            // Pages scroll and restyle their tops as they're used; a cheap look 3.5 times a second keeps up.
            let timer = Timer(timeInterval: 1/3.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.samplePlainBarColor() } }
            RunLoop.main.add(timer, forMode: .common); plainBarTimer = timer
        }
    }

    func samplePlainBarColor() {
        guard !plainBarSampling, window?.occlusionState.contains(.visible) == true else { return }
        var pages: [(bar: PlainNavBar, tab: BrowserTab)] = []
        for (bar, tab) in pageBarTabs {
            if tab.url != nil, tab.page is ChromiumPage { pages.append((bar, tab)) } else { bar.setColor(theme.page, animated: true) }
        }
        guard !pages.isEmpty else { return }
        plainBarSampling = true
        Task { [weak self] in
            for (bar, tab) in pages {
                let color = await (tab.page as? ChromiumPage)?.topColor()
                guard let self else { return }
                // Nothing drawn to look at, as a hidden page: the bar keeps the colour it has.
                guard let color else { continue }
                self.plainBarColors[tab.id] = color
                if (bar === self.navBar ? self.plainBarTabID : self.splitBarTabID) == tab.id { bar.setColor(color, animated: true) }
            }
            self?.plainBarSampling = false
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
