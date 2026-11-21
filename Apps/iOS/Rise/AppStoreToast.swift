import UIKit
import WebKit

/// Open App Store, with the store's icon and optional product artwork.
@MainActor final class AppStoreToast: PageActionToast {
    let link: AppStoreLink
    let appIcon = UIImageView(image: UIImage(named: "ToastAppStore"))
    private var artworkTask: Task<Void, Never>?

    init(link: AppStoreLink, page: WKWebView, showsAppArtwork: Bool = false,
         artwork: @escaping @MainActor (AppStoreLink) async -> UIImage? = { await AppStoreArtwork.shared.image(for: $0) }) {
        self.link = link
        super.init(message: "Open App Store", motionName: "app-store-toast", page: page,
                   trailingIcon: UIImage(named: "ToastOpenAppStore"))
        symbol.isHidden = true
        appIcon.tintColor = symbol.tintColor
        appIcon.contentMode = .scaleAspectFit
        appIcon.layer.cornerCurve = .continuous
        appIcon.clipsToBounds = true
        adopt(appIcon)
        // Keep artwork support available, but show only the App Store icon for now.
        guard showsAppArtwork else { return }
        artworkTask = Task { [weak self] in
            let image = await artwork(link)
            guard !Task.isCancelled, let self, !dismissed, let image else { return }
            appIcon.image = image.withRenderingMode(.alwaysOriginal)
            appIcon.layer.cornerRadius = 5
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        appIcon.frame = CGRect(x: 14, y: 15, width: 24, height: 24)
    }
    override func dismiss(animated: Bool = true, velocity: CGPoint? = nil) {
        artworkTask?.cancel(); artworkTask = nil
        super.dismiss(animated: animated, velocity: velocity)
    }
    isolated deinit { artworkTask?.cancel() }
}
