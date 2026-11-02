import {encodePayload, decodePayload} from '../src/ledger.js';
export const id=n=>`${String(n).padStart(8,'0')}-0000-4000-8000-000000000000`;
export const record=(n,url=`https://example.com/${n}`,clock=100)=>({tab:{id:id(n),url,title:`Page ${n}`},contentVersion:{clock,device:id(900)},position:n,positionVersion:{clock,device:id(900)}});
export function fakeBrowser(initial=[{url:'https://example.com/1',active:true}]){
  let next=1;const all=new Map(),store={},session={};
  const add=(data)=>{const t={id:next++,windowId:1,index:all.size,url:'about:blank',title:'Page',active:false,pinned:false,status:'complete',...data};all.set(t.id,t);return t;};
  initial.forEach(add);
  function reindex(){const by=new Map();for(const t of all.values()){const list=by.get(t.windowId)??[];list.push(t);by.set(t.windowId,list);}for(const list of by.values())list.sort((a,b)=>a.index-b.index).forEach((t,i)=>t.index=i);}
  const api={
    storage:{local:{set:async x=>Object.assign(store,structuredClone(x))},session:{set:async x=>Object.assign(session,structuredClone(x))}},
    windows:{
      getAll:async()=>[...new Set([...all.values()].map(t=>t.windowId))].map(w=>({id:w,incognito:false,type:'normal',tabs:structuredClone([...all.values()].filter(t=>t.windowId===w))})),
      get:async w=>{const tabs=[...all.values()].filter(t=>t.windowId===w);if(!tabs.length)throw Error('Window missing');return {id:w,incognito:false,type:'normal',tabs:structuredClone(tabs)};}
    },
    tabs:{
      get:async n=>{if(!all.has(n))throw Error('Missing tab');return structuredClone(all.get(n));},
      create:async data=>structuredClone(add(data)),
      update:async(n,data)=>{if(data.active)for(const t of all.values())if(t.windowId===all.get(n).windowId)t.active=false;Object.assign(all.get(n),data);return structuredClone(all.get(n));},
      remove:async n=>{all.delete(n);reindex();},
      move:async(n,{index})=>{const t=all.get(n);const list=[...all.values()].filter(a=>a.windowId===t.windowId&&a.id!==n).sort((a,b)=>a.index-b.index);list.splice(index,0,t);list.forEach((a,i)=>a.index=i);return structuredClone(t);},
    },
    runtime:{getURL:p=>`chrome-extension://test/${p}`},identity:{getRedirectURL:()=> 'https://test.chromiumapp.org/'}
  };
  return {api,all,store,session,add};
}
export class FakeCloud {
  constructor(){this.records=new Map();this.changes=[];this.calls=[];this.token='start';this.tag=0;this.fail=false;this.pageSize=200;this.account='account-one';this.conflict=null;}
  put(record){const name=record.tab.id;const value={recordName:name,recordType:'RiseTab',recordChangeTag:String(++this.tag),fields:{payload:{type:'BYTES',value:encodePayload(record)}}};this.records.set(name,value);this.changes.push(value);return value;}
  fetch=async(raw,options)=>{
    if(this.fail)throw Error('offline');
    const u=new URL(raw);const path=u.pathname.split(/\/(?:private|public)\//)[1];this.calls.push(path);
    if(u.searchParams.get('ckWebAuthToken')!==this.token)return Response.json({serverErrorCode:'AUTHENTICATION_REQUIRED',redirectURL:'https://idmsa.apple.com/signin'});
    this.token=`token-${this.calls.length}`;
    const body=options.body?JSON.parse(options.body):{};let result={};
    if(path==='users/caller')result={userRecordName:this.account};
    if(path==='changes/zone'){
      const from=Number(body.zones[0].syncToken??0);const slice=this.changes.slice(from,from+this.pageSize);
      result={zones:[{records:slice,syncToken:String(from+slice.length),moreComing:from+slice.length<this.changes.length}]};
    }
    if(path==='records/modify'){
      if(this.conflict){const f=this.conflict;this.conflict=null;f();}
      result={records:body.operations.map(op=>{
        const r=op.record,old=this.records.get(r.recordName);
        if(old&&r.recordChangeTag!==old.recordChangeTag)return {recordName:r.recordName,serverErrorCode:op.operationType==='create'?'EXISTS':'CONFLICT'};
        return this.put(decodePayload(r.fields.payload.value));
      })};
    }
    if(path==='records/lookup')result={records:body.records.map(r=>this.records.get(r.recordName)??{...r,serverErrorCode:'NOT_FOUND'})};
    return Response.json(result,{headers:{'x-apple-cloudkit-web-auth-token':this.token}});
  }
}
