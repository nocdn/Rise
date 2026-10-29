"""Puts uBlock Origin, Rise's ad blocking, at the given folder (the app's Resources/uBlock0.chromium):
the release pinned in Engine/ublock.json, checked against its checksum, with the pinned key in its
manifest so its extension id (mehgmpfnbopgodfmhbkfhkghemcgpeci, allowed in the engine) never
changes, and the lists Engine/ublock.json names off by default. Downloads are kept beside the
engine checkout, so a rebuild needs no network.

    python3 scripts/ublock.py <destination>
"""
import hashlib, json, os, pathlib, shutil, subprocess, sys, tempfile, zipfile

root = pathlib.Path(__file__).resolve().parents[1]
pin = json.loads((root / 'Engine/ublock.json').read_text())
cache = pathlib.Path(os.environ.get('RISE_CHROMIUM_ROOT', root.parent / 'rise-chromium')) / 'ublock'
archive = cache / f"uBlock0_{pin['version']}.chromium.zip"
destination = pathlib.Path(sys.argv[1])

def checksum(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

if not archive.exists() or checksum(archive) != pin['sha256']:
    cache.mkdir(parents=True, exist_ok=True)
    partial = archive.with_suffix('.partial')
    subprocess.run(['curl', '--fail', '--location', '--silent', '--show-error', '--retry', '2', '--max-time', '300',
                    pin['url'], '-o', str(partial)], check=True)
    if checksum(partial) != pin['sha256']:
        partial.unlink()
        raise SystemExit(f"uBlock Origin {pin['version']}: the download doesn't match Engine/ublock.json's checksum")
    partial.replace(archive)

with tempfile.TemporaryDirectory() as work:
    with zipfile.ZipFile(archive) as release:
        release.extractall(work)
    extension = pathlib.Path(work) / 'uBlock0.chromium'
    manifest_path = extension / 'manifest.json'
    manifest = json.loads(manifest_path.read_text())
    manifest['key'] = pin['key']
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + '\n')
    # Rise blocks ads, not trackers: uBlock Origin's tracker lists start off (the dashboard can turn
    # them on). Its list of lists stays the one it ships with, as upstream's newer one would turn
    # them back on; the lists themselves still update.
    assets_path = extension / 'assets/assets.json'
    assets = json.loads(assets_path.read_text())
    for key in pin['off']:
        assets[key]['off'] = True
    assets['assets.json']['contentURL'] = ['assets/assets.json']
    assets['assets.json'].pop('cdnURLs', None)
    assets_path.write_text(json.dumps(assets, indent='\t', ensure_ascii=False) + '\n')
    shutil.rmtree(destination, ignore_errors=True)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(extension, destination)
print(f"uBlock Origin {pin['version']} at {destination}")
