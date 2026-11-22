#!/usr/bin/env python3
"""Generate DSH Flick's original artwork.

The project does not reuse any DeepSeek graphic asset. The mark is a rounded
blue square with three white bars and a green status dot; the menu bar variant
is a black template image on a transparent background so macOS can tint it for
light and dark menu bars.

Outputs (in ``dsh-flick/Resources`` by default)::

    MenuIcon.png      18 x 18 px
    MenuIcon@2x.png   36 x 36 px
    MenuIcon@3x.png   54 x 54 px
    AppIcon.icns      macOS app icon
    AppIcon-1024.png  1024 px preview

Usage::

    python3 scripts/make-icons.py
    ./scripts/make-icons.sh

Requires Python 3.9+ and Pillow. The wrapper script finds a suitable
interpreter, including the one bundled with DeepSeek Harness.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    from PIL import Image, ImageDraw
except ImportError:
    sys.exit("错误：需要 Pillow。请安装（pip3 install Pillow）或用 PYTHON=... 指定带 Pillow 的解释器。")

PROJECT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUT_DIR = PROJECT_ROOT / "Resources"


def draw_app_icon(size: int = 1024) -> Image.Image:
    scale = 4
    pixels = size * scale
    image = Image.new("RGBA", (pixels, pixels), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    # Vertical blue gradient inside a rounded square.
    for y in range(pixels):
        t = y / max(1, pixels - 1)
        color = (
            int(31 + (11 - 31) * t),
            int(111 + (61 - 111) * t),
            int(235 + (145 - 235) * t),
            255,
        )
        draw.line([(0, y), (pixels, y)], fill=color)

    mask = Image.new("L", (pixels, pixels), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [int(pixels * 0.03), int(pixels * 0.03), int(pixels * 0.97), int(pixels * 0.97)],
        radius=int(pixels * 0.225),
        fill=255,
    )
    image.putalpha(mask)

    # Three bars and one green status dot.
    bar_x = int(pixels * 0.205)
    for width, height, top in ((0.44, 0.075, 0.30), (0.59, 0.075, 0.465), (0.34, 0.075, 0.63)):
        draw.rounded_rectangle(
            [
                bar_x,
                int(pixels * top),
                bar_x + int(pixels * width),
                int(pixels * top) + int(pixels * height),
            ],
            radius=int(pixels * height / 2),
            fill=(255, 255, 255, 245),
        )
    center_x, center_y, radius = int(pixels * 0.745), int(pixels * 0.655), int(pixels * 0.048)
    draw.ellipse(
        [center_x - radius, center_y - radius, center_x + radius, center_y + radius],
        fill=(126, 226, 168, 255),
    )
    return image.resize((size, size), Image.LANCZOS)


def draw_menu_icon(pixels: int) -> Image.Image:
    image = Image.new("RGBA", (pixels, pixels), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    x0 = round(pixels * 0.12)
    for index, width in enumerate((0.52, 0.72, 0.38)):
        y = round(pixels * (0.24 + index * 0.24))
        height = max(1, round(pixels * 0.11))
        draw.rounded_rectangle(
            [x0, y, x0 + round(pixels * width), y + height],
            radius=max(1, height // 2),
            fill=(0, 0, 0, 255),
        )
    return image


def write_menu_icons(out_dir: Path) -> None:
    for scale, name in ((1, "MenuIcon.png"), (2, "MenuIcon@2x.png"), (3, "MenuIcon@3x.png")):
        draw_menu_icon(18 * scale).save(out_dir / name)


def write_app_icon(out_dir: Path) -> None:
    icon = draw_app_icon(1024)
    icon.save(out_dir / "AppIcon-1024.png")

    with tempfile.TemporaryDirectory() as temporary:
        iconset = Path(temporary) / "DSHFlick.iconset"
        iconset.mkdir()
        for size in (16, 32, 128, 256, 512):
            icon.resize((size, size), Image.LANCZOS).save(iconset / f"icon_{size}x{size}.png")
            icon.resize((size * 2, size * 2), Image.LANCZOS).save(
                iconset / f"icon_{size}x{size}@2x.png"
            )
        target = out_dir / "AppIcon.icns"
        if shutil.which("iconutil"):
            subprocess.run(
                ["/usr/bin/iconutil", "-c", "icns", str(iconset), "-o", str(target)],
                check=True,
            )
        else:
            raise SystemExit("错误：缺少 iconutil（macOS 自带），无法生成 AppIcon.icns")


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate DSH Flick artwork.")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT_DIR, help="output directory")
    parser.add_argument("--source", help="ignored; kept for compatibility with old scripts")
    parser.add_argument("--preview", help="ignored; kept for compatibility")
    args = parser.parse_args()

    out_dir = args.out
    out_dir.mkdir(parents=True, exist_ok=True)
    write_menu_icons(out_dir)
    write_app_icon(out_dir)
    print(f"已生成原创图标: {out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
