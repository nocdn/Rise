import AppKit
import WebKit

/// Which engine draws a page. Saved history is tagged with it, since one engine can't read
/// the other's.
enum WebEngine: String, Codable {
    case webKit, chromium
}

/// Everything Rise asks of a page, whichever engine draws it. Rise lays out, clips and
/// animates `view` like any other view; the engine only fills it.
@MainActor protocol WebPage: ScriptablePage {
    var engine: WebEngine { get }
    var view: NSView { get }
    var url: URL? { get }
    var title: String? { get }
    var isLoading: Bool { get }
    var estimatedProgress: Double { get }
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }
    /// The engine's own fullscreen, which takes the page into its window.
    var isInNativeFullscreen: Bool { get }
    var isPlayingAudio: Bool { get }
    var zoom: CGFloat { get set }
    /// Pinched in or out, past the page's own zoom.
    var isMagnified: Bool { get }
    /// Under a Peek or rendering out of sight: it takes no hover and sets no cursor.
    var isCovered: Bool { get set }
    /// Called on the main actor whenever any of the state above changes.
    var onChange: ((WebPageChange) -> Void)? { get set }

    func load(_ url: URL)
    func goBack()
    func goForward()
    func reload()
    func reloadIgnoringCache()
    func stopLoading()
    /// False if the engine can't mute the page.
    @discardableResult func setAudioMuted(_ muted: Bool) -> Bool

    /// The back/forward history in the engine's own form, for saving; nil when unavailable.
    var sessionState: Data? { get }
    /// Restores history saved by `sessionState`; false if there was nothing to restore.
    func restoreSession(_ data: Data, fallback url: URL) -> Bool
    /// A picture of the page as it is now, `width` points wide (or its own width).
    func snapshot(width: CGFloat?) async -> NSImage?
    /// Whether the engine can show the page live elsewhere in the window (`liveLayer`), so motion
    /// needs no pictures of it.
    var showsLiveLayers: Bool { get }
    /// The page itself, `rect` of it in the view's coordinates (nil: all of it), live in a layer to
    /// show elsewhere, scaled by a transform. Nil where `showsLiveLayers` isn't, or before it has drawn.
    func liveLayer(showing rect: NSRect?) -> CALayer?
    /// A picture of part of the page as it is now: `rect` in the view's own coordinates.
    func snapshot(rect: NSRect) async -> NSImage?
    /// The whole page, beyond what shows: a JPEG of it, or a PDF of it as one long page, as it
    /// shows on screen. Nil if it couldn't be taken.
    func capture(_ format: PageCaptureFormat) async -> Data?

    /// Runs `body` as the body of an async function taking `arguments`, in Rise's own script
    /// world `world` (nil: the one Rise's page tools share), which the page can't see.
    /// Returns what it returns, or nil if it threw.
    func evaluate(_ body: String, arguments: [String: Any], world: String?) async -> Any?
    /// Runs `source` in `world` at the start of every document the page loads, and the current one.
    func addScriptToEveryDocument(_ source: String, world: String)
    /// Lets Rise scripts in `world` post to `name`, as `riseHandlers.<name>.postMessage(body)`.
    /// With `replying`, the post is a promise of the reply, which must be given once.
    func addMessageHandler(_ name: String, world: ScriptWorld, receive: @escaping (PageMessage) -> Void)
    func addMessageHandler(_ name: String, world: ScriptWorld, replying: @escaping (PageMessage, @escaping (Any?, String?) -> Void) -> Void)
    /// Runs `source` at the start of every document, in every frame or only the main one, in
    /// `world`, with `riseHandlers` holding `handlers` (added first) for it. Add each once.
    func addUserScript(_ source: String, world: ScriptWorld, mainFrameOnly: Bool, handlers: [String])
    /// Runs `body` as the body of an async function taking `arguments` in `frame` (nil: the main
    /// one) and `world`; a frame a message came from is in that message's world. It's sent to the
    /// page at once, so calls reach it in the order they're made.
    func evaluate(_ body: String, arguments: [String: Any], in frame: PageFrame?, world: ScriptWorld,
                  completion: @escaping (Result<Any?, Error>) -> Void)
    /// Draws the page in Rise's theme: `appearance` for what it prefers (light or dark), and
    /// `background` before it first draws and around it.
    func setTheme(_ appearance: NSAppearance, background: NSColor)
    /// Pauses the page's audio and video while it's held out of sight, and lets it go on after.
    func setMediaSuspended(_ suspended: Bool)
    /// The link under the pointer changed, where the engine reports it to the app.
    var onHoverLink: ((URL?) -> Void)? { get set }
    /// The page wants a link opened elsewhere: a new tab, in the background or not. True once Rise has.
    var onOpenElsewhere: ((URL, _ background: Bool) -> Bool)? { get set }
    /// "Open Link in Peek" from the page's own menu, where the engine draws that menu.
    var onOpenInPeek: ((URL) -> Void)? { get set }
}

/// Where a Rise script runs: with the page's own scripts, or in a world of Rise's they can't see.
enum ScriptWorld: Hashable {
    case page, named(String)
    var name: String? { if case .named(let name) = self { return name }; return nil }
}
/// A frame a Rise script posted from, to run scripts in again.
struct PageFrame {
    let isMain: Bool
    /// As `SitePermissions` writes origins; nil for one it doesn't keep, such as an opaque one.
    let origin: String?
    /// The engine's own handle to the frame.
    let handle: AnyObject
}
struct PageMessage {
    let body: Any
    let frame: PageFrame
    /// The page the frame is in: pages a page opens can share its scripts and handlers.
    weak var page: (any WebPage)?
}
struct PageScriptError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension WebPage {
    func runScript(_ body: String, arguments: [String: Any], world: String?) async throws -> Any? {
        guard let world else { return await evaluate(body, arguments: arguments, world: nil) }
        return try await evaluate(body, arguments: arguments, in: nil, world: .named(world))
    }
    var findWebView: WKWebView? { (self as? WebKitPage)?.webView }
    /// As the completion form; throws if the script threw.
    func evaluate(_ body: String, arguments: [String: Any], in frame: PageFrame?, world: ScriptWorld) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            evaluate(body, arguments: arguments, in: frame, world: world) { continuation.resume(with: $0) }
        }
    }
}

/// How a page is going somewhere.
enum PageNavigationKind { case newPage, history, reload }
/// What happens to a page as it loads, where the engine reports it through the page rather
/// than Rise's WebKit delegates.
enum PageEvent {
    case willNavigate(PageNavigationKind), finished, failed(String), crashed, openInOtherApp(URL)
    /// The engine closed the page itself, as for an extension's tabs.remove.
    case closed
}

enum WebPageChange {
    case title, url, progress, loading, navigation, fullscreen, audio
}

/// How a whole page is captured.
enum PageCaptureFormat { case jpeg, pdf }
