#!/usr/bin/env python3
"""Build a source-only ZIP for Load unpacked. No credentials, caches, tests or dependencies."""
from pathlib import Path
import json
import zipfile

root = Path(__file__).resolve().parent
version = json.loads((root / 'manifest.json').read_text())['version']
output = root.parents[1] / 'build' / f'Rise-Tab-Sync-{version}.zip'
output.parent.mkdir(parents=True, exist_ok=True)
files = [root / name for name in ('manifest.json', 'popup.html', 'style.css', 'README.md')]
files += sorted((root / 'src').glob('*.js')) + sorted((root / 'icons').glob('*.png'))
with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as archive:
    for file in files:
        archive.write(file, Path('Rise-Tab-Sync') / file.relative_to(root))
print(output)
