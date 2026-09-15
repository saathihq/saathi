#!/usr/bin/env python3
"""Ports the pointer-mascot data into Sources/SaathiMascot/Resources/mascot.json.

    scripts/port-mascot.py ~/pointer-mascots/build_data.json

The source lives outside the repository (it was extracted from a web page's bundle by the scripts
in that folder); the output is checked in so the package builds without it. Re-run when the source
changes, and commit the result.

What changes in the port:
  - keys become camelCase and the effects/glyph markup are dropped (the app does not use them);
  - the two SVG transform strings become numbers. The web renderer draws the body through a
    <use> of a path that itself carries translate(210 80), then applies `fit`; both are folded
    into one scale-then-translate `bodyTransform`. The face group's
    translate(anchor) scale(anchor.scale) translate(-120 -122.5) becomes `faceTransform` the
    same way.
"""
import json
import os
import re
import sys

if len(sys.argv) != 2:
    sys.exit(__doc__)

source = json.load(open(sys.argv[1]))
package_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
out_path = os.path.join(package_dir, "Sources", "SaathiMascot", "Resources", "mascot.json")

x, y, width, height = (float(v) for v in source["viewBox"].split())
fit = re.fullmatch(r"translate\(([-\d.]+) ([-\d.]+)\) scale\(([-\d.]+)\)", source["fit"])
if not fit:
    sys.exit(f"unexpected fit transform: {source['fit']!r}")
fit_tx, fit_ty, fit_scale = (float(v) for v in fit.groups())
anchor = source["anchor"]

data = {
    "bodyPath": source["body_path"],
    "viewBox": {"x": x, "y": y, "width": width, "height": height},
    "bodyTransform": {
        "scale": fit_scale,
        "tx": 210 * fit_scale + fit_tx,
        "ty": 80 * fit_scale + fit_ty,
    },
    "faceTransform": {
        "scale": anchor["scale"],
        "tx": anchor["x"] - 120 * anchor["scale"],
        "ty": anchor["y"] - 122.5 * anchor["scale"],
    },
    "eyeRefX": source["eyeRefX"],
    "faces": source["faces"],
    "mouths": source["mouths"],
    "gaze": source["gaze"],
    "expressions": source["expressions"],
    "motion": source["motion"],
    "faceInterval": source["faceInterval"],
    "blinkInterval": source["blinkInterval"],
    "palette": source["palette"],
}

os.makedirs(os.path.dirname(out_path), exist_ok=True)
with open(out_path, "w") as f:
    json.dump(data, f, separators=(",", ":"))
    f.write("\n")
print(f"wrote {out_path} ({os.path.getsize(out_path)} bytes)")
