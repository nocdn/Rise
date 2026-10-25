#!/usr/bin/env python3
"""Extract popup-only rules from Rise's pinned AdGuard/EasyList snapshots.

These rules are evaluated only for new windows and their redirects, never for
ordinary page resources. Keep exceptions, domain scopes and badfilter overrides.
"""
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]


def pattern_regex(pattern):
    if not pattern:
        return '.*'
    if pattern.startswith('/') and pattern.endswith('/'):
        return pattern[1:-1]
    prefix = suffix = ''
    if pattern.startswith('||'):
        prefix = r'^https?://(?:[a-z0-9_-]+\.)*'
        pattern = pattern[2:]
    elif pattern.startswith('|'):
        prefix, pattern = '^', pattern[1:]
    if pattern.endswith('|'):
        suffix, pattern = '$', pattern[:-1]
    return prefix + ''.join('.*' if c == '*' else r'(?:[^a-zA-Z0-9_.%-]|$)' if c == '^'
                            else re.escape(c) for c in pattern) + suffix


def extract(lines):
    parsed = []
    for line in lines:
        line = line.strip()
        if line.startswith(('!', '[')) or '$' not in line:
            continue
        pattern, options = line.rsplit('$', 1)
        modifiers = options.split(',')
        if 'popup' not in modifiers:
            continue
        allowed = {'popup', 'document', 'script', 'subdocument', 'third-party', '~third-party',
                   'match-case', 'badfilter', 'important'}
        unknown = [m for m in modifiers if m not in allowed and not m.startswith('domain=')]
        if unknown:
            raise ValueError(f'Unsupported popup modifier {unknown}: {line}')
        key = (pattern, tuple(sorted(m for m in modifiers if m != 'badfilter')))
        parsed.append((pattern, modifiers, key))
    disabled = {key for _, mods, key in parsed if 'badfilter' in mods}
    rules = []
    for pattern, mods, key in parsed:
        if key in disabled or 'badfilter' in mods:
            continue
        original = pattern+'$'+','.join(mods)
        exception = pattern.startswith('@@')
        if exception:
            pattern = pattern[2:]
        domains = next((m[7:].split('|') for m in mods if m.startswith('domain=')), [])
        rules.append(dict(pattern=pattern_regex(pattern), exception=exception,
                          include=[d.lower() for d in domains if not d.startswith('~')],
                          exclude=[d[1:].lower() for d in domains if d.startswith('~')],
                          party=-1 if '~third-party' in mods else 1 if 'third-party' in mods else 0,
                          matchCase='match-case' in mods, important='important' in mods, original=original))
    return list({json.dumps({k: v for k, v in r.items() if k != 'original'}, sort_keys=True): r for r in rules}.values())


def build():
    sources = sorted((ROOT / 'Filters/iOS/Sources').glob('*.txt'))
    rules = extract(line for source in sources for line in source.read_text().splitlines())
    result = dict(format=1, sources=[dict(file=p.name, sha256=hashlib.sha256(p.read_bytes()).hexdigest())
                                   for p in sources], rules=rules)
    path = ROOT / 'Apps/iOS/Rise/Blocking/popup-rules.json'
    path.write_text(json.dumps(result, separators=(',', ':')) + '\n')
    print(f'Bundled {len(rules)} popup rules, including {sum(r["exception"] for r in rules)} exceptions')


if __name__ == '__main__':
    build()
