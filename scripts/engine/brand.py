#!/usr/bin/env python3
"""Names Rise where Chromium names itself to people: "Chromium" becomes "Rise" in the browser's
branded strings and every translation of them, and Rise's icon replaces Chromium's logo. Run after
patch.sh; running again changes nothing.

A translation is found by a fingerprint of its English text, so each one renamed is given the
fingerprint of its renamed English, worked out by Chromium's own resource tool (grit).

Usage: brand.py <chromium/src> [--dry-run]
"""
import pathlib
import re
import subprocess
import sys
import tempfile

PRODUCT = "Rise"
# "Chromium" as the product, not the open-source project behind it (its authors) or ChromiumOS.
NAME = re.compile(r"\bChromium\b(?! Authors)")
# The text of a link to the Chromium project names the project, in every language. Its link opens
# with a placeholder, written out in the strings, closed in translations and named in fingerprints.
PROJECT = re.compile(r'(BEGIN_LINK_CHROMIUM(?:"[^>]*?/?>(?:[^<]*</ph>)?)?)Chromium')
# Each set: its strings file, every file holding its messages, and its translations.
SETS = [
    ("chrome/app/chromium_strings.grd", ["chrome/app/chromium_strings.grd", "chrome/app/settings_chromium_strings.grdp"],
     "chrome/app/resources/chromium_strings_*.xtb"),
    ("components/components_chromium_strings.grd", ["components/components_chromium_strings.grd"],
     "components/strings/components_chromium_strings_*.xtb"),
]
# The build's switches the strings' conditions read, as Rise builds for macOS.
DEFINES = {"_is_chrome_for_testing_branded": False, "enable_extensions": True, "enable_extensions_core": True,
           "enable_pdf": True, "toolkit_views": True, "use_titlecase": True}


def rename(text):
    text = PROJECT.sub(lambda match: match.group(1) + "\0", text)
    return NAME.sub(PRODUCT, text).replace("\0", "Chromium")


def renamed_ids(src, grd):
    """Old fingerprint to new, for every message whose English names the product."""
    from grit import grd_reader
    from grit.extern import tclib
    from grit.node import message as message_node

    path = src / grd
    root = grd_reader.Parse(str(path), str(path.parent), first_ids_file=None, defines=DEFINES, target_platform="darwin")
    ids = {}
    for node in root.Preorder():
        if not isinstance(node, message_node.MessageNode):
            continue
        message = node.GetCliques()[0].GetMessage()
        text = message.GetPresentableContent()
        if rename(text) == text:
            continue
        old = message.GetId()
        # A message with an id of its own keeps it; the rest go by their text.
        fingerprinted = old == tclib.GenerateMessageId(text, message.GetMeaning())
        ids[old] = tclib.GenerateMessageId(rename(text), message.GetMeaning()) if fingerprinted else old
    return ids


def brand(src, grd, sources, translations, dry):
    ids = renamed_ids(src, grd)
    print(f"{grd}: {len(ids)} messages name the product")
    if not ids:
        return
    for name in sources:
        path = src / name
        text = path.read_text(encoding="utf-8")
        if not dry:
            path.write_text(rename(text), encoding="utf-8")

    translation = re.compile(r'(<translation id=")(\d+)(">)(.*?)(</translation>)', re.S)
    files = sorted(src.glob(translations))
    moved = 0
    for path in files:
        text = path.read_text(encoding="utf-8")

        def renamed(match):
            nonlocal moved
            if match.group(2) not in ids:
                return match.group(0)
            moved += 1
            return match.group(1) + ids[match.group(2)] + match.group(3) + rename(match.group(4)) + match.group(5)

        result = translation.sub(renamed, text)
        if not dry and result != text:
            path.write_text(result, encoding="utf-8")
    print(f"  {moved} translations renamed across {len(files)} languages")


# Rise's icon, where Chromium shows its logo (settings, its About page), at each size and scale.
LOGO = pathlib.Path(__file__).resolve().parents[2] / "Engine/branding/logo.png"
LOGOS = {
    "chrome/app/theme/default_100_percent/chromium/product_logo_16.png": 16,
    "chrome/app/theme/default_100_percent/chromium/product_logo_32.png": 32,
    "chrome/app/theme/default_200_percent/chromium/product_logo_16.png": 32,
    "chrome/app/theme/default_200_percent/chromium/product_logo_32.png": 64,
}


def brand_logos(src, dry):
    changed = 0
    with tempfile.TemporaryDirectory() as work:
        for name, size in LOGOS.items():
            made = pathlib.Path(work) / f"{size}.png"
            subprocess.run(["sips", "-z", str(size), str(size), str(LOGO), "--out", str(made)], check=True, capture_output=True)
            target = src / name
            # Only a different picture is written, so the build doesn't redo it every time.
            if target.read_bytes() != made.read_bytes():
                changed += 1
                if not dry:
                    target.write_bytes(made.read_bytes())
    print(f"logos: {changed} changed")


def main():
    src = pathlib.Path(sys.argv[1]).resolve()
    sys.path.insert(0, str(src / "tools/grit"))
    for grd, sources, translations in SETS:
        brand(src, grd, sources, translations, "--dry-run" in sys.argv)
    brand_logos(src, "--dry-run" in sys.argv)


if __name__ == "__main__":
    main()
