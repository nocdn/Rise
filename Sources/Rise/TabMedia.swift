import AppKit

/// Follows the audio and video each tab plays, in every frame, so the tab's play
/// button can pause and resume any site's media, not only YouTube's. Media counts
/// once it plays with sound, so silent background loops don't give a tab a button.
@MainActor final class TabMedia: NSObject {
    static let handler = "riseTabMedia"
    weak var browser: BrowserController?
    private struct Frame {
        var paused: Bool
        /// When the frame last played, so play resumes the frame heard most recently.
        var playedAt: CFTimeInterval
        var frame: PageFrame
    }
    private var frames: [UUID: [String: Frame]] = [:]
    /// Called when a tab's state changes.
    var onChange: ((UUID) -> Void)?

    init(browser: BrowserController?) { self.browser = browser; super.init() }

    func install(on page: WebPage) {
        // The page's world, so media the page never adds to its document is seen as well.
        page.addMessageHandler(Self.handler, world: .page) { [weak self] message in self?.receive(message) }
        page.addUserScript(Self.script, world: .page, mainFrameOnly: false, handlers: [Self.handler])
    }

    /// Whether the tab's media is paused, or nil when it has none.
    func paused(_ id: UUID) -> Bool? {
        guard let frames = frames[id], !frames.isEmpty else { return nil }
        return frames.values.allSatisfy(\.paused)
    }

    /// Pauses everything the tab plays, or resumes what was playing last.
    func togglePlayback(_ id: UUID) {
        guard let tab = browser?.tabs.first(where: { $0.id == id }), let frames = frames[id], !frames.isEmpty else { return }
        let pause = paused(id) == false
        let targets = pause ? frames.filter { !$0.value.paused } : frames.max { $0.value.playedAt < $1.value.playedAt }.map { [$0.key: $0.value] } ?? [:]
        let page = tab.page
        for (key, frame) in targets {
            page.evaluate("return window.__riseTabMedia?.toggle(pause) ?? null", arguments: ["pause": pause],
                          in: frame.frame, world: .page) { [weak self, weak tab] result in
                let value = try? result.get()
                // A hidden page reports late, since its timers are throttled.
                guard let self, let tab else { return }
                if let paused = value as? Bool { self.update(tab.id, key: key) { $0.paused = paused } }
                // The answer the button waits for; reports before it can't undo the press.
                self.browser?.sidebar.rows[tab.id]?.setPlayback(paused: self.browser?.playbackPaused(tab.id), confirmed: true)
            }
        }
    }

    /// Forgets a tab's media, when it closes or its page's process ends.
    func remove(_ id: UUID) {
        guard frames.removeValue(forKey: id) != nil else { return }
        onChange?(id)
    }

    func receive(_ message: PageMessage) {
        guard let page = message.page, let tab = browser?.tabs.first(where: { $0.page === page }),
              let body = message.body as? [String: Any], let key = body["frame"] as? String else { return }
        let before = paused(tab.id)
        switch body["state"] as? String {
        case "playing":
            frames[tab.id, default: [:]][key] = Frame(paused: false, playedAt: CACurrentMediaTime(), frame: message.frame)
        case "paused":
            let playedAt = frames[tab.id]?[key]?.playedAt ?? CACurrentMediaTime()
            frames[tab.id, default: [:]][key] = Frame(paused: true, playedAt: playedAt, frame: message.frame)
        default:
            frames[tab.id]?[key] = nil
            if frames[tab.id]?.isEmpty == true { frames[tab.id] = nil }
        }
        if paused(tab.id) != before { onChange?(tab.id) }
    }
    private func update(_ id: UUID, key: String, _ change: (inout Frame) -> Void) {
        guard var frame = frames[id]?[key] else { return }
        let before = paused(id)
        change(&frame); frames[id]?[key] = frame
        if paused(id) != before { onChange?(id) }
    }

    static let script = #"""
    (() => {
      if (window.__riseTabMedia) return;
      const handler = riseHandlers.riseTabMedia;
      if (!handler) return;
      const post = handler.postMessage.bind(handler);
      const frame = Math.random().toString(36).slice(2);
      // Media that has played with sound, newest last.
      const heard = new Set();
      // Media first played outside the document.
      const loose = new WeakSet();
      let resume = [], previous = null, scheduled = false;
      const playing = media => !media.paused && !media.ended;
      const report = () => {
        scheduled = false;
        // Paused media that left the page is done with. Media that plays outside it
        // stays while it has a source, as players pause and resume it there.
        for (const media of heard) {
          if (!playing(media) && !media.isConnected && (!loose.has(media) || media.networkState === HTMLMediaElement.NETWORK_EMPTY)) heard.delete(media);
        }
        for (const media of heard) { if (heard.size <= 8) break; if (!playing(media)) heard.delete(media); }
        resume = resume.filter(media => heard.has(media));
        const state = heard.size === 0 ? null : [...heard].some(playing) ? 'playing' : 'paused';
        if (state !== previous) { previous = state; post({frame, state}); }
      };
      const schedule = () => { if (!scheduled) { scheduled = true; setTimeout(report, 30); } };
      const note = media => {
        if (!(media instanceof HTMLMediaElement)) return;
        if (playing(media) && !media.muted && media.volume > 0) { heard.delete(media); heard.add(media); resume = []; }
        if (heard.has(media)) schedule();
      };
      const events = ['play', 'playing', 'pause', 'ended', 'emptied', 'volumechange'];
      const listen = event => note(event.target);
      events.forEach(event => document.addEventListener(event, listen, true));
      // Media outside the document gets no document events; it is seen when it plays.
      const play = HTMLMediaElement.prototype.play;
      HTMLMediaElement.prototype.play = function() {
        if (this instanceof HTMLMediaElement && !this.isConnected && !loose.has(this)) { loose.add(this); events.forEach(event => this.addEventListener(event, listen)); }
        return play.apply(this, arguments);
      };
      setInterval(() => { if (heard.size) report(); }, 2000);
      addEventListener('pagehide', () => { previous = null; post({frame, state: null}); });
      addEventListener('pageshow', event => { if (event.persisted) report(); });
      Object.defineProperty(window, '__riseTabMedia', {value: Object.freeze({
        // Pauses all that plays here, or resumes it, else the media heard last.
        toggle(pause) {
          const media = [...heard];
          if (pause) {
            resume = media.filter(playing);
            resume.forEach(item => item.pause());
          } else {
            const items = resume.length ? resume : media.slice(-1);
            items.forEach(item => item.play().catch(() => {}));
            resume = [];
          }
          report();
          return pause;
        }
      })});
    })();
    """#
}
