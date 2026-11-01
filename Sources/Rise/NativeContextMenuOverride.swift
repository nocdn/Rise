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
      function intercept(event) {
        if (!event.isTrusted) return;
        if (event.type === 'pointerdown' || event.type === 'mousedown') {
          forced = event.button === 2 && event.shiftKey;
        }
        if (event.button === 2 && (event.shiftKey || forced)) {
          // Do not preventDefault: Chromium must build the actual link/media/edit menu,
          // with its document permissions and download context, rather than a synthetic one.
          event.stopImmediatePropagation();
        }
        if (event.type === 'auxclick' && event.button === 2) forced = false;
      }
      for (const type of ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'auxclick', 'contextmenu']) {
        window.addEventListener(type, intercept, {capture: true, passive: true});
      }
      window.addEventListener('blur', () => { forced = false; });
    })();
    """#
}
