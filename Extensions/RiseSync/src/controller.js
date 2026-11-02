import {DEFAULT_CONFIG, API_TOKENS} from './config.js';
import {Ledger, equal, encodePayload, decodePayload} from './ledger.js';
import {CloudKit, CloudError, authTokenFromRedirect} from './cloudkit.js';
import {BrowserTabs} from './browser.js';

export function initialState() {
  return {version:1,config:{...DEFAULT_CONFIG},auth:{},enabled:false,
    ledger:new Ledger(),dirty:[],tags:{},checkpoint:[],status:'setup',message:'Connect this browser to your Rise tabs.'};
}
export class Controller {
  constructor(api, state, runtime, fetcher) {
    this.api=api; this.state=state; this.runtime=runtime; this.fetcher=fetcher;
    this.ledger=new Ledger(state.ledger); state.ledger=this.ledger;
    runtime.bindings ??= {}; runtime.pendingCreates ??= {};
    this.browser=new BrowserTabs(api,state,runtime,()=>this.save());
    this.cloud=new CloudKit(state.config,state.auth,()=>this.save(),fetcher);
  }
  async save() {
    // Local storage commits ledger + dirty queue together. Session bindings survive worker sleep.
    await this.api.storage.local.set({rise:this.state});
    await this.api.storage.session.set({runtime:this.runtime});
  }
  mark(ids) { this.state.dirty=[...new Set([...this.state.dirty,...ids])]; }
  async capture() {
    const snapshot=await this.browser.snapshot(this.ledger);
    if (!snapshot) return false;
    this.mark(this.ledger.capture(snapshot)); await this.browser.checkpoint(snapshot); return true;
  }
  async receive(record) {
    const id=record.recordName?.toUpperCase();
    if (record.deleted) {
      if (this.ledger.close(id)) this.mark([id]); delete this.state.tags[id]; return;
    }
    if (record.recordType !== 'RiseTab') return;
    const value=decodePayload(record.fields?.payload?.value);
    if (!value || value.tab.id !== id) throw new Error('iCloud returned an invalid Rise tab. Sync stopped before applying it.');
    this.ledger.merge(value); this.state.tags[id]=record.recordChangeTag;
    if (!equal(this.ledger.records[id],value)) this.mark([id]);
  }
  async fetchChanges() {
    let reset=false;
    for (let page=0; page<1000; page++) {
      let zone;
      try { zone=await this.cloud.changes(this.state.syncToken); }
      catch(e) {
        if (['CHANGE_TOKEN_EXPIRED','SYNC_TOKEN_EXPIRED'].includes(e.code) && !reset) {
          this.state.syncToken=null; this.state.fullFetch={known:Object.keys(this.state.tags),seen:[]}; reset=true; await this.save(); continue;
        }
        throw e;
      }
      for (const record of zone.records ?? []) {
        await this.receive(record);
        if (this.state.fullFetch && !record.deleted && record.recordType==='RiseTab') this.state.fullFetch.seen.push(record.recordName.toUpperCase());
      }
      this.state.syncToken=zone.syncToken; await this.save();
      if (!zone.moreComing) {
        if (this.state.fullFetch) {
          const seen=new Set(this.state.fullFetch.seen);
          for (const id of this.state.fullFetch.known) if (!seen.has(id)) {
            if (this.ledger.close(id)) this.mark([id]); delete this.state.tags[id];
          }
          delete this.state.fullFetch; await this.save();
        }
        return;
      }
      if (!zone.syncToken) throw new Error('iCloud did not return a change cursor.');
    }
    throw new Error('iCloud has more changes. Sync again to continue.');
  }
  async upload() {
    // Small batches keep requests well under CloudKit's 2 MB request limit, including history.
    for (let pass=0; pass<3 && this.state.dirty.length; pass++) {
      let batch=[], size=0;
      for (const id of this.state.dirty) {
        const value=this.ledger.records[id]; if (!value) continue;
        const payload=encodePayload(value);
        if (batch.length && (size+payload.length>1500000 || batch.length>=100)) break;
        size+=payload.length;
        const tag=this.state.tags[id];
        batch.push({operationType:tag ? 'update':'create',record:{recordName:id,recordType:'RiseTab',
          ...(tag ? {recordChangeTag:tag}:{}),fields:{payload:{type:'BYTES',value:payload}}}});
      }
      if (!batch.length) return;
      const sent=new Map(batch.map(op=>[op.record.recordName, structuredClone(this.ledger.records[op.record.recordName])]));
      const results=await this.cloud.modify(batch), conflicts=[];
      for (const r of results) {
        const id=r.recordName?.toUpperCase(); if (!sent.has(id)) throw new Error('Unexpected iCloud upload response.');
        if (['CONFLICT','EXISTS','NOT_FOUND'].includes(r.serverErrorCode)) { conflicts.push(id); continue; }
        if (r.serverErrorCode) throw new CloudError(r);
        await this.receive(r);
        if (equal(this.ledger.records[id],sent.get(id))) this.state.dirty=this.state.dirty.filter(x=>x!==id);
        await this.save();
      }
      if (conflicts.length) {
        for (const r of await this.cloud.lookup(conflicts)) {
          const id=r.recordName?.toUpperCase();
          if (r.serverErrorCode==='NOT_FOUND') {
            delete this.state.tags[id];
            // Missing previously saved records are closures, matching native Rise.
            if (this.ledger.close(id)) this.mark([id]);
          } else if (r.serverErrorCode) throw new CloudError(r);
          else await this.receive(r);
        }
        await this.save();
      }
    }
  }
  async sync({force=false}={}) {
    if (!this.state.enabled || !this.state.auth.token) return;
    if (!await this.browser.recover(this.ledger)) {
      this.state.status='window'; this.state.message='Choose the window to sync. Your shared tabs are safe in iCloud.'; await this.save(); return;
    }
    await this.capture();
    if (!force && this.state.retryAt>Date.now()) return;
    this.state.status='syncing'; this.state.message='Bringing your tabs together…'; await this.save();
    try {
      const user=await this.cloud.user();
      if (!user.userRecordName) throw new CloudError();
      if (this.state.accountID && user.userRecordName!==this.state.accountID) {
        this.state.enabled=false; this.state.status='account';
        this.state.message='The iCloud account changed. Disconnect before connecting the new account.'; await this.save(); return;
      }
      this.state.accountID=user.userRecordName;
      await this.fetchChanges();
      // Capture edits that happened while the fetch was in flight before installing remote changes.
      await this.capture();
      await this.browser.apply(this.ledger);
      await this.capture();
      await this.upload();
      await this.capture();
      // Conflict merges can introduce a closure or navigation that also needs applying.
      await this.browser.apply(this.ledger);
      this.state.lastSync=Date.now(); this.state.failures=0; this.state.retryAt=0;
      this.state.status='ready'; this.state.message='Your tabs are together.';
    } catch(e) {
      const auth=['AUTHENTICATION_REQUIRED','AUTHENTICATION_FAILED'].includes(e.code);
      this.state.status=auth ? 'signin':'offline'; this.state.message=e.message;
      this.state.failures=(this.state.failures??0)+1;
      this.state.retryAt=Date.now()+Math.max(e.retryAfter??0, Math.min(300, 15*2**Math.min(this.state.failures,5)))*1000;
    }
    await this.save();
  }
  async connect(config,windowId) {
    if (this.state.accountID) throw new Error('Disconnect before changing your iCloud connection.');
    config.apiToken ??= API_TOKENS[config.environment];
    if (!config.apiToken?.trim() || !['development','production'].includes(config.environment)) throw new Error('Enter a CloudKit API token and choose an environment.');
    this.state.config={apiToken:config.apiToken.trim(),environment:config.environment};
    this.cloud=new CloudKit(this.state.config,this.state.auth,()=>this.save(),this.fetcher);
    try { await this.cloud.user(); }
    catch(e) {
      if (e.code!=='AUTHENTICATION_REQUIRED' || !e.redirectURL) throw e;
      const signIn=new URL(e.redirectURL);
      if (signIn.protocol!=='https:' || !(signIn.hostname==='apple.com' || signIn.hostname.endsWith('.apple.com') || signIn.hostname.endsWith('.apple-cloudkit.com'))) throw new Error('Unexpected iCloud sign-in address.');
      const callback=this.api.identity.getRedirectURL();
      const result=await this.api.identity.launchWebAuthFlow({url:signIn.href,interactive:true});
      this.state.auth.token=authTokenFromRedirect(result,callback); await this.save();
    }
    const user=await this.cloud.user();
    if (!user.userRecordName) throw new CloudError();
    this.state.accountID=user.userRecordName;
    this.state.status='window'; this.state.enabled=true; await this.save();
    // Fetch before matching existing PC tabs so initial setup adopts by occurrence.
    await this.fetchChanges();
    await this.browser.bind(windowId,this.ledger);
    this.state.enabled=true; await this.save(); await this.sync({force:true});
  }
  async signIn() {
    const account=this.state.accountID;
    // Keep the old ledger isolated if a different account is chosen during reauthentication.
    const cloud=new CloudKit(this.state.config,{},async()=>{},this.fetcher);
    try { await cloud.user(); } catch(e) {
      if (e.code!=='AUTHENTICATION_REQUIRED' || !e.redirectURL) throw e;
      const u=new URL(e.redirectURL);
      if (u.protocol!=='https:' || !/(^|\.)(apple\.com|apple-cloudkit\.com)$/.test(u.hostname)) throw new Error('Unexpected iCloud sign-in address.');
      this.state.auth.token=authTokenFromRedirect(await this.api.identity.launchWebAuthFlow({url:u.href,interactive:true}),this.api.identity.getRedirectURL());
      await this.save();
    }
    const user=await this.cloud.user();
    if (user.userRecordName!==account) {
      this.state.enabled=false; this.state.status='account'; this.state.message='A different iCloud account was selected. Disconnect to set it up safely.';
      await this.save(); return;
    }
    this.state.enabled=true; await this.sync({force:true});
  }
  async disconnect() {
    const fresh=initialState();
    Object.keys(this.state).forEach(k=>delete this.state[k]); Object.assign(this.state,fresh);
    this.ledger=new Ledger(fresh.ledger); this.state.ledger=this.ledger;
    this.runtime.windowId=null;this.runtime.bindings={};this.runtime.pendingCreates={};
    this.browser=new BrowserTabs(this.api,this.state,this.runtime,()=>this.save());
    this.cloud=new CloudKit(this.state.config,this.state.auth,()=>this.save(),this.fetcher);
    await this.save();
  }
  async view() {
    const windows=await this.browser.windows();
    return {status:this.state.status,message:this.state.message,enabled:this.state.enabled,connected:!!this.state.accountID,
      environment:this.state.config.environment,configured:!!this.state.config.apiToken,callback:this.api.identity.getRedirectURL(),
      origin:this.api.runtime.getURL('').replace(/\/$/,''),lastSync:this.state.lastSync, pending:this.state.dirty.length,
      windowId:this.runtime.windowId,windows:windows.map(w=>({id:w.id,count:w.tabs.length,title:w.tabs.find(t=>t.active)?.title??'Browser window'})),
      tabs:this.ledger.tabs.map(t=>({id:t.id,title:t.title,url:t.url})),
      held:Object.values(this.runtime.bindings).filter(b=>this.ledger.records[b.id]?.closedAt).length};
  }
}
