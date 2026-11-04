import AppKit

/// YouTube videos you open wait for you to press play, unless Autoplay YouTube videos is on in
/// Rise's settings. YouTube has no setting for this (its Autoplay toggle is about the next
/// video), but it handles a browser that blocks autoplay, as Chrome does for sites you rarely
/// play anything on: the player stays on the video's thumbnail with its large play button, at
/// the time in the link and in its playlist.
///
/// So Rise's script turns down YouTube's own players' (a watch page's, a Short's, an embed
/// page's) calls to `play()` until you first click or press a key in the page. A video you then
/// pick on YouTube plays as usual, as does its Autoplay's next one; hover previews and other
/// sites' embedded players are left alone. Page activation can't tell when that is, as Rise's
/// own scripts run with a user gesture.
@MainActor final class YouTubeAutoplay {
    static let key = "Rise.YouTubeAutoplay"
    private let preferences: UserDefaults
    /// Pages, whose script is swapped when the setting changes.
    private let scriptedPages = NSHashTable<AnyObject>.weakObjects()
    /// Off by default: videos wait for you.
    private(set) var isEnabled: Bool

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        isEnabled = preferences.bool(forKey: Self.key)
    }

    func install(on page: WebPage) {
        scriptedPages.add(page)
        page.addUserScript(Self.script(allowed: isEnabled), world: .page, mainFrameOnly: true, handlers: [])
    }

    /// Saves the choice for pages to come, and tells YouTube pages already open.
    func setEnabled(_ value: Bool) {
        isEnabled = value
        preferences.set(value, forKey: Self.key)
        for case let page as ChromiumPage in scriptedPages.allObjects {
            page.browserView.removeUserScripts(withPrefix: Self.marker)
            page.addUserScript(Self.script(allowed: value), world: .page, mainFrameOnly: true, handlers: [])
            guard YouTubeVideoPage.isYouTube(page.url) else { continue }
            page.evaluate("window.__riseYouTubeAutoplay?.(allowed)", arguments: ["allowed": value], in: nil, world: .page,
                          userGesture: false) { _ in }
        }
    }

    static func script(allowed: Bool) -> String {
        marker + "\n" + source.replacingOccurrences(of: "__RISE_ALLOWED__", with: allowed ? "true" : "false")
    }
    static let marker = "// Rise YouTube autoplay"

    static let source = #"""
    (() => {
      if (window.__riseYouTubeAutoplay || !/^(www\.|m\.)?youtube\.com$/.test(location.hostname)) return;
      let allowed = __RISE_ALLOWED__, chosen = false;
      // Not the hover previews' player (#inline-preview-player), nor a page's other videos.
      const players = '#movie_player, #shorts-player';
      // Once you've clicked or typed in the page, what plays is up to you and YouTube. Registered
      // first, at the document's start, so it comes before the press that plays.
      const choose = event => {
        if (!event.isTrusted || (event.type === 'keydown' && (event.key === 'Escape' || event.metaKey || event.ctrlKey))) return;
        chosen = true;
        removeEventListener('pointerdown', choose, true); removeEventListener('keydown', choose, true);
      };
      addEventListener('pointerdown', choose, true);
      addEventListener('keydown', choose, true);
      const play = HTMLMediaElement.prototype.play;
      // As Chrome turns down autoplay, which YouTube answers with its large play button.
      HTMLMediaElement.prototype.play = {play() {
        if (!allowed && !chosen && this instanceof HTMLVideoElement && this.closest(players)) {
          return Promise.reject(new DOMException('Rise waits for you to press play.', 'NotAllowedError'));
        }
        return play.apply(this, arguments);
      }}.play;
      Object.defineProperty(window, '__riseYouTubeAutoplay', {value: value => { allowed = !!value; }});
    })();
    """#
}
