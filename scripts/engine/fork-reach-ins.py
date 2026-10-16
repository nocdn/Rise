#!/usr/bin/env python3
"""Lists where Chrome's code looks for its own window (BrowserView), which Rise's fork doesn't
have: for Rise's window, the lookup finds nothing. Each place either checks for that, or uses the
window regardless, which would crash in Rise. Places are told apart by file and function, so they
survive lines moving.

Engine/fork/reach-ins.tsv holds the places reviewed, with a verdict for each (see its header). A
place not in it, such as one a Chromium update adds, is listed as new, and the script fails, so
it's looked at before the update ships.

Usage: fork-reach-ins.py <chromium/src> [--all] [--write]
  --all    lists every place, not only new ones
  --write  adds new places to the list, as "review", for filling in
"""
import pathlib
import re
import sys

LOOKUPS = re.compile(r"BrowserView::GetBrowserViewFor(?:Browser|NativeWindow)\s*\(")
# Code that doesn't run in Rise: tests, other platforms, and Chrome's own window UI, which only
# exists alongside a BrowserView.
SKIP = re.compile(r"(_unittest|_browsertest|browser_test_|_interactive_uitest|_uitest|_apitest|_pixeltest|test_util|"
                  r"_test_base|_test\.|/test/|/ash/|chromeos|_chromeos|/android/|_android|_win\.|/win/|"
                  r"_linux|/linux/|_ozone|/ui/views/)")
FUNCTION = re.compile(r"^[A-Za-z_][\w:<>,\s\*&~]*?\b([\w:~]+::[\w~]+|[\w~]+)\s*\(")
LIST = pathlib.Path(__file__).resolve().parents[2] / "Engine/fork/reach-ins.tsv"


def places(src: pathlib.Path):
    """(file, function, how) for each lookup: how is "checked" or "unchecked"."""
    for path in sorted((src / "chrome/browser").rglob("*")):
        if path.suffix not in (".cc", ".mm") or SKIP.search(str(path.relative_to(src))):
            continue
        lines = path.read_text(errors="replace").splitlines()
        function = "(file)"
        for number, line in enumerate(lines):
            if line and not line[0].isspace() and not line.startswith(("//", "#", "}", "namespace")):
                found = FUNCTION.match(line)
                if found:
                    function = found.group(1)
            if not LOOKUPS.search(line):
                continue
            yield str(path.relative_to(src)), function, how(lines, number)


def how(lines, number):
    """Whether the window the lookup finds is checked for before it's used."""
    line = lines[number]
    after = line[LOOKUPS.search(line).end():]
    # Used on the spot: GetBrowserViewForBrowser(browser)->Something().
    depth, rest = 1, ""
    for i, char in enumerate(after):
        depth += {"(": 1, ")": -1}.get(char, 0)
        if depth == 0:
            rest = after[i + 1:]
            break
    if rest.lstrip().startswith("->") or rest.lstrip().startswith("."):
        return "unchecked"
    if re.search(r"\b(if|while)\s*\(|\?|&&|\|\||return\s+\w+\s*&&|!=\s*nullptr|==\s*nullptr", line):
        return "checked"
    assigned = re.search(r"(\w+)\s*=\s*(?:\w+::)*\s*BrowserView::", line) or \
        re.search(r"(\w+)\s*=\s*$", lines[number - 1] if number else "")
    if not assigned:
        return "unchecked" if re.search(r"CHECK|CHECK_DEREF", line) else "checked"
    name = assigned.group(1)
    for later in lines[number + 1:number + 12]:
        if re.search(rf"\b(if|while)\s*\(\s*!?\s*{name}\b|\b{name}\s*(==|!=)|\b{name}\s*\?|&&\s*{name}\b|\b{name}\s*&&", later):
            return "checked"
        if re.search(rf"\b{name}\s*->|CHECK\(\s*{name}\b|CHECK_DEREF\(\s*{name}", later):
            return "unchecked"
    return "checked"


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    src = pathlib.Path(sys.argv[1]).expanduser()
    reviewed = {}
    header = []
    if LIST.exists():
        for row in LIST.read_text().splitlines():
            if row.startswith("#") or not row.strip():
                header.append(row)
                continue
            file, function, *rest = row.split("\t")
            reviewed[(file, function)] = rest
    found = {}
    for file, function, kind in places(src):
        found.setdefault((file, function), set()).add(kind)
    new = [key for key in found if key not in reviewed]
    gone = [key for key in reviewed if key not in found]
    shown = found if "--all" in sys.argv else new
    for key in sorted(shown):
        kinds = "unchecked" if "unchecked" in found[key] else "checked"
        verdict = reviewed.get(key, ["", "review"])[1] if key in reviewed else "NEW"
        print(f"{kinds:9}  {verdict:8}  {key[0]}  {key[1]}")
    counts = {k: sum(1 for v in found.values() if ("unchecked" in v) == (k == "unchecked")) for k in ("checked", "unchecked")}
    print(f"{len(found)} places ({counts['unchecked']} unchecked), {len(new)} new, {len(gone)} gone from the list")
    for key in sorted(gone):
        print(f"gone      {key[0]}  {key[1]}")
    if "--write" in sys.argv and new:
        rows = [row for row in LIST.read_text().splitlines()] if LIST.exists() else header
        for key in sorted(new):
            kinds = "unchecked" if "unchecked" in found[key] else "checked"
            rows.append("\t".join([key[0], key[1], kinds, "review", ""]))
        LIST.write_text("\n".join(rows) + "\n")
    sys.exit(1 if new else 0)


if __name__ == "__main__":
    main()
