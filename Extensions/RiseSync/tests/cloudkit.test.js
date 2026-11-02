import test from 'node:test';import assert from 'node:assert/strict';
import {CloudKit,authTokenFromRedirect} from '../src/cloudkit.js';
test('auth callback must match extension callback, with URL-encoded tokens intact',()=>{
 assert.equal(authTokenFromRedirect('https://test.chromiumapp.org/?ckWebAuthToken=a%2Bb%2Fc%3D','https://test.chromiumapp.org/'),'a+b/c=');
 for(const u of ['https://evil.test/?ckWebAuthToken=foo','https://test.chromiumapp.org/wrong?ckWebAuthToken=x','https://test.chromiumapp.org/'])assert.throws(()=>authTokenFromRedirect(u,'https://test.chromiumapp.org/'));
});
test('rotated authentication token is persisted even on an error response',async()=>{
 const auth={token:'old'};let saved=0;
 const cloud=new CloudKit({apiToken:'api',environment:'development'},auth,async()=>saved++,async()=>Response.json({ckWebAuthToken:'new',serverErrorCode:'THROTTLED',retryAfter:90}));
 await assert.rejects(cloud.user(),e=>e.code==='THROTTLED'&&e.retryAfter===90);assert.equal(auth.token,'new');assert.equal(saved,1);
});
test('network errors never expose a URL or authentication token',async()=>{
 const cloud=new CloudKit({apiToken:'SECRET',environment:'development'},{token:'SECRET'},async()=>{},async()=>{throw Error('SECRET URL');});
 await assert.rejects(cloud.user(),e=>!e.message.includes('SECRET'));
});
test('uses current public caller endpoint and rotates the real response-header token',async()=>{
 const auth={token:'old'};let saved=0;
 const cloud=new CloudKit({apiToken:'api',environment:'production'},auth,async()=>saved++,async(url)=>{
  assert.equal(new URL(url).pathname,'/database/1/iCloud.dev.bartosz.Rise/production/public/users/caller');
  return Response.json({userRecordName:'account'},{headers:{'X-Apple-CloudKit-Web-Auth-Token':'header-token'}});
 });
 assert.equal((await cloud.user()).userRecordName,'account');assert.equal(auth.token,'header-token');assert.equal(saved,1);
});
test('modern callback session is accepted and takes precedence over the legacy alias',()=>{
 assert.equal(authTokenFromRedirect('https://test.chromiumapp.org/?ckSession=new%2Btoken&ckWebAuthToken=legacy','https://test.chromiumapp.org/'),'new+token');
});

test('fetch uses the global receiver required by browser workers',async()=>{
 let called=false;
 async function fetcher(){assert.equal(this,globalThis);called=true;return Response.json({userRecordName:'a'});}
 const c=new CloudKit({apiToken:'api',environment:'production'},{},async()=>{},fetcher);
 await c.user();assert.ok(called);
});
