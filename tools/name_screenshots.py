"""Renames screenshots pulled out of an .xcresult to the names the tests gave them (like "02 After drawing a line.png")."""
import json
import os
import re
import sys

folder = sys.argv[1]
manifest_path = os.path.join(folder, "manifest.json")
if not os.path.exists(manifest_path):
    sys.exit(0)
manifest = json.load(open(manifest_path))
for test in manifest if isinstance(manifest, list) else [manifest]:
    for a in test.get("attachments", []):
        src = os.path.join(folder, a.get("exportedFileName", ""))
        name = a.get("suggestedHumanReadableName") or a.get("exportedFileName")
        if not os.path.isfile(src) or not name:
            continue
        # The tool adds a suffix like "_0_<uuid>"; keep the readable part.
        name = re.sub(r"_\d+_[0-9A-Fa-f-]{36}", "", name)
        base, ext = os.path.splitext(src)
        if not os.path.splitext(name)[1]:
            name += ext
        dst = os.path.join(folder, name.replace("/", "-"))
        if dst != src and not os.path.exists(dst):
            os.rename(src, dst)
