import Foundation

/// The script the chat's model uses pages through, run in a script world of Rise's the page's own
/// scripts can't see (`AIChatPageDriver`). It reads a page as an outline of what's on it, in
/// order: headings, text, and each link, button, field and control with a ref such as `e12`,
/// which stays the element's for as long as the page has it, so refs from an earlier look still
/// work after the page changes around them. It finds where an element is to click it (scrolled
/// into view, and not under something else), readies fields to be typed into, chooses options,
/// scrolls the page or a part of it, and waits for the page to settle after each act.
///
/// Inputs reach the page as the person's own, through DevTools; the script only finds and readies.
enum AIChatPageScript {
    static let world = "Rise.Agent"

    /// A call to `op` on the script, defining it first in a page that hasn't had it, taking `args`.
    static func call(_ op: String) -> String { library+"\nreturn await globalThis.__riseAgent.\(op)(args);" }

    static let library = #"""
    globalThis.__riseAgent ??= (() => {
      const state = { next: 1, refs: new Map(), ids: new WeakMap() };
      const clean = s => (s || '').replace(/\s+/g, ' ').trim();
      const cut = (s, n) => s.length > n ? s.slice(0, n - 1) + '…' : s;
      const quote = s => '"' + s.replace(/"/g, '\\"') + '"';

      function refOf(el) {
        let id = state.ids.get(el);
        if (!id) { id = 'e' + state.next++; state.ids.set(el, id); }
        state.refs.set(id, new WeakRef(el));
        return id;
      }
      function element(id) {
        const el = state.refs.get(String(id || '').replace(/^\[|\]$/g, ''))?.deref();
        return el && el.isConnected ? el : null;
      }

      // Roles, as the platform gives them, for the elements that have one worth naming.
      const interactiveRoles = new Set(['button', 'link', 'textbox', 'searchbox', 'combobox', 'checkbox', 'radio', 'switch',
        'slider', 'spinbutton', 'tab', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'option', 'treeitem', 'listbox']);
      const containerRoles = new Set(['navigation', 'main', 'dialog', 'alertdialog', 'form', 'search', 'list', 'table', 'grid',
        'menu', 'menubar', 'tablist', 'toolbar', 'tree', 'banner', 'contentinfo', 'complementary', 'region', 'group', 'radiogroup']);
      const nameFromContent = new Set(['button', 'link', 'heading', 'tab', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'option',
        'checkbox', 'radio', 'switch', 'treeitem', 'cell', 'columnheader', 'rowheader', 'clickable', 'draggable']);
      const skipped = new Set(['script', 'style', 'noscript', 'template', 'head', 'meta', 'link', 'base']);
      const textTypes = ['text', 'email', 'tel', 'url', 'password', 'search', 'number', ''];
      const valueTypes = ['date', 'time', 'datetime-local', 'month', 'week', 'color', 'range'];

      function inputType(el) { return el.localName === 'input' ? (el.getAttribute('type') || 'text').toLowerCase() : ''; }
      function role(el) {
        const given = clean(el.getAttribute('role')).split(' ')[0].toLowerCase();
        if (given && given !== 'presentation' && given !== 'none' && given !== 'generic') return given;
        if (el.getAttribute('aria-modal') === 'true') return 'dialog';
        switch (el.localName) {
          case 'a': case 'area': return el.hasAttribute('href') ? 'link' : '';
          case 'button': case 'summary': return 'button';
          case 'select': return el.multiple || el.size > 1 ? 'listbox' : 'combobox';
          case 'textarea': return 'textbox';
          case 'input': {
            const type = inputType(el);
            const roles = { button: 'button', submit: 'button', reset: 'button', image: 'button', file: 'button', checkbox: 'checkbox',
              radio: 'radio', range: 'slider', number: 'spinbutton', search: 'searchbox', hidden: '' };
            return type in roles ? roles[type] : 'textbox';
          }
          case 'h1': case 'h2': case 'h3': case 'h4': case 'h5': case 'h6': return 'heading';
          case 'img': return clean(el.getAttribute('alt')) ? 'img' : '';
          case 'nav': return 'navigation';
          case 'main': return 'main';
          case 'dialog': return el.open ? 'dialog' : '';
          case 'form': return clean(el.getAttribute('aria-label')) || el.getAttribute('aria-labelledby') ? 'form' : '';
          case 'ul': case 'ol': return 'list';
          case 'table': return 'table';
          case 'tr': return 'row';
          case 'iframe': case 'frame': return 'iframe';
          case 'video': return 'video';
          case 'audio': return 'audio';
          case 'option': return 'option';
        }
        const editable = el.getAttribute('contenteditable');
        if (editable !== null && editable !== 'false') return 'textbox';
        return '';
      }
      function textOf(node) { return clean(node.innerText ?? node.textContent); }
      function name(el, r) {
        const doc = el.ownerDocument;
        const by = el.getAttribute('aria-labelledby');
        if (by) {
          const text = clean(by.split(/\s+/).map(id => { const target = doc.getElementById(id); return target ? textOf(target) : ''; }).join(' '));
          if (text) return text;
        }
        const label = clean(el.getAttribute('aria-label'));
        if (label) return label;
        const tag = el.localName, type = inputType(el);
        if (tag === 'input' && ['button', 'submit', 'reset'].includes(type)) return clean(el.value) || (type === 'submit' ? 'Submit' : type === 'reset' ? 'Reset' : '');
        if (tag === 'input' && type === 'image') return clean(el.alt) || 'Submit';
        if (el.labels && el.labels.length) {
          const text = clean([...el.labels].map(textOf).join(' '));
          if (text) return text;
        }
        if (tag === 'img' || tag === 'area') return clean(el.getAttribute('alt')) || clean(el.title);
        if (tag === 'iframe' || tag === 'frame') return clean(el.title);
        if (['input', 'textarea', 'select'].includes(tag)) {
          return clean(el.getAttribute('placeholder')) || clean(el.getAttribute('aria-placeholder')) || clean(el.title);
        }
        if (nameFromContent.has(r) || r === 'textbox' && el.isContentEditable) {
          let text = r === 'textbox' ? '' : textOf(el);
          if (!text) text = clean([...el.querySelectorAll('img[alt], [aria-label]')].map(node => node.getAttribute('alt') || node.getAttribute('aria-label')).join(' '));
          if (!text) text = clean(el.querySelector('svg title')?.textContent);
          if (!text) text = clean(el.getAttribute('placeholder') || el.getAttribute('aria-placeholder'));
          return text || clean(el.title);
        }
        return clean(el.title);
      }

      // Where an element is on the page in front, through the frames it's in.
      function topRect(el) {
        const rect = el.getBoundingClientRect();
        let x = rect.left, y = rect.top, view = el.ownerDocument.defaultView;
        while (view && view.frameElement) {
          const frame = view.frameElement, outer = frame.getBoundingClientRect(), style = getComputedStyle(frame);
          x += outer.left + parseFloat(style.borderLeftWidth) + parseFloat(style.paddingLeft);
          y += outer.top + parseFloat(style.borderTopWidth) + parseFloat(style.paddingTop);
          view = view.parent;
        }
        return { x, y, width: rect.width, height: rect.height };
      }
      function kids(node) {
        if (node.shadowRoot) return node.shadowRoot.childNodes;
        if (node.localName === 'slot') { const given = node.assignedNodes({ flatten: true }); return given.length ? given : node.childNodes; }
        if ((node.localName === 'iframe' || node.localName === 'frame')) {
          try { return node.contentDocument?.body ? [node.contentDocument.body] : []; } catch { return []; }
        }
        return node.childNodes;
      }
      function isClickable(el, style, parentStyle) {
        if (el.hasAttribute('onclick')) return true;
        if (el.hasAttribute('tabindex') && el.tabIndex >= 0 && !['body', 'html'].includes(el.localName)) return true;
        return style.cursor === 'pointer' && parentStyle?.cursor !== 'pointer' && !['html', 'body', 'label'].includes(el.localName);
      }
      const interactiveSelector = 'a[href], button, input:not([type=hidden]), select, textarea, summary, [role], [onclick], [tabindex], [contenteditable]';
      function hasInteractive(el) {
        try { return !!el.querySelector(interactiveSelector) || !!el.shadowRoot; } catch { return false; }
      }
      function masked(el) {
        const auto = (el.getAttribute('autocomplete') || '').toLowerCase();
        return inputType(el) === 'password' || auto.startsWith('cc-') || auto.includes('one-time-code') || auto.includes('current-password') || auto.includes('new-password');
      }
      function states(el, r) {
        const out = [];
        const aria = n => el.getAttribute('aria-' + n);
        if (el.disabled || aria('disabled') === 'true') out.push('disabled');
        if (['checkbox', 'radio', 'switch', 'menuitemcheckbox', 'menuitemradio'].includes(r)) {
          const checked = el.localName === 'input' ? el.checked : aria('checked') === 'true';
          out.push(checked ? 'checked' : aria('checked') === 'mixed' || el.indeterminate ? 'mixed' : 'not checked');
        }
        if (aria('expanded') === 'true') out.push('expanded'); else if (aria('expanded') === 'false') out.push('collapsed');
        if (aria('selected') === 'true' || el.localName === 'option' && el.selected) out.push('selected');
        if (aria('pressed') === 'true') out.push('pressed');
        if (aria('current') && aria('current') !== 'false') out.push('current');
        if (el.required || aria('required') === 'true') out.push('required');
        if (el.readOnly || aria('readonly') === 'true') out.push('read-only');
        if (aria('invalid') === 'true') out.push('invalid');
        if (r === 'heading') { const level = /^h([1-6])$/.exec(el.localName)?.[1] || aria('level'); if (level) out.push('level ' + level); }
        const active = deepActive();
        if (active === el) out.push('focused');
        return out;
      }
      function value(el, r) {
        if (el.localName === 'select') {
          const chosen = [...el.selectedOptions].map(o => clean(o.label)).join(', ');
          const options = [...el.options].slice(0, 25).map(o => clean(o.label));
          return { value: chosen, extra: 'options: ' + options.join(' | ') + (el.options.length > 25 ? ' | …' + (el.options.length - 25) + ' more' : '') };
        }
        if (el.localName === 'input' || el.localName === 'textarea') {
          const type = inputType(el);
          if (['checkbox', 'radio', 'button', 'submit', 'reset', 'image'].includes(type)) return null;
          if (type === 'file') return { value: el.files?.length ? [...el.files].map(f => f.name).join(', ') : 'no file chosen' };
          if (!el.value) return null;
          return { value: masked(el) ? '•••••••• (hidden)' : cut(clean(el.value), 200) };
        }
        if (r === 'textbox' && el.isContentEditable) { const text = clean(el.innerText); return text ? { value: cut(text, 300) } : null; }
        if (['slider', 'spinbutton', 'progressbar'].includes(r) && el.getAttribute('aria-valuenow')) {
          return { value: clean(el.getAttribute('aria-valuetext') || el.getAttribute('aria-valuenow')) };
        }
        return null;
      }
      function deepActive() {
        let active = document.activeElement;
        while (active) {
          if (active.shadowRoot?.activeElement) { active = active.shadowRoot.activeElement; continue; }
          if ((active.localName === 'iframe' || active.localName === 'frame')) {
            try { const inner = active.contentDocument?.activeElement; if (inner && inner !== active.contentDocument.body) { active = inner; continue; } } catch {}
          }
          break;
        }
        return active;
      }
      function shortURL(href) {
        try {
          const url = new URL(href, location.href);
          if (url.protocol === 'javascript:') return '';
          const query = url.search.length > 60 ? url.search.slice(0, 59) + '…' : url.search;
          if (url.origin === location.origin) return cut(url.pathname + query + url.hash, 120);
          return cut(url.origin + url.pathname + query, 120);
        } catch { return ''; }
      }

      // The page's outline: a line per thing on it, indented under the parts that hold them.
      function outline(root) {
        const lines = [];
        let buffer = '', bufferRect = null, bufferDepth = 0;
        const viewW = innerWidth, viewH = innerHeight;
        function place(rect) {
          if (!rect) return 'in';
          if (rect.y + rect.height <= 0) return 'above';
          if (rect.y >= viewH) return 'below';
          return 'in';
        }
        function emit(text, depth, rect, el) { lines.push({ text, depth, where: place(rect), el }); }
        function fileLine(el, hidden) {
          const label = cut(clean(el.labels?.[0]?.innerText || el.getAttribute('aria-label') || el.title || el.name || ''), 80);
          const notes = [];
          if (hidden) notes.push('hidden');
          if (el.disabled) notes.push('disabled');
          if (el.webkitdirectory) notes.push('takes a folder'); else if (el.multiple) notes.push('takes several files');
          if (el.accept) notes.push('accepts ' + cut(el.accept, 60));
          const chosen = [...(el.files || [])].map(f => f.name);
          if (chosen.length) notes.push('holds ' + cut(chosen.join(', '), 120));
          return 'file field' + (label ? ' ' + quote(label) : '') + ' [' + refOf(el) + ']' + (notes.length ? ' (' + notes.join(', ') + ')' : '') + ' — upload_file gives it files';
        }
        function flush() {
          const text = clean(buffer);
          if (text) emit('text: ' + cut(text, 400), bufferDepth, bufferRect);
          buffer = ''; bufferRect = null;
        }
        function addText(text, depth, rect) {
          if (!text) return;
          if (!buffer) { bufferDepth = depth; bufferRect = rect; }
          buffer += text;
        }
        function visit(node, depth, parentStyle) {
          if (node.nodeType === Node.TEXT_NODE) {
            const parent = node.parentElement;
            if (parent && getComputedStyle(parent).visibility !== 'visible') return;
            addText(node.data.replace(/\s+/g, ' '), depth, parent ? topRect(parent) : null);
            return;
          }
          if (node.nodeType === Node.DOCUMENT_FRAGMENT_NODE || node.nodeType === Node.DOCUMENT_NODE) {
            for (const child of node.childNodes) visit(child, depth, parentStyle);
            return;
          }
          if (node.nodeType !== Node.ELEMENT_NODE) return;
          const el = node, tag = el.localName;
          if (skipped.has(tag) || el.getAttribute('aria-hidden') === 'true' || el.inert || tag === 'input' && inputType(el) === 'hidden') return;
          if (tag === 'svg' && !el.getAttribute('aria-label') && !el.getAttribute('role')) return;
          if (tag === 'br') { addText(' ', depth, null); return; }
          const style = getComputedStyle(el);
          // A file field, shown or not: most sites hide theirs behind a button of their own.
          if (tag === 'input' && inputType(el) === 'file') {
            const own = el.getBoundingClientRect();
            const hidden = style.display === 'none' || style.visibility !== 'visible' || parseFloat(style.opacity) < 0.05 || own.width < 2 || own.height < 2;
            const shown = hidden ? (el.labels?.[0] || el.parentElement) : el;
            flush();
            emit(fileLine(el, hidden), depth, shown ? topRect(shown) : null, el);
            return;
          }
          if (style.display === 'none') return;
          if (tag === 'dialog' && !el.open) return;
          // See-through: hidden, as menus waiting to fade in are, but for a box drawn by its label.
          if (parseFloat(style.opacity) === 0 && !(tag === 'input' && el.labels?.length)) return;
          // Hidden itself, though a part of it may show.
          if (style.visibility !== 'visible' && !(tag === 'input' && el.labels?.length)) { for (const child of kids(el)) visit(child, depth, style); return; }
          const rect = topRect(el);
          const box = style.display !== 'contents';
          // Placed off the page, as menus waiting to open are.
          if (box && (rect.x + rect.width <= -window.scrollX - 1 || rect.y + rect.height <= -window.scrollY - 1)) return;
          if (box && rect.width === 0 && rect.height === 0 && style.overflow === 'hidden') return;
          let r = role(el);
          // Picked up and moved, as cards and list items to put in order are.
          const draggable = !interactiveRoles.has(r) && !containerRoles.has(r) && r !== 'heading' && r !== 'img' && tag !== 'a'
            && (el.getAttribute('draggable') === 'true' || /^(grab|move)$/.test(style.cursor) && parentStyle?.cursor !== style.cursor);
          const clickable = draggable || !interactiveRoles.has(r) && !containerRoles.has(r) && r !== 'heading' && isClickable(el, style, parentStyle);
          if (draggable) r = 'draggable';
          else if (clickable && !r) r = 'clickable';
          const inline = style.display.startsWith('inline') && !interactiveRoles.has(r) && !clickable && !containerRoles.has(r)
            && r !== 'heading' && r !== 'img' && r !== 'iframe' && r !== 'row';
          if (inline) { for (const child of kids(el)) visit(child, depth, style); return; }
          flush();
          // A box clicked as a whole that holds controls of its own is a wrapper: its controls are what's used.
          if (clickable && !draggable && hasInteractive(el)) { for (const child of kids(el)) visit(child, depth, style); flush(); return; }
          if (interactiveRoles.has(r) || clickable) {
            const id = refOf(el), label = cut(name(el, r), 120), extras = states(el, r), current = value(el, r);
            let line = r + (label ? ' ' + quote(label) : '') + ' [' + id + ']';
            if (current?.value) line += ': ' + current.value;
            if (extras.length) line += ' (' + extras.join(', ') + ')';
            if (current?.extra) line += ' (' + current.extra + ')';
            if (r === 'link') { const href = shortURL(el.href); if (href) line += ' → ' + href; }
            emit(line, depth, rect, el);
            if (hasInteractive(el)) for (const child of kids(el)) visitInner(child, depth + 1, style);
            return;
          }
          if (r === 'heading') {
            emit('heading ' + quote(cut(name(el, r), 200)) + ' [' + refOf(el) + '] (' + states(el, r).join(', ') + ')', depth, rect, el);
            if (hasInteractive(el)) for (const child of kids(el)) visitInner(child, depth + 1, style);
            return;
          }
          if (r === 'img') { if (rect.width >= 24 && rect.height >= 24) emit('img ' + quote(cut(name(el, r), 150)) + ' [' + refOf(el) + ']', depth, rect, el); return; }
          if (tag === 'canvas') {
            if (rect.width >= 24 && rect.height >= 24) {
              const label = cut(clean(el.getAttribute('aria-label') || el.title || ''), 100);
              emit('canvas' + (label ? ' ' + quote(label) : '') + ' [' + refOf(el) + '] (' + Math.round(rect.width) + ' by ' + Math.round(rect.height) + ', drawn: view_page shows it)', depth, rect, el);
            }
            return;
          }
          if (r === 'iframe') {
            let inside = null;
            try { inside = el.contentDocument?.body; } catch {}
            if (!inside) { emit('iframe ' + quote(cut(name(el, r) || shortURL(el.src) || 'frame', 100)) + ' (another site’s, which can’t be read here)', depth, rect, el); return; }
            emit('iframe ' + quote(cut(name(el, r) || shortURL(el.src) || 'frame', 100)) + ':', depth, rect, el);
            visit(inside, depth + 1, null); flush();
            return;
          }
          if (r === 'video' || r === 'audio') {
            const media = el;
            emit(r + (media.paused ? ' (paused)' : ' (playing)') + (media.duration ? ' ' + Math.round(media.currentTime) + 's of ' + Math.round(media.duration) + 's' : ''), depth, rect, el);
            return;
          }
          if (r === 'row') {
            const cells = [...el.children].filter(c => ['td', 'th'].includes(c.localName) || ['cell', 'columnheader', 'rowheader', 'gridcell'].includes(c.getAttribute('role')));
            const text = cells.map(c => cut(textOf(c), 80)).join(' | ');
            if (text.replace(/[|\s]/g, '')) emit('row: ' + cut(text, 500), depth, rect, el);
            if (hasInteractive(el)) for (const child of kids(el)) visitInner(child, depth + 1, style);
            return;
          }
          if (containerRoles.has(r)) {
            const label = cut(name(el, r), 80);
            const modal = r === 'dialog' || r === 'alertdialog' || el.getAttribute('aria-modal') === 'true';
            const named = r === 'region' || r === 'group' ? !!label : r === 'list' ? el.children.length > 1 : true;
            if (named) emit(r + (label ? ' ' + quote(label) : '') + ' [' + refOf(el) + ']' + (modal ? ' (open)' : '') + ':', depth, rect, el);
            const inner = named ? depth + 1 : depth;
            for (const child of kids(el)) visit(child, inner, style);
            flush();
            return;
          }
          for (const child of kids(el)) visit(child, depth, style);
          flush();
        }
        // Inside a control: only the controls in it, its text being its name.
        function visitInner(node, depth, parentStyle) {
          if (node.nodeType !== Node.ELEMENT_NODE && node.nodeType !== Node.DOCUMENT_FRAGMENT_NODE) return;
          if (node.nodeType === Node.DOCUMENT_FRAGMENT_NODE) { for (const child of node.childNodes) visitInner(child, depth, parentStyle); return; }
          const el = node;
          if (skipped.has(el.localName) || el.getAttribute('aria-hidden') === 'true') return;
          const style = getComputedStyle(el);
          if (style.display === 'none') return;
          const r = role(el);
          if (interactiveRoles.has(r) || r === 'iframe') { const saved = buffer; buffer = ''; visit(el, depth, parentStyle); buffer = saved; return; }
          for (const child of kids(el)) visitInner(child, depth, style);
        }
        visit(root, 0, null);
        flush();
        return lines;
      }

      // The open dialog the page is showing over everything else, if any.
      function openDialog() {
        const candidates = [...document.querySelectorAll('dialog[open], [role=dialog], [role=alertdialog], [aria-modal=true]')]
          .filter(el => { const r = el.getBoundingClientRect(); return r.width > 40 && r.height > 40 && el.checkVisibility?.({ checkVisibilityCSS: true }) !== false && el.getAttribute('aria-hidden') !== 'true'; });
        // Only one that keeps the page behind it from being used; a cookie banner beside the page doesn't.
        return candidates.findLast(el => el.matches(':modal') || el.getAttribute('aria-modal') === 'true') || null;
      }

      function render(lines, from, budget, onlyNear) {
        let shown = [], refs = [], length = 0, last = null, index = from, firstIn = -1, lastIn = -1;
        lines.forEach((line, i) => { if (line.where === 'in') { if (firstIn < 0) firstIn = i; lastIn = i; } });
        let start = from, end = lines.length;
        if (onlyNear && firstIn >= 0) { start = Math.max(0, firstIn - 3); end = Math.min(lines.length, lastIn + 6); }
        for (index = start; index < end; index++) {
          const line = lines[index];
          if (line.where !== last) {
            const marker = { above: '--- above what’s on screen ---', in: '--- on screen ---', below: '--- below the screen ---' }[line.where];
            shown.push(marker); length += marker.length + 1; last = line.where;
          }
          const text = '  '.repeat(line.depth) + '- ' + line.text;
          if (length + text.length > budget && shown.length > 1) break;
          shown.push(text); length += text.length + 1;
          const match = /^(.*?) \[(e\d+)\]/.exec(line.text);
          if (match) refs.push([match[2], cut(match[1], 80)]);
        }
        return { text: shown.join('\n'), refs, start, end: index, total: lines.length };
      }

      function frame() {
        return new Promise(resolve => {
          let done = false; const finish = () => { if (!done) { done = true; resolve(); } };
          requestAnimationFrame(() => requestAnimationFrame(finish)); setTimeout(finish, 120);
        });
      }
      function within(node, el) {
        for (let at = node; at; at = at.parentNode || at.host) if (at === el) return true;
        return false;
      }
      function hitAt(doc, x, y) {
        let hit = doc.elementFromPoint(x, y);
        while (hit?.shadowRoot) { const inner = hit.shadowRoot.elementFromPoint(x, y); if (!inner || inner === hit) break; hit = inner; }
        return hit;
      }
      function describe(el) {
        if (!el) return 'nothing';
        const r = role(el) || el.localName, label = cut(name(el, r) || textOf(el), 60);
        return r + (label ? ' ' + quote(label) : '');
      }
      // A hidden checkbox or file field drawn by its label instead is used through the label.
      function stand(el) {
        if (el.localName === 'input' && ['checkbox', 'radio', 'file'].includes(inputType(el)) && el.labels?.length) {
          const style = getComputedStyle(el), rect = el.getBoundingClientRect();
          if (parseFloat(style.opacity) < 0.05 || rect.width < 2 || rect.height < 2 || style.visibility === 'hidden') {
            const label = [...el.labels].find(l => { const r = l.getBoundingClientRect(); return r.width > 2 && r.height > 2; });
            if (label) return label;
          }
        }
        return el;
      }

      return {
        async snapshot(args) {
          const lines = outline(document.documentElement);
          const dialog = args.dialogFirst !== false ? openDialog() : null;
          let header = '';
          let chosen = lines;
          if (dialog) {
            const inside = lines.filter(line => line.el && within(line.el, dialog) || line.el === dialog);
            // Lines from the dialog's own text, between its first and last element's lines.
            const first = lines.findIndex(line => line.el === dialog);
            if (first >= 0) {
              const depth = lines[first].depth;
              let end = first + 1;
              while (end < lines.length && lines[end].depth > depth) end++;
              chosen = lines.slice(first, end);
              header = 'A dialog is open over the page; only it is shown. Close it, or call snapshot_tab with behind_dialog true to see the page behind.\n';
            } else if (inside.length) { chosen = inside; header = 'A dialog is open over the page; only it is shown.\n'; }
          }
          const shown = render(chosen, Math.max(0, (args.from || 1) - 1), args.budget || 24000, !!args.nearScreen && !dialog);
          const scroller = document.scrollingElement;
          const scroll = scroller ? { y: Math.round(scroller.scrollTop), height: Math.round(scroller.scrollHeight), view: innerHeight } : null;
          return {
            text: header + shown.text, start: shown.start + 1, end: shown.end, total: shown.total, dialog: !!dialog,
            scroll, title: document.title, url: location.href, focused: describe(deepActive()), refs: shown.refs
          };
        },

        // Where to click `ref`: scrolled into view, at a point where it, not something over it, takes the click.
        async locate(args) {
          let el = element(args.ref);
          if (!el) return { error: 'gone' };
          el = stand(el);
          const view = el.ownerDocument.defaultView;
          let rect = el.getBoundingClientRect();
          if (!args.noScroll && (rect.top < 0 || rect.left < 0 || rect.bottom > view.innerHeight || rect.right > view.innerWidth)) {
            el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
            await frame();
            rect = el.getBoundingClientRect();
          }
          if (rect.width < 1 || rect.height < 1) return { error: 'invisible', what: describe(el) };
          const style = getComputedStyle(el);
          if (style.visibility === 'hidden' || el.checkVisibility?.({ checkVisibilityCSS: true }) === false) return { error: 'invisible', what: describe(el) };
          const left = Math.max(rect.left, 0), right = Math.min(rect.right, view.innerWidth);
          const top = Math.max(rect.top, 0), bottom = Math.min(rect.bottom, view.innerHeight);
          if (right - left < 1 || bottom - top < 1) return { error: 'offscreen', what: describe(el) };
          const points = [[0.5, 0.5], [0.3, 0.5], [0.7, 0.5], [0.5, 0.3], [0.5, 0.7], [0.2, 0.2], [0.8, 0.8]];
          const reachable = () => {
            for (const [fx, fy] of points) {
              const r = el.getBoundingClientRect();
              const x = Math.max(r.left, 0) + (Math.min(r.right, view.innerWidth) - Math.max(r.left, 0)) * fx;
              const y = Math.max(r.top, 0) + (Math.min(r.bottom, view.innerHeight) - Math.max(r.top, 0)) * fy;
              const hit = hitAt(el.ownerDocument, x, y);
              if (hit && (within(hit, el) || hit.control === el || el.localName === 'label' && el.control && within(hit, el.control))) return true;
            }
            return false;
          };
          // Under a bar fixed to the screen's top or bottom: scrolled to the other edge, clear of it.
          if (!args.noScroll && !reachable()) {
            for (const block of ['start', 'end']) {
              el.scrollIntoView({ block, inline: 'nearest', behavior: 'instant' });
              await frame();
              if (reachable()) break;
            }
            rect = el.getBoundingClientRect();
          }
          const placed = topRect(el);
          const shiftX = placed.x - rect.left, shiftY = placed.y - rect.top;
          const fromLeft = Math.max(rect.left, 0), fromRight = Math.min(rect.right, view.innerWidth);
          const fromTop = Math.max(rect.top, 0), fromBottom = Math.min(rect.bottom, view.innerHeight);
          let cover = null;
          for (const [fx, fy] of points) {
            const x = fromLeft + (fromRight - fromLeft) * fx, y = fromTop + (fromBottom - fromTop) * fy;
            const hit = hitAt(el.ownerDocument, x, y);
            if (hit && (within(hit, el) || hit.control === el || el.localName === 'label' && el.control && within(hit, el.control))) {
              return { x: x + shiftX, y: y + shiftY, what: describe(el), disabled: !!el.disabled || el.getAttribute('aria-disabled') === 'true' };
            }
            cover = cover || hit;
          }
          const x = (fromLeft + fromRight) / 2 + shiftX, y = (fromTop + fromBottom) / 2 + shiftY;
          return { x, y, what: describe(el), covered: describe(cover), disabled: !!el.disabled };
        },

        // Readies a field for typing: focused, its text chosen to be replaced or the caret at its end.
        async focus(args) {
          let el = element(args.ref);
          if (!el) return { error: 'gone' };
          if (el.localName === 'label' && el.control) el = el.control;
          const editable = node => node.localName === 'textarea' || node.localName === 'input' && !['checkbox', 'radio', 'button', 'submit', 'reset', 'image', 'file', 'hidden'].includes(inputType(node)) || node.isContentEditable;
          // Shown, as the person would need it to type there: not collapsed away, as a search box
          // behind its button often is.
          const showing = node => { const r = node.getBoundingClientRect(); return r.width > 2 && r.height > 2 && node.checkVisibility?.({ checkVisibilityCSS: true }) !== false; };
          if (!editable(el)) {
            const selector = 'input:not([type=hidden]), textarea, [contenteditable]:not([contenteditable=false])';
            const inner = [...(el.querySelectorAll?.(selector) || []), ...(el.shadowRoot?.querySelectorAll(selector) || [])].filter(editable);
            const shown = inner.find(showing);
            if (shown) el = shown;
            else if (inner.length) return { error: 'invisible', what: describe(el) };
            else return { error: 'not-editable', what: describe(el) };
          }
          if (el.disabled || el.readOnly) return { error: 'read-only', what: describe(el) };
          if (!showing(el) && !valueTypes.includes(inputType(el))) return { error: 'invisible', what: describe(el) };
          const type = inputType(el);
          if (valueTypes.includes(type)) return { special: type, what: describe(el) };
          const rect = el.getBoundingClientRect(), view = el.ownerDocument.defaultView;
          if (rect.top < 0 || rect.bottom > view.innerHeight) { el.scrollIntoView({ block: 'center', behavior: 'instant' }); await frame(); }
          el.focus({ preventScroll: true });
          const active = deepActive();
          const focused = active === el || within(active, el);
          if (focused) {
            if (args.replace) {
              if ('value' in el && typeof el.select === 'function') { try { el.select(); } catch {} }
              else { const sel = el.ownerDocument.getSelection(), range = el.ownerDocument.createRange(); range.selectNodeContents(el); sel.removeAllRanges(); sel.addRange(range); }
            } else {
              if ('value' in el) { try { el.setSelectionRange(el.value.length, el.value.length); } catch {} }
              else { const sel = el.ownerDocument.getSelection(), range = el.ownerDocument.createRange(); range.selectNodeContents(el); range.collapse(false); sel.removeAllRanges(); sel.addRange(range); }
            }
          }
          return { focused, what: describe(el), hasText: 'value' in el ? !!el.value : !!clean(el.innerText), masked: masked(el) };
        },
        // What a field holds now, to check what typing did.
        fieldValue(args) {
          let el = element(args.ref);
          if (!el) return { error: 'gone' };
          if (el.localName === 'label' && el.control) el = el.control;
          if (!('value' in el) && !el.isContentEditable) el = el.querySelector?.('input, textarea, [contenteditable]') || el;
          const text = 'value' in el ? el.value : clean(el.innerText);
          return { value: masked(el) ? (text ? '•••••••• (hidden, ' + text.length + ' characters)' : '') : cut(text ?? '', 400) };
        },
        // Fields typing can't fill, as a date or a colour: set as the person's choice would.
        setValue(args) {
          let el = element(args.ref);
          if (!el) return { error: 'gone' };
          if (el.localName === 'label' && el.control) el = el.control;
          const proto = Object.getPrototypeOf(el), setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
          if (setter) setter.call(el, args.value); else el.value = args.value;
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return { value: el.value };
        },
        select(args) {
          let el = element(args.ref);
          if (!el) return { error: 'gone' };
          if (el.localName === 'label' && el.control) el = el.control;
          if (el.localName !== 'select') el = el.querySelector?.('select') || el;
          if (el.localName !== 'select') return { error: 'not-select', what: describe(el) };
          if (el.disabled) return { error: 'disabled', what: describe(el) };
          const wanted = (args.options || []).map(o => clean(String(o)).toLowerCase());
          const options = [...el.options];
          const matched = [];
          for (const want of wanted) {
            const option = options.find(o => clean(o.label).toLowerCase() === want) || options.find(o => o.value.toLowerCase() === want)
              || options.find(o => clean(o.label).toLowerCase().includes(want));
            if (!option) return { error: 'no-option', wanted: want, options: options.slice(0, 40).map(o => clean(o.label)) };
            matched.push(option);
          }
          if (!el.multiple && matched.length > 1) return { error: 'single', what: describe(el) };
          for (const option of options) option.selected = matched.includes(option);
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return { chosen: [...el.selectedOptions].map(o => clean(o.label)) };
        },
        async scroll(args) {
          const el = args.ref ? element(args.ref) : null;
          if (args.ref && !el) return { error: 'gone' };
          if (el && !args.direction) {
            el.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'instant' });
            await frame();
            return { what: describe(el) };
          }
          const vertical = args.direction === 'up' || args.direction === 'down';
          const sign = args.direction === 'up' || args.direction === 'left' ? -1 : 1;
          const scrolls = node => {
            if (!node || node.nodeType !== 1) return false;
            const style = getComputedStyle(node);
            const overflow = vertical ? style.overflowY : style.overflowX;
            const room = vertical ? node.scrollHeight - node.clientHeight : node.scrollWidth - node.clientWidth;
            const isRoot = node === document.scrollingElement;
            return room > 1 && (isRoot ? overflow !== 'hidden' && overflow !== 'clip' : /(auto|scroll|overlay)/.test(overflow));
          };
          let target = null;
          if (el) { for (let at = el; at; at = at.parentElement || at.getRootNode()?.host) if (scrolls(at)) { target = at; break; } }
          if (!target) {
            if (scrolls(document.scrollingElement)) target = document.scrollingElement;
            else {
              // An app that scrolls a part of itself: the biggest part under the middle of the screen that scrolls.
              let best = null, bestArea = 0;
              for (const [fx, fy] of [[0.5, 0.5], [0.3, 0.5], [0.7, 0.5], [0.5, 0.3], [0.5, 0.7]]) {
                for (let at = hitAt(document, innerWidth * fx, innerHeight * fy); at; at = at.parentElement || at.getRootNode()?.host) {
                  if (scrolls(at)) { const r = at.getBoundingClientRect(), area = r.width * r.height; if (area > bestArea) { best = at; bestArea = area; } break; }
                }
              }
              target = best;
            }
          }
          if (!target) return { error: 'nothing-scrolls' };
          const page = target === document.scrollingElement;
          const size = vertical ? (page ? innerHeight : target.clientHeight) : (page ? innerWidth : target.clientWidth);
          const amount = Math.round(size * 0.85 * (args.amount || 1)) * sign;
          const before = vertical ? target.scrollTop : target.scrollLeft;
          target.scrollBy({ top: vertical ? amount : 0, left: vertical ? 0 : amount, behavior: 'instant' });
          await frame();
          const after = vertical ? target.scrollTop : target.scrollLeft;
          const room = vertical ? target.scrollHeight - target.clientHeight : target.scrollWidth - target.clientWidth;
          return { moved: Math.round(after - before), at: Math.round(after), room: Math.round(room), what: page ? 'the page' : describe(target) };
        },
        // Waits until nothing on the page has changed for a moment, or `limit` ms pass.
        settle(args) {
          return new Promise(resolve => {
            const quiet = args.quiet || 300, limit = args.limit || 2500, started = performance.now();
            let timer = null;
            const observer = new MutationObserver(() => { clearTimeout(timer); timer = setTimeout(done, quiet); });
            function done() { observer.disconnect(); clearTimeout(timer); clearTimeout(cap); resolve(Math.round(performance.now() - started)); }
            const cap = setTimeout(done, limit);
            observer.observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
            timer = setTimeout(done, quiet);
          });
        },
        findText(args) {
          const wanted = clean(args.text).toLowerCase();
          const text = (document.body?.innerText || '').replace(/\s+/g, ' ').toLowerCase();
          return { found: !!wanted && text.includes(wanted) };
        },
        // The file field `ref` is, labels, or holds, marked for DevTools to find; or, with none, a
        // place to drop files on.
        markUpload(args) {
          const el = element(args.ref);
          if (!el) return { error: 'gone' };
          const isFile = node => node?.localName === 'input' && inputType(node) === 'file';
          let input = isFile(el) ? el : el.localName === 'label' && isFile(el.control) ? el.control : null;
          if (!input) input = el.querySelector?.('input[type=file]') || el.shadowRoot?.querySelector('input[type=file]') || null;
          if (!input) return { zone: true, what: describe(el) };
          if (input.disabled) return { error: 'disabled', what: describe(input) };
          state.marked?.removeAttribute('data-rise-upload');
          input.setAttribute('data-rise-upload', args.mark);
          state.marked = input;
          return { multiple: input.multiple, accept: input.accept || '', folder: !!input.webkitdirectory, what: describe(el) };
        },
        unmarkUpload() {
          const input = state.marked;
          state.marked = null;
          input?.removeAttribute('data-rise-upload');
          return { files: input ? [...(input.files || [])].map(f => f.name) : [] };
        },
        // Scrolls so both ends of a drag show at once, if they fit on the screen together.
        async bringBoth(args) {
          const from = element(args.from), to = element(args.to);
          if (!from || !to) return { error: 'gone' };
          const a = topRect(from), b = topRect(to);
          const top = Math.min(a.y, b.y), bottom = Math.max(a.y + a.height, b.y + b.height);
          const left = Math.min(a.x, b.x), right = Math.max(a.x + a.width, b.x + b.width);
          if (bottom - top > innerHeight - 8 || right - left > innerWidth - 8) return { error: 'too-far' };
          // The part that scrolls and holds both, or the page.
          let scroller = null;
          for (let at = from.parentElement; at; at = at.parentElement || at.getRootNode()?.host) {
            if (at.nodeType === 1 && within(to, at) && at.scrollHeight > at.clientHeight + 1 && /(auto|scroll|overlay)/.test(getComputedStyle(at).overflowY)) { scroller = at; break; }
          }
          if (scroller) {
            const box = scroller.getBoundingClientRect();
            if (bottom - top > box.height - 8) return { error: 'too-far' };
            scroller.scrollBy({ top: (top + bottom) / 2 - (box.top + box.height / 2), behavior: 'instant' });
            await frame();
          }
          const c = topRect(from), d = topRect(to);
          const midY = (Math.min(c.y, d.y) + Math.max(c.y + c.height, d.y + d.height)) / 2;
          const midX = (Math.min(c.x, d.x) + Math.max(c.x + c.width, d.x + d.width)) / 2;
          window.scrollBy({ top: midY - innerHeight / 2, left: right - left > innerWidth / 2 ? midX - innerWidth / 2 : 0, behavior: 'instant' });
          await frame();
          return { ok: true };
        },
        // Counts what changes from now: the page's content, its fields' values, its scrolling.
        watch() {
          state.observer?.disconnect();
          state.changes = 0;
          state.observer = new MutationObserver(records => { state.changes += records.length; });
          state.observer.observe(document, { subtree: true, childList: true, characterData: true, attributes: true });
          if (!state.listening) {
            state.listening = true;
            for (const type of ['input', 'change', 'toggle', 'scroll', 'submit']) document.addEventListener(type, () => { state.changes++; }, true);
          }
          return { watching: true };
        },
        changes() { return { changes: state.changes ?? -1 }; },
        // What has the keyboard, and whether it's a field that edits text.
        focusInfo() {
          const el = deepActive();
          const editable = !!el && (el.isContentEditable || el.localName === 'textarea'
            || el.localName === 'input' && !['checkbox', 'radio', 'button', 'submit', 'reset', 'image', 'file', 'range', 'color'].includes(inputType(el)));
          return { editable, what: el && el !== document.body ? describe(el) : 'the page' };
        },
        // Describes a ref the model has, to say what was clicked.
        describe(args) { const el = element(args.ref); return el ? { what: describe(el) } : { error: 'gone' }; }
      };
    })();
    """#
}
