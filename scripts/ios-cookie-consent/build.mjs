import { build } from 'esbuild';
import { createHash } from 'node:crypto';
import fs from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { evalSnippets } from '@duckduckgo/autoconsent';

const root = new URL('../../', import.meta.url);
const output = new URL('Apps/iOS/Rise/CookieConsent/', root);
const pkg = new URL('node_modules/@duckduckgo/autoconsent/', import.meta.url);
const all = JSON.parse(await fs.readFile(new URL('rules/rules.json', pkg))).autoconsent;
// Keep real opt-in flows. Cosmetic removal cannot save consent or reliably unlock a page.
const unsafe = value => value && typeof value === 'object' && Object.entries(value).some(([key, child]) =>
    ['hide', 'stylesheet', 'setStyle', 'addStyle', 'removeClass'].includes(key) ||
    (key === 'eval' && /removeAttribute|\.style\s*=|classList\.remove/.test(evalSnippets[child]?.toString() || '')) || unsafe(child));
// PMC's ownership/terms migration notice is not a cookie-consent choice.
const rules = all.filter(r => r.name !== 'pmc-privacy-banner' && r.optIn?.length && !r.cosmetic && !unsafe(r.optIn)).map(r => {
    const { optOut, test, openCmp, prehideSelectors, _metadata, vendorUrl, comment, ...accept } = r;
    if (r.name === 'microsoft.com') {
        // Upstream's page-world eval picks the first Accept button in the document.
        // Restrict the action to the real, visible consent banner in the isolated world.
        accept.detectPopup = [{visible:'#wcpConsentBannerCtrl'}];
        accept.optIn = [{click:'xpath///*[@id="wcpConsentBannerCtrl"]//button[contains(., "Accept") or contains(., "Annehmen") or contains(., "akzeptieren")]'}];
    }
    return accept;
});
await fs.mkdir(output, { recursive: true });
await build({ entryPoints: [fileURLToPath(new URL('runtime.js', import.meta.url))], bundle: true,
    outfile: fileURLToPath(new URL('cookie-consent.js', output)), minify: true, legalComments: 'none',
    target: 'safari17', define: { RISE_ACCEPT_RULES: JSON.stringify(rules) } });
// Native bridge executes these bundled constants, never message-supplied JavaScript.
const allowed = new Set(['EVAL_COOKIEBOT_1','EVAL_COOKIEBOT_2','EVAL_CONSENTMANAGER_1','EVAL_CONSENTMANAGER_2','EVAL_CONSENTMANAGER_4']);
function collect(value) {
    if (!value || typeof value !== 'object') return;
    for (const [key, child] of Object.entries(value)) { if (key === 'eval') allowed.add(child); else collect(child); }
}
collect(rules);
const snippets = Object.fromEntries([...allowed].map(id => [id, `(${evalSnippets[id].toString()})()`]));
// Browser UI APIs persist asynchronously. Await acceptance before invoking closeCMP.
// https://usercentrics.com/beta-docs/available-properties
snippets.EVAL_USERCENTRICS_API_3 = `(async () => { await window.UC_UI.acceptAllConsents(); return true; })()`;
snippets.EVAL_USERCENTRICS_API_1 = `(async () => { await window.UC_UI.closeCMP(); return true; })()`;
snippets.RISE_COOKIEBOT_ACCEPT = `(() => {
    const c = window.Cookiebot;
    if (!c || c.hasResponse || c.dialog?.visible !== true || typeof c.submitCustomConsent !== 'function') return false;
    c.submitCustomConsent(true, true, true); return true;
})()`;
snippets.RISE_ONETRUST_ACCEPT = `(() => {
    const c = window.OneTrust;
    if (!c || typeof c.AllowAll !== 'function' || typeof c.IsAlertBoxClosed !== 'function' || c.IsAlertBoxClosed()) return false;
    c.AllowAll(); return true;
})()`;
await fs.writeFile(new URL('cookie-consent-evals.json', output), JSON.stringify(snippets));
await fs.copyFile(new URL('LICENSE', pkg), new URL('Autoconsent-LICENSE.txt', output));
for (const name of ['tldts-core','tldts-experimental']) {
    await fs.copyFile(new URL(`node_modules/${name}/LICENSE`,import.meta.url),new URL(`${name}-LICENSE.txt`,output));
}
const assets = [];
for (const file of ['cookie-consent.js', 'cookie-consent-evals.json']) {
    const bytes = await fs.readFile(new URL(file, output));
    assets.push({ file, sha256: createHash('sha256').update(bytes).digest('hex') });
}
const version = JSON.parse(await fs.readFile(new URL('package.json', pkg))).version;
await fs.writeFile(new URL('cookie-consent-manifest.json', output), JSON.stringify({ version, rules: rules.length, assets }, null, 2)+'\n');
console.log(`Bundled Autoconsent ${version}: ${rules.length} opt-in rules + 11 CMP adapters + Rise fallback`);
