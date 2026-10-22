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

    /// The page's colour under its top edge: the first solid background under a few points along
    /// it, the most common one, or the canvas's.
    static let pageTopColorScript = """
        // A hidden page isn't laid out to hit: no answer, so the bar keeps the colour it has.
        if (document.visibilityState !== 'visible') return null;
        const context = new OffscreenCanvas(1, 1).getContext('2d', { willReadFrequently: true });
        const solid = (css) => {
          if (!css) return null;
          context.clearRect(0, 0, 1, 1); context.fillStyle = 'rgba(0, 0, 0, 0)'; context.fillStyle = css; context.fillRect(0, 0, 1, 1);
          const [r, g, b, a] = context.getImageData(0, 0, 1, 1).data;
          return a > 128 ? `${r},${g},${b}` : null;
        };
        // Everything stacked there, front to back: an empty overlay in front, such as a loading
        // strip, doesn't hide the header behind it. A gradient counts by its first colour.
        const under = (x) => {
          for (const element of document.elementsFromPoint(x, 1)) {
            const style = getComputedStyle(element);
            const color = solid(style.backgroundColor)
              || (style.backgroundImage.includes('gradient') && solid((style.backgroundImage.match(/rgba?\\([^)]*\\)|#[0-9a-fA-F]{3,8}\\b/) || [])[0]));
            if (color) return color;
          }
          return null;
        };
        if (!document.elementsFromPoint(innerWidth / 2, 1).length) return null;
        const counts = {};
        for (const part of [0.1, 0.3, 0.5, 0.7, 0.9]) {
          const color = under(Math.round(innerWidth * part));
          if (color) counts[color] = (counts[color] || 0) + 1;
        }
        const best = Object.entries(counts).sort((a, b) => b[1] - a[1])[0];
        if (best) return best[0];
        const root = document.documentElement;
        const own = solid(getComputedStyle(root).backgroundColor) || (document.body && solid(getComputedStyle(document.body).backgroundColor));
        if (own) return own;
        // No colour of its own: Chromium's canvas, near-black for a page asking for dark, whose
        // text is light unless it says otherwise, and white for any other.
        const text = solid(getComputedStyle(root).color);
        return text && text.split(',').reduce((sum, part) => sum + Number(part), 0) > 382 ? 'canvas-dark' : 'canvas';
        """
    func samplePlainBarColor() {
        guard !plainBarSampling, let tab = selectedTab, window?.occlusionState.contains(.visible) == true else { return }
        guard tab.url != nil, tab.page is ChromiumPage else { navBar.setColor(theme.page, animated: true); return }
        plainBarSampling = true
        let id = tab.id, page = tab.page
        Task { [weak self] in
            let value = await page.evaluate(Self.pageTopColorScript, arguments: [:], world: nil)
            guard let self else { return }
            self.plainBarSampling = false
            guard let text = value as? String, let color = Self.canvas[text] ?? Self.color(rgb: text) else { return }
            self.plainBarColors[id] = color
            guard self.selectedID == id else { return }
            self.navBar.setColor(color, animated: true)
        }
    }
    /// Chromium's canvas under a page with no colour of its own: Blink's dark scheme background
    /// for one asking for dark, and white for any other.
    static let canvas = ["canvas-dark": NSColor(srgbRed: 18/255, green: 18/255, blue: 18/255, alpha: 1), "canvas": NSColor.white]
    static func color(rgb: String) -> NSColor? {
        let parts = rgb.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        return NSColor(srgbRed: parts[0]/255, green: parts[1]/255, blue: parts[2]/255, alpha: 1)
    }
}
