#!/usr/bin/env python3
"""Draw the app icon: the O of Overtake, as a piece of transit map.

The same letterform the wordmark uses — the geometry below is the `"O"` entry from
`TransitLetter.shapes` in `SEPTACommute/App/Views/Wordmark.swift`, so the icon and
the title bar are demonstrably the same mark rather than two things that resemble
each other. Change one and re-run this.

An octagon stroked in SEPTA's Broad Street orange with a white stop at every vertex.
No text: it has to read at 40 points in a Settings row, where a word cannot.

Rendered at 4x and downsampled, because Pillow has no anti-aliasing of its own and a
transit diagram is all edges.

    python3 tools/make_app_icon.py
"""
from __future__ import annotations

import json
from pathlib import Path

from PIL import Image, ImageDraw

SIZE = 1024
SCALE = 4
BACKGROUND = "#0B0B0C"
# SEPTA's published Broad Street Line orange, which is also the app's accent.
STROKE = "#F26100"
STOP = "#FFFFFF"

# TransitLetter.shapes["O"], on its 0.62 x 1.0 box with the origin top left.
LETTER_WIDTH = 0.62
OUTLINE = [
    (0.18, 0.0), (0.44, 0.0), (0.62, 0.25), (0.62, 0.75),
    (0.44, 1.0), (0.18, 1.0), (0.0, 0.75), (0.0, 0.25),
]

OUTPUT = Path("SEPTACommute/Resources/Assets.xcassets/AppIcon.appiconset")
FILENAME = "AppIcon.png"


def draw_icon(canvas: int) -> Image.Image:
    image = Image.new("RGB", (canvas, canvas), BACKGROUND)
    pen = ImageDraw.Draw(image)

    # The letter is taller than it is wide, so height decides the scale.
    cap = canvas * 0.62
    origin_x = (canvas - LETTER_WIDTH * cap) / 2
    origin_y = (canvas - cap) / 2
    points = [(origin_x + x * cap, origin_y + y * cap) for x, y in OUTLINE]

    stroke = cap * 0.17
    radius = cap * 0.115
    ring = cap * 0.035

    # Closed, and with round joins drawn by hand — Pillow's are square, which on an
    # octagon leaves visible notches at every corner.
    for start, end in zip(points, points[1:] + points[:1]):
        pen.line([start, end], fill=STROKE, width=int(stroke))
    for x, y in points:
        pen.ellipse([x - stroke / 2, y - stroke / 2, x + stroke / 2, y + stroke / 2], fill=STROKE)

    # Stops last, so they sit on top of the line the way they do on the map.
    for x, y in points:
        pen.ellipse([x - radius, y - radius, x + radius, y + radius], fill=STROKE)
        pen.ellipse(
            [x - radius + ring, y - radius + ring, x + radius - ring, y + radius - ring],
            fill=STOP,
        )
    return image


def main() -> int:
    icon = draw_icon(SIZE * SCALE).resize((SIZE, SIZE), Image.LANCZOS)
    OUTPUT.mkdir(parents=True, exist_ok=True)
    icon.save(OUTPUT / FILENAME, "PNG")

    # Xcode ships no icon at all, silently, if the filename isn't in the manifest.
    manifest = OUTPUT / "Contents.json"
    data = json.loads(manifest.read_text()) if manifest.exists() else {}
    data["images"] = [{
        "filename": FILENAME,
        "idiom": "universal",
        "platform": "ios",
        "size": "1024x1024",
    }]
    data["info"] = {"author": "overtake", "version": 1}
    manifest.write_text(json.dumps(data, indent=2) + "\n")

    print(f"wrote {OUTPUT / FILENAME} ({(OUTPUT / FILENAME).stat().st_size:,} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
