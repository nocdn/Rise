"""Downloads the filter lists Rise's ad blocking is built from (Filters/Sources), which
Engine/adblock compiles into the engine when ./scripts/build.sh builds it. The iPhone app's
lists are updated by scripts/update-ios-adblock.py."""
import pathlib, subprocess
root = pathlib.Path(__file__).resolve().parents[1]
source = root / 'Filters/Sources'; source.mkdir(parents=True, exist_ok=True)
for name, url in [('easylist', 'https://easylist.to/easylist/easylist.txt'), ('easyprivacy', 'https://easylist.to/easylist/easyprivacy.txt'),
                  ('hagezi-mini', 'https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.mini.txt')]:
    subprocess.run(['curl', '--fail', '--location', '--silent', '--show-error', '--retry', '2', '--max-time', '120', url,
                    '-o', str(source / (name + '.txt'))], check=True)
    print('Updated', name)
