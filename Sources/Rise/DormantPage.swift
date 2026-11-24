import AppKit
import RiseCore

/// What a tab holds before it's first shown or loaded, and while it sleeps: no engine page at all,
/// as an engine page starts a renderer process of its own, about 60 MB, whether or not it ever
/// loads. It draws the theme's page colour, runs nothing and holds nothing; `BrowserTab` puts a
/// real page in its place, where its view is, the moment the tab loads (`BrowserTab.wake`).
@MainActor final class DormantPage: WebPage {
    let view: NSView = {
        let view = DormantView(frame: .zero); view.wantsLayer = true; return view
    }()
    var url: URL? { nil }
    var title: String? { nil }
    var isLoading: Bool { false }
    var estimatedProgress: Double { 0 }
    var canGoBack: Bool { false }
    var canGoForward: Bool { false }
    var isInNativeFullscreen: Bool { false }
    var isPlayingAudio: Bool { false }
    var zoom: CGFloat = 1
    var isMagnified: Bool { false }
    var isCovered = false
    var onChange: ((WebPageChange) -> Void)?
    var onEvent: ((PageEvent) -> Void)?
    var onHoverLink: ((URL?) -> Void)?
    var onOpenElsewhere: ((URL, _ background: Bool) -> Bool)?
    var onOpenInPeek: ((URL) -> Void)?
    /// Asked to go somewhere directly, rather than through its tab: the tab wakes and goes there.
    var onLoad: ((URL) -> Void)?
    private var background = NSColor.white

    func load(_ url: URL) { onLoad?(url) }
    func goBack() {}
    func goForward() {}
    func reload() {}
    func reloadIgnoringCache() {}
    func stopLoading() {}
    @discardableResult func setAudioMuted(_ muted: Bool) -> Bool { true }
    var sessionState: Data? { nil }
    func restoreSession(_ data: Data, fallback url: URL) -> Bool { false }
    func snapshot(width: CGFloat?) async -> NSImage? { nil }
    var showsLiveLayers: Bool { false }
    func liveLayer(showing rect: NSRect?) -> CALayer? { nil }
    func snapshot(rect: NSRect) async -> NSImage? { nil }
    func capture(_ format: PageCaptureFormat) async -> Data? { nil }
    func evaluate(_ body: String, arguments: [String: Any], world: String?) async -> Any? { nil }
    func addScriptToEveryDocument(_ source: String, world: String) {}
    func addMessageHandler(_ name: String, world: ScriptWorld, receive: @escaping (PageMessage) -> Void) {}
    func addMessageHandler(_ name: String, world: ScriptWorld, replying: @escaping (PageMessage, @escaping (Any?, String?) -> Void) -> Void) {}
    func addUserScript(_ source: String, world: ScriptWorld, mainFrameOnly: Bool, handlers: [String]) {}
    func evaluate(_ body: String, arguments: [String: Any], in frame: PageFrame?, world: ScriptWorld,
                  completion: @escaping (Result<Any?, Error>) -> Void) { completion(.success(nil)) }
    func setTheme(_ appearance: NSAppearance, background: NSColor) {
        self.background = background
        CATransaction.begin(); CATransaction.setDisableActions(true)
        view.layer?.backgroundColor = background.cgColor
        CATransaction.commit()
    }
    func setMediaSuspended(_ suspended: Bool) {}
}

/// Takes focus as a page would, so the page that wakes in its place can take it over.
private final class DormantView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
