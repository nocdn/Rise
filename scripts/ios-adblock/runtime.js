// Embedded into each generated WKUserScript. No network fetches or runtime eval.
function riseExcluded(host) {
    host = host.toLowerCase().replace(/\.+$/, '');
    return ['youtube.com', 'youtube-nocookie.com', 'youtu.be', 'youtubekids.com'].some(d => host === d || host.endsWith('.'+d));
}
function riseContextAllowed() {
    if (riseExcluded(location.hostname)) return false;
    // The native policy installs no scripts at all for a YouTube top-level page.
    // Also protect same-origin frames and top URLs available through referrer.
    try { if (riseExcluded(top.location.hostname)) return false; } catch {}
    try { if (self !== top && document.referrer && riseExcluded(new URL(document.referrer).hostname)) return false; } catch {}
    return true;
}
function riseSelect(data) {
    const host = location.hostname.toLowerCase().replace(/\.+$/, '');
    const publicSuffix = tldts.getPublicSuffix(host);
    const entity = publicSuffix && host.endsWith('.'+publicSuffix) ? host.slice(0, -publicSuffix.length-1) : host;
    function domainMatches(domain) {
        if (domain.startsWith('/') && domain.endsWith('/')) {
            try { return new RegExp(domain.slice(1, -1)).test(host); } catch { return false; }
        }
        if (domain.endsWith('.*')) {
            const base = domain.slice(0, -2);
            return entity === base || entity.endsWith('.'+base);
        }
        return host === domain || host.endsWith('.'+domain);
    }
    function scoped(rule) {
        if (rule.include.length && !rule.include.some(domainMatches)) return false;
        if (rule.exclude.some(domainMatches)) return false;
        if (rule.path) {
            if (rule.path.startsWith('/') && rule.path.endsWith('/') && rule.path.length > 1) {
                // AdGuard path modifiers use /regex/ or a plain path prefix.
                try { if (!new RegExp(rule.path.slice(1, -1)).test(location.pathname+location.search)) return false; } catch { return false; }
            } else if (!(location.pathname+location.search).startsWith(rule.path)) return false;
        }
        return true;
    }
    const ids = new Set(data.generic);
    for (let suffix = host; suffix; suffix = suffix.includes('.') ? suffix.slice(suffix.indexOf('.')+1) : '') {
        for (const id of data.domains[suffix] || []) ids.add(id);
    }
    for (const id of data.special) if (scoped(data.rules[id])) ids.add(id);
    const exceptions = data.exceptions.filter(scoped).map(r => data.payloads[r.payload]);
    let flags = 0;
    for (const exception of data.networkExceptions) {
        if (!scoped(exception) || (exception.frame === 'main' && self !== top) || (exception.frame === 'sub' && self === top)) continue;
        try { if (new RegExp(exception.pattern, 'i').test(location.href)) flags |= exception.flags; } catch {}
    }
    const selected = new Set();
    for (const id of ids) {
        const rule = data.rules[id];
        if (!scoped(rule)) continue;
        const payload = data.payloads[rule.payload];
        if ((payload.kind === 'css' && (flags & 2 || !rule.include.length && flags & 1)) ||
            (payload.kind !== 'css' && flags & 4)) continue;
        const excepted = exceptions.some(e => {
            if (e.kind !== payload.kind) return false;
            if (e.kind === 'scriptlet') return (!e.canonical || e.canonical === payload.canonical) && e.args.every((a, i) => a === payload.args[i]);
            return e.key === payload.key || !e.key;
        });
        if (!excepted) selected.add(rule.payload);
    }
    return [...selected].map(id => data.payloads[id]);
}
