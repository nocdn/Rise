import AppKit

/// A page that draws nothing, for when Chromium isn't running, as in unit tests: it goes where
/// it's sent, with its history, and says so as a page would, a moment later, but runs no scripts.
/// A local file's `<title>` is its title, so tests can name their pages. Rise itself doesn't
/// run without the engine.
@MainActor final class BlankPage: WebPage {
    let view: NSView = {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600)); view.wantsLayer = true; return view
    }()
    private(set) var url: URL?
    var title: String? { didSet { onChange?(.title) } }
    var isLoading: Bool { false }
    var estimatedProgress: Double { 1 }
    private var back: [URL] = [], forward: [URL] = []
    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }
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
    private var background = NSColor.white
    /// How many times it has gone somewhere, history and reloads included.
    private(set) var loadCount = 0
    /// What Rise's scripts get back from it: nothing, unless a test says otherwise.
    var scriptAnswer: (_ body: String) -> Any? = { _ in nil }

    func load(_ url: URL) {
        if let current = self.url { back.append(current) }
        forward = []
        go(to: url, .newPage)
    }
    func goBack() {
        guard let previous = back.popLast() else { return }
        if let url { forward.append(url) }
        go(to: previous, .history)
    }
    func goForward() {
        guard let next = forward.popLast() else { return }
        if let url { back.append(url) }
        go(to: next, .history)
    }
    func reload() { if let url { go(to: url, .reload) } }
    func reloadIgnoringCache() { reload() }
    func stopLoading() {}
    private func go(to url: URL, _ kind: PageNavigationKind) {
        onEvent?(.willNavigate(kind))
        self.url = url; loadCount += 1
        if url.isFileURL, let html = try? String(contentsOf: url, encoding: .utf8),
           let range = html.range(of: "(?<=<title>)[^<]*(?=</title>)", options: [.regularExpression, .caseInsensitive]) {
            title = String(html[range])
        }
        onChange?(.url); onChange?(.navigation)
        DispatchQueue.main.async { [weak self] in self?.onChange?(.loading); self?.onEvent?(.finished) }
    }
    @discardableResult func setAudioMuted(_ muted: Bool) -> Bool { true }

    private struct History: Codable { let back: [URL], current: URL?, forward: [URL] }
    /// Nil for a page with nowhere to go back or forward to, which its address alone restores.
    var sessionState: Data? {
        back.isEmpty && forward.isEmpty ? nil : try? JSONEncoder().encode(History(back: back, current: url, forward: forward))
    }
    func restoreSession(_ data: Data, fallback url: URL) -> Bool {
        guard let history = try? JSONDecoder().decode(History.self, from: data), let current = history.current else { return false }
        back = history.back; forward = history.forward
        go(to: current, .history)
        return true
    }
    /// Its background colour, as it would show before the page draws.
    func snapshot(width: CGFloat?) async -> NSImage? {
        let size = view.bounds.size, scale = width.map { $0/max(1, size.width) } ?? 1
        return picture(NSSize(width: max(1, size.width*scale), height: max(1, size.height*scale)))
    }
    var showsLiveLayers: Bool { false }
    func liveLayer(showing rect: NSRect?) -> CALayer? { nil }
    func snapshot(rect: NSRect) async -> NSImage? { picture(rect.size) }
    func capture(_ format: PageCaptureFormat) async -> Data? { nil }
    private func picture(_ size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { [background] bounds in background.setFill(); bounds.fill(); return true }
    }

    func evaluate(_ body: String, arguments: [String: Any], world: String?) async -> Any? { scriptAnswer(body) }
    func addScriptToEveryDocument(_ source: String, world: String) {}
    func addMessageHandler(_ name: String, world: ScriptWorld, receive: @escaping (PageMessage) -> Void) {}
    func addMessageHandler(_ name: String, world: ScriptWorld, replying: @escaping (PageMessage, @escaping (Any?, String?) -> Void) -> Void) {}
    func addUserScript(_ source: String, world: ScriptWorld, mainFrameOnly: Bool, handlers: [String]) {}
    func evaluate(_ body: String, arguments: [String: Any], in frame: PageFrame?, world: ScriptWorld,
                  completion: @escaping (Result<Any?, Error>) -> Void) { completion(.success(scriptAnswer(body))) }
    func setTheme(_ appearance: NSAppearance, background: NSColor) {
        self.background = background; view.layer?.backgroundColor = background.cgColor
    }
    func setMediaSuspended(_ suspended: Bool) {}
}
