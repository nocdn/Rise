"""Rise's features on Chromium pages in an actual Rise window.

    python3 scripts/test-chromium-live.py [peek|features|extensions|scripts|app]

peek: Peek's motion, frame by frame (Tests/Live/ChromiumPeekBenchmarks.swift).
features: history after a relaunch, downloads, find, permissions, picture in picture and the
tab's media and sound (Tests/Live/ChromiumFeatureChecks.swift), with pages served from two local
sites so one can hold a frame of the other.
scripts: Rise's page scripts and messages, in frames of both sites (Tests/Live/ChromiumScriptChecks.swift).
app: Rise's menus, Dock, links from other apps and quitting (Tests/Live/ChromiumAppChecks.swift).

Chromium only runs from an app bundle with its helpers, so the check runs as the main program of
a copy of build/Rise.app (made by ./scripts/build.sh with the engine built). Frames are kept in
RISE_PEEK_OUT, or a temporary folder that's removed afterwards."""
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import socket
import tempfile

checks = {"peek": "ChromiumPeekBenchmarks.swift", "features": "ChromiumFeatureChecks.swift", "extensions": "ChromiumExtensionChecks.swift",
          "scripts": "ChromiumScriptChecks.swift", "app": "ChromiumAppChecks.swift"}
check = sys.argv[1] if len(sys.argv) > 1 else "peek"
if check not in checks:
    raise SystemExit(f"Unknown check {check}; choose from {', '.join(checks)}.")

root = Path(__file__).resolve().parents[1]
engine = Path(os.environ.get("RISE_CHROMIUM_ROOT", root.parent / "rise-chromium"))
# RISE_ENGINE_FORK=1 checks Rise on its own Chromium fork (Engine/fork-plan.md), from
# build/RiseFork.app (made by RISE_ENGINE_FORK=1 ./scripts/build.sh).
fork = os.environ.get("RISE_ENGINE_FORK") == "1"
app = root / ("build/RiseFork.app" if fork else "build/Rise.app")
framework = "Chromium Framework.framework" if fork else "Chromium Embedded Framework.framework"
if not (app / "Contents/Frameworks" / framework).exists():
    raise SystemExit(f"{app.name} has no Chromium; build the engine and run ./scripts/build.sh first.")
sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-version"], text=True).strip()
linker = ["-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "14.0", "-Xlinker", sdk]
build_path = ".build-fork" if fork else ".build"
subprocess.run(["swift", "build", "--build-tests", "--build-path", build_path, *linker], cwd=root, check=True)
debug = root / build_path / "debug"
sources = {path.name for path in (root / "Sources/Rise").glob("*.swift")} - {"RiseApp.swift"}
objects = [str(path) for path in (debug / "Rise.build").glob("*.swift.o")
           if path.name[:-2] in sources or path.name == "resource_bundle_accessor.swift.o"]
objects += [str(path) for path in (debug / "RiseCore.build").glob("*.o")]
objects += [str(path) for path in (debug / "RiseChromium.build").glob("*.o")]
# The engine itself: CEF's wrapper and Rise's bridge to it, or the fork's framework.
engine_linking = (["-F", str(app / "Contents/Frameworks"), "-framework", "Chromium Framework",
                   "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"] if fork else
                  [str(engine / "bridge-build/wrapper/libcef_dll_wrapper/libcef_dll_wrapper.a"), "-lc++",
                   *([str(engine / "adblock-build/release/librise_adblock.a")] if (engine / "adblock-build/release/librise_adblock.a").exists() else [])])

keep = os.environ.get("RISE_PEEK_OUT")
folder = Path(keep) if keep else Path(tempfile.mkdtemp(prefix="rise-chromium-peek-"))
folder.mkdir(parents=True, exist_ok=True)
probe = folder / "RiseProbe.app"
shutil.rmtree(probe, ignore_errors=True)
subprocess.run(["ditto", str(app), str(probe)], check=True)
# The probe takes Rise's name, so Chromium finds the helpers as "Rise Helper".
executable = probe / "Contents/MacOS/Rise"
subprocess.run(["swiftc", "-target", f"{platform.machine()}-apple-macos14.0", "-parse-as-library", "-module-name", "ChromiumPeekCheck",
                str(root / "Tests/Live" / checks[check]), "-I", str(debug / "Modules"),
                "-Xcc", f"-fmodule-map-file={debug / 'RiseChromium.build/module.modulemap'}",
                "-I", str(root / "Sources/RiseChromium/include"), *objects, *engine_linking,
                *linker, "-o", str(executable)], cwd=root, check=True)
subprocess.run(["codesign", "--force", "--sign", "-", str(executable)], check=True, capture_output=True)
subprocess.run(["codesign", "--force", "--sign", "-", str(probe)], check=True, capture_output=True)
environment = dict(os.environ, RISE_PEEK_OUT=str(folder), PACKAGE_RESOURCE_BUNDLE_PATH=str(debug))
arguments, servers = [], []
if check == "features":
    # A short clip with sound.
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=640x360:rate=30", "-f", "lavfi",
                    "-i", "sine=frequency=440", "-t", "30", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac",
                    "-shortest", str(folder / "clip.mp4")], check=True)
