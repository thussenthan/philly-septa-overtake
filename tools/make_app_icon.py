#!/usr/bin/env python3
"""Draw the app icon: two tracks, and the express overtaking the local.

The app's whole idea in one picture. A blue local runs along the top track,
stopping everywhere. The orange express starts below it, skips the stops, cuts up
at 45° and finishes ahead of the local on the same track. Lines and stops are drawn
the way the wordmark draws them, so the icon and the title read as one network
diagram. No text: it has to read at 40 points in a Settings row.

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
# A faint top-to-bottom gradient, near black, so the tile isn't flat on a dark
# home screen.
BACKGROUND_TOP = (24, 25, 28)
BACKGROUND = (11, 11, 12)
# SEPTA's Broad Street orange (the app's accent) for the express, and the
# Market-Frankford blue for the local.
EXPRESS = "#F26100"
LOCAL = "#0097D6"
STOP = "#FFFFFF"

OUTPUT = Path("SEPTACommute/Resources/Assets.xcassets/AppIcon.appiconset")
FILENAME = "AppIcon.png"

# Unit coordinates (0…1) on the square tile.
TOP_TRACK = 0.38
BOTTOM_TRACK = 0.64
LINE_WIDTH = 0.095
LOCAL_LINE = [(0.14, TOP_TRACK), (0.62, TOP_TRACK)]
LOCAL_STOPS = [0.14, 0.30, 0.46, 0.62]
EXPRESS_LINE = [(0.14, BOTTOM_TRACK), (0.54, BOTTOM_TRACK), (0.80, TOP_TRACK), (0.86, TOP_TRACK)]


def draw_icon(canvas: int) -> Image.Image:
    image = Image.new("RGB", (canvas, canvas), BACKGROUND)
    pen = ImageDraw.Draw(image)
    for y in range(0, canvas, SCALE):
        t = y / canvas
        colour = tuple(round(BACKGROUND_TOP[i] + (BACKGROUND[i] - BACKGROUND_TOP[i]) * t) for i in range(3))
        pen.rectangle([0, y, canvas, y + SCALE], fill=colour)

    def point(p):
        return (p[0] * canvas, p[1] * canvas)

    def line(points, colour):
        width = int(LINE_WIDTH * canvas)
        pixels = [point(p) for p in points]
        for a, b in zip(pixels, pixels[1:]):
            pen.line([a, b], fill=colour, width=width)
        # Round joins and caps by hand — Pillow's are square.
        r = width / 2
        for x, y in pixels:
            pen.ellipse([x - r, y - r, x + r, y + r], fill=colour)

    def stop(p, colour, radius=0.058, ring=0.019):
        x, y = point(p)
        outer, inner = radius * canvas, (radius - ring) * canvas
        pen.ellipse([x - outer, y - outer, x + outer, y + outer], fill=colour)
        pen.ellipse([x - inner, y - inner, x + inner, y + inner], fill=STOP)

    line(LOCAL_LINE, LOCAL)
    line(EXPRESS_LINE, EXPRESS)
    # Stops last, so they sit on top of the lines as they do on the map.
    for x in LOCAL_STOPS:
        stop((x, TOP_TRACK), LOCAL)
    stop((0.14, BOTTOM_TRACK), EXPRESS)
    # The express's one stop ahead — bigger, because it's where you get there first.
    stop((0.86, TOP_TRACK), EXPRESS, radius=0.075, ring=0.024)
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
