#!/usr/bin/env python3
"""Draws the Mukker icon (orange tile, white keys, two dark bars) and writes both platforms' icons.

    python3 scripts/make-icons.py

- macOS: App/Resources/Assets.xcassets/AppIcon.appiconset/icon_{16..1024}.png, the tile inset on
  Apple's icon grid (824 of 1024 px) so it sits with the other Dock icons.
- Windows: windows/src/Mukker.App/Assets/mukker.ico, 16-256 px frames, the tile nearly full-bleed
  like other tray and taskbar icons.

Each size is drawn on its own (supersampled, area-downsampled), and at 64 px and below the edges are
snapped to whole pixels, so the small tray sizes stay crisp instead of being a blurred large frame.
Requires Pillow.
"""
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw

ORANGE = (230, 151, 24, 255)  # the popup bezel's default, #E69718
WHITE = (255, 255, 255, 255)
DARK = (36, 36, 38, 255)

# The design, in 256-unit coordinates: (left, top, right, bottom[, corner radius]).
TILE = (16, 16, 240, 240, 36)
KEYS = (48, 92, 208, 208, 18)
BARS = [(81, 122, 107, 208), (149, 122, 175, 208)]

ROOT = Path(__file__).resolve().parent.parent
MAC_DIR = ROOT / "App/Resources/Assets.xcassets/AppIcon.appiconset"
WIN_ICO = ROOT / "windows/src/Mukker.App/Assets/mukker.ico"


def render(n: int, margin: float) -> Image.Image:
    """The icon at n x n px with the tile inset by `margin` (a fraction of n) on every side."""
    ss = 16 if n <= 256 else 4
    big = n * ss
    lo = margin * n
    scale = (n - 2 * lo) / (TILE[2] - TILE[0])
    snap = n <= 64

    def px(v: float) -> float:
        p = lo + (v - TILE[0]) * scale
        return round(p) if snap else p

    def rect_mask(x0, y0, x1, y1, r=0) -> Image.Image:
        m = Image.new("L", (big, big), 0)
        box = (px(x0) * ss, px(y0) * ss, px(x1) * ss - 1, px(y1) * ss - 1)
        d = ImageDraw.Draw(m)
        if r:
            d.rounded_rectangle(box, radius=max(1, r * scale * ss), fill=255)
        else:
            d.rectangle(box, fill=255)
        return m

    tile = rect_mask(*TILE)
    keys = rect_mask(*KEYS)
    bars = Image.new("L", (big, big), 0)
    for b in BARS:
        bars = ImageChops.lighter(bars, rect_mask(*b))
    bars = ImageChops.multiply(bars, keys)  # the bars end at the keys' rounded bottom edge

    im = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    for colour, mask in ((ORANGE, tile), (WHITE, keys), (DARK, bars)):
        im.paste(Image.new("RGBA", (big, big), colour), (0, 0), mask)
    return im.resize((n, n), Image.BOX)


def main() -> None:
    mac_margin = 100 / 1024
    for n in (16, 32, 64, 128, 256, 512, 1024):
        render(n, mac_margin).save(MAC_DIR / f"icon_{n}.png", optimize=True)

    win_margin = 16 / 256
    sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256]
    frames = [render(n, win_margin) for n in sizes]
    frames[-1].save(WIN_ICO, format="ICO", sizes=[(n, n) for n in sizes], append_images=frames[:-1])
    print(f"wrote {MAC_DIR.relative_to(ROOT)}/icon_*.png and {WIN_ICO.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
