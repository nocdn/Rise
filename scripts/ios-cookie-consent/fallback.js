import { classifyButtonTextRegex, cleanButtonText } from '@duckduckgo/autoconsent/heuristics';

const controls = 'button,input[type=button],input[type=submit],a,[role=button]';
const known = /cookie|consent|onetrust|didomi|cybot|privacy-center|cmp-container|gdpr/i;
const cookieWords = /cookies?|kekse|çerez|ciastecz|sütik|biscotti|biscoit|galletas|koekjes|eväste|kakor|informasjonskapsler|soubory cookie|クッキー|쿠키|饼干|餅乾|ملفات تعريف الارتباط/i;
const dangerous = /(?:subscribe|subscription|purchase|payment|checkout|buy now|sign in|log in|create account|age verification|terms of (?:use|service)|abonnieren|abonnement|paiement|zahlung)/i;
const extraAccept = /^(?:accept(?: all)?(?: cookies)?|allow all(?: cookies)?|agree(?: and continue)?|i agree|yes,? i agree|tout accepter|accepter(?: tous les cookies)?|alle akzeptieren|alles akzeptieren|akzeptieren|aceptar(?: todas| todo| todas las cookies)?|aceitar(?: todos| tudo)?|accetta(?: tutti)?|accepteer(?: alles)?|akceptuj(?: wszystkie)?|zaakceptuj(?: wszystkie)?|elfogadom|hyväksy(?: kaikki)?|godkänn(?: alla)?|accepter alle|acceptér alle|godta alle|alle toestaan|すべて同意|すべて許可|동의|모두 허용|全部接受|接受所有|同意全部|قبول الكل)$/i;

export function parentOf(node) { return node.parentElement || node.getRootNode()?.host || null; }
export function visible(node) {
    if (!node?.isConnected || !node.getClientRects().length) return false;
    for (let p = node; p; p = parentOf(p)) {
        if (p.hidden || p.inert || p.getAttribute('aria-hidden') === 'true') return false;
        const s = getComputedStyle(p);
        if (s.display === 'none' || s.visibility === 'hidden' || s.visibility === 'collapse' || +s.opacity === 0) return false;
    }
    const r = node.getBoundingClientRect();
    return r.width > 1 && r.height > 1;
}
const textOf = node => (node.innerText || node.textContent || '').replace(/\s+/g, ' ').trim();
function proseOf(node) {
    const walker = document.createTreeWalker(node,NodeFilter.SHOW_TEXT);
    let text = '', count = 0, n;
    while ((n=walker.nextNode()) && count++ < 160 && text.length < 12000) {
        if (!n.parentElement?.closest(`${controls},script,style,noscript,template`)) text += ` ${n.textContent}`;
    }
    return text.replace(/\s+/g,' ').trim();
}
export function consentContainer(button) {
    for (let p = parentOf(button), depth = 0; p && p !== document.body && p !== document.documentElement && depth < 12; p = parentOf(p), depth++) {
        if (p.matches('main,article,form') && p.querySelector('input[type=password],input[type=email],input[autocomplete=cc-number]')) return null;
        if (p.matches('main,article') && !p.matches('[role=dialog],[role=alertdialog]')) continue;
        const s = getComputedStyle(p), identity = `${p.id} ${typeof p.className === 'string' ? p.className : ''} ${p.getAttribute('aria-label') || ''}`;
        if (!(p.matches('dialog,[role=dialog],[role=alertdialog]') || ['fixed','sticky'].includes(s.position) || known.test(identity))) continue;
        const text = textOf(p);
        if (text.length < 12 || text.length > 12000) continue;
        // Cookie purpose must be explicit; an "Accept all" button by itself isn't consent.
        const prose = proseOf(p);
        const cookie = cookieWords.test(prose);
        const privacyConsent = /store and\/or access information.{0,80}device|personalised ads and content/i.test(prose);
        if (!cookie && !privacyConsent) continue;
        if (dangerous.test(text) && !cookie) continue;
        if (p.querySelector('input[type=password],input[type=email],input[autocomplete=cc-number]')) return null;
        return p;
    }
    // An entire iframe may be the consent panel; only use it with explicit purpose and few controls.
    if (window !== window.top && document.body && document.body.querySelectorAll(controls).length <= 20) {
        const text = textOf(document.body);
        if (text.length < 12000 && cookieWords.test(proseOf(document.body)) &&
            !document.body.querySelector('input[type=password],input[type=email],input[autocomplete=cc-number]') && !/age verification/i.test(text)) return document.body;
    }
    return null;
}

