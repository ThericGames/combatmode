"""Build the frame-picker badge: CombatMode/Assets/ui/pick-badge.tga.

    python scripts/art/make-pick-badge.py

The same gold round button as the character, help and info badges (make-char-badge.py), with a dark
magnifying glass for the "pick a frame on screen" button of the Extra Frames field.
64x64, RGBA, RLE-compressed. Needs Pillow + numpy.
"""
import importlib.util
import math
import os

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("make_char_badge", os.path.join(HERE, "make-char-badge.py"))
badge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(badge)

OUT = os.path.join(os.path.dirname(os.path.dirname(HERE)), "CombatMode", "Assets", "ui", "pick-badge.tga")


def magnifier(d, cx, cy, r):
    """A ring (the lens) up and to the left with a rounded handle to the lower right, sized against the disc radius r."""
    lens_r = r * 0.38
    w = r * 0.13
    lx, ly = cx - r * 0.12, cy - r * 0.12  # lens centre, nudged so the whole glyph sits centred
    d.ellipse([lx - lens_r, ly - lens_r, lx + lens_r, ly + lens_r], outline=255, width=round(w))
    k = math.sqrt(0.5)
    x0, y0 = lx + k * (lens_r + w * 0.3), ly + k * (lens_r + w * 0.3)
    x1, y1 = cx + r * 0.50, cy + r * 0.50
    hw = r * 0.17
    d.line([x0, y0, x1, y1], fill=255, width=round(hw))
    for x, y in ((x0, y0), (x1, y1)):  # round the handle ends
        d.ellipse([x - hw / 2, y - hw / 2, x + hw / 2, y + hw / 2], fill=255)


if __name__ == "__main__":
    badge.main(out=OUT, draw_glyph=magnifier)