if check in ("features", "scripts"):
    # Two sites: localhost and 127.0.0.1 are different sites.
    ports = []
    for _ in range(2):
        with socket.socket() as probe_socket:
            probe_socket.bind(("127.0.0.1", 0)); ports.append(probe_socket.getsockname()[1])
    # Each server's requests go in a log the checks read, to see what was fetched.
    servers = [subprocess.Popen([sys.executable, "-u", "-m", "http.server", str(port), "--bind", "127.0.0.1", "--directory", str(folder)],
                                stdout=subprocess.DEVNULL, stderr=open(folder / f"server-{index}.log", "w"))
               for index, port in enumerate(ports)]
    environment["RISE_CHECK_PORTS"] = ",".join(map(str, ports))
if check == "features":
    # Media plays without a click, and the camera is Chromium's made-up one, so no real camera is asked for.
    # rise-check.test is an ordinary site to the filter lists, which leave local addresses alone.
    arguments = ["--autoplay-policy=no-user-gesture-required", "--use-fake-device-for-media-stream",
                 "--host-resolver-rules=MAP rise-check.test 127.0.0.1"]
if check == "extensions":
    # A test extension, unpacked: a background worker, a content script on every page and a popup.
    extension = folder / "extension"
    extension.mkdir(exist_ok=True)
    (extension / "manifest.json").write_text("""{
      "manifest_version": 3, "name": "Rise Test Extension", "version": "1.0",
      "permissions": ["tabs", "storage", "activeTab"], "host_permissions": ["<all_urls>"],
      "background": {"service_worker": "background.js"},
      "content_scripts": [{"matches": ["<all_urls>"], "js": ["content.js"], "run_at": "document_idle"}],
      "action": {"default_popup": "popup.html", "default_title": "Rise Test", "default_icon": "icon.png"}
    }""")
    (extension / "background.js").write_text("""
    let activated = [];
    chrome.tabs.onActivated.addListener(info => activated.push(info.tabId));
    chrome.runtime.onMessage.addListener((message, sender, reply) => {
      (async () => {
        if (message.cmd === 'create') return {id: (await chrome.tabs.create({url: message.url, active: true})).id};
        if (message.cmd === 'activate') return {id: (await chrome.tabs.update(message.id, {active: true})).id};
        if (message.cmd === 'remove') { await chrome.tabs.remove(message.id); return {removed: true}; }
        if (message.cmd === 'activated') return {activated};
        const all = await chrome.tabs.query({});
        const active = await chrome.tabs.query({active: true, currentWindow: true});
        const windows = await chrome.windows.getAll({populate: true});
        return {tab: sender.tab?.id ?? null, window: sender.tab?.windowId ?? null, index: sender.tab?.index ?? null,
                all: all.map(t => [t.id, t.url, t.index, t.active]), active: active.map(t => t.id),
                windows: windows.map(w => [w.id, w.focused, w.tabs.length])};
      })().then(reply, error => reply({error: String(error)}));
      return true;
    });
    """)
    (extension / "content.js").write_text("""
    document.documentElement.dataset.riseExtensionId = chrome.runtime.id;
    const ask = (message, key) => chrome.runtime.sendMessage(message)
      .then(answer => document.documentElement.dataset[key] = JSON.stringify(answer))
      .catch(error => document.documentElement.dataset[key] = JSON.stringify({error: String(error)}));
    ask({}, 'riseExtension');
    addEventListener('message', event => { if (event.data?.riseTest) ask(event.data.riseTest, 'riseAnswer'); });
    """)
    # A 32 by 32 orange square for its button.
    import struct, zlib
    def chunk(kind, data): return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    pixels = b"".join(b"\0" + b"\xff\x80\x00\xff" * 32 for _ in range(32))
    (extension / "icon.png").write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 32, 32, 8, 6, 0, 0, 0))
                                         + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b""))
    (extension / "popup.html").write_text("<!doctype html><body style='margin:0;width:240px;height:120px'>Popup<script src=popup.js></script>")
    (extension / "popup.js").write_text("""
    chrome.tabs.query({active: true, currentWindow: true}).then(tabs => document.body.dataset.report = JSON.stringify(tabs.map(t => [t.id, t.url])))
      .catch(error => document.body.dataset.report = 'error ' + error);
    chrome.tabs.getCurrent().then(tab => document.body.dataset.kind =
      tab ? 'tab' : chrome.extension.getViews({type: 'popup'}).includes(window) ? 'popup' : 'neither');
    """)
    ports = []
    with socket.socket() as probe_socket:
        probe_socket.bind(("127.0.0.1", 0)); ports.append(probe_socket.getsockname()[1])
    servers = [subprocess.Popen([sys.executable, "-u", "-m", "http.server", str(ports[0]), "--bind", "127.0.0.1", "--directory", str(folder)],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)]
    environment["RISE_CHECK_PORTS"] = str(ports[0])
    arguments = [f"--load-extension={extension}"]
try:
    # RISE_LLDB=1 runs the check under lldb, which prints where it crashed.
    # RISE_LLDB_BREAK=<function> also prints where that function is called from, each time.
    breaks = [arg for name in filter(None, os.environ.get("RISE_LLDB_BREAK", "").split(","))
              for arg in ("-o", f"breakpoint set -n '{name}'", "-o", "breakpoint command add -o 'bt 25' -o continue 1")]
    debugger = ["lldb", "--batch", *breaks, "-o", "run", "-k", "bt 40", "-k", "quit 1", "--"] if os.environ.get("RISE_LLDB") else []
    result = subprocess.run([*debugger, str(executable), *arguments], env=environment)
finally:
    for server in servers:
        server.terminate()
if not keep:
    shutil.rmtree(folder, ignore_errors=True)
sys.exit(result.returncode)
