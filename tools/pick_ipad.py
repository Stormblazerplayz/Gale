"""Picks an iPad simulator for the UI tests and prints SIM_UDID=... and SIM_NAME=... lines.

Prefers the newest iOS, then the biggest iPad Pro, so the tests look like Storm's iPad.
Usage: python3 tools/pick_ipad.py sims.json   (from `xcrun simctl list devices available -j`)
"""
import json
import re
import sys


def version(runtime):
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    return (int(m.group(1)), int(m.group(2))) if m else (0, 0)


def score(name):
    if name.startswith("iPad Pro") and "13" in name:
        return 4
    if name.startswith("iPad Pro"):
        return 3
    if name.startswith("iPad Air"):
        return 2
    if name.startswith("iPad"):
        return 1
    return 0


def main():
    data = json.load(open(sys.argv[1]))["devices"]
    best = None
    for runtime, devices in data.items():
        if "iOS" not in runtime:
            continue
        for d in devices:
            s = score(d["name"])
            if s == 0 or not d.get("isAvailable", True):
                continue
            key = (version(runtime), s, d["name"])
            if best is None or key > best[0]:
                best = (key, d["udid"], d["name"], runtime)
    if best is None:
        sys.exit("No iPad simulator found.")
    print(f"SIM_UDID={best[1]}")
    print(f"SIM_NAME={best[2]} ({best[3].split('.')[-1]})")


if __name__ == "__main__":
    main()
