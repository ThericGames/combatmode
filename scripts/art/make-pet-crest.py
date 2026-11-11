"""Build the Ally HUD pet crest: CombatMode/Assets/ui/pet-crest.tga.

    python scripts/art/make-pet-crest.py

Pets have no group role, so the Ally HUD draws this crest in the role icon's place. To match the
role icons exactly it is built from one of them: the frame (halo, rim, gold ring) is copied pixel
for pixel from Assets/atlas/UI-Frame-HealerIcon.tga, the disc inside it is re-created in amber with
the same radial falloff (read from the Healer disc along its diagonals, where the cross is not), and a
cream paw print with a soft glow replaces the glyph. Same 31x30 size as the role icons. RGBA, then
RLE-compressed by compress-tga.py. Needs Pillow + numpy.
"""
import os
import subprocess
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SRC = os.path.join(ROOT, "CombatMode", "Assets", "atlas", "UI-Frame-HealerIcon.tga")
OUT = os.path.join(ROOT, "CombatMode", "Assets", "ui", "pet-crest.tga")

CX, CY = 14.5, 14.0  # disc centre in the 31x30 canvas (pixel centres at +0.5)
R_DISC = 10.2  # inside the gold ring
SS = 16  # supersampling for the paw

EDGE = np.array((16, 7, 1), np.float32)  # disc colour where the Healer's is darkest
BRIGHT = np.array((214, 118, 26), np.float32)  # ... and where it is brightest
GLYPH_TOP = np.array((255, 244, 208), np.float32)
GLYPH_BOTTOM = np.array((214, 192, 138), np.float32)
GLOW = np.array((255, 205, 110), np.float32)

# Paw print, pixels relative to the disc centre: (dx, dy, half width, half height)
PAD = (0.0, 3.6, 4.6, 3.3)
TOES = [
    (-6.0, 0.6, 1.6, 2.1),
    (-2.3, -3.5, 1.6, 2.2),
    (2.3, -3.5, 1.6, 2.2),
    (6.0, 0.6, 1.6, 2.1),
]


def diagonal_profile(img):
    """Healer disc green channel by radius along the 4 diagonals (the cross never reaches them)."""
    prof = {}
    for r10 in range(0, 110):
        r = r10 / 10
        vals = []
        for sx, sy in ((1, 1), (-1, 1), (1, -1), (-1, -1)):
            x = CX + sx * r * 0.7071 - 0.5
            y = CY + sy * r * 0.7071 - 0.5
            x0, y0 = int(np.floor(x)), int(np.floor(y))
            fx, fy = x - x0, y - y0
            g = 0.0
            for ox, oy, wgt in ((0, 0, (1 - fx) * (1 - fy)), (1, 0, fx * (1 - fy)), (0, 1, (1 - fx) * fy), (1, 1, fx * fy)):
                g += img[y0 + oy, x0 + ox, 1] * wgt
            vals.append(g)
        prof[r10] = float(np.mean(vals))
    return prof


def main():
    src = np.asarray(Image.open(SRC).convert("RGBA"), np.float32)
    h, w, _ = src.shape
    prof = diagonal_profile(src)
    # The cross covers the middle on the axes, not the diagonals, but the centre itself is bright:
    # hold the first clear value (r >= 4.5) inward.
    inner = max(prof[45], prof[50], prof[55])
    peak = max(prof[r10] for r10 in range(45, 95))

    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    dist = np.hypot(xx + 0.5 - CX - 0.5, yy + 0.5 - CY - 0.5)
    level = np.zeros((h, w), np.float32)
    for y in range(h):
        for x in range(w):
            r10 = int(min(dist[y, x], 10.9) * 10)
            level[y, x] = inner if dist[y, x] < 4.5 else prof[r10]
    level = np.clip(level / peak, 0, 1)
    disc = EDGE + (BRIGHT - EDGE) * level[..., None] ** 0.9

    # paw, supersampled, then box-reduced to the canvas
    n_w, n_h = w * SS, h * SS
    glyph = Image.new("L", (n_w, n_h), 0)
    d = ImageDraw.Draw(glyph)

    def ellipse(dx, dy, hw, hh):
        x, y = (CX + 0.5 + dx) * SS, (CY + 0.5 + dy) * SS
        d.ellipse((x - hw * SS, y - hh * SS, x + hw * SS, y + hh * SS), fill=255)

    ellipse(*PAD)
    for toe in TOES:
        ellipse(*toe)
    cover = np.asarray(glyph.resize((w, h), Image.BOX), np.float32) / 255
    glow = np.asarray(glyph.filter(ImageFilter.GaussianBlur(1.1 * SS)).resize((w, h), Image.BOX), np.float32) / 255
    glow = np.clip(glow * 1.5, 0, 1) * 0.3
    # dark halo hugging the paw so the cream shape separates from the amber disc
    halo = np.asarray(glyph.filter(ImageFilter.GaussianBlur(0.9 * SS)).resize((w, h), Image.BOX), np.float32) / 255
    halo = np.clip(halo * 2.2, 0, 1) * 0.65

    gy = np.clip((yy - (CY - 7)) / 14, 0, 1)[..., None]
    ink = GLYPH_TOP + (GLYPH_BOTTOM - GLYPH_TOP) * gy
    inside = disc * (1 - halo[..., None]) + GLOW * 0.0
    inside = inside * (1 - glow[..., None]) + GLOW * glow[..., None]
    inside = inside * (1 - cover[..., None]) + ink * cover[..., None]

    # swap it into the Healer frame, feathered over the last 0.8 px of the ring's inner edge
    mask = np.clip((R_DISC - dist) / 0.8, 0, 1)[..., None]
    rgb = src[..., :3] * (1 - mask) + inside * mask
    out = np.concatenate([rgb, src[..., 3:]], -1)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    Image.fromarray(np.clip(out + 0.5, 0, 255).astype(np.uint8), "RGBA").save(OUT)
    subprocess.run([sys.executable, os.path.join(HERE, "compress-tga.py")], check=True)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
