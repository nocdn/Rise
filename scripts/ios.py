#!/usr/bin/env python3
"""Build, test, or install Rise on a paired iPhone or Simulator using Apple's developer tools."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "Apps/iOS/Rise.xcodeproj"
DERIVED_DATA = ROOT / "build/ios"


def run(*command):
    subprocess.run(command, cwd=ROOT, check=True)


def resolve_device(selector):
    with tempfile.TemporaryDirectory(prefix="rise-ios-device-") as folder:
        path = Path(folder) / "device.json"
        subprocess.run(["xcrun", "devicectl", "device", "info", "details", "--device", selector,
                        "--json-output", str(path)], cwd=ROOT, stdout=subprocess.DEVNULL, check=True)
        return json.loads(path.read_text())["result"]["hardwareProperties"]["udid"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["build", "test", "run"])
    target = parser.add_mutually_exclusive_group()
    target.add_argument("--device", help="Paired iPhone name, UDID, or CoreDevice identifier")
    target.add_argument("--simulator", help="Simulator UDID (boots it if needed)")
    parser.add_argument("--team", help="Override the project's Apple development team")
    parser.add_argument("--configuration", choices=["Debug", "Release"], default="Debug")
    parser.add_argument("--console", action="store_true", help="Stream app logs after installation")
    args = parser.parse_args()
    if args.action in ["run", "test"] and not (args.device or args.simulator):
        parser.error("--device or --simulator is required for installation and tests")

    destination = "generic/platform=iOS"
    if args.device:
        destination = "id=" + resolve_device(args.device)
    elif args.simulator:
        run("xcrun", "simctl", "bootstatus", args.simulator, "-b")
        destination = "platform=iOS Simulator,id=" + args.simulator
    derived_data = ROOT / "build/ios-simulator" if args.simulator else DERIVED_DATA
    command = ["xcodebuild", "-project", str(PROJECT), "-scheme", "RiseiOS",
               "-configuration", args.configuration, "-destination", destination,
               "-derivedDataPath", str(derived_data), "-allowProvisioningUpdates",
               "-allowProvisioningDeviceRegistration"]
    if args.team:
        command.append("DEVELOPMENT_TEAM=" + args.team)
    run(*command, "test" if args.action == "test" else "build")

    if args.action == "run":
        platform = "iphonesimulator" if args.simulator else "iphoneos"
        app = derived_data / "Build/Products" / (args.configuration + "-" + platform) / "RiseiOS.app"
        if args.simulator:
            run("xcrun", "simctl", "install", args.simulator, str(app))
            launch = ["xcrun", "simctl", "launch", "--terminate-running-process"]
            if args.console:
                launch.append("--console-pty")
            run(*launch, args.simulator, "dev.bartosz.Rise.iOS")
            return
        run("xcrun", "devicectl", "device", "install", "app", "--device", args.device, str(app))
        launch = ["xcrun", "devicectl", "device", "process", "launch", "--device", args.device,
                  "--terminate-existing"]
        if args.console:
            launch.append("--console")
        run(*launch, "dev.bartosz.Rise.iOS")


if __name__ == "__main__":
    main()
