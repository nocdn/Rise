import WebKit

@MainActor extension YouTubePictureInPicture {
    static let script = #"""
    (() => {
      if (window.riseYouTubeVideo || !/(^|\.)youtube\.com$/.test(location.hostname) || location.protocol !== 'https:') return;
      let selected = null, active = false, token = '', scheduled = false, previous = '';
      let frameCount = 0, lastDraw = 0, frameInterval = 0;
      let width = 360, height = 202.5, pixelRatio = 2;
      const canvas = document.createElement('canvas');
      canvas.setAttribute('aria-hidden', 'true');
      const context = canvas.getContext('2d', {alpha:false});
      const post = body => window.webkit.messageHandlers.riseYouTubeVideo.postMessage({...body, href:location.href});
      const videoPage = () => (location.pathname === '/watch' && new URL(location.href).searchParams.get('v')) || /^\/(shorts|live|embed)\/.+/.test(location.pathname);
      const videos = () => [...document.querySelectorAll('video')];
      const choose = () => videos().filter(v => !v.paused && !v.ended && v.readyState >= 2)
        .sort((a,b) => (b.videoWidth*b.videoHeight)-(a.videoWidth*a.videoHeight))[0];
      const report = () => {
        scheduled = false;
        if (active && selected && !selected.isConnected) {
          const replacement = choose();
          if (replacement) { const id = token; exit(); enter(id, width, height, pixelRatio); }
        }
        const video = (active && selected?.isConnected ? selected : null) || choose() || videos()[0];
        const state = {hasVideo:!!video && !!videoPage(), playing:!!video && !video.paused && !video.ended && video.readyState >= 2, paused:video ? video.paused : true,
          ended:!!video?.ended, aspect:video?.videoWidth / video?.videoHeight || 16/9};
        const value = JSON.stringify({...state, href:location.href});
        if (value !== previous) { previous = value; post(state); }
      };
      const schedule = () => { if (!scheduled) { scheduled = true; setTimeout(report, 30); } };
      // YouTube mutates its DOM constantly. Watch for a replaced or removed
      // player only while it is floating; media events cover the rest.
      const observer = new MutationObserver(schedule);
      const exit = () => {
        canvas.remove(); observer.disconnect();
        active = false; token = ''; selected = null; frameCount = 0; lastDraw = 0; frameInterval = 0;
        // Release the backing store while the player is inline.
        canvas.width = 0; canvas.height = 0; schedule();
      };
      const resize = (w, h, ratio) => {
        if (![w,h,ratio].every(Number.isFinite) || w <= 0 || h <= 0) return;
        width = w; height = h; pixelRatio = Math.min(3, Math.max(1, ratio));
        if (!active) return;
        canvas.style.setProperty('width', `${width}px`, 'important');
        canvas.style.setProperty('height', `${height}px`, 'important');
        const pixelsWide = Math.max(1, Math.round(width*pixelRatio));
        const pixelsHigh = Math.max(1, Math.round(height*pixelRatio));
        if (canvas.width !== pixelsWide || canvas.height !== pixelsHigh) {
          canvas.width = pixelsWide; canvas.height = pixelsHigh;
        }
        draw(performance.now());
      };
      const draw = now => {
        if (!active || !selected || selected.readyState < 2 || !selected.videoWidth) return;
        try {
          const scale = Math.min(canvas.width/selected.videoWidth, canvas.height/selected.videoHeight);
          const w = selected.videoWidth*scale, h = selected.videoHeight*scale;
          context.fillStyle = 'black'; context.fillRect(0, 0, canvas.width, canvas.height);
          context.drawImage(selected, (canvas.width-w)/2, (canvas.height-h)/2, w, h);
          frameCount++;
          frameInterval = lastDraw ? Math.max(0, now-lastDraw) : 0;
          lastDraw = now;
          if (frameCount === 1) post({kind:'rendered', token, frames:frameCount});
        } catch { post({kind:'captureFailed', token}); exit(); }
      };
      const enter = (id, w, h, ratio) => {
        if (!videoPage()) return false;
        const video = choose();
        if (!video || document.fullscreenElement || (video.webkitPresentationMode && video.webkitPresentationMode !== 'inline')) return false;
        exit(); selected = video; active = true; token = id;
        // Overlay only the visible portion of the original viewport. Do not
        // resize or restyle YouTube's player, its ancestors, or the page.
        canvas.style.cssText = 'all:initial!important;display:block!important;position:fixed!important;left:0!important;top:0!important;margin:0!important;padding:0!important;border:0!important;background:black!important;pointer-events:none!important;z-index:2147483647!important;';
        document.documentElement.appendChild(canvas);
        observer.observe(document, {childList:true, subtree:true});
        resize(w,h,ratio); schedule(); return true;
      };
      const position = video => {
        const duration = video && Number.isFinite(video.duration) ? video.duration : 0;
        return {time:video?.currentTime || 0, duration};
      };
      window.riseYouTubeVideo = {enter, exit, resize, status:report,
        paint() {
          if (active && selected && !selected.paused) draw(performance.now());
          return {frames:frameCount, interval:frameInterval, ...position(selected)};
        },
        // A scrub uses fast keyframe seeks; its release lands exactly.
        seek(fraction, final) {
          const video = selected || choose() || videos()[0];
          if (!video || !Number.isFinite(video.duration) || !Number.isFinite(fraction)) return null;
          const time = Math.min(1, Math.max(0, fraction))*video.duration;
          if (!final && video.fastSeek) video.fastSeek(time); else video.currentTime = time;
          return {time, duration:video.duration};
        },
        canFloat() { const video = videoPage() && choose(); return video ? video.videoWidth/video.videoHeight || 16/9 : null; },
        pause() { (selected || choose())?.pause(); },
        togglePlayback() {
          const video = selected || choose() || videos()[0];
          if (!video) return null;
          if (video.paused) video.play().catch(() => {}); else video.pause();
          return video.paused;
        }
      };
      ['play','playing','pause','ended','loadedmetadata','emptied'].forEach(event => document.addEventListener(event, report, true));
      document.addEventListener('timeupdate', schedule, true);
      // The playback clock stops while paused; a seek still shows its frame.
      document.addEventListener('seeked', event => { if (active && event.target === selected) draw(performance.now()); }, true);
      ['yt-navigate-finish','yt-page-data-updated','popstate'].forEach(event => window.addEventListener(event, schedule));
      schedule();
    })();
    """#
}
