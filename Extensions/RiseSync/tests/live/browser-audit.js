// Open this file's chrome-extension:// URL in an isolated test profile only.
import {BrowserTabs} from '../../src/browser.js';
import {Ledger,uuid,allows} from '../../src/ledger.js';
import {CloudKit} from '../../src/cloudkit.js';
import {DEFAULT_CONFIG} from '../../src/config.js';
const report=document.getElementById('result'),lines=[];
const check=(value,text)=>{if(!value)throw new Error(text);lines.push(`PASS: ${text}`);report.textContent=lines.join('\n');};
let win;
try{
 win=await chrome.windows.create({url:['https://example.com/?rise-audit=one','https://example.com/?rise-audit=one'],focused:false});
 const runtime={},state={},ledger=new Ledger();let saves=0;
 const adapter=new BrowserTabs(chrome,state,runtime,async()=>{saves++;});runtime.bindings={};runtime.pendingCreates={};
 await adapter.bind(win.id,ledger);ledger.capture(await adapter.snapshot(ledger));
 check(ledger.tabs.length===2&&ledger.tabs[0].id!==ledger.tabs[1].id,'real duplicate browser tabs keep separate identities');
 const a=ledger.tabs[0].id,b=ledger.tabs[1].id;
 const remote={tab:{id:uuid(),url:'https://example.org/?rise-audit=remote',title:'Remote'},contentVersion:ledger.nextVersion(),position:-1,positionVersion:ledger.nextVersion()};
 ledger.merge(remote);await adapter.apply(ledger);
 check((await adapter.live()).length===3,'remote insert creates one background tab');
 check((await adapter.live()).find(t=>runtime.bindings[t.id]?.id===remote.tab.id)?.index===0,'remote order reaches the real tab strip');
 await adapter.apply(ledger);check((await adapter.live()).length===3,'repeated remote updates do not duplicate tabs');
 const active=(await adapter.live()).find(t=>t.active),activeID=runtime.bindings[active.id].id;
 ledger.close(activeID);await adapter.apply(ledger);
 check((await adapter.live()).some(t=>t.id===active.id),'remote closure preserves the actual active tab');
 const next=(await adapter.live()).find(t=>t.id!==active.id);await chrome.tabs.update(next.id,{active:true});await adapter.apply(ledger);
 check(!(await adapter.live()).some(t=>t.id===active.id),'held closure applies after switching away');
 const target=ledger.tabs.find(t=>t.id!==activeID),updated=structuredClone(ledger.records[target.id]);
 updated.tab.url='https://example.net/?rise-audit=navigated';updated.contentVersion=ledger.nextVersion();ledger.merge(updated);await adapter.apply(ledger);
 const t=(await adapter.live()).find(t=>runtime.bindings[t.id]?.id===target.id);
 check((t.pendingUrl||t.url)===updated.tab.url,'remote navigation reaches the actual Chromium tab');
 const restored=new BrowserTabs(chrome,state,structuredClone(runtime),async()=>{});await restored.apply(ledger);
 check((await restored.live()).length===2,'bindings survive a service-worker-style restart');
 check(saves>0,'tab mutations checkpoint their state');
 try { await new CloudKit(DEFAULT_CONFIG,{},async()=>{}).user(); throw new Error('Expected Apple sign-in'); }
 catch(e) { check(e.code==='AUTHENTICATION_REQUIRED'&&!!e.redirectURL,'real extension fetch receives Apple sign-in without a receiver error'); }
 report.textContent=lines.join('\n')+'\nALL PASSED';
}catch(e){report.textContent=lines.join('\n')+`\nFAIL: ${e.message}`;}
finally{if(win)await chrome.windows.remove(win.id);}
