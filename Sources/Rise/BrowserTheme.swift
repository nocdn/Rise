import AppKit

@MainActor extension BrowserController {
    func applyTheme() {
        let appearance = theme.appearance
        if NSApp.appearance?.name != appearance.name { NSApp.appearance = appearance }
        if window?.appearance?.name != appearance.name { window?.appearance = appearance }
        [pageShadow, pageClip, emptyPage, errorSurface].forEach { $0.fill = theme.page }
        errorTitle.textColor = theme.text; errorMessage.textColor = theme.muted
        developerBar.fill = theme.developerSurface; developerAddress.textColor = theme.text
        toolbarButtons.forEach {
            $0.contentTintColor = theme.muted; $0.hoverColor = theme.text.withAlphaComponent(0.07)
        }
        let allTabs = tabs + (peekTab.map { [$0] } ?? [])
        for tab in allTabs {
            if tab.webView.appearance?.name != appearance.name { tab.webView.appearance = appearance }
            if tab.webView.underPageBackgroundColor != theme.page { tab.webView.underPageBackgroundColor = theme.page }
        }
        findBar.fill = theme.popup
        [findBar.previous, findBar.next, findBar.close].forEach { $0.contentTintColor = theme.muted }
        if palette.theme != theme { palette.applyTheme(theme); if !palette.isHidden { palette.render() } }
        peekBackdrop?.fill = theme.background.withAlphaComponent(0.72)
        peekCard?.fill = theme.page; (peekCard?.subviews.first as? Surface)?.fill = theme.page
        for button in peekControls {
            button.baseColor = theme.popup; button.layer?.backgroundColor = theme.popup.cgColor
            button.hoverColor = theme.text.withAlphaComponent(0.07)
        }
    }
}
