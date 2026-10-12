"""Puts the Chromium engine into Rise.app: the framework and the helper apps Chromium runs
pages, graphics and networking in, each signed like Rise itself. Run before signing the app."""
import importlib.util
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

# Signs with the identity Rise itself is signed with.
spec = importlib.util.spec_from_file_location("sign_app", Path(__file__).resolve().parent.parent / "sign-app.py")
sign_app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sign_app)

ROOT = Path(__file__).resolve().parents[2]
ENGINE = Path(os.environ.get("RISE_CHROMIUM_ROOT", ROOT.parent / "rise-chromium"))
FRAMEWORK = "Chromium Embedded Framework.framework"
# The helpers Chromium looks for beside the framework: "<app> Helper<suffix>.app".
HELPERS = ["", " (GPU)", " (Renderer)", " (Alerts)"]


def sign(path, identity):
    subprocess.run(["codesign", "--force", "--sign", identity, str(path)], check=True, capture_output=True)


def signed_framework(identity):
    """The framework signed with `identity`, kept beside the engine so it's signed once per
    engine build rather than on every Rise build."""
    source = ENGINE / "distrib/current/Release" / FRAMEWORK
    cache = ENGINE / "signed" / identity.replace("/", "_") / FRAMEWORK
    stamp = cache.parent / "source-mtime"
    current = str(source.joinpath("Chromium Embedded Framework").stat().st_mtime_ns)
    if not cache.exists() or not stamp.exists() or stamp.read_text() != current:
        if cache.exists():
            shutil.rmtree(cache)
        cache.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["ditto", str(source), str(cache)], check=True)
        sign(cache, identity)
        stamp.write_text(current)
    return cache


def helper(app, suffix, executable, info, identity):
    name = "Rise Helper" + suffix
    bundle = app / "Contents/Frameworks" / (name + ".app")
    (bundle / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
    shutil.copy2(executable, bundle / "Contents/MacOS" / name)
    plist = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleDisplayName": name, "CFBundleName": name, "CFBundleExecutable": name,
        "CFBundleIdentifier": info["CFBundleIdentifier"] + ".helper" + (".alerts" if suffix == " (Alerts)" else ""),
        "CFBundleInfoDictionaryVersion": "6.0", "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": info["CFBundleShortVersionString"], "CFBundleVersion": info["CFBundleVersion"],
        "LSEnvironment": {"MallocNanoZone": "0"}, "LSFileQuarantineEnabled": True,
        "LSMinimumSystemVersion": info["LSMinimumSystemVersion"], "LSUIElement": "1",
        "NSSupportsAutomaticGraphicsSwitching": True,
    }
    (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(plist))
    sign(bundle, identity)


def main():
    app = Path(sys.argv[1])
    executable = Path(sys.argv[2])
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    identity, _, _ = sign_app.configuration(info)
    frameworks = app / "Contents/Frameworks"
    frameworks.mkdir(parents=True, exist_ok=True)
    subprocess.run(["rsync", "-a", "--delete", str(signed_framework(identity)) + "/", str(frameworks / FRAMEWORK) + "/"], check=True)
    for suffix in HELPERS:
        helper(app, suffix, executable, info, identity)


if __name__ == "__main__":
    main()
