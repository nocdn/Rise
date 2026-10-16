#!/usr/bin/env python3
"""Fetch the iOS app's Summarise log from a paired iPhone or Simulator and report how the last
few Summarises ran: what happened when, each phase's frame rate, and every dropped frame."""
import argparse
import json
from pathlib import Path
import statistics
import subprocess
import tempfile

BUNDLE = "dev.bartosz.Rise.iOS"
LOG = "Library/Caches/Summarise/log.jsonl"
PHASES = ["pinch", "cancel", "flight", "loading", "reveal", "card", "close", "after"]


def fetch(args, folder):
    destination = Path(folder) / "log.jsonl"
    if args.simulator:
        container = subprocess.run(["xcrun", "simctl", "get_app_container", args.simulator, BUNDLE, "data"],
                                   check=True, capture_output=True, text=True).stdout.strip()
        source = Path(container) / LOG
        return source.read_text() if source.exists() else ""
    subprocess.run(["xcrun", "devicectl", "device", "copy", "from", "--device", args.device,
                    "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE,
                    "--source", LOG, "--destination", str(destination)],
                   check=True, stdout=subprocess.DEVNULL)
    return destination.read_text()


def report(number, record):
    print(f"#{number}  {record['started']}  {record['path']} on {record['page']}")
    print(f"    {record['device']}")
    events = record["events"]
    print("  What happened:")
    for event in events:
        print(f"    {event['t']:7.3f} s  {event['name']}" + (f": {event['detail']}" if event["detail"] else ""))

    frames = record["frames"]
    print("  Phases:            frames  dropped  worst gap  rate    worst work  worst late")
    for phase in PHASES:
        own = [frame for frame in frames if frame["phase"] == phase]
        if not own:
            continue
        dropped = [frame for frame in own if frame["gap"] > frame["interval"]*1.5]
        rate = 1000/statistics.median(frame["interval"] for frame in own)
        # Of the loading and resting card only the dropped frames are kept.
        count = "-" if phase in ["loading", "card"] else str(len(own))
        print(f"    {phase:<16} {count:>7}  {len(dropped):>7}  {max(f['gap'] for f in own):6.1f} ms  {rate:4.0f} Hz"
              f"  {max(f['work'] for f in own):6.1f} ms  {max(f['late'] for f in own):6.1f} ms")

    dropped = [frame for frame in frames if frame["gap"] > frame["interval"]*1.5]
    if dropped:
        print("  Dropped frames (gap: time since the frame before; work: this frame's own time on the main thread):")
    for frame in dropped:
        missed = round(frame["gap"]/frame["interval"])-1
        near = [e for e in events if abs(e["t"]-frame["t"]) < 0.05]
        hint = "; near " + ", ".join(f"{e['name']} ({e['t']:.3f} s)" for e in near) if near else ""
        print(f"    {frame['t']:7.3f} s  {frame['phase']:<8} {frame['gap']:5.1f} ms gap, {missed} missed at {frame['interval']:.1f} ms,"
              f" work {frame['work']:.1f} ms, late {frame['late']:.1f} ms{hint}")
    print()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--device", help="Paired iPhone name, UDID, or CoreDevice identifier")
    target.add_argument("--simulator", help="Simulator UDID")
    parser.add_argument("--last", type=int, default=1, help="How many of the latest Summarises to report (default 1)")
    parser.add_argument("--json", action="store_true", help="Print the raw records instead")
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="rise-summarise-log-") as folder:
        lines = [line for line in fetch(args, folder).splitlines() if line.strip()]
    if not lines:
        print("No Summarises logged yet.")
        return
    records = [json.loads(line) for line in lines]
    start = len(records)-min(args.last, len(records))
    for number, record in enumerate(records[start:], start=start+1):
        if args.json:
            print(json.dumps(record, indent=2))
        else:
            report(number, record)


if __name__ == "__main__":
    main()
