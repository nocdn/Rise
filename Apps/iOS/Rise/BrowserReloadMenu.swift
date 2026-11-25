import UIKit
import WebKit

/// Holding Reload in More opens its menu: a reload without the cache, as ⌘⇧R does on the Mac, or
/// clearing what the site has stored, each confirmed first, then reloading it fresh.
extension BrowserViewController {
    @MainActor enum SiteDataClearing {
        case cache, all

        var types: Set<String> {
            switch self {
            case .cache: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache,
                          WKWebsiteDataTypeFetchCache, WKWebsiteDataTypeOfflineWebApplicationCache]
            case .all: WKWebsiteDataStore.allWebsiteDataTypes()
            }
        }
    }

    func installReloadMenu(on button: UIButton) {
        button.preferredMenuElementOrder = .fixed
        button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.reloadMenu() ?? [])
        }])
    }

    /// The site whose data the menu clears: the page's registrable domain, as Safari lists sites.
    private var reloadMenuHost: String? {
        guard let url = webView.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url.host()
    }

    private func reloadMenu() -> [UIMenuElement] {
        let clearing = reloadMenuHost == nil ? UIMenuElement.Attributes.disabled : []
        return [
            UIAction(title: "Hard reload", image: UIImage(named: "HardReloadToast")) { [weak self] _ in self?.hardReload() },
            UIAction(title: "Clear cache", image: UIImage(systemName: "eraser"), attributes: clearing) { [weak self] _ in
                self?.confirmClearing(.cache)
            },
            UIAction(title: "Clear site data", image: UIImage(systemName: "trash"),
                     attributes: clearing.union(.destructive)) { [weak self] _ in
                self?.confirmClearing(.all)
            },
        ]
    }

    private func confirmClearing(_ clearing: SiteDataClearing) {
        guard let host = reloadMenuHost else { return }
        let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let alert = switch clearing {
        case .cache: UIAlertController(title: "Clear cache?",
            message: "Images, scripts and other files saved from \(site) will download again.", preferredStyle: .alert)
        case .all: UIAlertController(title: "Clear site data?",
            message: "This signs you out of \(site) and removes its cookies, storage and cache.", preferredStyle: .alert)
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Proceed", style: .destructive) { [weak self] _ in
            self?.clear(clearing, host: host)
        })
        topPresenter.present(alert, animated: true)
    }

    /// Removes the site's data, its subdomains' included, then reloads it fresh, saying so briefly.
    private func clear(_ clearing: SiteDataClearing, host: String) {
        let page = webView
        let store = page.configuration.websiteDataStore
        closePanel()
        Task { [weak self] in
            let records = await store.dataRecords(ofTypes: clearing.types).filter { record in
                let domain = record.displayName.lowercased()
                return host.lowercased() == domain || host.lowercased().hasSuffix("."+domain)
            }
            await store.removeData(ofTypes: clearing.types, for: records)
            guard let self else { return }
            if page === webView { reloadPage(ignoringCache: true) }
            let message = clearing == .cache ? "Cleared cache" : "Cleared site data"
            let toast = Toast(message: message, glyph: UIImage(named: "HardReloadToast"),
                              name: clearing == .cache ? "clear-cache" : "clear-site-data", trailingInset: 19)
            showToast(toast)
            toast.leave(after: 1)
            UIAccessibility.post(notification: .announcement, argument: message)
        }
    }
}
