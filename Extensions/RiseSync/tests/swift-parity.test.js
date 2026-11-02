import test from 'node:test';import assert from 'node:assert/strict';
import {mkdtempSync,writeFileSync,rmSync} from 'node:fs';import {tmpdir} from 'node:os';import {join,resolve} from 'node:path';import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';import {Ledger} from '../src/ledger.js';import {id,record} from './helpers.js';
test('JavaScript ledger matches the actual Swift ledger for 300 deterministic edits/merges',()=>{
 const root=fileURLToPath(new URL('../../../',import.meta.url)),dir=mkdtempSync(join(tmpdir(),'rise-sync-parity-'));
 try{
  writeFileSync(join(dir,'main.swift'),`import Foundation
struct Operation: Decodable { var capture: [SharedBrowserTab]?; var merge: SharedTabRecord? }
var ledger = SharedTabsLedger()
ledger.deviceID = UUID(uuidString: "${id(999)}")!
ledger.clock = 10_000_000_000_000
let data = FileHandle.standardInput.readDataToEndOfFile()
let operations = try JSONDecoder().decode([Operation].self, from: data)
var result: [[SharedBrowserTab]] = []
for op in operations {
 if let tabs = op.capture { _ = ledger.capture(tabs) }
 if let record = op.merge { _ = ledger.merge(record) }
 result.append(ledger.tabs)
}
FileHandle.standardOutput.write(try JSONEncoder().encode(result))
`);
  const compile=spawnSync('swiftc',[join(root,'Sources/RiseCore/SharedTabsLedger.swift'),join(root,'Sources/RiseCore/TabNavigationHistory.swift'),join(dir,'main.swift'),'-o',join(dir,'parity')],{encoding:'utf8',timeout:60000});
  assert.equal(compile.status,0,compile.stderr);
  const ledger=new Ledger({deviceID:id(999),clock:10000000000000});const operations=[],expected=[];
  let seed=42;const random=n=>{seed=(1664525*seed+1013904223)>>>0;return seed%n;};
  for(let i=0;i<300;i++){
    if(i%3===0){const r=record(random(20)+1);r.contentVersion.clock=10000000000000+i;r.positionVersion.clock=10000000000000+random(i+1);r.position=random(20);if(i%12===0)r.closedAt={clock:10000000000000+i,device:id(900)};operations.push({merge:r});ledger.merge(r);}
    else {let tabs=structuredClone(ledger.tabs);if(i%7===0&&tabs.length)tabs.splice(random(tabs.length),1);if(i%5===0)tabs.push(record(100+i).tab);if(tabs.length&&i%2===0){const t=tabs[random(tabs.length)];t.url=`https://edit.test/${i}`;t.title=`Edit ${i}`;}if(i%4===0)tabs.reverse();operations.push({capture:tabs});ledger.capture(tabs);}
    expected.push(ledger.tabs);
  }
  const run=spawnSync(join(dir,'parity'),[],{input:JSON.stringify(operations),encoding:'utf8',timeout:30000,maxBuffer:10000000});assert.equal(run.status,0,run.stderr);
  assert.deepEqual(JSON.parse(run.stdout),expected);
 }finally{rmSync(dir,{recursive:true,force:true});}
});
