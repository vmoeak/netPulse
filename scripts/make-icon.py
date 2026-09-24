#!/usr/bin/env python3
"""Draws Sources/NetPulse/Resources/AppIcon.png, the 1024pt master the .icns
is generated from (see build-app.sh).

Kept as a script rather than a checked-in blob nobody can edit: the palette
below is the app's own (Theme.accentBlue / Theme.upOrange), so the icon
follows the UI if that ever changes.

    python3 scripts/make-icon.py

Requires Pillow. Everything is drawn at 4x and downsampled, which is what
gives the curves and the waveform their antialiasing.
"""

import math
from pathlib import Path

from PIL import Image, ImageDraw

SIZE = 1024
SCALE = 4  # supersampling factor
W = SIZE * SCALE

# Apple's icon grid: the rounded square occupies 824 of the 1024 canvas.
ART = int(824 / 1024 * W)
INSET = (W - ART) // 2

ACCENT_TOP = (74, 166, 255)     # lighter tint of Theme.accentBlue
ACCENT_BOTTOM = (0, 82, 214)    # deeper end of the same blue
UP_ORANGE = (240, 160, 32)      # Theme.upOrange


def squircle(size, exponent=5.0, steps=1024):
    """Superellipse |x|^n + |y|^n = 1 — the shape macOS icons actually use.
    A plain rounded rectangle reads subtly wrong next to system icons."""
    radius = size / 2
    points = []
    for i in range(steps):
        theta = 2.0 * math.pi * i / steps
        cos_t, sin_t = math.cos(theta), math.sin(theta)
        x = radius * abs(cos_t) ** (2.0 / exponent) * math.copysign(1, cos_t)
        y = radius * abs(sin_t) ** (2.0 / exponent) * math.copysign(1, sin_t)
        points.append((radius + x, radius + y))
    return points


def vertical_gradient(size, top, bottom):
    grad = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / max(size - 1, 1)
        grad.putpixel((0, y), tuple(int(top[c] + (bottom[c] - top[c]) * t) for c in range(3)))
    return grad.resize((size, size), Image.BICUBIC)


def scaled(points, box, inset):
    """Map (0..1, 0..1) waveform coordinates into the art box."""
    return [(inset + x * box, inset + y * box) for x, y in points]


def main():
    canvas = Image.new("RGBA", (W, W), (0, 0, 0, 0))

    # Rounded body, filled with the app's blue gradient.
    mask = Image.new("L", (ART, ART), 0)
    ImageDraw.Draw(mask).polygon(squircle(ART), fill=255)
    body = vertical_gradient(ART, ACCENT_TOP, ACCENT_BOTTOM).convert("RGBA")
    body.putalpha(mask)
    canvas.alpha_composite(body, (INSET, INSET))

    # Two traces, mirroring the UI's language: download is the white one,
    # upload the thinner orange one below it. Amplitudes are kept apart so
    # the lines never cross — at 32pt in the menu bar a crossing reads as a
    # smudge rather than as two signals.
    down = [(0.10, 0.55), (0.20, 0.55), (0.27, 0.33), (0.34, 0.55),
            (0.44, 0.55), (0.52, 0.25), (0.60, 0.55), (0.70, 0.55),
            (0.76, 0.43), (0.82, 0.55), (0.90, 0.55)]
    up = [(0.10, 0.75), (0.24, 0.75), (0.32, 0.67), (0.40, 0.75),
          (0.56, 0.75), (0.64, 0.70), (0.72, 0.75), (0.90, 0.75)]

    down_pts = scaled(down, ART, INSET)
    up_pts = scaled(up, ART, INSET)

    draw = ImageDraw.Draw(canvas)
    draw.line(up_pts, fill=UP_ORANGE + (255,), width=int(0.030 * ART), joint="curve")
    draw.line(down_pts, fill=(255, 255, 255, 255), width=int(0.042 * ART), joint="curve")

    # Round the trace ends; ImageDraw.line leaves them square.
    for pts, width, color in ((up_pts, 0.030, UP_ORANGE + (255,)),
                              (down_pts, 0.042, (255, 255, 255, 255))):
        r = width * ART / 2
        for x, y in (pts[0], pts[-1]):
            draw.ellipse([x - r, y - r, x + r, y + r], fill=color)

    out = Path(__file__).resolve().parent.parent / "Sources/NetPulse/Resources/AppIcon.png"
    canvas.resize((SIZE, SIZE), Image.LANCZOS).save(out)
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
