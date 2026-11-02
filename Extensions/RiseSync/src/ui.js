const $=id=>document.getElementById(id);
let view,busy=false,refreshing=false,showSettings=false,windowChanged=false;
const labels={setup:'Get connected',ready:'Up to date',syncing:'Syncing',paused:'Paused',signin:'Sign in needed',offline:'Waiting to reconnect',window:'Choose a window',account:'Account changed'};
async function send(type,data={}){
 const result=await chrome.runtime.sendMessage({type,...data});
 if(!result?.ok)throw new Error(result?.error??'The extension is restarting. Try again.');return result.data;
}
function panel(){
 const open=showSettings||!view?.connected;
 $('connection').hidden=!open;$('home').hidden=open;
 $('settings').textContent=open&&view?.connected?'←':'⚙';
 $('settings').setAttribute('aria-label',open&&view?.connected?'Back to shared tabs':'Connection settings');
}
function render(data){
 view=data;$('status').textContent=labels[data.status]??'Ready';$('dot').className=`dot ${data.status}`;
 $('message').textContent=data.message;$('connection-message').textContent=data.connected?data.message:'Sign in with the same Apple Account you use in Rise.';
 const when=data.lastSync?new Date(data.lastSync).toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'}):null;
 $('meta').textContent=[when?`Last synced ${when}`:'',data.pending?`${data.pending} changes waiting`:'',data.connected?data.environment==='development'?'Development':'Production':''].filter(Boolean).join(' · ');
 $('pause').hidden=!data.connected||data.status==='account';$('pause').textContent=data.enabled?'Pause':'Resume';
 $('sync').textContent=['window','signin','account'].includes(data.status)?'Connection settings →':'Sync now ↻';
 $('sync').hidden=!data.connected||(!data.enabled&&data.status!=='account');
 $('connection-title').textContent=data.connected?'Your connection':'Bring your tabs together.';
 $('setup-fields').hidden=data.connected;$('disconnect-area').hidden=!data.connected;
 $('connect').hidden=data.connected&&data.status!=='window'&&!windowChanged;
 $('connect').textContent=data.connected?'Use this window →':'Sign in with iCloud →';
 $('signin').hidden=data.status!=='signin';$('origin').textContent=data.origin;$('callback').textContent=data.callback;
 const chosen=Number($('window').value)||data.windowId;
 $('window').replaceChildren(...data.windows.map(w=>{
  const option=document.createElement('option');option.value=w.id;option.textContent=`${w.title} · ${w.count} tabs`;option.selected=w.id===chosen;return option;
 }));
 if(!data.connected&&document.activeElement!==$('environment'))$('environment').value=data.environment;
 $('held').hidden=!data.held;$('held').textContent='A remotely closed tab stays open while you read it. It closes after you switch away.';
 $('tab-section').hidden=!data.connected;$('count').textContent=data.tabs.length;renderTabs();panel();
}
function renderTabs(){
 if(!view)return;const query=$('search').value.trim().toLowerCase();
 const tabs=view.tabs.filter(t=>`${t.title??''} ${t.url??''}`.toLowerCase().includes(query));
 $('tabs').replaceChildren(...tabs.slice(0,150).map(t=>{
  const row=document.createElement('button');row.className='tab';row.title=t.url??'New Tab';
  const icon=document.createElement('span');icon.className='tab-icon';let host='New Tab';try{host=new URL(t.url).hostname.replace(/^www\./,'');}catch{}
  icon.textContent=host[0].toUpperCase();const text=document.createElement('span');text.className='tab-text';
  const title=document.createElement('span');title.className='tab-title';title.textContent=t.title||host;
  const url=document.createElement('span');url.className='tab-url';url.textContent=host;text.append(title,url);row.append(icon,text);
  row.addEventListener('click',()=>act('focus',{id:t.id}));return row;
 }));
 if(!tabs.length){const p=document.createElement('p');p.className='empty';p.textContent=query?'No matching tabs.':'Your shared tabs will appear here.';$('tabs').append(p);}
 if(tabs.length>150){const p=document.createElement('p');p.className='empty';p.textContent=`${tabs.length-150} more tabs. Search to find them.`;$('tabs').append(p);}
}
async function act(type,data){
 if(busy)return;busy=true;$('error').hidden=true;document.querySelectorAll('button').forEach(b=>b.disabled=true);
 try{await send(type,data);if(['connect','window'].includes(type)){showSettings=false;windowChanged=false;}$('token').value='';render(await send('view'));}
 catch(e){$('error').hidden=false;$('error').textContent=e.message;}
 finally{busy=false;document.querySelectorAll('button').forEach(b=>b.disabled=false);}
}
$('settings').addEventListener('click',()=>{showSettings=!showSettings;panel();});
$('pause').addEventListener('click',()=>act(view.enabled?'pause':'resume'));
$('sync').addEventListener('click',()=>{if(['window','signin','account'].includes(view.status)){showSettings=true;panel();}else act('sync');});
$('connect-form').addEventListener('submit',e=>{
 e.preventDefault();const windowId=Number($('window').value);
 if(view.connected)act('window',{windowId});else act('connect',{windowId,config:{apiToken:$('token').value||undefined,environment:$('environment').value}});
});
$('window').addEventListener('change',()=>{windowChanged=true;if(view.connected)$('connect').hidden=false;});
$('signin').addEventListener('click',()=>act('signin'));$('disconnect').addEventListener('click',()=>act('disconnect'));
$('search').addEventListener('input',renderTabs);
for(const button of document.querySelectorAll('[data-copy]'))button.addEventListener('click',async()=>{
 try{await navigator.clipboard.writeText($(button.dataset.copy).textContent);button.textContent='Copied';}
 catch{$('error').hidden=false;$('error').textContent='Select and copy the address above.';}
});
async function refresh(){if(busy||refreshing)return;refreshing=true;try{render(await send('view'));}catch(e){$('error').hidden=false;$('error').textContent=e.message;}finally{refreshing=false;}}
await refresh();chrome.storage.onChanged.addListener((_changes,area)=>{if(area==='local')refresh();});
