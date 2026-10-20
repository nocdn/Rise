import Foundation

enum VideoPlaybackScript {
    static func source(allowsAutoplay: Bool, menuAuthorization: String) -> String {
        #"""
        (() => {
          if (window.__riseVideoPlayback) return;
          let allowsAutoplay = \#(allowsAutoplay);
          const videos = new Set();
          const known = new WeakSet();
          const userPlayed = new WeakMap();
          const wantedAutoplay = new WeakSet();
          const observedRoots = new WeakSet();
          let lastGesture = -Infinity;
          let handlingInput = false;
          const taps = new Map();
          // Native evaluateJavaScript also grants WebKit activation. Require actual trusted
          // page input, so browser scripts and synthetic clicks cannot authorize autoplay.
          const hasGesture = () => navigator.userActivation?.isActive === true && performance.now() - lastGesture < 5000;
          const isVideo = element => element instanceof HTMLVideoElement;
          // Prefer the requested URL: currentSrc can still point at the previous resource
          // immediately after a site reuses the same element for its next video.
          const source = video => video.srcObject || video.src ||
            Array.from(video.querySelectorAll('source'), item => [item.src, item.type, item.media].join('|')).join('\n');
          const wasUserPlayed = video => userPlayed.has(video) && userPlayed.get(video) === source(video);
          const allowUserPlayback = video => userPlayed.set(video, source(video));

          function prepare(video) {
            if (!isVideo(video)) return;
            if (!known.has(video)) {
              known.add(video);
              videos.add(new WeakRef(video));
            }
            if (!video.hasAttribute('playsinline')) video.setAttribute('playsinline', '');
            if (!video.hasAttribute('webkit-playsinline')) video.setAttribute('webkit-playsinline', '');
            if (!allowsAutoplay && video.autoplay) {
              wantedAutoplay.add(video);
              video.autoplay = false;
            }
          }

          function scan(root) {
            prepare(root);
            root.querySelectorAll?.('video').forEach(prepare);
          }

          function observe(root) {
            if (observedRoots.has(root)) return;
            observedRoots.add(root);
            new MutationObserver(changes => {
              for (const change of changes) {
                if (change.type === 'attributes') prepare(change.target);
                else change.addedNodes.forEach(scan);
              }
            }).observe(root, {subtree: true, childList: true, attributes: true,
                             attributeFilter: ['playsinline', 'webkit-playsinline', 'autoplay']});
            scan(root);
            // Native controls are inside a closed shadow tree: their trusted events retarget
            // to the video. Record that intent before the asynchronous play event arrives.
            root.addEventListener('pointerdown', event => {
              if (event.isTrusted) taps.set(event.pointerId, {x: event.clientX, y: event.clientY});
            }, true);
            root.addEventListener('pointermove', event => {
              const tap = taps.get(event.pointerId);
              if (tap && Math.hypot(event.clientX - tap.x, event.clientY - tap.y) > 10) taps.delete(event.pointerId);
            }, true);
            root.addEventListener('pointercancel', event => taps.delete(event.pointerId), true);
            for (const type of ['pointerup', 'click', 'keydown']) {
              root.addEventListener(type, event => {
                if (!event.isTrusted || (type === 'keydown' && ![' ', 'Enter'].includes(event.key))) return;
                if (type === 'pointerup') {
                  if (!taps.has(event.pointerId)) return;
                  taps.delete(event.pointerId);
                }
                lastGesture = performance.now();
                handlingInput = true;
                setTimeout(() => { handlingInput = false; }, 0);
                const video = event.composedPath().find(isVideo);
                if (video) allowUserPlayback(video);
              }, true);
            }
            root.addEventListener('play', event => {
              const video = event.target;
              if (!isVideo(video)) return;
              prepare(video);
              if (hasGesture()) allowUserPlayback(video);
              if (!allowsAutoplay && !wasUserPlayed(video)) video.pause();
            }, true);
          }

          // A MutationObserver alone is too late for createElement('video').play() in the
          // same task, or for detached autoplay probes used by embedded players.
          for (const name of ['createElement', 'createElementNS']) {
            const original = Document.prototype[name];
            Document.prototype[name] = function(...args) {
              const element = Reflect.apply(original, this, args);
              prepare(element);
              return element;
            };
          }
          const attachShadow = Element.prototype.attachShadow;
          Element.prototype.attachShadow = function(...args) {
            const root = Reflect.apply(attachShadow, this, args);
            observe(root);
            return root;
          };
          const play = HTMLMediaElement.prototype.play;
          HTMLMediaElement.prototype.play = function(...args) {
            if (isVideo(this)) {
              prepare(this);
              if (hasGesture()) allowUserPlayback(this);
              if (!allowsAutoplay && !wasUserPlayed(this)) {
                return Promise.reject(new DOMException('Tap Play to start this video.', 'NotAllowedError'));
              }
            }
            return Reflect.apply(play, this, args);
          };

          // Inline playback prevents WebKit's automatic player presentation. Also reject
          // unsolicited fullscreen API calls, retaining the page's deliberate fullscreen button.
          const nativePresentation = new Map();
          for (const name of ['webkitEnterFullscreen', 'webkitEnterFullScreen', 'webkitSetPresentationMode']) {
            const original = HTMLVideoElement.prototype[name];
            if (typeof original !== 'function') continue;
            nativePresentation.set(name, original);
            HTMLVideoElement.prototype[name] = function(...args) {
              prepare(this);
              if ((name !== 'webkitSetPresentationMode' || args[0] === 'fullscreen') && !(hasGesture() && handlingInput)) return;
              return Reflect.apply(original, this, args);
            };
          }
          const nativeRequestFullscreen = Element.prototype.requestFullscreen;
          for (const name of ['requestFullscreen', 'webkitRequestFullscreen', 'webkitRequestFullScreen']) {
            const original = Element.prototype[name];
            if (typeof original !== 'function') continue;
            Element.prototype[name] = function(...args) {
              if (!(hasGesture() && handlingInput)) {
                if (name === 'requestFullscreen') {
                  return Promise.reject(new DOMException('Tap the fullscreen button to enter fullscreen.', 'NotAllowedError'));
                }
                return;
              }
              return Reflect.apply(original, this, args);
            };
          }

          function setAutoplay(enabled) {
            allowsAutoplay = enabled;
            for (const ref of videos) {
              const video = ref.deref();
              if (!video) { videos.delete(ref); continue; }
              prepare(video);
              if (!enabled && !wasUserPlayed(video)) video.pause();
              if (enabled && wantedAutoplay.has(video)) {
                wantedAutoplay.delete(video);
                video.autoplay = true;
              }
            }
            // postMessage reaches cross-origin and nested frames without reading their DOM.
            for (let i = 0; i < frames.length; i++) {
              frames[i].postMessage({type: '__riseVideoAutoplay', enabled}, '*');
            }
          }
          window.addEventListener('message', event => {
            if (event.source === parent && event.data?.type === '__riseVideoAutoplay' &&
                typeof event.data.enabled === 'boolean') setAutoplay(event.data.enabled);
            if (event.data?.type === '__riseVideoAutoplayRequest') {
              for (let i = 0; i < frames.length; i++) {
                if (event.source === frames[i]) {
                  event.source.postMessage({type: '__riseVideoAutoplay', enabled: allowsAutoplay}, '*');
                  break;
                }
              }
            }
          });
          function nativeInput(callback) {
            const previousGesture = lastGesture, previousInput = handlingInput;
            lastGesture = performance.now(); handlingInput = true;
            try { return callback(); }
            finally { lastGesture = previousGesture; handlingInput = previousInput; }
          }
          function performUserAction(video, action, authorization) {
            if (authorization !== '\#(menuAuthorization)' || !isVideo(video) || !video.isConnected) return false;
            prepare(video);
            // Only this native command gets activation, including after asynchronous loading.
            // Restore page input state immediately; unrelated players remain unapproved.
            return nativeInput(() => {
              switch (action) {
                case 'play': allowUserPlayback(video); return Reflect.apply(play, video, []);
                case 'pause': video.pause(); return true;
                case 'mute': video.muted = true; return true;
                case 'unmute': video.muted = false; return true;
                case 'fullscreen':
                case 'pip': {
                  allowUserPlayback(video);
                  const selectedSource = source(video);
                  const present = () => {
                    if (!video.isConnected || source(video) !== selectedSource) return false;
                    return nativeInput(() => {
                      if (action === 'fullscreen') {
                        if (nativePresentation.has('webkitEnterFullscreen')) return Reflect.apply(nativePresentation.get('webkitEnterFullscreen'), video, []);
                        if (nativeRequestFullscreen) return Reflect.apply(nativeRequestFullscreen, video, []);
                      } else {
                        if (nativePresentation.has('webkitSetPresentationMode')) return Reflect.apply(nativePresentation.get('webkitSetPresentationMode'), video, ['picture-in-picture']);
                        if (video.requestPictureInPicture) return video.requestPictureInPicture();
                      }
                      return false;
                    });
                  };
                  // AVKit can remain stuck entering fullscreen when a metadata-only video
                  // has never rendered a frame. Explicit presentation may start playback;
                  // wait for play() before presenting that otherwise unloaded player.
                  return video.readyState < 2 ? Reflect.apply(play, video, []).then(present) : present();
                }
              }
              return false;
            });
          }
          Object.defineProperty(window, '__riseVideoPlayback', {value: Object.freeze({setAutoplay, performUserAction})});
          observe(document);
          // A frame may have been navigating when the preference changed, before it could
          // receive the broadcast. Reconcile with its parent as soon as its script starts.
          if (parent !== window) parent.postMessage({type: '__riseVideoAutoplayRequest'}, '*');
        })();
        """#
    }
}
