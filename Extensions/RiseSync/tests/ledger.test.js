import test from 'node:test';import assert from 'node:assert/strict';
import {Ledger,allows,equal,encodePayload,decodePayload} from '../src/ledger.js';import {id,record} from './helpers.js';
test('closures dominate offline edits and reopening uses a fresh identity',()=>{
  const a=new Ledger(),b=new Ledger();a.capture([record(1).tab]);b.merge(a.records[id(1)]);b.observedTabs=b.tabs;
  a.capture([]);b.capture([{...record(1).tab,url:'https://offline.test/'}]);b.merge(a.records[id(1)]);a.merge(b.records[id(1)]);
  assert.deepEqual(a.tabs,[]);assert.deepEqual(b.tabs,[]);
  a.capture([{...record(1).tab,id:id(2)}]);assert.equal(a.tabs[0].id,id(2));
});
test('independent content and ordering merges converge',()=>{
 const a=new Ledger(),b=new Ledger();a.capture([record(1).tab,record(2).tab]);for(const r of Object.values(a.records))b.merge(r);b.observedTabs=b.tabs;
 a.capture([...a.tabs].reverse());b.capture([{...b.tabs[0],url:'https://navigation.test'},b.tabs[1]]);
 for(const r of Object.values(b.records))a.merge(r);for(const r of Object.values(a.records))b.merge(r);
 assert.deepEqual(a.tabs,b.tabs);assert.equal(a.tabs[0].id,id(2));assert.equal(a.tabs[1].url,'https://navigation.test');
});
test('unapplied remote insert is not a local close',()=>{
 const a=new Ledger();a.capture([record(1).tab]);a.merge(record(2));a.capture([record(1).tab]);assert.equal(a.tabs.length,2);
});
test('history survives title edits and is dropped on navigation; Unicode bytes round trip',()=>{
 const a=new Ledger();const r=record(1);r.tab.title='こんにちは 🌅';r.tab.navigationHistory={entries:[{url:r.tab.url,title:'Earlier'}],index:0};a.merge(r);a.observedTabs=a.tabs;
 a.capture([{...record(1).tab,title:'Renamed'}]);assert.deepEqual(a.tabs[0].navigationHistory,r.tab.navigationHistory);
 assert.deepEqual(decodePayload(encodePayload(a.records[id(1)])),a.records[id(1)]);
 a.capture([{...record(1).tab,url:'https://elsewhere.test'}]);assert.equal(a.tabs[0].navigationHistory,undefined);
});
test('rejects unsafe addresses and malformed/oversized wire payloads',()=>{
 for(const u of ['file:///secret','chrome://settings','javascript:alert(1)','https://user:pass@example.com','https://example.com/'+ 'a'.repeat(8200)])assert.equal(allows(u),false);
 for(const u of ['http://localhost/','https://example.com/','https://例え.テスト/'])assert.equal(allows(u),true);
 const a=new Ledger();for(const r of [{...record(1),position:Infinity},{...record(1),contentVersion:{clock:1e50,device:id(1)}},{...record(1),tab:{id:'bad',url:'https://a.test'}}])assert.equal(a.merge(r),false);
 assert.equal(decodePayload('%%%'),null);assert.equal(decodePayload('a'.repeat(1400001)),null);
});
test('object key order is irrelevant and duplicate URLs keep distinct identities',()=>{
 assert.ok(equal({a:1,b:2},{b:2,a:1}));const a=new Ledger();a.capture([record(1).tab,{...record(1).tab,id:id(2)}]);assert.equal(a.tabs.length,2);
});