export function createFallback(state, click, send, dismissed) {
    const queued = new Set(), roots = new WeakSet(), observers = [], walkers = [], candidates = new Set();
    const retries = new WeakMap();
    const containers = new WeakMap();
    let timer, stopped = false, slices = 0, maxSlice = 0, visited = 0, attempts = 0;
    let overflow = false;
    // A page that changes constantly (an app, an animation) is looked over once a second
    // instead of on every change, as Brave's cosmetic filtering does.
    let changes = 0, window_ = performance.now(), polling = 0;
    const busy = count => {
        const now = performance.now();
        if (now-window_ > 1000) { window_ = now; changes = 0; }
        if ((changes += count) < 400 || polling) return false;
        observers.forEach(o=>o.disconnect());
        polling = setInterval(() => { if (state.active && !document.hidden) { enqueue(document.documentElement); schedule(); } }, 1000);
        return true;
    };
    const observe = root => {
        if (roots.has(root) || polling) return;
        roots.add(root);
        const observer = new MutationObserver(records => {
            if (!state.active || busy(records.length)) return;
            for (const record of records) {
                if (record.type === 'childList') for (const n of record.addedNodes) if (n.nodeType === 1) enqueue(n);
                if (record.type !== 'childList' || record.removedNodes.length) {
                    const n = record.target.nodeType === 1 ? record.target : record.target.parentElement;
                    if (n) enqueue(n);
                    for (const b of candidates) if (n && (n.contains(b) || containers.get(b)?.contains(n))) queued.add(b);
                }
            }
            schedule();
        });
        observer.observe(root, { subtree: true, childList: true, attributes: true, characterData: true,
            attributeFilter: ['class','style','hidden','open','disabled','aria-disabled','aria-hidden','inert'] });
        observers.push(observer);
    };
    function enqueue(node) {
        if (node.matches?.(controls) && queued.size < 512) queued.add(node);
        else if (queued.size >= 512) overflow = true;
        // Time-sliced tree traversal also discovers open shadow roots without a whole-DOM query on every mutation.
        if (walkers.length < 128) walkers.push({ first: node, walker: document.createTreeWalker(node, NodeFilter.SHOW_ELEMENT) });
        else overflow = true;
    }
    function schedule(delay = 120) {
        if (timer || stopped || !state.active || document.hidden) return;
        timer = setTimeout(pump, delay);
    }
    function evaluate(button) {
        if (!state.active || state.manual || button.disabled || button.getAttribute('aria-disabled') === 'true') return;
        // Classify cheaply before any geometry/style reads. Ordinary links and controls
        // on a long article should never force layout just to rule out consent.
        const text = cleanButtonText(button.getAttribute('aria-label') || button.value || button.textContent || '');
        const type = classifyButtonTextRegex(text);
        const explicit = extraAccept.test(text);
        const acknowledgement = type === 'acknowledge' && !/settings|preferences|privacy|manage|options/i.test(text);
        if (type !== 'accept' && !explicit && !acknowledgement) return;
        if (/reject|decline|deny|only necessary|essential only|without accepting|buy|pay|subscribe|terms/i.test(text)) return;
        if (!visible(button)) return;
        const container = consentContainer(button);
        if (!container || !visible(container)) return;
        if (button.tagName === 'A') {
            const href = button.getAttribute('href');
            if (href && !href.startsWith('#') && !href.startsWith('javascript:')) return;
        }
        // Never submit an unrelated form or follow an external link to "accept".
        const form = button.closest('form');
        if (form && !known.test(`${form.id} ${form.className}`) && (button.type || '').toLowerCase() === 'submit') return;
        const rect = button.getBoundingClientRect();
        if (rect.bottom < 0 || rect.top > innerHeight || rect.right < 0 || rect.left > innerWidth) return;
        let hit = document.elementFromPoint(Math.max(0,Math.min(innerWidth-1,rect.left+rect.width/2)), Math.max(0,Math.min(innerHeight-1,rect.top+rect.height/2)));
        // Shadow hosts are the document's hit-test result, descend to the real button.
        while (hit?.shadowRoot) {
            const next = hit.shadowRoot.elementFromPoint?.(rect.left+rect.width/2,rect.top+rect.height/2);
            if (!next || next === hit) break; hit = next;
        }
        if (hit && hit !== button && !button.contains(hit)) return;
        // Give a multi-option panel's explicit "accept all" priority over a plain OK/close.
        if (acknowledgement && [...container.querySelectorAll(controls)].some(b => b !== button && visible(b) && classifyButtonTextRegex(cleanButtonText(b.innerText || b.value || b.textContent || '')) === 'accept')) return;
        candidates.add(button);
        containers.set(button,container);
        if (candidates.size > 80) candidates.delete(candidates.values().next().value);
        if (click(button, 'fallback')) {
            attempts++;
            send({ type: 'action', source: 'fallback', action: 'accept', label: text.slice(0,80) });
            // A premature click may precede a late event handler. Retry only while still visible;
            // once the banner has gone, consent is given.
            const retry = retries.get(button) || 0; retries.set(button,retry+1);
            setTimeout(() => {
                if (!state.active) return;
                if (visible(button)) { queued.add(button); schedule(); } else if (!visible(container)) dismissed();
            }, Math.min(8000,1100*2**retry));
        }
    }
    function pump() {
        timer = null;
        if (stopped || !state.active || document.hidden) return;
        const start = performance.now();
        while ((walkers.length || queued.size || overflow) && performance.now()-start < 4) {
            if (!walkers.length && !queued.size && overflow) { overflow = false; enqueue(document.documentElement); }
            if (queued.size) {
                const button = queued.values().next().value; queued.delete(button);
                if (button.matches?.(controls)) evaluate(button);
            } else {
                const item = walkers[0];
                const n = item.first || item.walker.nextNode(); item.first = null;
                if (!n) { walkers.shift(); continue; }
                visited++;
                if (n.shadowRoot) { observe(n.shadowRoot); enqueue(n.shadowRoot); }
                if (n.matches?.(controls)) queued.add(n);
            }
        }
        slices++; maxSlice = Math.max(maxSlice,performance.now()-start);
        if (walkers.length || queued.size || overflow) schedule(20);
    }
    const trusted = event => {
        if (!state.active || !event.isTrusted || !event.target?.nodeType) return;
        const node = event.composedPath?.()[0] || event.target;
        const button = node.closest?.(controls);
        const settings = button && /(?:cookie|privacy).{0,30}(?:settings|preferences)|manage.{0,30}(?:cookie|consent)/i.test(textOf(button));
        // The person answers it themselves; there's nothing left to look for.
        if (settings || consentContainer(node)) { state.manual = true; send({ type:'manual' }); dismissed(); }
    };
    document.addEventListener('pointerdown',trusted,true);
    document.addEventListener('keydown',trusted,true);
    const visibility = () => { if (state.active && !document.hidden) { enqueue(document.documentElement); schedule(); } };
    document.addEventListener('visibilitychange',visibility);
    observe(document);
    enqueue(document.documentElement);
    schedule(600); // The maintained CMP rules get the first opportunity.
    for (const delay of [1500,4000]) setTimeout(() => { if (state.active) { enqueue(document.documentElement); schedule(); } },delay);
    return {
        stop() {
            stopped = true; clearTimeout(timer); clearInterval(polling); observers.forEach(o=>o.disconnect()); queued.clear(); walkers.length=0; candidates.clear();
            document.removeEventListener('pointerdown',trusted,true); document.removeEventListener('keydown',trusted,true); document.removeEventListener('visibilitychange',visibility);
        },
        stats() { return { slices, maxSlice, visited, attempts, polling: !!polling, queued: queued.size, walkers: walkers.length }; },
        pending() { return [...candidates].some(b=>visible(b)); },
        inspect() {
            const panels = new Set();
            const inspectRoot = root => {
                for (const b of root.querySelectorAll(controls)) { const c=consentContainer(b); if (c && visible(c)) panels.add(c); }
                for (const n of root.querySelectorAll('*')) if (n.shadowRoot) inspectRoot(n.shadowRoot);
            };
            inspectRoot(document);
            return [...panels].slice(0,10).map(c=>({text:textOf(c).slice(0,500), id:c.id, buttons:[...c.querySelectorAll(controls)].filter(visible).map(b=>textOf(b).slice(0,80))}));
        }
    };
}
