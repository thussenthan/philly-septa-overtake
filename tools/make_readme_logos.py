#!/usr/bin/env python3
"""Draw the logos the README shows: the wordmark, and the app icon with its corners.

The wordmark is the same drawing `Wordmark` in `SEPTACommute/App/Views/Wordmark.swift`
makes — the letter shapes, palette, stroke and stop sizes below are copied from it —
written out as SVG so GitHub can show it. It comes in a light and a dark version,
with the line colours put through the same contrast adjustment `Theme.adaptive`
applies in the app, so a pale line still reads on white and a dark one on black.

The icon is the app icon from the asset catalogue, downsampled and given the rounded
corners iOS would draw on it — the catalogue holds a square, because iOS masks it.

Run `tools/make_app_icon.py` first if the icon has changed, then:

    python3 tools/make_readme_logos.py
"""
from __future__ import annotations

import colorsys
from pathlib import Path

from PIL import Image, ImageDraw

NAME = "OVERTAKE"
OUTPUT = Path("docs")
ICON_SOURCE = Path("SEPTACommute/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
ICON_SIZE = 256

# Wordmark.palette.
PALETTE = ["F26100", "0097D6", "5A960A", "5F249F", "DC2E6B", "FFD700"]

# TransitLetter.width and .gap, and the columns and rows the letters are built from.
WIDTH, GAP = 0.62, 0.26
l, c, r = 0.0, 0.31, 0.62
t, m, b = 0.0, 0.5, 1.0

# TransitLetter.shapes, for the letters the name uses.
SHAPES = {
    "A": [[(l, b), (c, t), (r, b)], [(0.155, m), (0.465, m)]],
    "E": [[(r, t), (l, t), (l, b), (r, b)], [(l, m), (0.50, m)]],
    "K": [[(l, t), (l, b)], [(r, t), (l, 0.52)], [(0.20, 0.44), (r, b)]],
    "O": [[(0.18, t), (0.44, t), (r, 0.25), (r, 0.75), (0.44, b), (0.18, b),
           (l, 0.75), (l, 0.25), (0.18, t)]],
    "R": [[(l, b), (l, t), (0.40, t), (r, 0.25), (0.40, m), (l, m)], [(0.30, m), (r, b)]],
    "T": [[(l, t), (r, t)], [(c, t), (c, b)]],
    "V": [[(l, t), (c, b), (r, t)]],
}


def adjusted(hex_colour: str, dark: bool) -> str:
    """UIColor.adjustedForContrast(darkMode:)."""
    red, green, blue = (int(hex_colour[i:i + 2], 16) / 255 for i in (0, 2, 4))
    hue, saturation, brightness = colorsys.rgb_to_hsv(red, green, blue)
    if dark:
        brightness = max(brightness, 0.82)
        saturation = min(saturation, 0.78)
    else:
        brightness = min(brightness, 0.86)
    return "#" + "".join(f"{round(v * 255):02X}" for v in colorsys.hsv_to_rgb(hue, saturation, brightness))


def stops(polyline: list[tuple[float, float]]) -> list[tuple[float, float]]:
    """TransitLetter.stopPoints(of:): every vertex of a closed stroke, the ends of an open one."""
    first, last = polyline[0], polyline[-1]
    closed = len(polyline) > 3 and abs(first[0] - last[0]) < 0.001 and abs(first[1] - last[1]) < 0.001
    return polyline[:-1] if closed else [first, last]


def wordmark(dark: bool, height: float = 100) -> str:
    inset = height * 0.14
    advance = (WIDTH + GAP) * height
    width = len(NAME) * advance - GAP * height + inset * 2
    line_width = height * 0.17
    radius = height * 0.115
    ring = height * 0.035

    parts = []
    for index, character in enumerate(NAME):
        colour = adjusted(PALETTE[index % len(PALETTE)], dark)
        ox, oy = index * advance + inset, inset

        def place(point: tuple[float, float]) -> str:
            return f"{ox + point[0] * height:.2f},{oy + point[1] * height:.2f}"

        polylines = SHAPES[character]
        for polyline in polylines:
            parts.append(
                f'<polyline points="{" ".join(place(p) for p in polyline)}" fill="none" '
                f'stroke="{colour}" stroke-width="{line_width:.2f}" '
                'stroke-linecap="round" stroke-linejoin="round"/>'
            )

        # Stops last, deduplicated, as the app draws them.
        seen = set()
        for polyline in polylines:
            for point in stops(polyline):
                key = f"{point[0]:.2f},{point[1]:.2f}"
                if key in seen:
                    continue
                seen.add(key)
                x, y = place(point).split(",")
                parts.append(
                    f'<circle cx="{x}" cy="{y}" r="{radius:.2f}" fill="#FFFFFF" '
                    f'stroke="{colour}" stroke-width="{ring:.2f}"/>'
                )

    total_height = height + inset * 2
    body = "\n  ".join(parts)
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width:.2f} {total_height:.2f}" '
        f'width="{width:.0f}" height="{total_height:.0f}" role="img" aria-label="Overtake">\n'
        f"  <title>Overtake</title>\n  {body}\n</svg>\n"
    )


def icon() -> Image.Image:
    # Masked at 4x and downsampled, for the same reason make_app_icon.py draws that way.
    big = ICON_SIZE * 4
    source = Image.open(ICON_SOURCE).convert("RGBA").resize((big, big), Image.LANCZOS)
    mask = Image.new("L", (big, big), 0)
    # iOS's icon corner radius is about 22.37% of the side.
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, big - 1, big - 1], radius=big * 0.2237, fill=255)
    source.putalpha(mask)
    return source.resize((ICON_SIZE, ICON_SIZE), Image.LANCZOS)


def main() -> int:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    for name, dark in (("wordmark-light.svg", False), ("wordmark-dark.svg", True)):
        (OUTPUT / name).write_text(wordmark(dark))
        print(f"wrote {OUTPUT / name}")
    icon().save(OUTPUT / "icon.png", "PNG", optimize=True)
    print(f"wrote {OUTPUT / 'icon.png'} ({(OUTPUT / 'icon.png').stat().st_size:,} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
