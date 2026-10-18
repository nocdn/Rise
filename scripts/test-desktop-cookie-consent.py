#!/usr/bin/env python3
"""Run the shared consent fixtures in real Rise/Chromium, with optional public-site comparisons."""
import argparse
import datetime
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import threading

ROOT = Path(__file__).resolve().parent.parent

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--no-build', action='store_true')
    parser.add_argument('--cases', help='Comma-separated shared fixture names; otherwise all cases')
    parser.add_argument('--real-sites', action='store_true')
    parser.add_argument('--site-url', action='append', help='Restrict public comparisons to these URLs')
    args = parser.parse_args()
    output = ROOT / 'build/desktop-cookie-consent' / datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    output.mkdir(parents=True)
    if not args.no_build:
        subprocess.run(['./scripts/restart.sh'], cwd=ROOT, check=True)
    spec = importlib.util.spec_from_file_location('consent_fixtures', ROOT / 'scripts/ios-cookie-consent/fixtures.py')
    fixtures = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fixtures)
    server = fixtures.ThreadingHTTPServer(('127.0.0.1', 0), fixtures.Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = dict(os.environ, RISE_PEEK_OUT=str(output), RISE_COOKIE_BASE=f'http://127.0.0.1:{server.server_port}',
               RISE_COOKIE_CASES=args.cases or '', RISE_COOKIE_PUBLIC='1' if args.real_sites or args.site_url else '0',
               RISE_COOKIE_URLS=json.dumps(args.site_url or []))
    try:
        result = subprocess.run(['python3', 'scripts/test-chromium-live.py', 'Tests/Live/ChromiumCookieConsentChecks.swift'], cwd=ROOT, env=env)
    finally:
        server.shutdown(); server.server_close()
        if not os.environ.get('RISE_LLDB') and not os.environ.get('RISE_KEEP_PROBE'):
            shutil.rmtree(output / 'RiseProbe.app', ignore_errors=True)
    print(output, flush=True)
    completed = json.loads((output / 'done.json').read_text()) if (output / 'done.json').exists() else {'failures': 1}
    raise SystemExit(result.returncode or (1 if completed['failures'] else 0))

if __name__ == '__main__':
    main()
