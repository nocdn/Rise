"""Live Peek and split/return motion in an actual Rise AppKit window and WebKit engine."""
import os
import platform
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
sdk = subprocess.check_output(
    ["xcrun", "--sdk", "macosx", "--show-sdk-version"], text=True
).strip()
linker = ["-Xlinker", "-platform_version", "-Xlinker", "macos",
          "-Xlinker", "14.0", "-Xlinker", sdk]
# Build the testable module and verify Peek state mechanics.
subprocess.run(["swift", "test", *linker, "--filter", "BrowserLifecycleTests|PeekInteractionTests|SplitTabsTests"],
               cwd=root, check=True)
products = root / ".build/debug"
folders = list((root / ".build/out/Intermediates.noindex/Rise.build/Debug").glob(
    "Rise-*-testable-t.build/Objects-normal/*"))
if len(folders) != 1:
    raise SystemExit("Expected one testable Rise object directory. Clean the debug build and retry.")
objects = [str(path) for path in folders[0].glob("*.o") if path.name != "RiseApp.o"]
with tempfile.TemporaryDirectory(prefix="rise-peek-check-") as folder:
    environment = dict(os.environ)
    environment["PACKAGE_RESOURCE_BUNDLE_PATH"] = str(products)
    environment["RISE_BENCHMARK_SESSION"] = str(Path(folder) / "session.json")
    for benchmark in ["PeekBenchmarks", "SplitBenchmarks"]:
        executable = Path(folder) / benchmark
        subprocess.run(["swiftc", "-target", f"{platform.machine()}-apple-macos14.0", "-parse-as-library",
                        str(root / f"Tests/Live/{benchmark}.swift"),
                        "-I", str(products), *objects, str(products / "RiseCore.o"),
                        *linker, "-o", str(executable)], cwd=root, check=True)
        subprocess.run([str(executable)], env=environment, check=True)
