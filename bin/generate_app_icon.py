#!/usr/bin/env python3
"""Generates the GS app icon (1024x1024 PNG) used by AppIcon.appiconset.

Design:
  - Vertical linear gradient: #74D2D8 (top) → #EBED8C (bottom)
  - 'GSx' text centred, white, bold SF Pro (system font)
  - Square, no manual rounded corners — iOS masks at runtime

Run from repo root:  bin/generate_app_icon.py
Writes to GSApp/Assets.xcassets/AppIcon.appiconset/icon-1024.png
"""

import os
from PIL import Image, ImageDraw, ImageFont

SIZE = 1024
TOP = (0x74, 0xD2, 0xD8)
BOTTOM = (0xEB, 0xED, 0x8C)
TEXT = "GSx"
TEXT_COLOR = (255, 255, 255)
FONT_PATH = "/System/Library/Fonts/SFNS.ttf"

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
OUT_DIR = os.path.join(REPO_ROOT, "GSApp", "Assets.xcassets", "AppIcon.appiconset")
OUT_PATH = os.path.join(OUT_DIR, "icon-1024.png")


def vertical_gradient(width: int, height: int, top: tuple, bottom: tuple) -> Image.Image:
    base = Image.new("RGB", (width, height), top)
    pixels = base.load()
    for y in range(height):
        t = y / max(height - 1, 1)
        r = int(top[0] + (bottom[0] - top[0]) * t)
        g = int(top[1] + (bottom[1] - top[1]) * t)
        b = int(top[2] + (bottom[2] - top[2]) * t)
        for x in range(width):
            pixels[x, y] = (r, g, b)
    return base


def find_font_size(draw: ImageDraw.ImageDraw, text: str, max_width: int, target_height: int) -> ImageFont.FreeTypeFont:
    # Binary search font size that fits ~70% of icon width / 50% height.
    lo, hi = 50, 900
    best = ImageFont.truetype(FONT_PATH, lo)
    while lo <= hi:
        mid = (lo + hi) // 2
        font = ImageFont.truetype(FONT_PATH, mid)
        bbox = draw.textbbox((0, 0), text, font=font)
        w = bbox[2] - bbox[0]
        h = bbox[3] - bbox[1]
        if w <= max_width and h <= target_height:
            best = font
            lo = mid + 1
        else:
            hi = mid - 1
    return best


def main() -> None:
    img = vertical_gradient(SIZE, SIZE, TOP, BOTTOM)
    draw = ImageDraw.Draw(img)
    font = find_font_size(draw, TEXT, max_width=int(SIZE * 0.72), target_height=int(SIZE * 0.50))
    bbox = draw.textbbox((0, 0), TEXT, font=font)
    text_w = bbox[2] - bbox[0]
    text_h = bbox[3] - bbox[1]
    x = (SIZE - text_w) // 2 - bbox[0]
    y = (SIZE - text_h) // 2 - bbox[1]
    draw.text((x, y), TEXT, font=font, fill=TEXT_COLOR)

    os.makedirs(OUT_DIR, exist_ok=True)
    img.save(OUT_PATH, format="PNG", optimize=True)
    print(f"wrote {OUT_PATH} ({SIZE}x{SIZE})")


if __name__ == "__main__":
    main()
