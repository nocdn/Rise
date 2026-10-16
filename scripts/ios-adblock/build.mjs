// Build-time only: parse the converter's advanced output and embed maintained libraries.
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';
const modules = process.env.RISE_ADBLOCK_NODE_MODULES;
const { RuleParser, QuoteUtils } = await import(pathToFileURL(path.join(modules, '@adguard/agtree/dist/index.js')));
const { scriptlets } = await import(pathToFileURL(path.join(modules, '@adguard/scriptlets/dist/scriptlets/index.js')));
const { minify } = await import(pathToFileURL(path.join(modules, 'terser/main.js')));
const [input, output] = process.argv.slice(2);
const lines = fs.readFileSync(input, 'utf8').split('\n').filter(Boolean);
const runtime = fs.readFileSync(new URL('./runtime.js', import.meta.url), 'utf8');
const tldts = fs.readFileSync(path.join(modules, 'tldts/dist/index.umd.min.js'), 'utf8').replace(/\/\/# sourceMappingURL=.*$/m, '');
const extendedCss = fs.readFileSync(path.join(modules, '@adguard/extended-css/dist/extended-css.min.js'), 'utf8').replace(/\/\/# sourceMappingURL=.*$/m, '');
const functions = [], functionIDs = new Map();
const statistics = { scriptlets: 0, javascript: 0, cosmetics: 0, exceptions: 0, excludedYouTube: 0 };
function functionID(source) {
    if (!functionIDs.has(source)) { functionIDs.set(source, functions.length); functions.push(source); }
    return functionIDs.get(source);
}
function newData() { return { payloads: [], rules: [], exceptions: [], networkExceptions: [], domains: {}, generic: [], special: [] }; }
const start = newData(), end = newData();
const payloadIDs = new Map();
function add(data, scope, payload, exception) {
    const key = (data === start ? 's' : 'e')+JSON.stringify(payload);
    if (!payloadIDs.has(key)) { payloadIDs.set(key, data.payloads.length); data.payloads.push(payload); }
    const rule = { payload: payloadIDs.get(key), ...scope };
    if (exception) { data.exceptions.push(rule); statistics.exceptions++; return; }
    const id = data.rules.length;
    data.rules.push(rule);
    if (!scope.include.length) data.generic.push(id);
    for (const domain of scope.include) {
        if (domain.includes('*') || domain.startsWith('/')) { data.special.push(id); continue; }
        (data.domains[domain] ??= []).push(id);
    }
}
function domains(values) {
    return { include: values.filter(x => !x.exception).map(x => x.value.toLowerCase()),
             exclude: values.filter(x => x.exception).map(x => x.value.toLowerCase()) };
}
function scope(rule) {
    const result = { ...domains(rule.domains?.children ?? []), path: '' };
    for (const modifier of rule.modifiers?.children ?? []) {
        if (modifier.name.value === 'domain') {
            for (const domain of modifier.value.value.split('|')) (domain.startsWith('~') ? result.exclude : result.include).push(domain.replace(/^~/, ''));
        } else if (modifier.name.value === 'path') result.path = modifier.value.value;
        else throw new Error('Unsupported cosmetic modifier: '+modifier.name.value);
    }
    return result;
}
function youtube(domain) {
    return ['youtube.com', 'youtube-nocookie.com', 'youtu.be', 'youtubekids.com'].some(x => domain === x || domain.endsWith('.'+x));
}
function payloadKey(source) { return createHash('sha256').update(source).digest('hex'); }
function patternRegex(pattern) {
    if (pattern.startsWith('/') && pattern.endsWith('/')) return pattern.slice(1, -1);
    let prefix = '', suffix = '';
    if (pattern.startsWith('||')) { prefix = '^[a-z][a-z0-9+.-]*:\\/\\/(?:[^/]*\\.)?'; pattern = pattern.slice(2); }
    else if (pattern.startsWith('|')) { prefix = '^'; pattern = pattern.slice(1); }
    if (pattern.endsWith('|')) { suffix = '$'; pattern = pattern.slice(0, -1); }
    return prefix+[...pattern].map(c => c === '*' ? '.*' : c === '^' ? '(?:[^a-zA-Z0-9_.%-]|$)' : c.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('')+suffix;
}
// A $badfilter exception cancels the matching exception, rather than enabling it.
const badFilters = new Set(lines.filter(l => /[,\$]badfilter(?:,|$)/.test(l)).map(l => l.replace(/,badfilter(?=,|$)|badfilter,|\$badfilter$/, '')));
for (const line of lines) {
    const rule = RuleParser.parse(line);
    if (rule.category === 'Network') {
        if (badFilters.has(line)) continue;
        const mods = rule.modifiers?.children ?? [];
        if (mods.some(m => m.name.value === 'badfilter')) continue;
        let flags = 0;
        for (const m of mods) flags |= ({ generichide: 1, elemhide: 2, jsinject: 4, document: 7 })[m.name.value] ?? 0;
        if (!flags) continue;
        const domain = mods.find(m => m.name.value === 'domain')?.value?.value ?? '';
        const frame = mods.some(m => m.name.value === 'subdocument') ? 'sub' : mods.some(m => m.name.value === 'document') ? 'main' : '';
        const entry = { ...domains(domain.split('|').filter(Boolean).map(d => ({ value: d.replace(/^~/, ''), exception: d.startsWith('~') }))),
                        path: '', pattern: patternRegex(rule.pattern.value), flags, frame };
        start.networkExceptions.push(entry); end.networkExceptions.push(entry);
        continue;
    }
    const restriction = scope(rule);
    if (restriction.include.length && restriction.include.every(youtube)) { statistics.excludedYouTube++; continue; }
    if (rule.type === 'ScriptletInjectionRule') {
        for (const params of rule.body.children) {
            const [name, ...args] = params.children.map(p => QuoteUtils.removeQuotesAndUnescape(p.value));
            const fn = name ? scriptlets.getScriptletFunction(name) : null;
            if (!rule.exception && !fn) throw new Error('Unknown scriptlet: '+name);
            add(start, restriction, { kind: 'scriptlet', name: name ?? '', canonical: fn?.name ?? name ?? '', args,
                                    function: fn ? functionID(fn.toString()) : -1 }, rule.exception);
            if (!rule.exception) statistics.scriptlets++;
        }
    } else if (rule.type === 'JsInjectionRule') {
        const source = rule.body.value;
        add(start, restriction, { kind: 'js', key: payloadKey(source), function: functionID('function(){'+source+'}') }, rule.exception);
        if (!rule.exception) statistics.javascript++;
    } else if (rule.type === 'CssInjectionRule' || rule.type === 'ElementHidingRule') {
        const selector = rule.body.selectorList.value;
        const css = selector+(rule.body.remove ? ' { remove: true; }' : ' { '+(rule.body.declarationList?.value ?? 'display: none !important;')+' }');
        add(end, restriction, { kind: 'css', key: payloadKey(css), selector, css, extended: rule.body.remove || /:(contains|has-text|matches-|xpath|upward|remove|nth-ancestor)|\[-ext-/i.test(selector) }, rule.exception);
        if (!rule.exception) statistics.cosmetics++;
    } else throw new Error('Unsupported rule: '+line);
}
for (const data of [start, end]) data.special = [...new Set(data.special)];
const guard = runtime.slice(0, runtime.indexOf('function riseSelect'));
// Guard before library allocation: YouTube doesn't run even the selector engine.
const prelude = guard+'if (!riseContextAllowed()) return;\n'+tldts+'\n'+runtime.slice(runtime.indexOf('function riseSelect'));
const startSource = '(function(){'+prelude+'\nconst data='+JSON.stringify(start)+';\nconst functions={'+functions.map((f, i) => i+':'+f).join(',')+'};\n'+`
    for (const rule of riseSelect(data)) {
        try {
            if (rule.kind === 'scriptlet') functions[rule.function]({ name: rule.name, args: rule.args, verbose: false, engine: 'adguard', version: '2.5.1' }, rule.args);
            else functions[rule.function]();
        } catch {}
    }
})();`;
const endSource = '(function(){'+prelude+'\nconst data='+JSON.stringify(end)+';\n'+`
    const plain = [], extended = [];
    for (const rule of riseSelect(data)) {
        if (!rule.extended && CSS.supports('selector('+rule.selector+')')) plain.push(rule.css);
        else extended.push(rule.css);
    }
    if (plain.length) {
        const style = document.createElement('style'); style.textContent = plain.join('\\n');
        (document.head || document.documentElement).appendChild(style);
    }
    if (!extended.length) return;
`+extendedCss+'\ntry { new ExtendedCss({ styleSheet: extended.join("\\n") }).apply(); } catch {}\n})();';
for (const [name, source] of [['adblock-start.js', startSource], ['adblock-end.js', endSource]]) {
    const result = await minify(source, { ecma: 2020, compress: false, mangle: true, format: { comments: false } });
    fs.writeFileSync(path.join(output, name), '// Generated from AdGuard filters; GPL-3.0. See Blocking-LICENSE.txt and Blocking-NOTICES.txt.\n'+result.code+'\n');
}
fs.writeFileSync(path.join(output, 'advanced-stats.json'), JSON.stringify(statistics));
