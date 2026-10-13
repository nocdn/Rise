// Test the site selector and mandatory early exit without driving a browser GUI.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const runtime = fs.readFileSync(new URL('./runtime.js', import.meta.url), 'utf8');
function context(host, pathname = '/') {
    const c = { location: { hostname: host, pathname, search: '', href: 'https://'+host+pathname }, document: { referrer: '' },
        tldts: { getPublicSuffix: h => h.endsWith('.co.uk') ? 'co.uk' : h.split('.').at(-1) } };
    c.top = c; c.self = c; vm.createContext(c); vm.runInContext(runtime, c); return c;
}
const data = { payloads: [
    { kind: 'scriptlet', name: 'set-constant', canonical: 'setConstant', args: ['detector', 'false'] },
    { kind: 'css', key: 'ad', css: '.ad { display:none }' },
], rules: [
    { payload: 0, include: ['example.*'], exclude: ['safe.example.co.uk'], path: '/news' },
    { payload: 1, include: [], exclude: [], path: '' },
], domains: {}, generic: [1], special: [0], exceptions: [], networkExceptions: [] };
assert.equal(context('www.example.co.uk', '/news/article').riseSelect(data).length, 2);
assert.equal(context('www.example.co.uk', '/account').riseSelect(data).length, 1);
assert.equal(context('safe.example.co.uk', '/news').riseSelect(data).length, 1);
assert.equal(context('example.co.uk.evil.com', '/news').riseSelect(data).length, 1);
const exception = { ...data.rules[0], include: ['example.*'] };
const alias = { kind: 'scriptlet', canonical: 'setConstant', args: [] };
const excepted = { ...data, payloads: [...data.payloads, alias], exceptions: [{ ...exception, payload: 2 }] };
assert.equal(context('example.com', '/news').riseSelect(excepted).length, 1);
const genericDisabled = { ...data, networkExceptions: [{ include: [], exclude: [], path: '', pattern: '^https://example\\.com/', flags: 1, frame: '' }] };
assert.equal(context('example.com', '/news').riseSelect(genericDisabled).length, 1);
for (const host of ['youtube.com', 'm.youtube.com', 'WWW.YOUTUBE.COM.', 'youtu.be', 'www.youtubekids.com', 'youtube-nocookie.com']) {
    const c = context(host);
    assert.equal(c.riseContextAllowed(), false, host);
    // Use the actual generated scripts: neither library nor page code is touched.
    Object.defineProperty(c, 'CSS', { get() { throw Error('YouTube touched the CSS engine'); } });
    for (const name of ['adblock-start.js', 'adblock-end.js']) {
        vm.runInContext(fs.readFileSync(new URL('../../Apps/iOS/Rise/Blocking/'+name, import.meta.url), 'utf8'), c, { timeout: 1000 });
    }
}
for (const host of ['notyoutube.com', 'youtube.com.evil.org', 'www.example.com']) assert.equal(context(host).riseContextAllowed(), true);
const linkedFromYouTube = context('www.example.com');
linkedFromYouTube.document.referrer = 'https://www.youtube.com/watch?v=example';
assert.equal(linkedFromYouTube.riseContextAllowed(), true, 'Following a YouTube link must still protect the destination');
console.log('Passed: site/path scopes, exclusions, aliases, generic exceptions, and both bundled YouTube early exits.');
