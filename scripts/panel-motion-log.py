#!/usr/bin/env python3
"""Read search/Downloads panel frame callbacks and drag costs; callback gaps are not rendered hitches."""
import argparse
import json
from pathlib import Path
import statistics
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
target = parser.add_mutually_exclusive_group(required=True)
target.add_argument('--simulator')
target.add_argument('--device')
target.add_argument('--file', type=Path)
parser.add_argument('--last', type=int, default=3)
parser.add_argument('--json', action='store_true')
args = parser.parse_args()
relative = 'Library/Caches/Panels/log.jsonl'
with tempfile.TemporaryDirectory(prefix='rise-panel-log-') as temporary:
    if args.file:
        path = args.file
    elif args.simulator:
        container = subprocess.check_output(['xcrun', 'simctl', 'get_app_container', args.simulator,
                                             'dev.bartosz.Rise.iOS', 'data'], text=True).strip()
        path = Path(container) / relative
    else:
        path = Path(temporary) / 'log.jsonl'
        subprocess.run(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', args.device,
                        '--domain-type', 'appDataContainer', '--domain-identifier', 'dev.bartosz.Rise.iOS',
                        '--source', relative, '--destination', str(path)], check=True, stdout=subprocess.DEVNULL)
    records = [json.loads(line) for line in path.read_text().splitlines() if line.strip()] if path.exists() else []
for record in records[-max(1, args.last):]:
    if args.json:
        print(json.dumps(record, indent=2))
        continue
    print(f"{record['started']}  {record['panel']}  up to {record['maximumFPS']} fps; "
          f"low power {record['lowPower']}, thermal state {record['thermalState']}")
    work = [sample['ms'] for sample in record['work']]
    if work:
        print(f"  Drag work: mean {statistics.mean(work):.3f} ms, max {max(work):.3f} ms")
    for phase in ['drag', 'settle']:
        frames = [f for f in record['frames'] if f['phase'] == phase and f['intervalMS'] > 0]
        if frames:
            rate = 1000/statistics.median(f['intervalMS'] for f in frames)
            gaps = sum(f['gapMS'] > f['intervalMS']*1.5 for f in frames)
            print(f"  {phase}: {len(frames)} callbacks at {rate:.0f} Hz; {gaps} long callback gaps, "
                  f"worst {max(f['gapMS'] for f in frames):.1f} ms")
    for event in record['events']:
        print(f"  {event['t']:.3f}s  {event['name']}")
if not records:
    print('No panel drags logged yet.')
