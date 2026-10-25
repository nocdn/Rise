"""Downloads the filter lists Rise's ad blocking is built from (Filters/Sources), which
Engine/adblock compiles into the engine when ./scripts/build.sh builds it. The iPhone app's
lists are updated by scripts/update-ios-adblock.py."""
import pathlib, subprocess
root = pathlib.Path(__file__).resolve().parents[1]
source = root / 'Filters/Sources'; source.mkdir(parents=True, exist_ok=True)
subprocess.run(['curl', '--fail', '--location', '--silent', '--show-error', '--retry', '2', '--max-time', '120',
                'https://easylist.to/easylist/easylist.txt', '-o', str(source / 'easylist.txt')], check=True)
print('Updated easylist')
