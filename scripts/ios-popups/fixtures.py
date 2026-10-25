#!/usr/bin/env python3
"""Deterministic HTTP fixtures for native Rise taps; no public ad network is loaded."""
import argparse
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
import json
from urllib.parse import urlsplit

AD = 'https://profitableratecpmnetwork.com/unwanted'
BUTTON = '<button id="run">Run case</button>'
LINK = '<a id="run" href="/destination/wanted" target="_blank"><span>Run case</span></a>'
CASES = [
    dict(name='direct-link', markup=LINK, tabs=1, path='/destination/wanted'),
    dict(name='hijacked-link', markup=LINK, script="document.addEventListener('click',()=>window.open('/destination/unwanted'),true)", tabs=1, path='/destination/wanted'),
    dict(name='rewritten-link', markup=LINK, script="run.addEventListener('pointerdown',()=>run.href='/destination/unwanted')", tabs=0),
    dict(name='known-ad-button', markup=BUTTON, script=f"run.onclick=()=>window.open('{AD}')", tabs=0),
    dict(name='generic-div', markup='<div id="run">Run case</div>', script="run.onclick=()=>window.open('/destination/unwanted')", tabs=0),
    dict(name='synthetic-link', markup='<div id="run">Run case</div>', script="run.onclick=()=>{let a=document.createElement('a');a.href='/destination/unwanted';a.target='_blank';a.click()}", tabs=0),
    dict(name='delayed-background-popup', markup='<div id="run">Run case</div>', script="run.onclick=()=>setTimeout(()=>window.open('/destination/unwanted'),100)", tabs=0),
    dict(name='one-window-per-gesture', markup=BUTTON, script="run.onclick=()=>{window.open('/destination/wanted');window.open('/destination/unwanted')}", tabs=1, path='/destination/wanted'),
    dict(name='scripted-button', markup=BUTTON, script="run.onclick=()=>window.open('/destination/wanted')", tabs=1, path='/destination/wanted'),
    dict(name='blank-then-navigate', markup=BUTTON, script="run.onclick=()=>{const p=window.open('about:blank');if(p)p.location='/destination/wanted'}", tabs=1, path='/destination/wanted'),
    dict(name='blank-document-write', markup=BUTTON, script="run.onclick=()=>{const p=window.open('');if(p){p.document.write('<h1>Written export</h1>');p.document.close()}}", tabs=1, text='Written export'),
    dict(name='get-form', markup='<form action="/destination/search" target="_blank"><input type="hidden" name="q" value="a & b"><button id="run">Run case</button></form>', tabs=1, path='/destination/search', query=True),
    dict(name='post-form', markup='<form action="/destination/payment" method="post" target="_blank"><input type="hidden" name="token" value="fixture-token"><button id="run">Run case</button></form>', tabs=1, path='/destination/payment', post=True),
    dict(name='rewritten-form', markup='<form action="/destination/wanted" target="_blank"><button id="run">Run case</button></form>', script="run.onpointerdown=()=>run.form.action='/destination/unwanted'", tabs=0),
    dict(name='shadow-link', markup='<div id="host"></div>', script="host.attachShadow({mode:'open'}).innerHTML='<style>a{display:block;padding:30px;background:#1676de;color:white}</style><a href=\"/destination/wanted\" target=\"_blank\">Run case</a>'", tabs=1, path='/destination/wanted'),
    dict(name='cross-origin-frame-button', markup='<iframe src="http://localhost:PORT/frame/button"></iframe>', tabs=1, path='/destination/wanted'),
    dict(name='cross-origin-frame-background', markup='<iframe src="http://localhost:PORT/frame/background"></iframe>', tabs=0),
    dict(name='transparent-overlay', markup='<a id="run" href="/destination/unwanted" target="_blank" style="position:fixed;inset:0;opacity:0"></a>', tabs=0),
    dict(name='same-window-open', markup=BUTTON, script="run.onclick=()=>window.open('/destination/wanted','_self')", tabs=0, selfNavigation=True),
    dict(name='popunder', markup='<div id="run">Run case</div>', script=f"run.onclick=()=>{{window.open('/destination/wanted');location.href='{AD}'}}", tabs=0),
    dict(name='blob-export', markup=BUTTON, script="run.onclick=()=>window.open(URL.createObjectURL(new Blob(['<h1>Blob export</h1>'],{type:'text/html'})))", tabs=1, text='Blob export'),
    dict(name='window-close', markup=BUTTON, script="run.onclick=()=>{const p=window.open('/destination/wanted');setTimeout(()=>p?.close(),350)}", tabs=0),
    dict(name='disabled-autopopup', markup=BUTTON, script="run.onclick=()=>setTimeout(()=>window.open('/destination/wanted'),100)", tabs=1, path='/destination/wanted', disabled=True),
    dict(name='reenabled-synthetic-click', markup=BUTTON, script="run.onclick=()=>{let a=document.createElement('a');a.href='/destination/unwanted';a.target='_blank';a.click()}", automatic=True, tabs=0),
    dict(name='async-button', markup=BUTTON, script="run.onclick=()=>setTimeout(()=>window.open('/destination/wanted'),100)", tabs=1, path='/destination/wanted'),
    dict(name='expired-gesture', markup=BUTTON, script="run.onclick=()=>setTimeout(()=>window.open('/destination/unwanted'),1900)", tabs=0, wait=2400),
    dict(name='noopener-link', markup=LINK.replace('target="_blank"', 'target="_blank" rel="noopener noreferrer"'), tabs=1, path='/destination/wanted'),
    dict(name='http-redirect', markup=BUTTON, script="run.onclick=()=>window.open('/redirect/wanted')", tabs=1, path='/destination/wanted'),
    dict(name='http-ad-redirect', markup=BUTTON, script="run.onclick=()=>window.open('/redirect/ad')", tabs=0),
    dict(name='blank-ad-redirect', markup=BUTTON, script="run.onclick=()=>{const p=window.open('about:blank');if(p)p.location='/destination/advert?dovr=true'}", tabs=0),
    dict(name='unactivated-window-open', markup=BUTTON, script="run.onclick=()=>window.open('/destination/unwanted?token=never-log-this-token')", automatic=True, tabs=0),
    dict(name='observer-flood', markup=BUTTON, script="run.onclick=()=>{for(let i=0;i<150;i++)window.webkit.messageHandlers.risePopupObserver.postMessage({phase:'attempt',id:'never-log-this-page-id-'+i,url:'/destination/unwanted?token=never-log-this-token',target:'_blank',active:'true'});window.open('/destination/unwanted')}", automatic=True, tabs=0),
]
HITS = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        self.do_GET()

    def do_GET(self):
        path = urlsplit(self.path).path
        body = self.rfile.read(int(self.headers.get('Content-Length', '0'))).decode()
        if path.startswith('/destination/'):
            HITS.append(dict(path=self.path, method=self.command, body=body))
        if path == '/cases':
            return self.reply(json.dumps(CASES), 'application/json')
        if path == '/hits':
            return self.reply(json.dumps(HITS), 'application/json')
        if path.startswith('/redirect/'):
            self.send_response(302)
            self.send_header('Location', '/destination/advert?dovr=true' if path.endswith('/ad') else '/destination/wanted')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if path.startswith('/destination/'):
            return self.reply(f'<meta name="viewport" content="width=device-width"><h1>Destination</h1><p>{self.command}: {self.path}</p><p>{body}</p>')
        if path.startswith('/frame/'):
            markup = BUTTON if path.endswith('button') else '<div id="run">Run case</div>'
            return self.reply(page('iframe', markup, "run.onclick=()=>window.open('/destination/wanted');document.addEventListener('pointerdown',()=>parent.postMessage('tapped','*'),true)"))
        case = next((c for c in CASES if path == '/case/'+c['name']), None)
        if case:
            return self.reply(page(case['name'], case['markup'].replace('PORT', str(self.server.server_port)), case.get('script', '')))
        self.reply('<h1>Missing fixture</h1>')

    def reply(self, body, mime='text/html'):
        data = body.encode()
        self.send_response(200)
        self.send_header('Content-Type', mime+'; charset=utf-8')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(data)


def page(name, markup, script):
    return f'''<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
    <style>body{{font:18px -apple-system;margin:24px;background:#f6f6f8;color:#111}}h1{{font-size:18px;height:55px;margin:0}}#run{{display:block;width:100%;box-sizing:border-box;border:0;padding:30px 20px;background:#1676de;color:white;font:20px -apple-system;text-decoration:none}}iframe{{width:100%;height:240px;border:0}}</style>
    <h1>{name}</h1>{markup}<p>Native popup regression fixture</p>
    <script>window.clicked=false;const tapped=e=>{{if(e.composedPath().some(n=>n.id==='run'||n.id==='host'))window.clicked=true}};document.addEventListener('pointerdown',tapped,true);document.addEventListener('click',tapped,true);addEventListener('message',e=>{{if(e.data==='tapped')window.clicked=true}});{script}</script>'''


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=8765)
    args = parser.parse_args()
    ThreadingHTTPServer(('0.0.0.0', args.port), Handler).serve_forever()
