#!/usr/bin/env python3
"""Makes the Portalistic app icon (host/AppIcon.icns and host/AppIcon.png) from host/Icon.svg.

    python3 host/make-icon.py            (needs Pillow; cairosvg too if Icon.svg is vector art)

Icon.svg is Michael's artwork (Portalistic-Icon-EXACT.svg, Oct 12 2026): a 1254 px picture of
the icon with its own rounded square, wrapped in an SVG. The icon's body is fitted to the macOS
icon grid (824 px of 1024, centered), so it sits like other apps in the Dock. bottle window
copies AppIcon.icns into the app; run this only when the artwork changes.
"""
import base64
import io
import pathlib
import re

import numpy as np
from PIL import Image

HOST = pathlib.Path(__file__).resolve().parent


def artwork():
    svg = (HOST / "Icon.svg").read_text()
    m = re.search(r'data:image/png;base64,([A-Za-z0-9+/=\s]+)"', svg)
    if m:   # a picture wrapped in SVG
        return Image.open(io.BytesIO(base64.b64decode(re.sub(r"\s", "", m.group(1))))).convert("RGBA")
    import cairosvg   # vector art
    return Image.open(io.BytesIO(cairosvg.svg2png(bytestring=svg.encode(), output_width=2048))).convert("RGBA")


src = artwork()
a = np.array(src.getchannel("A"))
# the icon's body: rows and columns that are mostly opaque (not its soft shadow or the sparks)
rows = np.where((a > 200).sum(axis=1) > a.shape[1] * 0.5)[0]
cols = np.where((a > 200).sum(axis=0) > a.shape[0] * 0.5)[0]
body = max(cols.max() - cols.min() + 1, rows.max() - rows.min() + 1)
scale = 824 / body
big = src.resize((round(src.width * scale), round(src.height * scale)), Image.LANCZOS)
cx = (cols.min() + cols.max() + 1) / 2 * scale
cy = (rows.min() + rows.max() + 1) / 2 * scale
icon = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
icon.alpha_composite(big, (round(512 - cx), round(512 - cy)))
icon.save(HOST / "AppIcon.png")
icon.save(HOST / "AppIcon.icns", sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])
print("wrote", HOST / "AppIcon.icns", "and AppIcon.png")
