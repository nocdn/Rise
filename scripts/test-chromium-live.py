"""Rise's features on Chromium pages in an actual Rise window.

    python3 scripts/test-chromium-live.py [peek|features]

peek: Peek's motion, frame by frame (Tests/Live/ChromiumPeekBenchmarks.swift).
features: history after a relaunch, downloads, find, permissions, picture in picture and the
tab's media and sound (Tests/Live/ChromiumFeatureChecks.swift), with pages served from two local
sites so one can hold a frame of the other.

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

checks = {"peek": "ChromiumPeekBenchmarks.swift", "features": "ChromiumFeatureChecks.swift"}
check = sys.argv[1] if len(sys.argv) > 1 else "peek"
if check not in checks:
    raise SystemExit(f"Unknown check {check}; choose from {', '.join(checks)}.")

root = Path(__file__).resolve().parents[1]
engine = Path(os.environ.get("RISE_CHROMIUM_ROOT", root.parent / "rise-chromium"))
app = root / "build/Rise.app"
if not (app / "Contents/Frameworks/Chromium Embedded Framework.framework").exists():
    raise SystemExit("build/Rise.app has no Chromium; build the engine and run ./scripts/build.sh first.")
sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-version"], text=True).strip()
linker = ["-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "14.0", "-Xlinker", sdk]
subprocess.run(["swift", "build", "--build-tests", *linker], cwd=root, check=True)
debug = root / ".build/debug"
sources = {path.name for path in (root / "Sources/Rise").glob("*.swift")} - {"RiseApp.swift"}
objects = [str(path) for path in (debug / "Rise.build").glob("*.swift.o")
           if path.name[:-2] in sources or path.name == "resource_bundle_accessor.swift.o"]
objects += [str(path) for path in (debug / "RiseCore.build").glob("*.o")]
objects += [str(debug / "RiseChromium.build/RiseChromium.mm.o")]

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
                "-I", str(root / "Sources/RiseChromium/include"), *objects,
                str(engine / "bridge-build/wrapper/libcef_dll_wrapper/libcef_dll_wrapper.a"), "-lc++",
                *linker, "-o", str(executable)], cwd=root, check=True)
subprocess.run(["codesign", "--force", "--sign", "-", str(executable)], check=True, capture_output=True)
subprocess.run(["codesign", "--force", "--sign", "-", str(probe)], check=True, capture_output=True)
environment = dict(os.environ, RISE_PEEK_OUT=str(folder), PACKAGE_RESOURCE_BUNDLE_PATH=str(debug))
arguments, servers = [], []
if check == "features":
    # A short clip with sound, and two sites: localhost and 127.0.0.1 are different sites.
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=640x360:rate=30", "-f", "lavfi",
                    "-i", "sine=frequency=440", "-t", "30", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac",
                    "-shortest", str(folder / "clip.mp4")], check=True)
    ports = []
    for _ in range(2):
        with socket.socket() as probe_socket:
            probe_socket.bind(("127.0.0.1", 0)); ports.append(probe_socket.getsockname()[1])
    servers = [subprocess.Popen([sys.executable, "-m", "http.server", str(port), "--bind", "127.0.0.1", "--directory", str(folder)],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) for port in ports]
    environment["RISE_CHECK_PORTS"] = ",".join(map(str, ports))
    # Media plays without a click, and the camera is Chromium's made-up one, so no real camera is asked for.
    arguments = ["--autoplay-policy=no-user-gesture-required", "--use-fake-device-for-media-stream"]
try:
    result = subprocess.run([str(executable), *arguments], env=environment)
finally:
    for server in servers:
        server.terminate()
if not keep:
    shutil.rmtree(folder, ignore_errors=True)
sys.exit(result.returncode)
