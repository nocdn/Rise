import Foundation

/// Firefox's Shift–right-click convention: keep Chromium's own hit testing and default
/// action, but prevent the site from substituting its menu. Installed before page scripts
/// in an isolated world, in every frame, including cross-origin and popup documents.
enum NativeContextMenuOverride {
    static let world = ScriptWorld.named("Rise.NativeContextMenu")
    static let source = #"""
    (() => {
      if (globalThis.riseNativeContextMenu) return;
      globalThis.riseNativeContextMenu = true;
      let forced = false;
      let changes = [];
      let restoreTimer = 0;
      function restoreHitTest() {
        clearTimeout(restoreTimer);
        changes.splice(0).reverse().forEach(restore => restore());
      }
      function pointerEvents(node, value) {
        const previous = node.style.getPropertyValue('pointer-events');
        const priority = node.style.getPropertyPriority('pointer-events');
        const original = node.getAttribute('style');
        node.style.setProperty('pointer-events', value, 'important');
        const applied = node.getAttribute('style');
        changes.push(() => {
          if (node.getAttribute('style') === applied) {
            if (original === null) node.removeAttribute('style'); else node.setAttribute('style', original);
            return;
          }
          // Do not overwrite a style the player changed while the menu was opening.
          if (node.style.getPropertyValue('pointer-events') !== value || node.style.getPropertyPriority('pointer-events') !== 'important') return;
          if (previous) node.style.setProperty('pointer-events', previous, priority);
          else node.style.removeProperty('pointer-events');
          if (original === null && !node.style.length) node.removeAttribute('style');
        });
      }
      function uncoverVideo(event) {
        if (event.composedPath().some(node => node instanceof HTMLVideoElement)) return;
        let video;
        // Some players also disable pointer events on the video itself. Only search
        // within a player-sized ancestor of the clicked control, never through a modal
        // or another unrelated part of the page for a video that happens to be behind it.
        for (const parent of event.composedPath()) {
          if (!(parent instanceof Element) || parent === document.body || parent === document.documentElement) break;
          const bounds = parent.getBoundingClientRect();
          video = [...parent.querySelectorAll('video')].find(candidate => {
            const r = candidate.getBoundingClientRect(), style = getComputedStyle(candidate);
            return r.width > 0 && r.height > 0 && event.clientX >= r.left && event.clientX < r.right &&
              event.clientY >= r.top && event.clientY < r.bottom && bounds.width <= r.width * 1.5 &&
              bounds.height <= r.height * 1.5 && style.visibility === 'visible' && style.opacity !== '0';
          });
          if (video) break;
        }
        if (!video) return;
        pointerEvents(video, 'auto');
        const stack = video.getRootNode().elementsFromPoint(event.clientX, event.clientY);
        const index = stack.indexOf(video);
        if (index < 0) { restoreHitTest(); return; }
        // Let Chromium's *next* hit test see the media, not the player's transparent
        // controls. This preserves the real native frame, referrer and blob download
        // context, instead of fabricating a media URL/menu in the app.
        for (const node of stack.slice(0, index)) if (!node.contains(video)) pointerEvents(node, 'none');
      }
      function intercept(event) {
        if (!event.isTrusted) return;
        if (event.type === 'pointerdown') restoreHitTest();
        if (event.type === 'pointerdown' || event.type === 'mousedown') {
          forced = event.button === 2 && event.shiftKey;
          if (forced && event.type === 'pointerdown') uncoverVideo(event);
        }
        if (event.button === 2 && (event.shiftKey || forced)) {
          // Do not preventDefault: Chromium must build the actual link/media/edit menu,
          // with its document permissions and download context, rather than a synthetic one.
          event.stopImmediatePropagation();
        }
        if (['contextmenu', 'pointerup', 'pointercancel'].includes(event.type)) {
          // The default context-menu action must finish its hit test before restoring
          // the controls. No styles remain changed while the native menu is in use.
          clearTimeout(restoreTimer);
          restoreTimer = setTimeout(restoreHitTest, 0);
        }
        if (event.type === 'auxclick' && event.button === 2) forced = false;
      }
      for (const type of ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'auxclick', 'contextmenu', 'pointercancel']) {
        window.addEventListener(type, intercept, {capture: true, passive: true});
      }
      window.addEventListener('blur', () => { forced = false; restoreHitTest(); });
    })();
    """#
}
