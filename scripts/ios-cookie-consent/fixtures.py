#!/usr/bin/env python3
"""Real HTTP consent fixtures. Exercised inside Rise's WKWebView, not a mocked DOM."""
import argparse
import json
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

CASES = [
    dict(name="simple"), dict(name="locked-modal", modal=True), dict(name="native-dialog", native=True),
    dict(name="sourcepoint-consent-or-pay", provider="sourcepoint", label="Accept all"),
    dict(name="onetrust", provider="onetrust"), dict(name="didomi", provider="didomi"),
    dict(name="cookiebot", provider="cookiebot"), dict(name="cookiebot-closed-shadow", provider="cookiebot", closed=True),
    dict(name="onetrust-api", provider="onetrust", closed=True),
    dict(name="usercentrics-async", provider="usercentrics", label="Apply selected preferences"),
    dict(name="usercentrics-api-failure", provider="usercentrics", label="Apply selected preferences", apiFails=True, negative=True),
    dict(name="open-shadow", shadow=1), dict(name="nested-shadow", shadow=3),
    dict(name="late-banner", delay=1800), dict(name="very-late-banner", delay=11000, timeout=15),
    dict(name="late-handler", handlerDelay=2200), dict(name="disabled-then-enabled", disabledUntil=2200),
    dict(name="very-late-handler", handlerDelay=6500, timeout=12), dict(name="late-shadow", shadow=2, delay=2200),
    dict(name="large-spa-mutation-batch", batch=True, delay=5500, timeout=10),
    dict(name="hidden-then-visible", hiddenUntil=1800), dict(name="aria-hidden-then-visible", ariaUntil=1800),
    dict(name="button-replaced", replaceAt=1600), dict(name="spa-second-banner", repeat=True),
    dict(name="csp-strict", csp=True), dict(name="cross-origin-frame", frame=True),
    dict(name="same-origin-frame", frame=True, sameOrigin=True), dict(name="nested-frames", frame=True, nested=True),
    dict(name="hidden-decoy", decoy=True), dict(name="external-accept-link", negative=True, external=True),
    dict(name="checkout", negative=True, danger="Confirm purchase", form=True),
    dict(name="newsletter", negative=True, danger="Subscribe to our newsletter", email=True),
    dict(name="login", negative=True, danger="Log in to accept cookies", password=True),
    dict(name="paywall", negative=True, danger="Subscribe to continue", noCookie=True),
    dict(name="legal-terms", negative=True, danger="Accept all terms of service", noCookie=True),
    dict(name="pmc-legal-migration", negative=True, provider="pmc", noCookie=True, label="Continue"),
    dict(name="microsoft-scoped-accept", provider="microsoft"),
    dict(name="microsoft-hidden-with-terms", provider="microsoft", permanentlyHidden=True, negative=True),
    dict(name="cookie-policy-article", negative=True, article=True),
    dict(name="named-cookie-policy-article", negative=True, article=True, named=True),
    dict(name="hidden-banner", negative=True, permanentlyHidden=True),
    dict(name="inert-banner", negative=True, inert=True),
    dict(name="disabled-button", negative=True, permanentlyDisabled=True),
    dict(name="reject-only", negative=True, label="Reject all"),
    dict(name="settings-only", negative=True, label="Manage preferences"),
    dict(name="no-cookie-purpose", negative=True, noCookie=True),
    dict(name="busy-dom", busy=True, timeout=10), dict(name="long-article", long=True, timeout=10),
    dict(name="existing-decline", negative=True, existing=True, provider="cookiebot", closed=True),
    dict(name="unknown-closed-shadow", negative=True, closed=True),
    dict(name="temporary-occlusion", coverUntil=1800),
    dict(name="silent-handler-failure", silent=True, negative=True),
    dict(name="acknowledge-notice", label="Got it"), dict(name="accessible-label", ariaLabel=True),
]
PURPOSES={"de":"Diese Website verwendet Cookies und ähnliche Technologien.",
          "fr":"Nous utilisons des cookies et des technologies similaires.",
          "es":"Este sitio utiliza cookies y tecnologías similares.",
          "it":"Questo sito utilizza biscotti e tecnologie simili.",
          "pt":"Este site utiliza cookies e tecnologias semelhantes.",
          "nl":"Wij gebruiken cookies en vergelijkbare technologieën.",
          "pl":"Używamy ciasteczek i podobnych technologii.",
          "fi":"Käytämme evästeitä ja vastaavia tekniikoita.",
          "sv":"Vi använder kakor och liknande tekniker.",
          "da":"Vi bruger cookies og lignende teknologier.",
          "ja":"このウェブサイトではクッキーと同様の技術を使用しています。",
          "ko":"이 웹사이트는 쿠키와 유사한 기술을 사용합니다.",
          "zh":"本网站使用 Cookie 和类似技术。",
          "ar":"يستخدم هذا الموقع ملفات تعريف الارتباط وتقنيات مماثلة."}
