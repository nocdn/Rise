import WebKit

/// Hit-tests in each frame's own document, including player overlays and shadow roots.
/// Only opaque, short-lived video identities leave JavaScript; commands revalidate the source.
enum VideoContextMenuScript {
    @MainActor static let userScript = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    static let source = #"""
    (() => {
      if (window.__riseVideoMenu) return;
      const roots = new WeakMap();
      const attach = Element.prototype.attachShadow;
      Element.prototype.attachShadow = function(...args) {
        const root = Reflect.apply(attach, this, args); roots.set(this, root); return root;
      };
      let selected = null;
      const sourceOf = video => video.srcObject || video.src ||
        [...video.querySelectorAll('source')].map(item => [item.src, item.type, item.media].join('|')).join('\n') || video.currentSrc;
      const target = token => {
        const video = selected?.token === token && selected.ref.deref();
        return video?.isConnected && sourceOf(video) === selected.source ? video : null;
      };
      function snapshot(token) {
        const video = target(token);
        if (!video) return null;
        let url = null;
        const sources = [...video.querySelectorAll('source')];
        const address = video.src || video.currentSrc;
        // currentSrc may still describe the previous child source during replacement.
        const current = video.src || !sources.length || sources.some(item => item.src === address);
        try { const parsed = new URL(current ? address : ''); if (['http:', 'https:'].includes(parsed.protocol)) url = parsed.href; } catch (_) {}
        const type = sources.find(item => item.src === address)?.type || '';
        return {token, paused: video.paused || video.ended, muted: video.muted,
          ready: video.readyState >= 1,
          fullscreen: !!(video.webkitEnterFullscreen || video.requestFullscreen),
          pip: !video.disablePictureInPicture && !!(video.webkitSupportsPresentationMode?.('picture-in-picture') || document.pictureInPictureEnabled),
          url, downloadable: !!url && !video.srcObject && !video.mediaKeys && !video.webkitKeys &&
            !/\.(m3u8|mpd)(?:[?#]|$)/i.test(url) && !/(mpegurl|dash\+xml)/i.test(type)};
      }
      function elements(root, x, y, seen = new Set()) {
        if (seen.has(root)) return [];
        seen.add(root);
        const list = root.elementsFromPoint?.(x, y) || [];
        return list.flatMap(element => {
          const shadow = element.shadowRoot || roots.get(element);
          return shadow ? [...elements(shadow, x, y, seen), element] : [element];
        });
      }
      function probe(data) {
        if (!data || typeof data.nonce !== 'string') return;
        const {x, y, originX, originY, scaleX, scaleY, nonce} = data;
        const list = elements(document, x, y);
        // A frame on top owns the touch; do not select a video behind that frame.
        const frame = list.find(element => element instanceof HTMLIFrameElement);
        const video = list.find(element => element instanceof HTMLVideoElement);
        if (frame && (!video || list.indexOf(frame) < list.indexOf(video))) {
          const rect = frame.getBoundingClientRect();
          const sx = rect.width / frame.offsetWidth, sy = rect.height / frame.offsetHeight;
          if (!(sx > 0 && sy > 0)) return;
          const left = rect.left + frame.clientLeft*sx, top = rect.top + frame.clientTop*sy;
          frame.contentWindow?.postMessage({type:'__riseVideoProbe', nonce,
            x:(x-left)/sx, y:(y-top)/sy, originX:originX+left*scaleX, originY:originY+top*scaleY,
            scaleX:scaleX*sx, scaleY:scaleY*sy}, '*');
          return;
        }
        if (!video) { selected = null; return; }
        const token = crypto.randomUUID?.() || `${Date.now()}-${Math.random()}`;
        selected = {token, ref:new WeakRef(video), source:sourceOf(video)};
        const rect = video.getBoundingClientRect();
        window.webkit.messageHandlers.riseVideoMenu.postMessage({nonce, ...snapshot(token),
          rect:[originX+rect.left*scaleX, originY+rect.top*scaleY, rect.width*scaleX, rect.height*scaleY]});
      }
      addEventListener('message', event => {
        if (event.source === parent && event.data?.type === '__riseVideoProbe') probe(event.data);
      });
      function probeNativePoint(x, y, width, height, nonce) {
        const viewport = window.visualViewport;
        const sx = width/(viewport?.width || innerWidth), sy = height/(viewport?.height || innerHeight);
        const ox = viewport?.offsetLeft || 0, oy = viewport?.offsetTop || 0;
        probe({nonce, x:x/sx+ox, y:y/sy+oy, originX:-ox*sx, originY:-oy*sy, scaleX:sx, scaleY:sy});
      }
      async function perform(token, action, authorization) {
        const video = target(token);
        if (!video) return false;
        const result = window.__riseVideoPlayback?.performUserAction(video, action, authorization);
        if (result === false || !window.__riseVideoPlayback) return false;
        return (await result) !== false;
      }
      Object.defineProperty(window, '__riseVideoMenu', {value:Object.freeze({probeNativePoint, snapshot, perform})});
    })();
    """#
}
