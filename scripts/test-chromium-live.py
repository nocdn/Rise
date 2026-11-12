"""Rise's features on Chromium pages in an actual Rise window.

    python3 scripts/test-chromium-live.py [peek|features|extensions|passkeys|scripts|app|float|capture|tools|youtube|media|devtools|certificates|path/to/Check.swift]

peek: Peek's motion, frame by frame (Tests/Live/ChromiumPeekBenchmarks.swift).
features: history after a relaunch, downloads, find, permissions, picture in picture and the
tab's media and sound (Tests/Live/ChromiumFeatureChecks.swift), with pages served from two local
sites so one can hold a frame of the other.
devtools: DevTools' menus, close button, device mode, downloads, saving and choosing files
(Tests/Live/ChromiumDevToolsChecks.swift).
certificates: a site asking for a client certificate gets macOS's chooser, on a local site and on
client.badssl.com (Tests/Live/ChromiumClientCertificateChecks.swift). It puts a test identity, and
badssl.com's public client certificate, in a keychain of its own for the run (not the login keychain),
granted to Rise's signing team so nothing asks for a password, and deletes that keychain after.
scripts: Rise's page scripts and messages, in frames of both sites (Tests/Live/ChromiumScriptChecks.swift).
passkeys: Real provisioned-platform availability, relying-party isolation and cancellation, without
creating a passkey or completing biometric authentication (Tests/Live/ChromiumPasskeyChecks.swift).
app: Rise's menus, Dock, links from other apps and quitting (Tests/Live/ChromiumAppChecks.swift).
tools: Page Assistant, hover cards, Copy Text from Page Image, Share Page, the tab switcher and Smart
Rename (Tests/Live/ChromiumToolChecks.swift).
youtube: Rise's floating YouTube player (Tests/Live/ChromiumYouTubeChecks.swift), on a YouTube page
served locally. media: any site's floating video, the tab's media and sound buttons, page full
screen, Gmail's and Proton Mail's inbox readers, pausing downloads, what Page Assistant reads, site search learning,
the swipe's page probe and hard reloads (Tests/Live/ChromiumMediaChecks.swift). Both are tests written for XCTest
(Tests/Live/LiveXCTest.swift), with pages at the addresses they name (scripts/live-fixture-server.py).

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
import time

checks = {"peek": "ChromiumPeekBenchmarks.swift", "features": "ChromiumFeatureChecks.swift", "extensions": "ChromiumExtensionChecks.swift", "passkeys": "ChromiumPasskeyChecks.swift",
          "float": "ChromiumFloatingVideoChecks.swift", "capture": "ChromiumCaptureChecks.swift", "tools": "ChromiumToolChecks.swift",
          "youtube": "ChromiumYouTubeChecks.swift", "media": "ChromiumMediaChecks.swift",
          "scripts": "ChromiumScriptChecks.swift", "app": "ChromiumAppChecks.swift", "devtools": "ChromiumDevToolsChecks.swift",
          "certificates": "ChromiumClientCertificateChecks.swift"}
check = sys.argv[1] if len(sys.argv) > 1 else "peek"
# Checks written as XCTest cases, with pages at the HTTPS addresses they name.
fixtures = check in ("youtube", "media")
fixture_hosts = ["www.youtube.com", "youtube.com", "videos.example", "other.example", "media.example",
                 "fullscreen.example", "example.com", "vimeo.com", "mail.google.com", "mail.proton.me", "calendar.google.com", "github.com", "lamps.example"]
if check not in checks and not check.endswith(".swift"):
    raise SystemExit(f"Unknown check {check}; choose from {', '.join(checks)}.")

root = Path(__file__).resolve().parents[1]
app = root / "build/Rise.app"
if not (app / "Contents/Frameworks/Chromium Framework.framework").exists():
    raise SystemExit(f"{app.name} has no Chromium; build the engine and run ./scripts/build.sh first.")
sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-version"], text=True).strip()
linker = ["-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "14.0", "-Xlinker", sdk]
# The probe links individual objects from SwiftPM's native layout. Keep that build separate
# from Xcode 27's default Swift Build layout used by the app and unit tests.
build_path = ".build/chromium-live"
subprocess.run(["swift", "build", "--build-system", "native", "--build-tests", "--jobs", os.environ.get("RISE_BUILD_JOBS", "4"), "--build-path", build_path, *linker], cwd=root, check=True)
debug = root / build_path / "debug"
sources = {path.name for path in (root / "Sources/Rise").glob("*.swift")} - {"RiseApp.swift"}
objects = [str(path) for path in (debug / "Rise.build").glob("*.swift.o")
           if path.name[:-2] in sources or path.name == "resource_bundle_accessor.swift.o"]
objects += [str(path) for path in (debug / "RiseCore.build").glob("*.o")]
# Only objects whose sources are still there: a build keeps those of files since removed.
engine_sources = {path.name for path in (root / "Sources/RiseChromium").glob("*.m")}
objects += [str(path) for path in (debug / "RiseChromium.build").glob("*.o") if path.name[:-2] in engine_sources]
# The engine itself: the fork's framework, as the app has it.
engine_linking = ["-F", str(app / "Contents/Frameworks"), "-framework", "Chromium Framework",
                   "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]

keep = os.environ.get("RISE_PEEK_OUT")
folder = Path(keep) if keep else Path(tempfile.mkdtemp(prefix="rise-chromium-peek-"))
folder.mkdir(parents=True, exist_ok=True)
probe = folder / "RiseProbe.app"
shutil.rmtree(probe, ignore_errors=True)
started = time.time()
bundle_id = subprocess.run(["defaults", "read", str(app / "Contents/Info"), "CFBundleIdentifier"],
                           capture_output=True, text=True).stdout.strip() or "dev.bartosz.Rise"
subprocess.run(["ditto", str(app), str(probe)], check=True)
# The probe takes Rise's name, so Chromium finds the helpers as "Rise Helper".
executable = probe / "Contents/MacOS/Rise"
subprocess.run(["swiftc", "-target", f"{platform.machine()}-apple-macos14.0", "-parse-as-library", "-module-name", "ChromiumPeekCheck",
                str(Path(check) if check.endswith(".swift") else root / "Tests/Live" / checks[check]),
                *([str(root / "Tests/Live/LiveXCTest.swift")] if fixtures else []), "-I", str(debug / "Modules"),
                "-Xcc", f"-fmodule-map-file={debug / 'RiseChromium.build/module.modulemap'}",
                "-I", str(root / "Sources/RiseChromium/include"), *objects, *engine_linking,
                *linker, "-o", str(executable)], cwd=root, check=True)
if check in ("passkeys", "certificates") or os.environ.get("RISE_LIVE_STABLE_SIGNING") == "1":
    # An ad-hoc probe cannot exercise macOS's real keychain entitlement checks. Use Rise's
    # normal certificate and provisioning profile, including RISE_SIGNING_* overrides.
    # For certificates, its team is what the test keychain grants its keys to: an ad-hoc
    # signature changes with every build, so macOS would ask for the password on each run.
    subprocess.run([sys.executable, str(root / "scripts/sign-app.py"), str(probe)], check=True)
else:
    subprocess.run(["codesign", "--force", "--sign", "-", str(executable)], check=True, capture_output=True)
    subprocess.run(["codesign", "--force", "--sign", "-", str(probe)], check=True, capture_output=True)
environment = dict(os.environ, RISE_PEEK_OUT=str(folder), PACKAGE_RESOURCE_BUNDLE_PATH=str(debug))
arguments, servers = [], []
if check in ("features", "float") or check.endswith(".swift"):
    # A short clip with sound.
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=640x360:rate=30", "-f", "lavfi",
                    "-i", "sine=frequency=440", "-t", "30", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac",
                    "-shortest", str(folder / "clip.mp4")], check=True)
if check in ("features", "scripts", "float", "capture", "tools", "passkeys", "devtools") or check.endswith(".swift"):
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
if check == "features" or check.endswith(".swift"):
    # Media plays without a click, and the camera is Chromium's made-up one, so no real camera is asked for.
    # rise-check.test is an ordinary site to the filter lists, which leave local addresses alone.
    arguments = ["--autoplay-policy=no-user-gesture-required", "--use-fake-device-for-media-stream",
                 "--host-resolver-rules=MAP rise-check.test 127.0.0.1, MAP other-check.test 127.0.0.1, MAP pagead2.googlesyndication.com 127.0.0.1"]
if fixtures:
    # One HTTPS server for every fixture address, with a certificate made for the run.
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2", "-subj", "/CN=rise-check",
                    "-keyout", str(folder / "fixture-key.pem"), "-out", str(folder / "fixture-cert.pem")], check=True, capture_output=True)
    with socket.socket() as probe_socket:
        probe_socket.bind(("127.0.0.1", 0)); secure_port = probe_socket.getsockname()[1]
    servers.append(subprocess.Popen([sys.executable, "-u", str(root / "scripts/live-fixture-server.py"), str(folder), str(secure_port),
                                     str(folder / "fixture-cert.pem"), str(folder / "fixture-key.pem")],
                                    stdout=subprocess.DEVNULL, stderr=open(folder / "fixture-server.log", "w")))
    arguments = ["--autoplay-policy=no-user-gesture-required", "--ignore-certificate-errors",
                 "--host-resolver-rules=" + ", ".join(f"MAP {host} 127.0.0.1:{secure_port}" for host in fixture_hosts)]
if check == "tools":
    # A company's own GitLab server, on the local site.
    arguments = ["--host-resolver-rules=MAP gitlab.rise-check.test 127.0.0.1"]
if check == "extensions":
    # A test extension, unpacked: a background worker, a content script on every page and a popup.
    extension = folder / "extension"
    extension.mkdir(exist_ok=True)
    (extension / "manifest.json").write_text("""{
      "manifest_version": 3, "name": "Rise Test Extension", "version": "1.0",
      "permissions": ["tabs", "storage", "activeTab", "contextMenus", "nativeMessaging"], "host_permissions": ["<all_urls>"],
      "background": {"service_worker": "background.js"},
      "content_scripts": [{"matches": ["<all_urls>"], "js": ["content.js"], "run_at": "document_idle"}],
      "action": {"default_popup": "popup.html", "default_title": "Rise Test", "default_icon": "icon.png"},
      "commands": {"rise-test-command": {"suggested_key": {"default": "Ctrl+Shift+Y"}, "description": "Rise test"},
                   "_execute_action": {"suggested_key": {"default": "Ctrl+Shift+U"}}}
    }""")
    (extension / "background.js").write_text("""
    let activated = [], clicked = null, commanded = null;
    chrome.commands.onCommand.addListener((name, tab) => commanded = [name, tab?.id ?? null]);
    chrome.tabs.onActivated.addListener(info => activated.push(info.tabId));
    chrome.contextMenus.removeAll(() => chrome.contextMenus.create({id: 'rise-test', title: 'Rise Test “%s”', contexts: ['selection']}));
    chrome.contextMenus.onClicked.addListener((info, tab) => clicked = [info.menuItemId, info.selectionText, tab?.id ?? null]);
    chrome.runtime.onMessage.addListener((message, sender, reply) => {
      (async () => {
        if (message.cmd === 'create') return {id: (await chrome.tabs.create({url: message.url, active: true})).id};
        if (message.cmd === 'activate') return {id: (await chrome.tabs.update(message.id, {active: true})).id};
        if (message.cmd === 'remove') { await chrome.tabs.remove(message.id); return {removed: true}; }
        if (message.cmd === 'activated') return {activated};
        if (message.cmd === 'clicked') return {clicked};
        if (message.cmd === 'commanded') return {commanded};
        if (message.cmd === 'native') return chrome.runtime.sendNativeMessage('dev.bartosz.rise.test.echo', message.payload);
        if (message.cmd === 'popup') { await chrome.action.openPopup(); return {opened: true}; }
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
identities = []
if check == "certificates":
    # A local site that asks for a certificate from a test CA, and that CA's identity in the keychain.
    fixture = root / "scripts/client-certificate-fixture.py"
    signature = subprocess.run(["codesign", "-dv", str(probe)], capture_output=True, text=True).stderr
    team = next((line.split("=", 1)[1] for line in signature.splitlines() if line.startswith("TeamIdentifier=")), "")
    if not team or team == "not set":
        sys.exit("The certificates check needs a signing identity with a team (scripts/sign-app.py), so the keychain can grant its key without asking.")
    subprocess.run([sys.executable, str(fixture), "setup", str(folder / "certs"), team], check=True)
    identities.append(lambda: subprocess.run([sys.executable, str(fixture), "teardown", str(folder / "certs")]))
    with socket.socket() as probe_socket:
        probe_socket.bind(("127.0.0.1", 0)); port = probe_socket.getsockname()[1]
    servers = [subprocess.Popen([sys.executable, "-u", str(fixture), "serve", str(folder / "certs"), str(port)],
                                stdout=subprocess.DEVNULL, stderr=open(folder / "certificate-server.log", "w"))]
    environment["RISE_CHECK_PORTS"] = str(port)
    # client.badssl.com, a real site asking for badssl.com's public client certificate, when online.
    badssl = folder / "badssl" / "badssl.com-client.p12"
    badssl.parent.mkdir(exist_ok=True)
    if subprocess.run(["curl", "-sSfL", "-o", str(badssl), "https://badssl.com/certs/badssl.com-client.p12"], capture_output=True).returncode == 0 \
            and subprocess.run([sys.executable, str(fixture), "import", str(badssl), "badssl.com", team], capture_output=True).returncode == 0:
        environment["RISE_BADSSL"] = "1"
    # The local site's certificate is the test CA's; the site at rise-cert.test is the same one.
    arguments = ["--ignore-certificate-errors", "--host-resolver-rules=MAP rise-cert.test 127.0.0.1"]
# The probe shares Rise's bundle identifier, so its window would replace the frame Rise remembers.
frame_key = "NSWindow Frame RiseBrowser"
saved_frame = subprocess.run(["defaults", "read", bundle_id, frame_key], capture_output=True, text=True).stdout.strip()
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
    for remove in identities:
        remove()
    if saved_frame:
        subprocess.run(["defaults", "write", bundle_id, frame_key, saved_frame])
if not keep:
    shutil.rmtree(folder, ignore_errors=True)
# macOS keeps a copy of each app it launches, to check its signature against, which takes the
# probe's full size once its folder is gone; copies from this run go too, unless another run's
# probe is still going.
clones = Path(tempfile.gettempdir()).parent / "X" / f"{bundle_id}.code_sign_clone"
if clones.is_dir() and subprocess.run(["pgrep", "-f", "RiseProbe.app/Contents/MacOS"], capture_output=True).returncode != 0:
    for clone in clones.glob("code_sign_clone.*"):
        if clone.stat().st_mtime >= started - 5 and (clone / "RiseProbe.app.bundle").exists():
            shutil.rmtree(clone, ignore_errors=True)
sys.exit(result.returncode)
