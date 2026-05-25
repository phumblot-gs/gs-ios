#!/usr/bin/env python3
"""Exports the GS app icon in formats useful for the Android port.

Writes everything under `exports/icon/` at the repo root:

  - icon-1024.png        : 1024×1024 master (same as iOS AppIcon)
  - icon-512.png         : 512×512 for the Play Console listing
  - adaptive-foreground.png : 1024×1024 transparent background, only
                              the white 'GSx' text — for the
                              foreground layer of an Android adaptive
                              icon (mipmap-anydpi-v26).
  - adaptive-background.png : 1024×1024 pure gradient, no text — for
                              the background layer.

Re-uses the geometry / font / colour choices from
`bin/generate_app_icon.py`. Idempotent.
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
OUT_DIR = os.path.join(REPO_ROOT, "exports", "icon")
SOURCE = os.path.join(REPO_ROOT, "GSApp", "Assets.xcassets", "AppIcon.appiconset", "icon-1024.png")


def vertical_gradient(width: int, height: int, top: tuple, bottom: tuple, alpha: int = 255) -> Image.Image:
    base = Image.new("RGBA", (width, height), (*top, alpha))
    pixels = base.load()
    for y in range(height):
        t = y / max(height - 1, 1)
        r = int(top[0] + (bottom[0] - top[0]) * t)
        g = int(top[1] + (bottom[1] - top[1]) * t)
        b = int(top[2] + (bottom[2] - top[2]) * t)
        for x in range(width):
            pixels[x, y] = (r, g, b, alpha)
    return base


def find_font_size(draw: ImageDraw.ImageDraw, text: str, max_width: int, target_height: int) -> ImageFont.FreeTypeFont:
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


def draw_text_centred(img: Image.Image, text: str) -> None:
    draw = ImageDraw.Draw(img)
    font = find_font_size(draw, text, max_width=int(SIZE * 0.72), target_height=int(SIZE * 0.50))
    bbox = draw.textbbox((0, 0), text, font=font)
    text_w = bbox[2] - bbox[0]
    text_h = bbox[3] - bbox[1]
    x = (SIZE - text_w) // 2 - bbox[0]
    y = (SIZE - text_h) // 2 - bbox[1]
    draw.text((x, y), text, font=font, fill=TEXT_COLOR)


def main() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)

    # 1. Master 1024 (same as iOS) — copy from the existing PNG so
    # the two assets are guaranteed identical to the byte.
    with Image.open(SOURCE) as src:
        master = src.convert("RGB")
        master.save(os.path.join(OUT_DIR, "icon-1024.png"), format="PNG", optimize=True)
        print(f"wrote icon-1024.png ({master.size[0]}×{master.size[1]})")

        # 2. 512×512 Play Console listing icon.
        listing = master.resize((512, 512), Image.LANCZOS)
        listing.save(os.path.join(OUT_DIR, "icon-512.png"), format="PNG", optimize=True)
        print("wrote icon-512.png (512×512)")

    # 3. Adaptive-icon background layer — gradient only, no text.
    background = vertical_gradient(SIZE, SIZE, TOP, BOTTOM)
    background.convert("RGB").save(
        os.path.join(OUT_DIR, "adaptive-background.png"),
        format="PNG",
        optimize=True
    )
    print("wrote adaptive-background.png (1024×1024)")

    # 4. Adaptive-icon foreground layer — transparent backdrop,
    # only the white 'GSx'. Android composes the two layers and
    # masks them to whatever shape the launcher wants (circle,
    # squircle, etc.) with a 72-of-108 dp safe area.
    foreground = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw_text_centred(foreground, TEXT)
    foreground.save(
        os.path.join(OUT_DIR, "adaptive-foreground.png"),
        format="PNG",
        optimize=True
    )
    print("wrote adaptive-foreground.png (1024×1024, transparent)")


if __name__ == "__main__":
    main()
