import AppKit

@MainActor extension BrowserController {
    static let automaticThemeName = "automatic"

    /// Picks a theme, or nil to follow macOS's light or dark appearance.
    func chooseTheme(_ choice: RiseTheme?) {
        automaticTheme = choice == nil
        theme = choice ?? systemTheme(); update()
    }

    /// Light or Dark, matching macOS's current appearance.
    func systemTheme() -> RiseTheme {
        // In Automatic, the app leaves its appearance to macOS, so its
        // effective appearance is the system's rather than a chosen theme's.
        if NSApp.appearance != nil { NSApp.appearance = nil }
        observeSystemAppearance()
        return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .neutral
    }

    private func observeSystemAppearance() {
        guard systemAppearanceObservation == nil else { return }
        systemAppearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.automaticTheme else { return }
                let theme = self.systemTheme()
                if theme != self.theme { self.theme = theme; self.update() }
            }
        }
    }

    var plainLightTheme: Bool { preferences.bool(forKey: RiseTheme.plainLightKey) }
    func setPlainLightTheme(_ on: Bool) {
        preferences.set(on, forKey: RiseTheme.plainLightKey); RiseTheme.plainLight = on
        update(); layoutChrome()
    }
    /// Kero's Plain wash: its grey at 82% over the window's sidebar material, so a little of the
    /// desktop shows through, under everything else.
    func layoutPlainBackdrop() {
        let shown = theme.isPlain
        if shown, plainMaterial.superview == nil {
            plainMaterial.material = .sidebar; plainMaterial.blendingMode = .behindWindow; plainMaterial.state = .active
            plainTint.fill = RiseTheme.plainBackground.withAlphaComponent(0.82)
            for (index, view) in [plainMaterial, plainTint].enumerated() {
                view.autoresizingMask = [.width, .height]
                root.addSubview(view, positioned: .below, relativeTo: root.subviews.dropFirst(index).first)
            }
        }
        plainMaterial.isHidden = !shown; plainTint.isHidden = !shown
        if shown { plainMaterial.frame = root.bounds; plainTint.frame = root.bounds }
    }

    func applyTheme() {
        let appearance = theme.appearance
        // In Automatic, the app keeps macOS's appearance so it can see it change.
        let appAppearance = automaticTheme ? nil : appearance
        if NSApp.appearance?.name != appAppearance?.name { NSApp.appearance = appAppearance }
        if window?.appearance?.name != appearance.name { window?.appearance = appearance }
        [pageShadow, pageClip, emptyPage, errorSurface].forEach { $0.fill = theme.page }
        errorTitle.textColor = theme.text; errorMessage.textColor = theme.muted
        developerBar.fill = theme.developerSurface; developerAddress.textColor = theme.text
        // In Plain, they're the page bar's, in its colours.
        if !theme.isPlain {
            toolbarButtons.forEach { $0.contentTintColor = theme.sidebarIcon; $0.hoverColor = theme.text.withAlphaComponent(0.07) }
        }
        let allTabs = tabs + allPeekTabs
        for tab in allTabs { tab.page.setTheme(appearance, background: theme.page) }
        if theme == .dark {
            for tab in allTabs where tab.darkFavicon == nil {
                if let icon = suggestionFavicons.darkImage(for: tab.url) { tab.darkFavicon = icon }
            }
        }
        (Array(findBars.values)+[tablessFindBar]).forEach { $0.applyTheme(theme) }
        infoPlaque.applyTheme(theme)
        if palette.theme != theme {
            palette.applyTheme(theme)
            for suggestion in palette.suggestions {
                guard let origin = SitePermissions.origin(suggestion.url),
                      let icon = tabs.first(where: { SitePermissions.origin($0.url) == origin })?.favicon(for: theme) ??
                        suggestionFavicons.image(for: suggestion.url, fetch: false, dark: theme == .dark) else { continue }
                palette.updateFavicon(icon, origin: origin)
            }
            if !palette.isHidden { palette.render() }
        }
        peekBackdrop?.fill = theme.background.withAlphaComponent(0.72)
        peekCard?.fill = theme.page; (peekCard?.subviews.first as? Surface)?.fill = theme.page
        peekControls.forEach { $0.applyTheme(theme) }
        splitHandle.applyTheme(theme); devTools.handle.applyTheme(theme)
    }
}
