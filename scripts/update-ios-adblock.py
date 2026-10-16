#!/usr/bin/env python3
"""Refresh the iPhone's bundled filters; --reuse-sources reproduces the checked-in snapshot."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Filters/iOS/Sources"
OUTPUT = ROOT / "Apps/iOS/Rise/Blocking"
CONVERTER_SHA = "6687be9f1a77abd5299299086c5fbffd0d1b5baec755eb4808aa2f53e275d3c0"
FILTERS = {
    "base.txt": "https://filters.adtidy.org/extension/safari/filters/2.txt",
    "mobile.txt": "https://filters.adtidy.org/extension/safari/filters/11.txt",
    "quick-fixes.txt": "https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/filters/filter_24_QuickFixes/filter.txt",
}


def download(url, destination):
    subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error", "--retry", "2",
                    "--max-time", "120", url, "-o", str(destination)], check=True)


def asset(path, **metadata):
    return {"file": path.name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), **metadata}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reuse-sources", action="store_true")
    parser.add_argument("--converter", type=Path, help="Use an already downloaded, checksum-verified converter")
    parser.add_argument("--node-modules", type=Path, help="Use the pinned dependencies already installed here")
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        parser.error("The pinned converter needs an Apple Silicon Mac.")
    SOURCES.mkdir(parents=True, exist_ok=True)
    OUTPUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="rise-ios-filters-") as directory:
        work = Path(directory)
        if not args.reuse_sources:
            for name, url in FILTERS.items():
                download(url, work / name)
                shutil.copyfile(work / name, SOURCES / name)
        converter = args.converter or work / "ConverterTool"
        if not args.converter:
            download("https://github.com/AdguardTeam/SafariConverterLib/releases/download/v4.3.0/ConverterTool", converter)
        if hashlib.sha256(converter.read_bytes()).hexdigest() != CONVERTER_SHA:
            raise SystemExit("Converter checksum mismatch")
        converter.chmod(0o755)
        if not args.converter:
            psl = work / "swift-psl_PublicSuffixList.bundle"
            psl.mkdir()
            for name in ["common.bin", "asterisk.bin", "negated.bin", "version.txt"]:
                download("https://raw.githubusercontent.com/ameshkov/swift-psl/7ccee9d576d4ca45219440e346f61117f44c816f/Sources/PublicSuffixList/Resources/"+name, psl / name)
        (work / "combined.txt").write_text("\n".join((SOURCES / name).read_text() for name in FILTERS))
        subprocess.run([str(converter), "convert", "--safari-version", "17.0", "--advanced-blocking", "true",
                        "--input-path", str(work / "combined.txt"), "--safari-rules-json-path", str(work / "native.json"),
                        "--advanced-blocking-rules-path", str(work / "advanced.txt")], check=True)
        rules = json.loads((work / "native.json").read_text())
        # WebKit's exceptions apply only to their own list. Keep every exception, in its
        # original order, in each shard. The final exclusions protect redirects and embeds
        # even before the navigation delegate removes the entire blocker on YouTube.
        youtube = ["youtube.com", "youtube-nocookie.com", "youtu.be", "youtubekids.com"]
        def host_patterns(hosts):
            # WebKit's content-rule regex dialect does not allow disjunctions, even
            # though JavaScript regexes do. Split hosts and end anchors explicitly.
            return [r"^https?://([^/@]+@)?([a-z0-9-]+\.)*"+host.replace(".", r"\.")+r"\.?"+ending
                    for host in hosts for ending in ["[:/]", "$"]]
        exemptions = [
            {"trigger": {"url-filter": ".*", "if-top-url": host_patterns(youtube)}, "action": {"type": "ignore-previous-rules"}},
            {"trigger": {"url-filter": ".*", "if-domain": ["*"+name for name in youtube]}, "action": {"type": "ignore-previous-rules"}},
            {"trigger": {"url-filter": ".*", "if-frame-url": host_patterns(youtube)}, "action": {"type": "ignore-previous-rules"}},
        ] + [{"trigger": {"url-filter": pattern}, "action": {"type": "ignore-previous-rules"}}
             for pattern in host_patterns(youtube+["googlevideo.com"])]
        positions = [i for i, rule in enumerate(rules) if rule["action"]["type"] != "ignore-previous-rules"]
        # iOS 17 WebKit allows 150,000 rules. Avoid repeating megabytes of exceptions
        # when the complete list fits; leave room below the limit for future refreshes.
        budget = 140000-(len(rules)-len(positions))-len(exemptions)
        if budget <= 0:
            raise SystemExit("The exception set is too large for a native rule list")
        lists = []
        for old in OUTPUT.glob("ads-*.json"):
            old.unlink()
        for n, start in enumerate(range(0, len(positions), budget)):
            selected = set(positions[start:start+budget])
            part = [r for i, r in enumerate(rules) if i in selected or r["action"]["type"] == "ignore-previous-rules"] + exemptions
            path = OUTPUT / f"ads-{n+1}.json"
            path.write_text(json.dumps(part, separators=(",", ":"), ensure_ascii=False)+"\n")
            lists.append(asset(path, rules=len(part)))
        modules = args.node_modules
        if not modules:
            for name in ["package.json", "package-lock.json"]:
                shutil.copyfile(ROOT / "scripts/ios-adblock" / name, work / name)
            subprocess.run(["npm", "ci", "--ignore-scripts", "--no-audit", "--no-fund", "--prefix", str(work)], check=True)
            modules = work / "node_modules"
        dependencies = json.loads((ROOT / "scripts/ios-adblock/package.json").read_text())["dependencies"]
        for package, version in dependencies.items():
            if json.loads((modules / package / "package.json").read_text())["version"] != version:
                raise SystemExit("Wrong build dependency version: "+package)
        environment = {**os.environ, "RISE_ADBLOCK_NODE_MODULES": str(modules.resolve())}
        subprocess.run(["node", str(ROOT / "scripts/ios-adblock/build.mjs"), str(work / "advanced.txt"), str(OUTPUT)],
                       env=environment, check=True)
        stats = json.loads((OUTPUT / "advanced-stats.json").read_text())
        (OUTPUT / "advanced-stats.json").unlink()
        manifest = {"format": 1, "converter": "AdGuard SafariConverterLib 4.3.0, Safari 17",
                    "lists": lists, "scripts": [asset(OUTPUT / name) for name in ["adblock-start.js", "adblock-end.js"]],
                    "sources": [asset(SOURCES / name, url=url) for name, url in FILTERS.items()], "advanced": stats}
        (OUTPUT / "adblock-manifest.json").write_text(json.dumps(manifest, indent=2)+"\n")
        print(json.dumps({"lists": lists, "advanced": stats}, indent=2))


if __name__ == "__main__":
    main()
