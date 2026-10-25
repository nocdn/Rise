import WebKit

/// Observes calls which WebKit may suppress before WKUIDelegate is called.
/// The page world is untrusted: these messages are diagnostic evidence only.
@MainActor enum PopupOpenObserver {
    static let marker = "// Rise.PopupOpenObserver\n"
    static let userScript = WKUserScript(source: marker+source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    static let source = #"""
    (() => {
      const original = window.open;
      if (typeof original !== 'function') return;
      const apply = Reflect.apply;
      let sequence = 0;
      const epoch = Math.random().toString(36).slice(2);
      const send = body => { try { window.webkit.messageHandlers.risePopupObserver.postMessage(body); } catch {} };
      window.open = new Proxy(original, {apply(target, receiver, args) {
        const id = epoch+':'+(++sequence);
        // Never coerce arguments: a website's custom toString must run only when
        // the original window.open would call it, with its original side effects.
        try {
        const value = typeof args[0] === 'string' ? args[0].slice(0,8192) : args.length ? null : '';
        const name = typeof args[1] === 'string' && ['_blank','_self','_parent','_top',''].includes(args[1].toLowerCase()) ? args[1].toLowerCase() : 'named';
        let url = value;
        try { if(value !== null) url = new URL(value || 'about:blank',document.baseURI).href.slice(0,8192); } catch {}
        let active = false;
        try { active = navigator.userActivation?.isActive === true; } catch {}
        send({phase:'attempt',id,url:url ?? '<non-string>',target:name,active:active?'true':'false'});
        } catch {}
        try {
          const result = apply(target,receiver,args);
          send({phase:'returned',id,handle:result === null ? 'null' : 'window'});
          return result;
        } catch(error) {
          try {
          const name = typeof error?.name === 'string' && /^[a-zA-Z]{1,40}$/.test(error.name) ? error.name : 'unknown';
          send({phase:'threw',id,error:name});
          } catch {}
          throw error;
        }
      }});
      send({phase:'ready',id:epoch});
    })();
    """#
}
