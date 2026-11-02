import {allows, uuid} from './ledger.js';

const address = t => t.pendingUrl || t.url;
const portable = (t, b) => allows(address(t)) || (b && b.url == null && /^(chrome|edge|brave|helium):\/\/newtab\/?$|^about:blank$/.test(address(t) ?? ''));

// A binding is a tab identity, never just a URL: two copies of a URL remain two tabs.
export class BrowserTabs {
  constructor(api, state, runtime, save) { this.api = api; this.state = state; this.runtime = runtime; this.save = save; }
  async windows() { return (await this.api.windows.getAll({populate:true, windowTypes:['normal']})).filter(w => !w.incognito); }
  async live() {
    if (this.runtime.windowId == null) return null;
    try {
      const w = await this.api.windows.get(this.runtime.windowId, {populate:true});
      return w.incognito || w.type !== 'normal' ? null : w.tabs.sort((a,b) => a.index-b.index);
    } catch { return null; }
  }
  async recover(ledger) {
    if (this.runtime.closedWindow) return false;
    if (await this.live()) return true;
    this.runtime.windowId = null;
    if (!this.state.checkpoint?.length) return false;
    const windows = await this.windows();
    // Only reconnect automatically when the restored URLs identify a unique window.
    const scored = windows.map(w => {
      const counts = new Map();
      for (const t of w.tabs) counts.set(address(t), (counts.get(address(t)) ?? 0) + 1);
      let score = 0;
      for (const t of this.state.checkpoint) if (counts.get(t.url) > 0) { score++; counts.set(t.url, counts.get(t.url)-1); }
      return {w,score};
    }).sort((a,b) => b.score-a.score);
    if (!scored[0]?.score || scored[0].score === scored[1]?.score) return false;
    await this.bind(scored[0].w.id, ledger, {restoring:true}); return true;
  }
  async bind(windowId, ledger, {restoring=false} = {}) {
    const w = await this.api.windows.get(windowId, {populate:true});
    if (w.incognito || w.type !== 'normal') throw new Error('Choose a regular browser window.');
    const pool = (this.state.checkpoint ?? []).filter(t => restoring || !ledger.records[t.id]?.closedAt).map(t => structuredClone(t));
    for (const tab of ledger.tabs) if (!pool.some(t => t.id === tab.id)) pool.push(tab);
    this.runtime = Object.assign(this.runtime, {windowId, closedWindow:false, bindings:{}, pendingCreates:{}});
    for (const tab of w.tabs.sort((a,b) => a.index-b.index)) {
      if (!allows(address(tab))) continue;
      const i = pool.findIndex(t => t.url === address(tab));
      const matched = i >= 0 ? pool.splice(i,1)[0] : null;
      this.runtime.bindings[tab.id] = {id:matched?.id ?? uuid(), url:address(tab), title:matched?.title ?? tab.title};
    }
    // Missing restored tabs are not closes. They will be reimported from iCloud.
    ledger.observedTabs = [];
    await this.save();
  }
  async snapshot(ledger) {
    const tabs = await this.live(); if (!tabs) return null;
    const liveIDs = new Set(tabs.map(t => String(t.id)));
    for (const id of Object.keys(this.runtime.bindings)) if (!liveIDs.has(id)) delete this.runtime.bindings[id];
    // Recover an interrupted tabs.create without creating a duplicate on worker restart.
    for (const [id, value] of Object.entries(this.runtime.pendingCreates)) {
      let found = tabs.find(t => this.runtime.bindings[t.id]?.id === id);
      found ??= tabs.find(t => !this.runtime.bindings[t.id] && address(t) === (value.url ?? 'chrome://newtab/'));
      if (found) { this.runtime.bindings[found.id] = value; delete this.runtime.pendingCreates[id]; }
    }
    const result = [];
    for (const tab of tabs) {
      let b = this.runtime.bindings[tab.id];
      if (!portable(tab,b)) { delete this.runtime.bindings[tab.id]; continue; }
      if (!b) b = this.runtime.bindings[tab.id] = {id:uuid(),url:address(tab),title:tab.title};
      let url = allows(address(tab)) ? address(tab) : undefined;
      let title = tab.status === 'complete' ? tab.title : b.title;
      if (b.pending) {
        if (url === b.pending.to) {
          if (tab.status === 'complete') delete b.pending; else title = b.title;
        } else if (url === b.pending.from) { url = b.pending.to; title = b.title; }
        else delete b.pending; // A user navigation wins over the pending remote navigation.
      }
      // Chromium cannot restore portable history. Preserve it on title-only edits.
      const value = {id:b.id, ...(url == null ? {} : {url}), ...(title == null ? {} : {title})};
      b.url = url; b.title = title; result.push(value);
    }
    return result;
  }
  async checkpoint(snapshot) {
    if (snapshot) this.state.checkpoint = structuredClone(snapshot);
    await this.save();
  }
  async apply(ledger) {
    let tabs = await this.live(); if (!tabs) return false;
    const wanted = ledger.tabs, desired = new Map(wanted.map(t => [t.id,t]));
    for (const tab of tabs) {
      const b = this.runtime.bindings[tab.id]; if (!b) continue;
      if (!desired.has(b.id) && ledger.records[b.id]?.closedAt && !tab.active) {
        // Check again immediately before closing: never close a newly selected tab.
        if ((await this.api.tabs.get(tab.id)).active) continue;
        await this.api.tabs.remove(tab.id); delete this.runtime.bindings[tab.id]; await this.save();
      }
    }
    tabs = await this.live(); if (!tabs) return false;
    for (const value of wanted) {
      let tab = tabs.find(t => this.runtime.bindings[t.id]?.id === value.id);
      if (!tab) {
        const binding = {id:value.id,url:value.url,title:value.title};
        this.runtime.pendingCreates[value.id] = binding; await this.save();
        tab = await this.api.tabs.create({windowId:this.runtime.windowId, url:value.url ?? 'chrome://newtab/', active:false});
        this.runtime.bindings[tab.id] = binding; delete this.runtime.pendingCreates[value.id];
        tabs.push(tab);
        if (!ledger.observedTabs.some(t => t.id === value.id)) ledger.observedTabs.push(structuredClone(value));
        await this.save();
      } else if ((allows(address(tab)) ? address(tab) : undefined) !== value.url) {
        const b = this.runtime.bindings[tab.id];
        b.pending = {from:address(tab),to:value.url}; b.url = value.url; b.title = value.title;
        await this.save();
        await this.api.tabs.update(tab.id, {url:value.url ?? 'chrome://newtab/'});
        ledger.observedTabs = ledger.observedTabs.map(t => t.id === value.id ? structuredClone(value) : t);
        await this.save();
      }
    }
    // Pinned tabs keep Chromium's mandatory pinned/unpinned boundary and local pin state.
    tabs = await this.live(); if (!tabs) return false;
    const order = wanted.map(v => tabs.find(t => this.runtime.bindings[t.id]?.id === v.id)).filter(Boolean);
    const arranged = [...order.filter(t => t.pinned), ...order.filter(t => !t.pinned)];
    const slots = tabs.filter(t => arranged.some(a => a.id === t.id)).map(t => t.index);
    for (let i=0; i<arranged.length; i++) {
      const current = await this.api.tabs.get(arranged[i].id);
      if (current.index !== slots[i]) await this.api.tabs.move(current.id, {index:slots[i]});
    }
    // Acknowledge only what was actually installed; deferred inserts cannot become closes.
    const snapshot = await this.snapshot(ledger);
    if (snapshot) {
      const previous = new Map(ledger.observedTabs.map(t => [t.id,t]));
      ledger.observedTabs = snapshot.map(t => structuredClone(desired.get(t.id) ?? previous.get(t.id) ?? t));
      // A user close during installation must still be observed by the next capture.
      const actual = new Set(snapshot.map(t => t.id));
      for (const value of wanted) if (!actual.has(value.id)) ledger.observedTabs.push(structuredClone(value));
      await this.checkpoint(snapshot);
    }
    return true;
  }
}
