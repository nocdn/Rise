import AppKit

/// Follows the audio and video each tab plays, in every frame, so the tab's play
/// button can pause and resume any site's media, not only YouTube's. Media counts
/// once it plays with sound, so silent background loops don't give a tab a button.
/// It also tells the sidebar's Now Playing what plays (`NowPlaying.swift`): the page's
/// Media Session details, its position and its sound's levels, and seeks and skips it.
@MainActor final class TabMedia: NSObject {
    static let handler = "riseTabMedia"
    weak var browser: BrowserController?
    /// What the page says plays, from its Media Session; empty where it says nothing.
    struct Details: Equatable {
        var title = "", artist = "", artwork: URL?
        /// The page takes next and previous track, as media keys would; otherwise skipping seeks.
        var skipsTracks = false
    }
    private struct Frame {
        var paused: Bool
        /// When the frame last played, so play resumes the frame heard most recently.
        var playedAt: CFTimeInterval
        var frame: PageFrame
        var details = Details()
    }
    private var frames: [UUID: [String: Frame]] = [:]
    /// Called when a tab's state changes.
    var onChange: ((UUID) -> Void)?
    /// Called when anything a tab reports changes: its state or its details.
    var onReport: ((UUID) -> Void)?

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

    /// Tabs with media, and when each last played.
    var tabsWithMedia: [(id: UUID, paused: Bool, playedAt: CFTimeInterval)] {
        frames.compactMap { id, frames in
            guard !frames.isEmpty else { return nil }
            return (id, frames.values.allSatisfy(\.paused), frames.values.map(\.playedAt).max() ?? 0)
        }
    }
    /// The frame Now Playing follows: one playing, else the one heard most recently.
    private func leadingFrame(_ id: UUID) -> Frame? {
        frames[id]?.values.max { ($0.paused ? 0 : 1, $0.playedAt) < ($1.paused ? 0 : 1, $1.playedAt) }
    }
    func details(_ id: UUID) -> Details? { leadingFrame(id)?.details }
    /// The leading media's position, and with `meter`, five bands of its sound's level, low to
    /// high, each 0 to 1; nil levels where the page's sound can't be read.
    struct Status { var time: Double, duration: Double, paused: Bool, levels: [Double]? }
    func status(_ id: UUID, meter: Bool, completion: @escaping (Status?) -> Void) {
        call(id, "return window.__riseTabMedia?.status(meter) ?? null", ["meter": meter]) { value in
            guard let body = value as? [String: Any], let time = body["time"] as? Double, let duration = body["duration"] as? Double else {
                completion(nil); return
            }
            completion(Status(time: time, duration: duration, paused: body["paused"] as? Bool ?? true,
                              levels: (body["levels"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue }))
        }
    }
    func seek(_ id: UUID, to fraction: Double, final: Bool, completion: @escaping (Status?) -> Void = { _ in }) {
        call(id, "return window.__riseTabMedia?.seek(fraction, final) ?? null", ["fraction": fraction, "final": final]) { value in
            guard let body = value as? [String: Any], let time = body["time"] as? Double, let duration = body["duration"] as? Double else {
                completion(nil); return
            }
            completion(Status(time: time, duration: duration, paused: body["paused"] as? Bool ?? true, levels: nil))
        }
    }
    /// The next or previous track where the page takes them, else ten seconds on or back.
    func skip(_ id: UUID, forward: Bool) {
        call(id, "return window.__riseTabMedia?.skip(forward) ?? null", ["forward": forward]) { _ in }
    }
    private func call(_ id: UUID, _ body: String, _ arguments: [String: Any], completion: @escaping (Any?) -> Void) {
        guard let tab = browser?.tabs.first(where: { $0.id == id }), let frame = leadingFrame(id) else { completion(nil); return }
        tab.page.evaluate(body, arguments: arguments, in: frame.frame, world: .page) { result in completion(try? result.get()) }
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
        let details = Details(title: body["title"] as? String ?? "", artist: body["artist"] as? String ?? "",
                              artwork: (body["artwork"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }.flatMap { ["https", "http", "data"].contains($0.scheme) ? $0 : nil },
                              skipsTracks: body["skipsTracks"] as? Bool == true)
        switch body["state"] as? String {
        case "playing":
            // Still playing, it keeps when it began, so a page's details changing doesn't reorder tabs.
            let playedAt = frames[tab.id]?[key].flatMap { $0.paused ? nil : $0.playedAt } ?? CACurrentMediaTime()
            frames[tab.id, default: [:]][key] = Frame(paused: false, playedAt: playedAt, frame: message.frame, details: details)
        case "paused":
            let playedAt = frames[tab.id]?[key]?.playedAt ?? CACurrentMediaTime()
            frames[tab.id, default: [:]][key] = Frame(paused: true, playedAt: playedAt, frame: message.frame, details: details)
        default:
            frames[tab.id]?[key] = nil
            if frames[tab.id]?.isEmpty == true { frames[tab.id] = nil }
        }
        if paused(tab.id) != before { onChange?(tab.id) }
        onReport?(tab.id)
    }
    private func update(_ id: UUID, key: String, _ change: (inout Frame) -> Void) {
        guard var frame = frames[id]?[key] else { return }
        let before = paused(id)
        change(&frame); frames[id]?[key] = frame
        if paused(id) != before { onChange?(id) }
        onReport?(id)
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
      // The Media Session's details and the actions the page takes, as media keys would use them.
      const session = navigator.mediaSession, actions = new Map();
      if (session && window.MediaSession) {
        const setActionHandler = MediaSession.prototype.setActionHandler;
        MediaSession.prototype.setActionHandler = function(action, handler) {
          if (this === session) { if (typeof handler === 'function') actions.set(action, handler); else actions.delete(action); schedule(); }
          return setActionHandler.apply(this, arguments);
        };
        const metadata = Object.getOwnPropertyDescriptor(MediaSession.prototype, 'metadata');
        if (metadata?.set) Object.defineProperty(MediaSession.prototype, 'metadata', {...metadata, set(value) { metadata.set.call(this, value); schedule(); }});
      }
      const area = image => Math.max(0, ...String(image.sizes || '').split(/\s+/).map(size => { const [w, h] = size.split('x').map(Number); return (w || 0)*(h || 0); }));
      const details = () => {
        const data = session?.metadata;
        const images = [...(data?.artwork || [])].filter(image => image?.src);
        const image = images.sort((a, b) => area(b)-area(a))[0];
        let artwork = '';
        try { artwork = image ? new URL(image.src, location.href).href : ''; } catch {}
        return {title: String(data?.title || ''), artist: String(data?.artist || data?.album || ''), artwork,
                skipsTracks: actions.has('nexttrack') || actions.has('previoustrack')};
      };
      // The media Now Playing follows: the last heard that plays, else the last heard.
      const leading = () => { const media = [...heard]; return media.filter(playing).pop() || media.pop() || null; };
      const position = media => ({time: media.currentTime || 0, duration: Number.isFinite(media.duration) ? media.duration : 0, paused: media.paused});
      // Its sound, read from a copy of its stream, so what's heard is left alone. Media with
      // another site's or protected data gives none; reading stops once Rise stops asking.
      const unreadable = new WeakSet(), streams = new WeakMap();
      let meter = null;
      const closeMeter = () => {
        if (!meter) return;
        clearTimeout(meter.idle);
        try { meter.source?.disconnect(); meter.context.close(); } catch {}
        meter = null;
      };
      const levels = media => {
        if (unreadable.has(media)) return null;
        try {
          if (meter?.media !== media) {
            closeMeter();
            const capture = media.captureStream || media.mozCaptureStream;
            if (!capture) { unreadable.add(media); return null; }
            const stream = streams.get(media) || capture.call(media);
            streams.set(media, stream);
            const context = new AudioContext(), analyser = context.createAnalyser(), silence = context.createGain();
            analyser.fftSize = 1024; analyser.smoothingTimeConstant = 0.5; silence.gain.value = 0;
            analyser.connect(silence); silence.connect(context.destination);
            meter = {media, stream, context, analyser, data: new Uint8Array(analyser.frequencyBinCount), source: null, track: null};
          }
          clearTimeout(meter.idle); meter.idle = setTimeout(closeMeter, 3000);
          const track = meter.stream.getAudioTracks()[0];
          if (!track) return null;
          if (meter.track !== track.id) {
            meter.source?.disconnect();
            meter.source = meter.context.createMediaStreamSource(new MediaStream([track]));
            meter.source.connect(meter.analyser); meter.track = track.id;
          }
          if (meter.context.state === 'suspended') meter.context.resume().catch(() => {});
          meter.analyser.getByteFrequencyData(meter.data);
          const hertz = meter.context.sampleRate/meter.analyser.fftSize;
          return [[40, 150], [150, 500], [500, 1500], [1500, 4500], [4500, 14000]].map(([low, high]) => {
            const from = Math.max(1, Math.floor(low/hertz)), to = Math.min(meter.data.length, Math.ceil(high/hertz));
            let sum = 0; for (let i = from; i < to; i++) sum += meter.data[i];
            return Math.round(sum/Math.max(1, to-from)/255*1000)/1000;
          });
        } catch { unreadable.add(media); closeMeter(); return null; }
      };
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
        const body = state ? {frame, state, ...details()} : {frame, state};
        const value = JSON.stringify(body);
        if (value !== previous) { previous = value; post(body); }
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
        },
        status(withLevels) {
          const media = leading();
          return media ? {...position(media), levels: withLevels && playing(media) ? levels(media) : null} : null;
        },
        // A scrub seeks to keyframes quickly; its release lands exactly.
        seek(fraction, final) {
          const media = leading();
          if (!media || !Number.isFinite(media.duration) || !Number.isFinite(fraction)) return null;
          const time = Math.min(1, Math.max(0, fraction))*media.duration;
          if (!final && media.fastSeek) media.fastSeek(time); else media.currentTime = time;
          return {...position(media), time};
        },
        skip(forward) {
          const action = actions.get(forward ? 'nexttrack' : 'previoustrack');
          if (action) { try { action({action: forward ? 'nexttrack' : 'previoustrack'}); return true; } catch {} }
          const media = leading();
          if (!media) return false;
          const end = Number.isFinite(media.duration) ? media.duration : Infinity;
          media.currentTime = Math.min(end, Math.max(0, media.currentTime+(forward ? 10 : -10)));
          return true;
        }
      })});
    })();
    """#
}
