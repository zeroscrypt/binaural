#!/usr/bin/env python3
"""Draw the app icon, so it can be regenerated instead of being a mystery blob.

The menu-bar item is the SF Symbol `waveform` (``StatusItemController``), and the
dock, Finder and the window title were showing the generic Xcode icon next to
it — two different marks for one program. This draws the same waveform on the
product's own colour, so the two are recognisably one thing.

Run it from the repository root:

    python3 scripts/make_app_icon.py

It writes ``apple/Sources/macOS/Assets.xcassets/AppIcon.appiconset/icon_1024.png``.
Only that one size is generated: macOS scales a single 1024px master into
whatever the Dock asks for, and committing the whole size matrix means ten
copies of the same picture to keep in step.

Requires Pillow (``pip install Pillow``); it is not a runtime dependency and the
committed PNG is what the build uses.
"""

from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageDraw

# --------------------------------------------------------------------- geometry

#: Everything is laid out on this canvas and then downsampled, which is what
#: gives the curves clean edges. Supersampling rather than a 4x canvas so the
#: superellipse points stay cheap to compute.
CANVAS = 1024
SUPERSAMPLE = 4
WORK = CANVAS * SUPERSAMPLE

#: The icon body. Apple's macOS icons are a superellipse ("squircle") rather
#: than the rounded rectangle other platforms use — ``n = 5`` is the value that
#: reads as macOS — and it does not fill the canvas edge to edge.
BODY_EXPONENT = 5.0
BODY_RADIUS = 0.80 * WORK / 2

#: Where the waveform sits inside the body. Insets are fractions of the body,
#: so the mark keeps its proportions if the canvas size ever changes.
BAR_MARGIN = 0.105
BAR_COUNT = 7
BAR_WIDTH_RATIO = 0.056

#: Bar heights as a fraction of the tallest, symmetric about the centre so the
#: icon reads as a waveform rather than as a bar chart leaning one way.
BAR_PATTERN = (0.34, 0.62, 1.0, 0.78, 1.0, 0.62, 0.34)
MAX_BAR_HEIGHT_RATIO = 0.47

#: The product's own colours (``theme.TOKENS["primary"]``, light and dark).
BACKGROUND_TOP = (167, 139, 250)
BACKGROUND_BOTTOM = (108, 46, 214)
FOREGROUND = (255, 255, 255)


def _squircle_points(cx: float, cy: float, radius: float, exponent: float, steps: int = 2048):
    """Points on a superellipse ``|x|^n + |y|^n = 1``, centred on ``(cx, cy)``.

    A plain rounded rectangle reads as a foreign app on macOS; this is the shape
    the platform's own icons use.
    """
    points = []
    power = 2.0 / exponent
    for index in range(steps):
        theta = 2.0 * math.pi * index / steps
        cos_t, sin_t = math.cos(theta), math.sin(theta)
        x = math.copysign(abs(cos_t) ** power, cos_t)
        y = math.copysign(abs(sin_t) ** power, sin_t)
        points.append((cx + x * radius, cy + y * radius))
    return points


def _draw_body() -> Image.Image:
    """The squircle, filled with a vertical gradient."""
    centre = WORK / 2.0

    # A 1px-wide gradient is stretched over the shape; building it per-row over
    # the full canvas would be four million pixels for no visible gain.
    gradient = Image.new("RGB", (1, WORK))
    pixels = gradient.load()
    for y in range(WORK):
        t = y / (WORK - 1)
        pixels[0, y] = tuple(
            round(top + (bottom - top) * t)
            for top, bottom in zip(BACKGROUND_TOP, BACKGROUND_BOTTOM)
        )
    gradient = gradient.resize((WORK, WORK))

    mask = Image.new("L", (WORK, WORK), 0)
    ImageDraw.Draw(mask).polygon(
        _squircle_points(centre, centre, BODY_RADIUS, BODY_EXPONENT), fill=255
    )

    body = Image.new("RGBA", (WORK, WORK), (0, 0, 0, 0))
    body.paste(gradient, (0, 0), mask)
    return body


def _draw_waveform(image: Image.Image) -> None:
    """The mark: seven bars on a sine, drawn over the body."""
    draw = ImageDraw.Draw(image)
    centre = WORK / 2.0

    span = BODY_RADIUS * 2 * (1 - 2 * BAR_MARGIN)
    bar_width = span * BAR_WIDTH_RATIO
    gap = (span - bar_width * BAR_COUNT) / (BAR_COUNT - 1)
    max_height = BODY_RADIUS * 2 * MAX_BAR_HEIGHT_RATIO

    start_x = centre - span / 2
    for index, fraction in enumerate(BAR_PATTERN):
        height = max_height * fraction
        x0 = start_x + index * (bar_width + gap)
        y0 = centre - height / 2
        # A capsule rather than a rectangle: the ends read as the rounded caps
        # of a waveform, and match the corner treatment of the body.
        draw.rounded_rectangle(
            [x0, y0, x0 + bar_width, y0 + height],
            radius=bar_width / 2,
            fill=FOREGROUND + (255,),
        )


def build_icon() -> Image.Image:
    """The finished 1024px icon."""
    image = _draw_body()
    _draw_waveform(image)
    return image.resize((CANVAS, CANVAS), Image.LANCZOS)


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    destination = (
        root / "apple" / "Sources" / "macOS" / "Assets.xcassets"
        / "AppIcon.appiconset" / "icon_1024.png"
    )
    destination.parent.mkdir(parents=True, exist_ok=True)
    build_icon().save(destination)
    print(f"wrote {destination}")


if __name__ == "__main__":
    main()