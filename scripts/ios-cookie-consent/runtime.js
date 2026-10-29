import AutoConsent from '@duckduckgo/autoconsent';
import { createFallback, visible } from './fallback.js';

(() => {
    if (window.__riseCookieConsent) return;
    const transport = typeof riseHandlers !== 'undefined' ? riseHandlers.riseCookieConsent : window.webkit?.messageHandlers?.riseCookieConsent;
    // Chromium supplies its handler lexically. Retain the isolated-world transport so a
    // bfcache resume evaluated by the native bridge can initialize the same runtime again.
    const post = transport ? message => transport.postMessage(message) : globalThis.__riseCookieConsentPost;
    if (typeof post !== 'function') return;
    globalThis.__riseCookieConsentPost = post;
    const token = `${Date.now()}-${Math.random()}`;
    const born = performance.timeOrigin+performance.now();
    const state = { active:true, manual:false, clicks:0, lastClick:0 };
    const clicked = new WeakMap();
    const nativeClick = HTMLElement.prototype.click;
    const send = message => { try { post({ ...message, token }); } catch {} };
    function click(element, source) {
        if (!state.active || state.manual || state.clicks >= 24 || !element?.isConnected || element.disabled || element.closest('[inert]')) return false;
        const label = element.getAttribute('aria-label') || element.value || element.textContent || '';
        if (/subscribe|purchase|checkout|buy now|pay now|(?:accept|agree).{0,30}terms|[£€$]\s*\d/i.test(label)) return false;
        const previous = clicked.get(element) || { count:0, time:0 };
        if (previous.count >= 5 || Date.now()-previous.time < 900) return false;
        // Maintained flows may toggle visually hidden checkboxes; ordinary controls must be visible.
        if (!(element.matches('input[type=checkbox]') && source === 'rule') && !visible(element)) return false;
        previous.count++; previous.time=Date.now(); clicked.set(element,previous);
        state.clicks++; state.lastClick=Date.now();
        nativeClick.call(element); return true;
    }
    // This prototype belongs to the isolated world. Page scripts retain their normal
    // click() method, while even an adapter's direct click respects disable/manual state.
    HTMLElement.prototype.click = function() { click(this,'rule'); };
    let engine;
    const bridge = message => {
        if (!state.active || state.manual) return;
        if (message.type === 'eval') send({ type:'eval', id:message.id, snippetId:message.snippetId });
        else if (message.type === 'cmpDetected' || message.type === 'autoconsentDone' || message.type === 'optInResult')
            send({ type:message.type, cmp:message.cmp, result:message.result });
        if (message.type === 'autoconsentDone' || (message.type === 'optInResult' && message.result)) dismissed();
    };
    // Watching a page costs it time on every change, so it stops once the banner is answered
    // (here or in any of the page's frames), or when none has shown up: the whole page, every frame.
    let finished = false;
    function finish() {
        if (finished || !state.active) return;
        finished = true;
        window.__riseCookieConsent?.stop();
        if (window !== window.top) try { window.top.postMessage({ riseCookieConsentDone:true }, '*'); } catch {}
    }
    // Once the banner has gone, after a moment for a late one to follow it.
    function dismissed() { setTimeout(() => { if (!fallback.pending()) finish(); }, 2000); }
    // None after 15 s (or, while one is being answered, a minute) on a document that's on screen.
    let quiet = 0;
    const settle = () => setTimeout(() => {
        if (!state.active) return;
        quiet += 15;
        const asking = engine.state.detectedCmps.length || fallback.pending();
        if (!document.hidden && (!asking || quiet >= 60)) finish(); else settle();
    }, 15000);
    engine = new AutoConsent(bridge);
    engine.domActions.click = async (selector,all=false) => {
        const elements = engine.domActions.elementSelector(selector);
        let result = false;
        for (const e of elements) { result=click(e,'rule') || result; if (!all && result) break; }
        return result;
    };
    engine.domActions.clickElement = async e => click(e,'rule');
    // A cosmetic rule must never hide a consent wall without actually persisting a choice.
    for (const method of ['hide','stylesheet','removeClass','setStyle','addStyle','prehide']) engine.domActions[method] = () => false;
    const rules = RISE_ACCEPT_RULES.filter(r => {
        const context = r.runContext;
        if (context?.urlPattern) { try { if (!new RegExp(context.urlPattern).test(location.href)) return false; } catch { return false; } }
        return window === window.top ? context?.main !== false : context?.frame !== false;
    });
    const fallback = createFallback(state,click,send,dismissed);
    window.__riseCookieConsent = {
        token,
        canAct() { return state.active && !state.manual; },
        shouldResume() { return !state.manual; },
        respond(id,result,expectedToken) { if (expectedToken === token && state.active && !id.startsWith('rise-')) engine.receiveMessageCallback({type:'evalResp',id,result:!!result}); },
        stop(propagate=true) {
            state.active=false; fallback.stop(); HTMLElement.prototype.click=nativeClick;
            removeEventListener('message',receiveStop);
            if (propagate) for (let i=0;i<window.frames.length;i++) window.frames[i].postMessage({riseCookieConsentStop:true,sentAt:performance.timeOrigin+performance.now()},'*');
        },
        dispose() { this.stop(false); removeEventListener('pageshow',pageShow); },
        pending() { return state.active && !state.manual && fallback.pending(); },
        inspect() { return { token, active:state.active, manual:state.manual, clicks:state.clicks, lifecycle:engine.state.lifecycle,
            cmps:engine.state.detectedCmps, panels:fallback.inspect(), performance:fallback.stats(), enginePerformance:engine.measurePerformance() }; }
    };
    engine.initialize({ enabled:true, autoAction:'optIn', enableCosmeticRules:false, enablePrehide:false,
        enableGeneratedRules:true, detectRetries:8, isMainWorld:false, enableHeuristicDetection:false,
        enablePopupMutationObserver:false, heuristicMode:'off', performanceLoggingEnabled:true,
        logs:{lifecycle:false,rulesteps:false,detectionsteps:false,evals:false,errors:false,messages:false,waits:false} }, {autoconsent:rules});
    // Upstream starts generic detection with Promise.all. Hundreds of synchronous DOM
    // queries in one microtask turn can occupy a frame on a long article. Serialize the
    // detectors and yield between short batches without changing their matching rules.
    let detectionQueue = Promise.resolve(), batchStart = performance.now();
    for (const cmp of engine.rules) {
        if (cmp.name === 'Sourcepoint-frame') {
            const detectPopup = cmp.detectPopup.bind(cmp);
            // The upstream paywall safeguard is for opt-out. Its explicit accept-all
            // action remains free in consent-or-pay dialogs and never selects payment.
            cmp.detectPopup = async () => [...document.querySelectorAll('.sp_choice_type_11,.sp_choice_type_ACCEPT_ALL')].some(visible) || detectPopup();
        }
        const detect = cmp.detectCmp.bind(cmp);
        cmp.detectCmp = () => {
            const result = detectionQueue.then(async () => {
                if (!state.active || state.manual) return false;
                if (performance.now()-batchStart >= 4) { await new Promise(resolve=>setTimeout(resolve,0)); batchStart=performance.now(); }
                return detect();
            });
            detectionQueue = result.catch(()=>false);
            return result;
        };
    }
    const receiveStop = event => {
        if (!state.active || window.__riseCookieConsent?.token!==token) return;
        if (event.source===window.parent && event.data?.riseCookieConsentStop===true && event.data.sentAt>=born) window.__riseCookieConsent.stop();
        // A frame of this page answered its banner: the top document stops every frame.
        else if (window===window.top && event.data?.riseCookieConsentDone===true && event.source !== window) finish();
    };
    const pageShow = event => { if (event.persisted) send({type:'resume'}); };
    addEventListener('message',receiveStop);
    addEventListener('pageshow',pageShow);
    // APIs can close consent inside a closed shadow tree. Only providers with an explicit
    // unanswered, visible dialog state are eligible; a saved manual choice is preserved.
    for (const delay of [1200,3500,8000]) setTimeout(() => {
        if (state.active && !state.manual) for (const snippetId of ['RISE_COOKIEBOT_ACCEPT','RISE_ONETRUST_ACCEPT'])
            send({type:'eval',id:`rise-${snippetId}-${delay}`,snippetId});
    },delay);
    settle();
    send({type:'ready'});
})();