for language, label in [("de","Alle akzeptieren"),("fr","Tout accepter"),("es","Aceptar todas"),
                        ("it","Accetta tutti"),("pt","Aceitar todos"),("nl","Accepteer alles"),
                        ("pl","Akceptuj wszystkie"),("fi","Hyväksy kaikki"),("sv","Godkänn alla"),
                        ("da","Acceptér alle"),("ja","すべて同意"),("ko","모두 허용"),
                        ("zh","全部接受"),("ar","قبول الكل")]:
    CASES.append(dict(name="language-"+language, label=label, purpose=PURPOSES[language]))

SCRIPT = r"""
const config = FIXTURE;
window.accepted=0;window.wrong=0;window.errors=[];window.banner=null;window.fixtureReady=false;
addEventListener('error',e=>window.errors.push(e.message));
const cookieKey='consent_'+config.name.replace(/[^a-z0-9]/gi,'_');
const hasCookie=()=>document.cookie.includes(cookieKey+'=yes');
const article=document.querySelector('main');
document.getElementById('normal').addEventListener('click',()=>window.normalClicked=true);
let currentPanel;
function accept() {
  window.accepted++;document.cookie=cookieKey+'=yes;path=/;SameSite=Lax';
  if(window.Cookiebot){Cookiebot.hasResponse=true;Cookiebot.dialog.visible=false;}
  if(currentPanel?.tagName==='DIALOG')currentPanel.close();
  window.banner?.remove();document.getElementById('backdrop')?.remove();
  document.body.style.overflow='';article.inert=false;
  parent.postMessage({fixtureAccepted:true},'*');
  if(config.repeat && accepted===1){document.cookie=cookieKey+'=;Max-Age=0;path=/';setTimeout(create,1200);}
}
function create() {
 if(hasCookie())return;
 if(config.batch){const batch=document.createDocumentFragment();for(let i=0;i<700;i++){const row=document.createElement('div');row.innerHTML='<span>Normal live row '+i+'</span>';batch.append(row);}article.append(batch);}
 const outer=document.createElement('div');outer.id='fixture-container';
 let root=outer;
 if(config.shadow || config.closed){
  for(let i=0;i<(config.shadow||1);i++){
   const host=document.createElement('div');root.append(host);root=host.attachShadow({mode:config.closed?'closed':'open'});
   const style=document.createElement('style');style.textContent='.panel{position:fixed;inset:auto 8px 18px;z-index:2147483646;background:#fff;border:2px solid #333;padding:22px;color:#111;font:17px sans-serif}button{padding:12px;margin:6px}';root.append(style);
  }
 }
 const panel=document.createElement(config.native?'dialog':config.form?'form':config.article?'article':config.provider==='pmc'?'aside':'div');
 currentPanel=panel;panel.className='panel';panel.setAttribute('role',config.article?'article':'dialog');
 if(config.article){panel.removeAttribute('role');panel.style.position='static';panel.className=config.named?'cookie-policy':'';}
 if(config.permanentlyHidden)panel.style.display='none';
 if(config.hiddenUntil){panel.style.display='none';setTimeout(()=>panel.style.display='',config.hiddenUntil);}
 if(config.ariaUntil){panel.setAttribute('aria-hidden','true');setTimeout(()=>panel.setAttribute('aria-hidden','false'),config.ariaUntil);}
 if(config.inert)panel.inert=true;
 const purpose=config.noCookie?'Choose your options': config.purpose||'We use cookies and similar technologies to improve this website. You can accept all cookies or manage your preferences.';
 panel.innerHTML='<p>'+purpose+'</p>'+(config.danger?'<p>'+config.danger+'</p>':'');
 if(config.email)panel.innerHTML+='<input type=email placeholder=Email>';
 if(config.password)panel.innerHTML+='<input type=password>';
 if(config.form)panel.innerHTML+='<input autocomplete=cc-number>';
 if(config.provider==='onetrust')panel.id='onetrust-banner-sdk';
 if(config.provider==='didomi')panel.id='didomi-host';
 if(config.provider==='cookiebot')panel.id='CybotCookiebotDialog';
 if(config.provider==='usercentrics')panel.id='usercentrics-cmp-ui';
 if(config.provider==='pmc')panel.setAttribute('aria-labelledby','pmc-privacy-banner-heading');
 if(config.provider==='microsoft'){
  panel.id='wcpConsentBannerCtrl';
  const legal=document.createElement('div');legal.innerHTML='<button>Accept terms</button>';legal.querySelector('button').onclick=()=>wrong++;document.body.prepend(legal);
 }
 let button=document.createElement(config.external?'a':'button');
 button.type=config.form?'submit':'button';button.textContent=config.label||'Accept all cookies';
 if(config.external){button.href='/danger';button.onclick=e=>{e.preventDefault();wrong++;};}
 if(config.ariaLabel){button.textContent='';button.setAttribute('aria-label','Accept all cookies');button.innerHTML='<svg width=25 height=25><path d="M1 12L10 20L24 1" stroke=black /></svg>';}
 if(config.provider==='onetrust')button.id='onetrust-accept-btn-handler';
 if(config.provider==='didomi')button.id='didomi-notice-agree-button';
 if(config.provider==='cookiebot')button.id='CybotCookiebotDialogBodyLevelButtonLevelOptinAllowAll';
 if(config.provider==='sourcepoint')button.className='sp_choice_type_11';
 const bind=()=>button.addEventListener('click',()=>{if(config.silent)return;if(config.negative){wrong++;}else accept();});
 if(!config.external){if(config.handlerDelay)setTimeout(bind,config.handlerDelay);else bind();}
 if(config.permanentlyDisabled||config.disabledUntil)button.disabled=true;
 if(config.disabledUntil)setTimeout(()=>button.disabled=false,config.disabledUntil);
 if(config.decoy){const decoy=button.cloneNode(true);decoy.removeAttribute('id');decoy.style.display='none';decoy.onclick=()=>wrong++;panel.append(decoy);}
 panel.append(button);
 if(config.provider==='sourcepoint'){const pay=document.createElement('button');pay.className='sp_choice_type_9';pay.textContent='Reject all and subscribe for £5';pay.onclick=()=>wrong++;panel.append(pay);}
 if(!config.negative){const reject=document.createElement('button');reject.textContent='Reject all';reject.onclick=()=>wrong++;panel.append(reject);}
 root.append(panel);document.body.append(outer);window.banner=outer;
 if(config.coverUntil){const cover=document.createElement('div');cover.style='position:fixed;inset:0;background:#888;z-index:2147483647';document.body.append(cover);setTimeout(()=>cover.remove(),config.coverUntil);}
 if(config.native)panel.showModal();
 if(config.modal){document.body.style.overflow='hidden';article.inert=true;const back=document.createElement('div');back.id='backdrop';back.style='position:fixed;inset:0;background:#0008;z-index:1000';document.body.append(back);}
 if(config.replaceAt)setTimeout(()=>{const copy=button.cloneNode(true);copy.addEventListener('click',accept);button.replaceWith(copy);},config.replaceAt);
}
if(config.provider==='cookiebot')window.Cookiebot={hasResponse:!!config.existing||hasCookie(),dialog:{visible:!config.existing&&!hasCookie()},submitCustomConsent:(p,s,m)=>{if(p&&s&&m)accept();else wrong++;}};
if(config.provider==='onetrust')window.OneTrust={IsAlertBoxClosed:()=>hasCookie(),AllowAll:accept};
if(config.provider==='usercentrics')window.UC_UI={acceptAllConsents:()=>new Promise((resolve,reject)=>setTimeout(()=>{if(config.apiFails){reject(new Error('Consent failed'));return;}document.cookie=cookieKey+'=yes;path=/';resolve();},550)),closeCMP:()=>{if(hasCookie())accept();else wrong++;},areAllConsentsAccepted:hasCookie};
if(config.frame){
 const frame=document.createElement('iframe');frame.style='position:fixed;inset:0;width:100%;height:100%;border:0;z-index:9999';
 const host=config.sameOrigin?'127.0.0.1':'localhost';
 const name=config.nested?'cross-origin-frame':'simple';
 frame.src=location.protocol+'//'+host+':'+location.port+'/case/'+name;document.body.append(frame);window.banner=frame;
 addEventListener('message',e=>{if(e.data?.fixtureAccepted && e.source===frame.contentWindow){accepted++;frame.remove();document.cookie=cookieKey+'=yes;path=/';parent.postMessage({fixtureAccepted:true},'*');}});
}else if(config.delay)setTimeout(create,config.delay);else create();
if(config.busy){let n=0;window.churn=setInterval(()=>{const x=document.createElement('span');x.textContent='live price '+n++;article.append(x);if(n>500)clearInterval(churn);},15);}
if(config.long){const fragment=document.createDocumentFragment();for(let i=0;i<18000;i++){const p=document.createElement('p');p.textContent='Article paragraph '+i+' about cooking without any consent actions.';fragment.append(p);}article.append(fragment);}
window.fixtureReady=true;
window.fixtureReport=()=>{
 const panelVisible=!!banner?.isConnected && !!currentPanel?.getClientRects().length && getComputedStyle(currentPanel).display!=='none';
 const r=article.getBoundingClientRect(),hit=document.elementFromPoint(20,Math.max(1,Math.min(innerHeight-1,r.top+25)));
 return {accepted,wrong,cookie:hasCookie(),bannerConnected:!!banner?.isConnected,panelVisible,locked:article.inert||getComputedStyle(document.body).overflow==='hidden',articleHit:hit===article||article.contains(hit),errors,articleLength:article.textContent.length};
};
"""

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        parsed=urlparse(self.path)
        name=parse_qs(parsed.query).get('case',[parsed.path.rsplit('/',1)[-1]])[0]
        case=next((c for c in CASES if c['name']==name),None)
        if parsed.path=='/manifest':
            selected=[] if parse_qs(parsed.query).get('checks') else CASES
            if parse_qs(parsed.query).get('cases'):
                names=parse_qs(parsed.query)['cases'][0].split(',');selected=[c for c in selected if c['name'] in names]
            body=json.dumps([dict(c,url='/index.html?message_id=fixture&case='+c['name'] if c.get('provider')=='sourcepoint' else '/case/'+c['name']) for c in selected]).encode(); mime='application/json'
        elif parsed.path=='/script.js':
            case=next(c for c in CASES if c['name']==parse_qs(parsed.query)['case'][0])
            body=('const FIXTURE='+json.dumps(case)+';'+SCRIPT).encode();mime='application/javascript'
        elif case:
            body=(f'''<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><title>{name}</title>
            <style>body{{font:18px sans-serif;margin:0}} main{{padding:10px;min-height:2000px;background:#effaf4}}
            .panel{{position:fixed;inset:auto 8px 18px;z-index:2147483646;background:#fff;border:2px solid #333;padding:22px;color:#111}}
            button,a{{padding:12px;margin:6px}} dialog.panel{{inset:20% 8px auto}}dialog::backdrop{{background:#0008}}</style>
            </head><body><main><h1>Usable article</h1><p>Normal controls and scrolling must survive consent.</p><button id=normal type=button>Normal article action</button></main>
            <script src="/script.js?case={name}"></script></body></html>''').encode();mime='text/html'
        else: body=b'not found';mime='text/plain'
        self.send_response(200);self.send_header('Content-Type',mime+';charset=utf-8')
        self.send_header('Cache-Control','no-store');self.send_header('Content-Length',str(len(body)))
        if case and case.get('csp'):self.send_header('Content-Security-Policy',"default-src 'self'; script-src 'self'; style-src 'unsafe-inline'; frame-src http://127.0.0.1:* http://localhost:*")
        self.end_headers();self.wfile.write(body)

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--port',type=int,default=8899);args=parser.parse_args()
    print(f'Serving {len(CASES)} cookie-consent fixtures on {args.port}',flush=True)
    ThreadingHTTPServer(('0.0.0.0',args.port),Handler).serve_forever()
