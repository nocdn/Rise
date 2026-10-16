
@MainActor extension VideoPictureInPicture {
    static let script = #"""
    (() => {
      if (window.risePictureInPicture) return;
      const top = window === window.top;
      // YouTube's own video pages float whatever they play. Anywhere else, and in
      // any frame, a video floats once it has played with sound, so muted previews
      // and background loops stay put.
      const watchPage = top && /(^|\.)youtube\.com$/.test(location.hostname) && location.protocol === 'https:';
      const frame = Math.random().toString(36).slice(2), key = '__risePictureInPicture';
      let selected = null, active = false, token = '', scheduled = false, previous = '', entries = 0;
      let frameCount = 0, lastDraw = 0, frameInterval = 0;
      let width = 360, height = 202.5, pixelRatio = 2, originX = 0, originY = 0, placed = false;
      const canvas = document.createElement('canvas');
      canvas.setAttribute('aria-hidden', 'true');
      const context = canvas.getContext('2d', {alpha:false});
      const post = body => riseHandlers.risePictureInPicture.postMessage({...body, frame, href:location.href});
      const videoPage = () => (location.pathname === '/watch' && new URL(location.href).searchParams.get('v')) || /^\/(shorts|live|embed)\/.+/.test(location.pathname);
      const heard = new WeakSet(), watched = new WeakSet();
      const mediaEvents = ['play','playing','pause','ended','loadedmetadata','emptied','volumechange'];
      // Players inside open shadow roots, found again every few seconds at most.
      let roots = [], rootsFound = -Infinity;
      const shadowRoots = () => {
        if (watchPage) return [];
        const now = performance.now();
        if (now-rootsFound < 2000) return roots;
        rootsFound = now; roots = [];
        const walk = root => {
          const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
          for (let node = walker.nextNode(); node; node = walker.nextNode()) if (node.shadowRoot) { roots.push(node.shadowRoot); walk(node.shadowRoot); }
        };
        walk(document);
        return roots;
      };
      const videos = () => {
        const found = [...document.querySelectorAll('video')];
        for (const root of shadowRoots()) for (const video of root.querySelectorAll('video')) {
          found.push(video);
          // Their media events stop at the shadow root.
          if (!watched.has(video)) {
            watched.add(video); mediaEvents.forEach(event => video.addEventListener(event, onMedia));
            video.addEventListener('timeupdate', onTime); video.addEventListener('seeked', onSeeked);
            video.addEventListener('encrypted', markEncrypted); video.addEventListener('webkitneedkey', markEncrypted);
          }
        }
        return found;
      };
      const playing = video => !video.paused && !video.ended && video.readyState >= 2;
      // Encrypted video draws as black. Players such as Vimeo's set up keys for every
      // video, so only media that has met encrypted data counts.
      const protectedVideos = new WeakSet();
      const encrypted = video => protectedVideos.has(video);
      const markEncrypted = event => { protectedVideos.add(event.target); schedule(); };
      const hear = video => { if (video instanceof HTMLVideoElement && playing(video) && !video.muted && video.volume > 0) heard.add(video); };
      // Media events miss video already playing in a shadow root when it's found, so
      // looking also hears it.
      const candidates = (withEncrypted = false) => videos().filter(video => {
        hear(video); return (withEncrypted || !encrypted(video)) && (watchPage || heard.has(video));
      });
      const largest = list => list.filter(playing).sort((a,b) => (b.videoWidth*b.videoHeight)-(a.videoWidth*a.videoHeight))[0];
      const choose = () => largest(candidates());
      // Encrypted video floats in Chromium's own picture in picture instead.
      const chooseEncrypted = () => largest(candidates(true).filter(encrypted));
      let nativeVideo = null;
      const floatable = () => !watchPage || !!videoPage();
      const report = () => {
        scheduled = false;
        if (active && selected && !selected.isConnected) {
          const replacement = choose();
          if (replacement) { const id = token; stop(); enter(id, width, height, pixelRatio); }
        }
        const video = (active && selected?.isConnected ? selected : null) || choose() || chooseEncrypted() || candidates()[0] || candidates(true)[0];
        const state = {hasVideo:!!video && floatable(), playing:!!video && playing(video), paused:video ? video.paused : true,
          ended:!!video?.ended, encrypted:!!video && encrypted(video), aspect:video?.videoWidth / video?.videoHeight || 16/9};
        const value = JSON.stringify({...state, href:location.href});
        // Frames that never had a video stay quiet; there are many, ads among them.
        if (value !== previous && (previous || state.hasVideo)) { previous = value; post(state); }
      };
      const schedule = () => { if (!scheduled) { scheduled = true; setTimeout(report, 30); } };
      const onMedia = event => { hear(event.target); report(); };
      const onTime = event => { hear(event.target); schedule(); };
      // The playback clock stops while paused; a seek still shows its frame.
      const onSeeked = event => { if (active && event.target === selected) draw(performance.now()); };
      // YouTube mutates its DOM constantly. Watch for a replaced or removed
      // player only while it is floating; media events cover the rest.
      const observer = new MutationObserver(schedule);
      const stop = () => {
        entries++;
        canvas.remove(); observer.disconnect();
        active = false; token = ''; selected = null; frameCount = 0; lastDraw = 0; frameInterval = 0;
        // Release the backing store while the player is inline.
        canvas.width = 0; canvas.height = 0; schedule();
      };
      const exit = () => { stop(); wantsLift = false; lower(); };

      // A video in a frame floats from that frame's viewport. Each frame above
      // it lifts the frame holding it over its own page, at its full viewport,
      // so the frame's viewport becomes the window's. Pages are left as they
      // were once the video is back.
      let lifted = null, liftedUp = false, wantsLift = false;
      const replies = new Map();
      const send = (target, body) => { try { target.postMessage({[key]: body}, '*'); } catch {} };
      const ask = () => new Promise(resolve => {
        const id = Math.random().toString(36).slice(2);
        const timer = setTimeout(() => { replies.delete(id); resolve(null); }, 1000);
        replies.set(id, size => { clearTimeout(timer); replies.delete(id); resolve(size); });
        send(parent, {type:'lift', id});
      });
      const frameElement = source => {
        const frames = [...document.querySelectorAll('iframe, frame'), ...shadowRoots().flatMap(root => [...root.querySelectorAll('iframe')])];
        return frames.find(element => element.contentWindow === source) || null;
      };
      const lift = element => {
        if (lifted?.element === element) return;
        drop();
        lifted = {element, style:element.getAttribute('style'), popover:element.getAttribute('popover')};
        element.setAttribute('popover', 'manual');
        element.style.cssText = 'position:fixed!important;inset:0 auto auto 0!important;width:100vw!important;height:100vh!important;' +
          'min-width:0!important;min-height:0!important;max-width:none!important;max-height:none!important;margin:0!important;padding:0!important;' +
          'border:0!important;transform:none!important;translate:none!important;scale:none!important;rotate:none!important;clip-path:none!important;' +
          'mask:none!important;filter:none!important;opacity:1!important;visibility:visible!important;display:block!important;' +
          'background:black!important;z-index:2147483647!important;';
        try { element.showPopover(); } catch {}
      };
      const drop = () => {
        if (!lifted) return;
        const {element, style, popover} = lifted; lifted = null;
        try { element.hidePopover(); } catch {}
        if (popover === null) element.removeAttribute('popover'); else element.setAttribute('popover', popover);
        if (style === null) element.removeAttribute('style'); else element.setAttribute('style', style);
      };
      const lower = () => { if (liftedUp) { liftedUp = false; send(parent, {type:'lower'}); } };
      // Lowers every frame from here down, and the canvas at the bottom.
      const release = () => {
        const child = lifted?.element.contentWindow;
        drop(); if (child) send(child, {type:'release'});
        stop(); liftedUp = false; wantsLift = false;
      };
      addEventListener('message', async event => {
        const body = event.data?.[key];
        if (!body || typeof body !== 'object') return;
        if (body.type === 'lift') {
          const element = frameElement(event.source);
          const size = !element ? null : top ? {width:innerWidth, height:innerHeight} : liftedUp ? {width:innerWidth, height:innerHeight} : await ask();
          if (element && size) { if (!top) liftedUp = true; lift(element); }
          // A frame inside a hidden container has no box even when lifted, so the page would show instead.
          if (element && size && !element.getClientRects().length) { drop(); lower(); send(event.source, {type:'lifted', id:body.id, size:null}); return; }
          send(event.source, {type:'lifted', id:body.id, size});
        } else if (body.type === 'lower') {
          if (lifted && lifted.element.contentWindow === event.source) { drop(); lower(); }
        } else if (event.source === parent && event.source !== window) {
          if (body.type === 'lifted') replies.get(body.id)?.(body.size);
          else if (body.type === 'release') release();
        }
      });

      // The canvas covers the whole viewport, so a new size never shows the
      // page around it while it paints. Each new size is drawn in the opposite
      // corner where it fits beside the last one, which stays intact until
      // Rise has switched to the new picture. Returns where it is drawn.
      const resize = (w, h, ratio) => {
        if (![w,h,ratio].every(Number.isFinite) || w <= 0 || h <= 0) return null;
        const previous = {x: originX, y: originY, w: width, h: height};
        width = w; height = h; pixelRatio = Math.min(3, Math.max(1, ratio));
        if (!active) return null;
        // innerWidth drops a zoomed viewport's fraction of a pixel, which the visual viewport keeps.
        const view = visualViewport ?? {width: innerWidth, height: innerHeight};
        const viewWidth = Math.max(width, innerWidth, view.width), viewHeight = Math.max(height, innerHeight, view.height);
        canvas.style.setProperty('width', `${viewWidth}px`, 'important');
        canvas.style.setProperty('height', `${viewHeight}px`, 'important');
        const pixelsWide = Math.max(1, Math.round(viewWidth*pixelRatio));
        const pixelsHigh = Math.max(1, Math.round(viewHeight*pixelRatio));
        let cleared = false;
        if (canvas.width !== pixelsWide || canvas.height !== pixelsHigh) {
          canvas.width = pixelsWide; canvas.height = pixelsHigh; cleared = true;
        }
        const apart = (x, y) => x >= previous.x+previous.w || x+width <= previous.x || y >= previous.y+previous.h || y+height <= previous.y;
        const corners = [{x:0, y:0}, {x:viewWidth-width, y:viewHeight-height}];
        const other = corners.find(c => (c.x !== previous.x || c.y !== previous.y) && apart(c.x, c.y));
        const next = !placed || cleared ? corners[0] : other || corners[0];
        originX = next.x; originY = next.y; placed = true;
        draw(performance.now());
        return {x: originX, y: originY};
      };
      const draw = now => {
        if (!active || !selected || selected.readyState < 2 || !selected.videoWidth) return;
        try {
          const left = Math.round(originX*pixelRatio), top = Math.round(originY*pixelRatio);
          const areaWidth = Math.min(canvas.width-left, Math.round(width*pixelRatio));
          const areaHeight = Math.min(canvas.height-top, Math.round(height*pixelRatio));
          const scale = Math.min(areaWidth/selected.videoWidth, areaHeight/selected.videoHeight);
          const w = selected.videoWidth*scale, h = selected.videoHeight*scale;
          context.fillStyle = 'black'; context.fillRect(left, top, areaWidth, areaHeight);
          context.drawImage(selected, left+(areaWidth-w)/2, top+(areaHeight-h)/2, w, h);
          frameCount++;
          frameInterval = lastDraw ? Math.max(0, now-lastDraw) : 0;
          lastDraw = now;
          if (frameCount === 1) post({kind:'rendered', token, frames:frameCount});
        } catch { post({kind:'captureFailed', token}); exit(); }
      };
      const enter = async (id, w, h, ratio) => {
        if (!floatable()) return false;
        const video = choose();
        if (!video || document.fullscreenElement || document.querySelector('[data-rise-fullscreen]') || document.pictureInPictureElement) return false;
        stop();
        const entry = entries;
        if (!top) {
          wantsLift = true;
          const size = liftedUp ? {width:innerWidth, height:innerHeight} : await ask();
          if (size) liftedUp = true;
          // Left while waiting: put the frame back down.
          if (!wantsLift) lower();
          if (entry !== entries || !size) return false;
          // The lifted frame takes a moment to reach the viewport's size.
          for (let i = 0; i < 30 && (Math.abs(innerWidth-size.width) > 1 || Math.abs(innerHeight-size.height) > 1); i++) {
            await new Promise(resolve => setTimeout(resolve, 16));
          }
          if (entry !== entries) return false;
        }
        selected = video; active = true; token = id; placed = false; originX = 0; originY = 0;
        // Overlay only the visible portion of the original viewport. Do not
        // resize or restyle the player, its ancestors, or the page.
        canvas.style.cssText = 'all:initial!important;display:block!important;position:fixed!important;left:0!important;top:0!important;margin:0!important;padding:0!important;border:0!important;background:black!important;pointer-events:none!important;z-index:2147483647!important;';
        document.documentElement.appendChild(canvas);
        observer.observe(document, {childList:true, subtree:true});
        resize(w,h,ratio); schedule(); return true;
      };
      const position = video => {
        const duration = video && Number.isFinite(video.duration) ? video.duration : 0;
        return {time:video?.currentTime || 0, duration};
      };
      const current = () => selected || choose() || candidates()[0];
      window.risePictureInPicture = {enter, exit, release, resize, status:report,
        paint() {
          if (active && selected && !selected.paused) draw(performance.now());
          return {frames:frameCount, interval:frameInterval, ...position(selected)};
        },
        // A scrub uses fast keyframe seeks; its release lands exactly.
        seek(fraction, final) {
          const video = current();
          if (!video || !Number.isFinite(video.duration) || !Number.isFinite(fraction)) return null;
          const time = Math.min(1, Math.max(0, fraction))*video.duration;
          if (!final && video.fastSeek) video.fastSeek(time); else video.currentTime = time;
          return {time, duration:video.duration};
        },
        // Why each video would or wouldn't float, for diagnosing a site.
        describe() {
          return videos().map(video => ({heard:heard.has(video), encrypted:encrypted(video), playing:playing(video), muted:video.muted,
            volume:video.volume, size:`${video.videoWidth}x${video.videoHeight}`, chosen:video === choose(), floatable:floatable()}));
        },
        canFloat() { const video = floatable() && choose(); return video ? {aspect:video.videoWidth/video.videoHeight || 16/9, frame} : null; },
        pause() { (selected || choose())?.pause(); },
        enterNative() {
          const video = floatable() && chooseEncrypted();
          if (!video) return false;
          // The standard picture in picture, Chromium's own window.
          if (!document.pictureInPictureEnabled || video.disablePictureInPicture || document.pictureInPictureElement === video) return false;
          video.requestPictureInPicture().catch(() => { if (nativeVideo === video) nativeVideo = null; });
          nativeVideo = video; return true;
        },
        exitNative(pause) {
          const video = nativeVideo; nativeVideo = null;
          if (!video) return;
          if (pause) video.pause();
          // Leaving it, the video carries on playing in the page.
          if (document.pictureInPictureElement === video) document.exitPictureInPicture().catch(() => {});
        },
        togglePlayback() {
          const video = current();
          if (!video) return null;
          if (video.paused) video.play().catch(() => {}); else video.pause();
          return video.paused;
        }
      };
      mediaEvents.forEach(event => document.addEventListener(event, onMedia, true));
      document.addEventListener('timeupdate', onTime, true);
      document.addEventListener('seeked', onSeeked, true);
      ['encrypted', 'webkitneedkey'].forEach(event => document.addEventListener(event, markEncrypted, true));
      ['yt-navigate-finish','yt-page-data-updated','popstate'].forEach(event => window.addEventListener(event, schedule));
      addEventListener('pagehide', () => { if (previous) post({hasVideo:false}); previous = ''; });
      addEventListener('pageshow', event => { if (event.persisted) schedule(); });
      schedule();
    })();
    """#
}
