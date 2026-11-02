import test from 'node:test';import assert from 'node:assert/strict';
import {Controller,initialState} from '../src/controller.js';import {Ledger,decodePayload} from '../src/ledger.js';
import {id,record,fakeBrowser,FakeCloud} from './helpers.js';
async function setup(tabs){
 const browser=fakeBrowser(tabs),cloud=new FakeCloud(),state=initialState();state.config.apiToken='api';state.auth.token='start';state.enabled=true;
 const c=new Controller(browser.api,state,{},cloud.fetch);cloud.put(record(1));await c.fetchChanges();await c.browser.bind(1,c.ledger);return {c,browser,cloud};
}
test('two-way create, navigation, reordering, close and token rotation',async()=>{
 const {c,browser,cloud}=await setup();cloud.put(record(1));cloud.put(record(2));
 await c.sync();assert.equal(c.state.status,'ready');assert.equal(browser.all.size,2);
 const one=[...browser.all.values()].find(t=>t.url.endsWith('/1'));one.url='https://local-edit.test';one.title='Local edit';
 await c.sync();assert.equal(decodePayload(cloud.records.get(id(1)).fields.payload.value).tab.url,'https://local-edit.test');
 const remote=structuredClone(c.ledger.records[id(2)]);remote.tab.url='https://remote-edit.test';remote.contentVersion={clock:Date.now()+10000,device:id(900)};remote.position=-1;remote.positionVersion=remote.contentVersion;cloud.put(remote);
 await c.sync();assert.equal([...browser.all.values()].find(t=>t.url==='https://remote-edit.test').index,0);
 const two=[...browser.all.values()].find(t=>t.url==='https://remote-edit.test');browser.all.delete(two.id);await c.sync();
 assert.ok(decodePayload(cloud.records.get(id(2)).fields.payload.value).closedAt);assert.equal(c.state.dirty.length,0);
});
test('remote active closure stays locally, then disappears after switching away',async()=>{
 const {c,browser,cloud}=await setup();cloud.put(record(1));cloud.put(record(2));await c.sync();
 const r=structuredClone(c.ledger.records[id(1)]);r.closedAt={clock:Date.now()+10000,device:id(900)};cloud.put(r);await c.sync();
 assert.equal(browser.all.size,2);assert.equal(c.ledger.tabs.length,1);
 const other=[...browser.all.values()].find(t=>t.url.endsWith('/2'));await browser.api.tabs.update(other.id,{active:true});await c.sync();assert.equal(browser.all.size,1);
});
test('offline edits survive a worker restart and converge when reconnected',async()=>{
 const {c,browser,cloud}=await setup();await c.sync();cloud.fail=true;
 const local=[...browser.all.values()][0];local.url='https://offline.test';await c.sync({force:true});assert.equal(c.state.status,'offline');assert.ok(c.state.dirty.length);
 const restored=new Controller(browser.api,structuredClone(browser.store.rise),structuredClone(browser.session.runtime),cloud.fetch);cloud.fail=false;
 await restored.sync({force:true});assert.equal(restored.state.status,'ready');assert.equal(restored.state.dirty.length,0);assert.ok([...cloud.records.values()].some(r=>decodePayload(r.fields.payload.value).tab.url==='https://offline.test'));
});
test('browser restart matches duplicate URLs by occurrence without closing missing restored tabs',async()=>{
 const {c,browser,cloud}=await setup([{url:'https://example.com/1',active:true},{url:'https://example.com/1'}]);await c.sync();const ids=c.ledger.tabs.map(t=>t.id);
 const local=structuredClone(browser.store.rise);browser.all.clear();browser.add({id:100,url:'https://example.com/1',active:true});
 const restored=new Controller(browser.api,local,{},cloud.fetch);await restored.sync({force:true});assert.equal(browser.all.size,2);assert.deepEqual(restored.ledger.tabs.map(t=>t.id),ids);
});
test('a closed or ambiguous window never mass-deletes or adopts unrelated windows',async()=>{
 const {c,browser}=await setup();await c.sync();browser.all.clear();browser.add({windowId:2,url:'https://unrelated.test',active:true});c.runtime.windowId=null;
 await c.sync({force:true});assert.equal(c.state.status,'window');assert.equal(c.ledger.tabs.length,1);assert.equal(browser.all.size,1);
});
test('concurrent CloudKit edits conflict, merge and retry without force overwrites',async()=>{
 const {c,browser,cloud}=await setup();cloud.put(record(1));await c.sync();
 const one=[...browser.all.values()][0];one.title='Local';
 cloud.conflict=()=>{const r=structuredClone(c.ledger.records[id(1)]);r.closedAt={clock:Date.now()+1000,device:id(900)};cloud.put(r);};
 await c.sync({force:true});assert.equal(c.state.status,'ready');assert.ok(c.ledger.records[id(1)].closedAt);assert.equal(c.state.dirty.length,0);
});
test('account changes stop before any private records are fetched or uploaded',async()=>{
 const {c,cloud}=await setup();await c.sync();cloud.account='other-account';const n=cloud.calls.length;
 await c.sync({force:true});assert.equal(c.state.status,'account');assert.equal(c.state.enabled,false);assert.deepEqual(cloud.calls.slice(n),['users/caller']);
});
test('pagination and deletion tombstones are consumed durably',async()=>{
 const {c,cloud}=await setup();cloud.pageSize=1;cloud.put(record(1));cloud.put(record(2));cloud.put(record(3));await c.sync();assert.equal(c.ledger.tabs.length,3);
 cloud.records.delete(id(2));cloud.changes.push({recordName:id(2),deleted:true});await c.sync();assert.ok(c.ledger.records[id(2)].closedAt);assert.equal(c.state.dirty.length,0);
});
test('disconnect erases account data without closing tabs or touching iCloud',async()=>{
 const {c,browser,cloud}=await setup();await c.sync();const n=cloud.calls.length;await c.disconnect();assert.equal(c.state.accountID,undefined);assert.equal(c.ledger.tabs.length,0);assert.equal(c.cloud.auth.token,undefined);assert.equal(browser.all.size,1);assert.equal(cloud.calls.length,n);
});
test('interrupted remote creation is adopted instead of duplicated',async()=>{
 const {c,browser}=await setup();const r=record(2);c.ledger.merge(r);c.runtime.pendingCreates[id(2)]=r.tab;browser.add({url:r.tab.url});
 await c.browser.snapshot(c.ledger);await c.browser.apply(c.ledger);assert.equal(browser.all.size,2);
});
test('paused sync performs no network or browser mutation',async()=>{
 const {c,cloud,browser}=await setup();c.state.enabled=false;const n=cloud.calls.length;await c.sync();assert.equal(cloud.calls.length,n);assert.equal(browser.all.size,1);
});
test('a user close during a remote install remains a local close after acknowledgement',async()=>{
 const {c,browser}=await setup();await c.capture();const r=record(2);c.ledger.merge(r);
 const move=browser.api.tabs.move;browser.api.tabs.move=async(...args)=>{const result=await move(...args);const imported=[...browser.all.values()].find(t=>c.runtime.bindings[t.id]?.id===id(2));if(imported)browser.all.delete(imported.id);return result;};
 // Put the imported tab at the front so apply performs a move, then close it there.
 c.ledger.records[id(2)].position=-1;
 await c.browser.apply(c.ledger);await c.capture();assert.ok(c.ledger.records[id(2)].closedAt);
});
test('cursor expiry refetches and closes formerly saved records missing from the full snapshot',async()=>{
 const {c,cloud}=await setup();cloud.put(record(2));await c.sync();cloud.records.delete(id(2));cloud.changes=cloud.changes.filter(r=>r.recordName!==id(2));
 const changes=c.cloud.changes.bind(c.cloud);let first=true;c.cloud.changes=async token=>{if(first){first=false;const e=new Error('expired');e.code='CHANGE_TOKEN_EXPIRED';throw e;}return changes(token);};
 await c.sync({force:true});assert.ok(c.ledger.records[id(2)].closedAt);assert.equal(c.state.fullFetch,undefined);
});
test('intentionally closing the bound window does not adopt another matching window',async()=>{
 const {c,browser}=await setup();await c.sync();browser.add({windowId:2,url:'https://example.com/1'});
 for(const [id,t] of browser.all)if(t.windowId===1)browser.all.delete(id);
 c.runtime.windowId=null;c.runtime.closedWindow=true;
 await c.sync({force:true});assert.equal(c.state.status,'window');assert.equal(c.runtime.windowId,null);
});
