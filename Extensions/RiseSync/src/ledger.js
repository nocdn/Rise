// Wire compatible with Sources/RiseCore/SharedTabsLedger.swift. No browser APIs.
export const uuid = () => crypto.randomUUID().toUpperCase();
const UUID = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/i;
const canonical = v => Array.isArray(v) ? v.map(canonical) : v && typeof v === 'object' ? Object.fromEntries(Object.keys(v).sort().filter(k => v[k] !== undefined).map(k => [k, canonical(v[k])])) : v;
export const equal = (a, b) => JSON.stringify(canonical(a)) === JSON.stringify(canonical(b));
export function allows(url) {
  if (typeof url !== 'string' || new TextEncoder().encode(url).length > 8192) return false;
  try { const u = new URL(url); return ['http:', 'https:'].includes(u.protocol) && !!u.hostname && !u.username && !u.password; }
  catch { return false; }
}
function tabValue(tab) {
  if (!tab || !UUID.test(tab.id) || (tab.url != null && !allows(tab.url))) throw new Error('Invalid shared tab');
  const result = { id: tab.id.toUpperCase() };
  if (tab.url != null) result.url = tab.url;
  if (typeof tab.title === 'string') result.title = tab.title;
  const h = tab.navigationHistory;
  if (h && Array.isArray(h.entries) && h.entries.length <= 100 && Number.isInteger(h.index) &&
      h.entries[h.index]?.url === tab.url && h.entries.every(e => allows(e.url)) &&
      new TextEncoder().encode(JSON.stringify(h)).length <= 750000) result.navigationHistory = structuredClone(h);
  return result;
}
const versionValid = v => v && Number.isSafeInteger(v.clock) && v.clock >= 0 && UUID.test(v.device);
export function compare(a, b) {
  return a.clock === b.clock ? (a.device.toUpperCase() < b.device.toUpperCase() ? -1 : a.device.toUpperCase() === b.device.toUpperCase() ? 0 : 1) : a.clock < b.clock ? -1 : 1;
}
function preservingHistory(tab, previous) {
  const value = structuredClone(tab);
  if (!value.navigationHistory && value.url === previous.url && previous.navigationHistory) value.navigationHistory = structuredClone(previous.navigationHistory);
  return value;
}
export function validRecord(input) {
  try {
    if (!versionValid(input.contentVersion) || !versionValid(input.positionVersion) ||
        (input.closedAt != null && !versionValid(input.closedAt)) || !Number.isFinite(input.position)) return null;
    const r = { tab: tabValue(input.tab), contentVersion: input.contentVersion, position: input.position, positionVersion: input.positionVersion };
    if (input.closedAt) r.closedAt = input.closedAt;
    return r;
  } catch { return null; }
}
export class Ledger {
  constructor(data = {}) {
    this.deviceID = data.deviceID ?? uuid(); this.clock = data.clock ?? 0;
    this.records = data.records ?? {}; this.observedTabs = data.observedTabs ?? [];
  }
  nextVersion() { this.clock = Math.max(this.clock + 1, Date.now()); return { clock: this.clock, device: this.deviceID }; }
  get tabs() {
    return Object.values(this.records).filter(r => !r.closedAt).sort((a,b) => a.position - b.position ||
      (a.tab.id < b.tab.id ? -1 : a.tab.id > b.tab.id ? 1 : 0)).map(r => structuredClone(r.tab));
  }
  capture(snapshot) {
    snapshot = snapshot.map(tabValue).map(t => this.records[t.id] ? preservingHistory(t, this.records[t.id].tab) : t);
    const previous = new Map(this.observedTabs.map(t => [t.id, t]));
    const indices = new Map(this.observedTabs.map((t,i) => [t.id,i]));
    const ids = new Set(snapshot.map(t => t.id)), changed = new Set();
    for (const id of previous.keys()) {
      const r = this.records[id];
      if (!ids.has(id) && r && !r.closedAt) { r.closedAt = this.nextVersion(); changed.add(id); }
    }
    snapshot.forEach((tab, index) => {
      let r = this.records[tab.id];
      if (r) {
        if (r.closedAt) return;
        if (previous.has(tab.id) && !equal(previous.get(tab.id), tab)) { r.tab = tab; r.contentVersion = this.nextVersion(); changed.add(tab.id); }
        if (indices.get(tab.id) !== index) { r.position = index; r.positionVersion = this.nextVersion(); changed.add(tab.id); }
      } else {
        const v = this.nextVersion(); r = {tab, contentVersion:v, position:index, positionVersion:v};
        this.records[tab.id] = r; changed.add(tab.id);
      }
    });
    this.observedTabs = structuredClone(snapshot); return changed;
  }
  merge(input) {
    const r = validRecord(input); if (!r) return false;
    this.clock = Math.max(this.clock, r.contentVersion.clock, r.positionVersion.clock, r.closedAt?.clock ?? 0);
    const old = this.records[r.tab.id]; let next = structuredClone(r);
    if (old) {
      next = structuredClone(old);
      if (compare(old.contentVersion, r.contentVersion) < 0) { next.tab = preservingHistory(r.tab, old.tab); next.contentVersion = r.contentVersion; }
      else next.tab = preservingHistory(old.tab, r.tab);
      if (compare(old.positionVersion, r.positionVersion) < 0) { next.position = r.position; next.positionVersion = r.positionVersion; }
      if (r.closedAt && (!next.closedAt || compare(next.closedAt, r.closedAt) < 0)) next.closedAt = r.closedAt;
    }
    const changed = !equal(old, next); this.records[r.tab.id] = next; return changed;
  }
  close(id) {
    const r = this.records[id]; if (!r || r.closedAt) return false;
    r.closedAt = this.nextVersion(); return true;
  }
}
export function encodePayload(record) {
  const bytes = new TextEncoder().encode(JSON.stringify(record)); let s = '';
  for (let i = 0; i < bytes.length; i += 8192) s += String.fromCharCode(...bytes.subarray(i, i + 8192));
  return btoa(s);
}
export function decodePayload(value) {
  if (typeof value !== 'string' || value.length > 1400000) return null;
  try { return validRecord(JSON.parse(new TextDecoder('utf-8', {fatal:true}).decode(Uint8Array.from(atob(value), c => c.charCodeAt(0))))); }
  catch { return null; }
}
