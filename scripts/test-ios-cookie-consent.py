#!/usr/bin/env python3
"""Runs native WebKit consent audits without GUI automation or XCTest's service hub."""
import argparse
import datetime
import json
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent

def run(*command, **kwargs):
    return subprocess.run(command, cwd=ROOT, check=True, **kwargs)

def audit(simulator, name, target, destination):
    run('xcrun','simctl','launch','--terminate-running-process',simulator,'dev.bartosz.Rise.iOS',
        '-RiseCookieConsentAudit','caches:'+name,target,stdout=subprocess.DEVNULL)
    container=Path(subprocess.check_output(['xcrun','simctl','get_app_container',simulator,'dev.bartosz.Rise.iOS','data'],text=True).strip())
    folder=container/'Library/Caches'/name
    deadline=time.monotonic()+(2000 if target != 'fixtures' and not target.startswith('http:') else 500)
    last=0
    while time.monotonic()<deadline:
        if (folder/'failure.txt').exists():
            shutil.copytree(folder,destination,dirs_exist_ok=True)
            raise RuntimeError((folder/'failure.txt').read_text())
        if (folder/'done.txt').exists():
            shutil.copytree(folder,destination,dirs_exist_ok=True)
            return destination
        if time.monotonic()-last>20:
            for file in ['fixtures.json','sites.json']:
                try:
                    data=json.loads((folder/file).read_text())
                    print(f'{name}: {len(data)} completed',flush=True)
                except (FileNotFoundError,json.JSONDecodeError):pass
            last=time.monotonic()
        time.sleep(1)
    raise TimeoutError('The native consent audit did not finish')

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--simulator',required=True)
    parser.add_argument('--no-build',action='store_true')
    parser.add_argument('--skip-fixtures',action='store_true')
    parser.add_argument('--checks-only',action='store_true',help='Run native/settings/ad checks without repeating the DOM cases')
    parser.add_argument('--cases',help='Run comma-separated fixture names plus the native/ad checks')
    parser.add_argument('--real-sites',help='all, or comma-separated site indices from CookieConsentAudit.swift')
    args=parser.parse_args()
    stamp=datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    output=ROOT/'build/ios-cookie-consent'/stamp;output.mkdir(parents=True)
    if not args.no_build:
        with (output/'build.log').open('w') as log:
            run('./scripts/restart.sh','--ios','--simulator',args.simulator,stdout=log,stderr=subprocess.STDOUT)
    if not args.skip_fixtures:
        with socket.socket() as sock:
            sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
        server=subprocess.Popen([sys.executable,str(ROOT/'scripts/ios-cookie-consent/fixtures.py'),'--port',str(port)],stdout=subprocess.DEVNULL)
        try:
            time.sleep(.3)
            target=f'http://127.0.0.1:{port}'+('/?checks=1' if args.checks_only else '')
            if args.cases:target=f'http://127.0.0.1:{port}/?cases='+args.cases
            folder=audit(args.simulator,'CookieFixtures-'+stamp,target,output/'fixtures')
            cases=json.loads((folder/'fixtures.json').read_text());settings=json.loads((folder/'settings.json').read_text())
            failed=[case['case'] for case in cases if not case['passed']]
            failed.extend(name for name,passed in settings.items() if not passed)
            if failed:raise RuntimeError('Failed: '+', '.join(failed))
            ads=json.loads((folder/'ad-regressions.json').read_text())
            print(f'Passed {len(cases)} consent fixtures, {len(settings)} native checks, {len(ads)} ad regressions',flush=True)
        finally:
            server.terminate();server.wait()
    if args.real_sites:
        folder=audit(args.simulator,'CookieSites-'+stamp,args.real_sites,output/'sites')
        pages=json.loads((folder/'sites.json').read_text())
        print(f'Audited {len(pages)} public page loads; inspect before/after reports and ambiguous snapshots',flush=True)
    print(output,flush=True)

if __name__=='__main__':main()
