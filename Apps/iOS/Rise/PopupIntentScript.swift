import WebKit

@MainActor enum PopupIntentScript {
    static let marker = "// Rise.PopupIntent\n"
    static let world = WKContentWorld.world(name: "Rise.PopupIntent")
    static let userScript = WKUserScript(source: marker + source, injectionTime: .atDocumentStart,
                                         forMainFrameOnly: false, in: world)
    // Capture intent before page handlers can rewrite links. The isolated world is
    // essential: page JavaScript cannot forge messages or mark synthetic clicks trusted.
    static let source = #"""
    (() => {
      const send = window.webkit.messageHandlers.risePopupIntent.postMessage.bind(window.webkit.messageHandlers.risePopupIntent);
      let current = null, sequence = 0;
      const epoch = Math.random().toString(36).slice(2);
      function describe(event) {
        const path = event.composedPath();
        const elements = path.filter(e => e instanceof Element);
        const link = elements.find(e => e.matches('a[href],area[href]'));
        if (link) {
          const rect = link.getBoundingClientRect(), style = getComputedStyle(link);
          const empty = !link.textContent.trim() && !link.querySelector('img,svg,picture') && !link.getAttribute('aria-label');
          const overlay = rect.width * rect.height > innerWidth * innerHeight * 0.6 && (empty || Number(style.opacity) < 0.1);
          return {kind: overlay ? 'none' : 'link', href: link.href, method: '', reason:overlay?'large_invisible_overlay':'link', node:link.localName, element: link};
        }
        const control = elements.find(e => e.matches('button,input,select,[role="button"],[role="link"]'));
        if (!control || control.disabled) return {kind:'none', href:'', method:'', reason:control?'disabled_control':'generic_content', node:elements[0]?.localName || '', element:elements[0]};
        const form = control.form;
        const submits = form && (control.matches('button:not([type]),button[type="submit"],input[type="submit"],input[type="image"]') || event.type === 'keydown' && event.key === 'Enter');
        if (submits) {
          const action = control.hasAttribute('formaction') ? control.formAction : form.action;
          return {kind:'form', href:action, method:(control.getAttribute('formmethod') || form.method || 'get').toLowerCase(), reason:'form_submit', node:control.localName, element:control};
        }
        if (control.matches('input:not([type="button"]),select')) return {kind:'none',href:'',method:'',reason:'non_action_input',node:control.localName,element:control};
        return {kind:'button',href:'',method:'',reason:'action_button',node:control.localName,element:control};
      }
      function capture(event) {
        if (!event.isTrusted || event.type === 'keydown' && !['Enter',' '].includes(event.key)) return;
        if ('button' in event && event.button !== 0 && event.button !== 1) return;
        const next = describe(event), now = performance.now();
        // pointerdown and its click share one allowance and the original URL, even
        // if the website rewrites href, target or formAction between those events.
        if (event.type !== 'click' || !current || now-current.time > 1800 || current.element !== next.element) {
          current = {...next, time:now, id:epoch+':'+(++sequence)};
        }
        send({id:current.id, kind:current.kind, href:current.href, method:current.method, reason:current.reason, node:current.node, event:event.type});
      }
      for (const type of ['pointerdown','click','keydown']) window.addEventListener(type,capture,true);
    })();
    """#
}
