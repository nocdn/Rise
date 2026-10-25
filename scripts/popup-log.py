#!/usr/bin/env python3
"""Fetch Rise's persistent popup diagnostics from a paired iPhone/Simulator, or read an in-app export."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
from urllib.parse import urlsplit

BUNDLE = 'dev.bartosz.Rise.iOS'
LOG = 'Library/Application Support/RiseDiagnostics/Popups'


def records(path):
    files = sorted(path.rglob('*.jsonl')) if path.is_dir() else [path]
    result, unreadable = [], 0
    for file in files:
        if file.suffix == '.json':
            data = json.loads(file.read_text())
            result.extend(data.get('events', []))
            continue
        for line in file.read_text().splitlines():
            if not line.strip():
                continue
            try:
                result.append(json.loads(line))
            except json.JSONDecodeError:
                unreadable += 1
    return sorted(result, key=lambda r: r.get('timestamp', 0)), unreadable


def on_site(record, site):
    for field in ['source', 'destination', 'frame']:
        host = urlsplit(record.get(field) or '').hostname or ''
        if host == site or host.endswith('.'+site):
            return True
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--device', help='Paired iPhone name or UDID')
    source.add_argument('--simulator', help='Simulator UDID')
    source.add_argument('--read', type=Path, help='Directory of fetched JSONL files or a Share popup diagnostics JSON export')
    parser.add_argument('--output', type=Path, help='Keep a local copy here')
    parser.add_argument('--site', help='Filter by website hostname')
    parser.add_argument('--last', type=int, default=100)
    parser.add_argument('--blocked', action='store_true', help='Only native denied window/navigation decisions')
    parser.add_argument('--json', action='store_true', help='Print structured records')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='rise-popup-logs-') as temporary:
        if args.read:
            path = args.read
        elif args.simulator:
            container = subprocess.check_output(['xcrun', 'simctl', 'get_app_container', args.simulator, BUNDLE, 'data'], text=True).strip()
            path = Path(container) / LOG
        else:
            path = Path(temporary) / 'Popups'
            subprocess.run(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', args.device,
                            '--domain-type', 'appDataContainer', '--domain-identifier', BUNDLE,
                            '--source', LOG, '--destination', str(path)], check=True, stdout=subprocess.DEVNULL)
        if not path.exists():
            print('No persistent popup diagnostics yet. Private traces are in-memory and must be shared from App settings during that private session.')
            return
        if args.output:
            if path.is_dir():
                shutil.copytree(path, args.output, dirs_exist_ok=True)
            else:
                args.output.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, args.output)
        data, unreadable = records(path)
    if args.site:
        site = urlsplit(args.site if '://' in args.site else 'https://'+args.site).hostname or args.site
        data = [r for r in data if on_site(r, site.lower())]
    if args.blocked:
        data = [r for r in data if r.get('details', {}).get('allowed') == 'false']
    selected = data[-max(0, args.last):] if args.last > 0 else data
    if args.json:
        print(json.dumps(selected, indent=2))
        return
    print(f'{len(data)} matching events; showing {len(selected)}. Unreadable/truncated lines: {unreadable}. Times are UTC.')
    for record in selected:
        stamp = datetime.fromtimestamp(record.get('timestamp', 0)/1000, timezone.utc).isoformat(timespec='milliseconds')
        details = record.get('details', {})
        reason = details.get('reason') or details.get('classification') or details.get('stage') or ''
        print(f"{stamp} {record['event']} {reason}")
        if record.get('source'):
            print('  from:', record['source'])
        if record.get('destination'):
            print('  to:  ', record['destination'])
        print('  ids:', ' '.join(f'{key}={record[key]}' for key in ['pageID', 'documentID', 'chainID', 'requestID'] if record.get(key)))
        if details:
            print('  context:', json.dumps(details, sort_keys=True))
        rules = record.get('rules') or {}
        for kind in ['blocking', 'exceptions']:
            for rule in rules.get(kind, []):
                print(f"  {kind} [{rules.get('catalogID', '')[:12]}:{rule['index']}]: {rule.get('filter') or rule['pattern']}")


if __name__ == '__main__':
    main()
