import {Controller, initialState} from './controller.js';

let chain=Promise.resolve(), timer;
const ready=(async()=>{
  await chrome.storage.local.setAccessLevel({accessLevel:'TRUSTED_CONTEXTS'});
  await chrome.storage.session.setAccessLevel({accessLevel:'TRUSTED_CONTEXTS'});
  const [{rise},{runtime}]=await Promise.all([chrome.storage.local.get('rise'),chrome.storage.session.get('runtime')]);
  const controller=new Controller(chrome,rise??initialState(),runtime??{});
  // Alarms survive worker sleep; recreate them after browser startup/update if needed.
  await chrome.alarms.create('rise-sync',{periodInMinutes:0.5});
  return controller;
})();
function enqueue(work) {
  const result=chain.then(async()=>work(await ready));
  chain=result.catch(async()=>{}); return result;
}
async function badge(c) {
  const text=!c.state.enabled ? 'Ⅱ' : ['signin','account','offline','window'].includes(c.state.status) ? '!' : '';
  await chrome.action.setBadgeText({text});
  await chrome.action.setBadgeBackgroundColor({color:c.state.status==='offline' ? '#A86835':'#6252C7'});
  await chrome.action.setTitle({title:`Rise Tab Sync — ${c.state.message}`});
}
function schedule() {
  clearTimeout(timer);
  timer=setTimeout(()=>{ enqueue(async c=>{await c.sync();await badge(c);}).catch(()=>{}); },300);
}
chrome.alarms.onAlarm.addListener(a=>{ if(a.name==='rise-sync') schedule(); });
chrome.runtime.onStartup.addListener(schedule);
chrome.runtime.onInstalled.addListener(details=>{
  schedule();
});
function scheduleWindow(windowId) {
  ready.then(c=>{if(c.runtime.windowId===windowId)schedule();}).catch(()=>{});
}
chrome.tabs.onCreated.addListener(tab=>scheduleWindow(tab.windowId));
chrome.tabs.onUpdated.addListener((_id,change,tab)=>{if(change.url!==undefined || change.title!==undefined || change.status==='complete')scheduleWindow(tab.windowId);});
chrome.tabs.onMoved.addListener((_id,info)=>scheduleWindow(info.windowId));
chrome.tabs.onActivated.addListener(info=>scheduleWindow(info.windowId));
chrome.tabs.onAttached.addListener((_id,info)=>scheduleWindow(info.newWindowId));
chrome.tabs.onDetached.addListener((_id,info)=>scheduleWindow(info.oldWindowId));
chrome.tabs.onReplaced.addListener((added,removed)=>{
  enqueue(async c=>{if(c.runtime.bindings[removed]){c.runtime.bindings[added]=c.runtime.bindings[removed];delete c.runtime.bindings[removed];await c.save();}}).then(schedule).catch(()=>{});
});
chrome.tabs.onRemoved.addListener((_id,info)=>{
  if(info.isWindowClosing) {
    enqueue(async c=>{
      if(c.runtime.windowId===info.windowId){c.runtime.windowId=null;c.runtime.closedWindow=true;c.runtime.bindings={};c.runtime.pendingCreates={};await c.save();}
    }).then(schedule).catch(()=>{});
  } else scheduleWindow(info.windowId);
});
chrome.runtime.onMessage.addListener((message,sender,reply)=>{
  if(sender.id!==chrome.runtime.id || sender.tab?.incognito) return false;
  enqueue(async c=>{
    switch(message?.type){
      case 'view': return c.view();
      case 'connect': await c.connect(message.config,message.windowId);break;
      case 'signin': await c.signIn();break;
      case 'sync': await c.sync({force:true});break;
      case 'pause': c.state.enabled=false;c.state.status='paused';c.state.message='Sync is paused. Your tabs stay where they are.';await c.save();break;
      case 'resume':
        if(c.state.status==='account')throw new Error('Disconnect before connecting a different iCloud account.');
        c.state.enabled=true;await c.save();await c.sync({force:true});break;
      case 'window': await c.browser.bind(message.windowId,c.ledger);await c.sync({force:true});break;
      case 'focus': {
        const pair=Object.entries(c.runtime.bindings).find(([,b])=>b.id===message.id);
        if(pair){await chrome.tabs.update(Number(pair[0]),{active:true});await chrome.windows.update(c.runtime.windowId,{focused:true});}
        break;
      }
      case 'disconnect': {
        // Disconnecting never closes browser tabs or deletes iCloud records.
        await c.disconnect();break;
      }
      default:throw new Error('Unknown action.');
    }
    await badge(c);return c.view();
  }).then(data=>reply({ok:true,data})).catch(e=>reply({ok:false,error:e.message}));
  return true;
});
