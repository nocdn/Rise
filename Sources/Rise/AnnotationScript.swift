import Foundation

/// Isolated-world quote anchoring. It never wraps, edits or replaces the article's text nodes.
enum AnnotationScript {
    static let world = "Rise.Annotations", handler = "riseAnnotation"
    static let source = #"""
    (() => {
      if (globalThis.riseAnnotations) return;
      let notes=[], ranges=new Map(), host=null, shadow=null, active=null, scheduled=false, highlightSheet=null, badgeSheet=null, appearance={};
      const highlight='rise-page-annotations';
      const send = body => { try { riseHandlers.riseAnnotation.postMessage(body); } catch {} };
      function textMap() {
        const nodes=[], walker=document.createTreeWalker(document.body||document.documentElement,NodeFilter.SHOW_TEXT);
        let text='', n;
        while((n=walker.nextNode()) && text.length<500000) {
          if(n.parentElement?.closest('script,style,noscript,textarea,input,select,[contenteditable="true"],[data-rise-annotation-root]'))continue;
          nodes.push({node:n,start:text.length}); text+=n.data;
        }
        return {text,nodes};
      }
      function capture(fallback) {
        const selection=getSelection(), map=textMap();
        const selected=selection?.rangeCount?selection.getRangeAt(0):null;
        const r=selected&&!selected.collapsed?selected:null;
        const exact=(r?r.toString():fallback||'').slice(0,12000);
        if(!exact.trim()||r?.commonAncestorContainer?.parentElement?.closest('input,textarea,[contenteditable="true"]'))return null;
        let start=-1;
        if(r) {
          const direct=map.nodes.find(n=>n.node===r.startContainer);
          if(direct)start=direct.start+r.startOffset;
          else {
            // A paragraph selected with selectNodeContents has an element boundary,
            // not a text-node boundary. Locate its first included text node rather
            // than falling back to the first identical quote in the document.
            const first=map.nodes.find(n=>r.intersectsNode(n.node)&&r.comparePoint(n.node,0)===0);
            if(first)start=first.start;
          }
        }
        if(start<0||map.text.slice(start,start+exact.length)!==exact)start=map.text.indexOf(exact);
        if(start<0)return null;
        return {exact,start,prefix:map.text.slice(Math.max(0,start-80),start),suffix:map.text.slice(start+exact.length,start+exact.length+80)};
      }
      function locate(anchor,map) {
        let at=-1, best=-Infinity, cursor=0, count=0;
        while(count++<500 && (cursor=map.text.indexOf(anchor.exact,cursor))>=0) {
          let score=-Math.abs(cursor-anchor.start)/Math.max(1,map.text.length);
          if(anchor.prefix && map.text.slice(Math.max(0,cursor-anchor.prefix.length),cursor)===anchor.prefix)score+=4;
          if(anchor.suffix && map.text.slice(cursor+anchor.exact.length,cursor+anchor.exact.length+anchor.suffix.length)===anchor.suffix)score+=4;
          if(score>best){at=cursor;best=score;} cursor++;
        }
        if(at<0)return null;
        const end=at+anchor.exact.length;
        const first=map.nodes.find(n=>n.start+n.node.length>at), last=map.nodes.find(n=>n.start<end&&n.start+n.node.length>=end);
        if(!first||!last)return null;
        try {const r=document.createRange();r.setStart(first.node,at-first.start);r.setEnd(last.node,end-last.start);return r;}catch{return null;}
      }
      function ensureHost() {
        // Constructed stylesheets also work on pages that disallow inline styles.
        if(!highlightSheet){highlightSheet=new CSSStyleSheet();highlightSheet.replaceSync('::highlight(rise-page-annotations){background-color:rgba(142,106,219,.19)}');}
        if(!document.adoptedStyleSheets.includes(highlightSheet))document.adoptedStyleSheets=[...document.adoptedStyleSheets,highlightSheet];
        if(host?.isConnected)return;
        host=document.createElement('div');host.dataset.riseAnnotationRoot='';
        host.style.cssText='all:initial!important;position:fixed!important;inset:0!important;pointer-events:none!important;z-index:2147483646!important;contain:layout style!important';
        shadow=host.attachShadow({mode:'closed'});
        badgeSheet=new CSSStyleSheet();paint();shadow.adoptedStyleSheets=[badgeSheet];
        document.documentElement.append(host);
      }
      function paint() {
        badgeSheet?.replaceSync(`button{all:initial;box-sizing:border-box;position:absolute;width:21px;height:21px;border-radius:${appearance.radius||'7px'};background:${appearance.background||'#fff'};color:${appearance.color||'#222'};border:${appearance.borderWidth||'.5px'} solid ${appearance.border||'#ddd'};box-shadow:${appearance.shadow||'0 3px 20px #0002'};font:600 11px -apple-system,BlinkMacSystemFont,sans-serif;text-align:center;line-height:20px;cursor:pointer;pointer-events:auto;user-select:none}button[hidden]{display:none!important}button[aria-expanded=true]{opacity:0;pointer-events:none;transition:opacity ${appearance.openingFade||'.12s'} ease-out}button[data-handoff=waiting]{opacity:1;box-shadow:none;transition:none}button[data-handoff=fading]{transition:box-shadow 60ms linear}@media(prefers-reduced-motion:reduce){button[aria-expanded=true]{transition:none}}`);
      }
      function place() {
        scheduled=false;if(!notes.length){host?.remove();host=null;shadow=null;CSS.highlights?.delete(highlight);if(highlightSheet){document.adoptedStyleSheets=document.adoptedStyleSheets.filter(s=>s!==highlightSheet);highlightSheet=null;}return;}
        ensureHost();let occupied=[];
        for(const note of notes) {
          const r=ranges.get(note.id), button=shadow.getElementById(note.id);if(!button)continue;
          const rects=r?[...r.getClientRects()].filter(r=>r.width>0&&r.height>0):[];
          const visible=rects.filter(r=>r.bottom>0&&r.top<innerHeight&&r.right>0&&r.left<innerWidth);
          button.hidden=!visible.length;if(!visible.length)continue;
          const last=visible.at(-1), first=visible[0];
          let x=last.right+3, y=last.bottom-11;
          if(x+23>innerWidth-8){x=first.left-24;y=first.top-12;}
          x=Math.max(8,Math.min(innerWidth-29,x));y=Math.max(8,Math.min(innerHeight-29,y));
          while(occupied.some(p=>Math.abs(p.x-x)<23&&Math.abs(p.y-y)<23)&&y<innerHeight-52)y+=24;
          occupied.push({x,y});button.style.left=x+'px';button.style.top=y+'px';
          button.setAttribute('aria-expanded',String(note.id===active));
          if(note.id===active)send({action:'geometry',id:note.id,rect:{x,y,width:21,height:21},viewport:{width:innerWidth,height:innerHeight}});
        }
      }
      function schedule(){if(!scheduled){scheduled=true;requestAnimationFrame(place);}}
      function restore(list,expanded=active) {
        notes=list;active=expanded;ranges.clear();if(!notes.length){place();return;}
        ensureHost();const kept=new Set(notes.map(n=>n.id));shadow.querySelectorAll('button').forEach(b=>{if(!kept.has(b.id))b.remove();});const map=textMap();
        for(const note of notes){const r=locate(note.anchor,map);if(!r)continue;ranges.set(note.id,r);
          // Keep the same target across layout/theme mutations. Replacing the button between
          // a mouse down and up would silently lose that click (including a middle click).
          if(shadow.getElementById(note.id))continue;
          const button=document.createElement('button');button.id=note.id;button.textContent=String(note.number);button.title='Annotation '+note.number;button.setAttribute('aria-label','Ask about annotation '+note.number);
          const post=action=>{if(action==='open'){active=note.id;place();}const r=button.getBoundingClientRect();send({action,id:note.id,rect:{x:r.x,y:r.y,width:r.width,height:r.height},viewport:{width:innerWidth,height:innerHeight}});};
          button.addEventListener('click',e=>{e.preventDefault();e.stopPropagation();post('open');});
          // Button 1 is the mouse's middle button in DOM events. Prevent its default
          // autoscroll too; removal uses precisely the same native action as the menu.
          button.addEventListener('mousedown',e=>{if(e.button===1){e.preventDefault();e.stopPropagation();}});
          button.addEventListener('auxclick',e=>{if(e.button===1){e.preventDefault();e.stopPropagation();post('remove');}});
          button.addEventListener('contextmenu',e=>{e.preventDefault();e.stopPropagation();post('menu');});shadow.append(button);
        }
        if(globalThis.Highlight&&CSS.highlights)CSS.highlights.set(highlight,new Highlight(...ranges.values()));place();
      }
      const painted=()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
      globalThis.riseAnnotations={capture,restore,style(value){appearance=value;paint();},activate(id){shadow?.querySelectorAll('[data-handoff]').forEach(b=>delete b.dataset.handoff);active=id;place();},
        async prepareHandoff(id){const b=shadow?.getElementById(id);if(!b||b.hidden||active!==id)return false;b.dataset.handoff='waiting';active=null;place();await painted();return b.isConnected&&!b.hidden&&active===null&&b.dataset.handoff==='waiting';},
        finishHandoff(id){const b=shadow?.getElementById(id);if(b?.dataset.handoff==='waiting')b.dataset.handoff='fading';},
        rect(id){const b=shadow?.getElementById(id);if(!b||b.hidden)return null;const r=b.getBoundingClientRect();return {rect:{x:r.x,y:r.y,width:r.width,height:r.height},viewport:{width:innerWidth,height:innerHeight},expanded:b.getAttribute('aria-expanded')==='true',handoff:b.dataset.handoff||null};},count(){return ranges.size;}};
      addEventListener('scroll',schedule,true);addEventListener('resize',schedule);visualViewport?.addEventListener('resize',schedule);
      let mutationTimer;
      const observer=new MutationObserver(records=>{if(!notes.length||!records.some(r=>!host?.contains(r.target)&&r.target!==host&&r.target?.id!=='rise-annotation-highlight-style'))return;clearTimeout(mutationTimer);mutationTimer=setTimeout(()=>restore(notes),200);});
      const ready=()=>{observer.observe(document.documentElement,{childList:true,characterData:true,attributes:true,attributeFilter:['class','style','hidden'],subtree:true});send({action:'ready'});};
      if(document.readyState==='loading')addEventListener('DOMContentLoaded',ready,{once:true});else ready();
    })();
    """#
}
