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

    /// Kero's Plain wash: its grey at 82% over the window's sidebar material, so a little of the
    /// desktop shows through, under everything else.
    func layoutPlainBackdrop() {
        if plainMaterial.superview == nil {
            plainMaterial.material = .sidebar; plainMaterial.blendingMode = .behindWindow; plainMaterial.state = .active
            for (index, view) in [plainMaterial, plainTint].enumerated() {
                view.autoresizingMask = [.width, .height]
                root.addSubview(view, positioned: .below, relativeTo: root.subviews.dropFirst(index).first)
            }
        }
        // Light's grey or Dark's near-black; the material follows the window's appearance.
        plainTint.fill = theme.background.withAlphaComponent(0.82)
        plainMaterial.frame = root.bounds; plainTint.frame = root.bounds
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
        let allTabs = tabs + allPeekTabs
        for tab in allTabs { tab.page.setTheme(appearance, background: theme.page) }
        if theme == .dark {
            for tab in allTabs where tab.darkFavicon == nil {
                if let icon = suggestionFavicons.darkImage(for: tab.url) { tab.darkFavicon = icon }
            }
        }
        (Array(findBars.values)+[tablessFindBar]).forEach { $0.applyTheme(theme) }; permissionCoordinator.applyTheme(theme); adBlockPrompt.applyTheme(theme); currencyReplacement.applyTheme(theme); timeReplacement.panel.applyTheme(theme)
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
