// Runs only in Rise's isolated content world; never inserts HTML or changes navigation/forms.
(() => {
  if (globalThis.__riseTranslation) { globalThis.__riseTranslation.report(); return; }
  const id = globalThis.crypto?.randomUUID?.() || Date.now().toString(36)+Math.random().toString(36), records = new Map(), roots = new Set();
  let keys = new WeakMap();
  const skip = 'script,style,noscript,code,pre,kbd,samp,textarea,input,select,option,svg,math,[translate="no"],.notranslate,[contenteditable]:not([contenteditable="false"])';
  const attributes = ['title', 'alt', 'placeholder', 'aria-label'];
  let enabled = false, counter = 0, timer, revision = 0;
  const post = body => { try { webkit.messageHandlers.risePageTranslation.postMessage({...body, document: id}); } catch (_) {} };
  const raw = r => r.attribute ? r.node.getAttribute(r.attribute) : r.node.data;
  const write = (r, value) => { if (r.attribute) r.node.setAttribute(r.attribute, value); else r.node.data = value; };
  function eligible(element) {
    if (!element || element.closest(skip)) return false;
    const tagged = element.closest('[lang]');
    return !(tagged && tagged !== document.documentElement && /^en(?:-|$)/i.test(tagged.lang));
  }
  function remember(node, attribute) {
    const value = attribute ? node.getAttribute(attribute) : node.data;
    if (!value || !/\p{L}/u.test(value) || value.trim().length < 2 || value.length > 6000) return;
    let values = keys.get(node);
    if (!values) { values = new Map(); keys.set(node, values); }
    const key = attribute || '#text';
    let record = values.get(key);
    if (record && (record.original === value || record.translated === value)) return;
    if (!record) {
      record = {id: String(++counter), node, attribute};
      values.set(key, record); records.set(record.id, record);
    }
    record.original = value; record.translated = null; record.pending = false;
  }
  function scan(root) {
    if (!root || !enabled) return;
    if (root.nodeType === Node.TEXT_NODE) { if (eligible(root.parentElement)) remember(root); return; }
    if (root.nodeType === Node.ELEMENT_NODE && !eligible(root)) return;
    if (root.nodeType === Node.ELEMENT_NODE) {
      for (const name of attributes) if (root.hasAttribute(name)) remember(root, name);
      if (root.shadowRoot) scan(root.shadowRoot);
    }
    observe(root);
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
      acceptNode(node) {
        if (!eligible(node.nodeType === Node.TEXT_NODE ? node.parentElement : node)) return NodeFilter.FILTER_REJECT;
        return NodeFilter.FILTER_ACCEPT;
      }
    });
    while (walker.nextNode()) {
      const node = walker.currentNode;
      if (node.nodeType === Node.TEXT_NODE) remember(node);
      else {
        for (const name of attributes) if (node.hasAttribute(name)) remember(node, name);
        if (node.shadowRoot) scan(node.shadowRoot);
      }
    }
  }
  function report() {
    if (enabled) return;
    post({kind: 'ready', language: document.documentElement.lang || document.querySelector('meta[http-equiv="content-language" i]')?.content || '',
          sample: (document.body?.innerText || '').slice(0, 6000)});
  }
  function flush() {
    timer = null;
    if (!enabled) { report(); roots.clear(); return; }
    for (const root of roots) if (root.isConnected) scan(root);
    roots.clear();
    if ([...records.values()].some(r => !r.pending && r.translated === null && r.node.isConnected)) post({kind: 'work'});
  }
  const observer = new MutationObserver(changes => {
    for (const change of changes) {
      if (change.type === 'childList') { for (const node of change.addedNodes) roots.add(node); }
      else roots.add(change.target);
    }
    if (!timer) timer = setTimeout(flush, enabled ? 120 : 400);
  });
  const watched = new WeakSet();
  function observe(root) {
    if (watched.has(root) || (root !== document && !(root instanceof ShadowRoot))) return;
    watched.add(root);
    observer.observe(root, {subtree: true, childList: true, characterData: true, attributes: true, attributeFilter: [...attributes, 'lang']});
  }
  let originalLanguage, originalDirection, bodyDirection;
  function restoreAttribute(node, name, value) { if (!node) return; if (value === null) node.removeAttribute(name); else node.setAttribute(name, value); }
  globalThis.__riseTranslation = {
    id, report,
    enable(value, version) {
      if (version < revision) return;
      revision = version;
      if (enabled === value) return;
      enabled = value;
      if (value) {
        originalLanguage = document.documentElement.getAttribute('lang');
        originalDirection = document.documentElement.getAttribute('dir');
        bodyDirection = document.body?.getAttribute('dir') ?? null;
        scan(document.body);
        document.documentElement.lang = 'en'; document.documentElement.dir = 'ltr';
        if (document.body) document.body.dir = 'ltr';
      } else {
        for (const r of records.values()) if (r.node.isConnected && r.translated !== null && raw(r) === r.translated) write(r, r.original);
        records.clear(); roots.clear(); keys = new WeakMap();
        restoreAttribute(document.documentElement, 'lang', originalLanguage);
        restoreAttribute(document.documentElement, 'dir', originalDirection);
        restoreAttribute(document.body, 'dir', bodyDirection);
      }
    },
    take() {
      let length = 0; const batch = [];
      for (const r of records.values()) {
        if (!r.node.isConnected) { records.delete(r.id); continue; }
        if (r.pending || r.translated !== null) continue;
        if (raw(r) !== r.original) { r.original = raw(r); if (!r.original) continue; }
        const text = r.original.trim();
        if (batch.length && (batch.length >= 48 || length + text.length > 10000)) break;
        r.pending = true; length += text.length; batch.push({id:r.id, text, original:r.original});
      }
      return batch;
    },
    apply(batch, version) {
      if (!enabled || revision !== version) return;
      for (const item of batch) {
        const r = records.get(item.id);
        if (!r || !r.node.isConnected || r.original !== item.original || raw(r) !== r.original) continue;
        const leading = r.original.match(/^\s*/)[0], trailing = r.original.match(/\s*$/)[0];
        r.translated = leading + item.text + trailing; r.pending = false; write(r, r.translated);
      }
    }
  };
  observe(document); report();
  // A restored back/forward-cache document starts in its original language, like a fresh
  // navigation. Otherwise WebKit can restore translated DOM after native state has reset.
  addEventListener('pagehide', () => globalThis.__riseTranslation.enable(false, revision + 1));
  addEventListener('pageshow', report);
})();
