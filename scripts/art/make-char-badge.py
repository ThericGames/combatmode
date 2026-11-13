"""Build the character-specific badge: CombatMode/Assets/ui/char-badge.tga.

    python scripts/art/make-char-badge.py

A round gold button with a dark italic "C", in the style of Blizzard's tutorial "i" info button (the options'
help badge): a lit top edge, a gold gradient face, a dark outline and a soft shadow underneath. The
disc fills the canvas (no empty margin, so it never shrinks when drawn at the badge size); drawn at 8x
and reduced for smooth edges. 64x64, RGBA, then RLE-compressed by compress-tga.py. Needs Pillow + numpy.
"""
import os
import subprocess
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
OUT = os.path.join(ROOT, "CombatMode", "Assets", "ui", "char-badge.tga")

SIZE = 64
SS = 8  # supersampling
DISC = 58  # disc diameter inside the canvas; the rest is the shadow's room (bottom) and the antialias edge
FACE_TOP = (255, 231, 173)
FACE_MID = (248, 205, 120)
FACE_BOTTOM = (214, 130, 8)
RIM_DARK = (58, 42, 20)
GLYPH = (20, 13, 6)
FONTS = ["georgiaz.ttf", "georgiabd.ttf", "georgiab.ttf", "timesbd.ttf", "arialbd.ttf"]


def font(px):
    for name in FONTS:
        for folder in (r"C:\Windows\Fonts", "/usr/share/fonts/truetype/msttcorefonts", "/Library/Fonts"):
            path = os.path.join(folder, name)
            if os.path.exists(path):
                return ImageFont.truetype(path, px)
    sys.exit("no bold serif font found")


def lerp(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def main(glyph_char="C", out=OUT, draw_glyph=None):
    """draw_glyph(draw, cx, cy, r) paints a custom dark glyph on the supersampled face instead of the text one."""
    n = SIZE * SS
    cx = n / 2
    cy = n / 2 - 1.0 * SS  # a little up: the shadow takes the bottom
    r = DISC * SS / 2
    yy, xx = np.mgrid[0:n, 0:n].astype(np.float32)
    dist = np.hypot(xx - cx, yy - cy)

    # shadow: a soft dark disc nudged down
    sh = np.clip(1 - (np.hypot(xx - cx, yy - (cy + 1.6 * SS)) - r * 0.92) / (2.2 * SS), 0, 1) * 0.35
    img = np.zeros((n, n, 4), np.float32)
    img[..., 3] = sh

    # face: vertical gradient, brighter in the upper half
    t = np.clip((yy - (cy - r)) / (2 * r), 0, 1)
    face = np.zeros((n, n, 3), np.float32)
    for i in range(3):
        top = FACE_TOP[i] + (FACE_MID[i] - FACE_TOP[i]) * np.clip(t / 0.45, 0, 1)
        bot = FACE_MID[i] + (FACE_BOTTOM[i] - FACE_MID[i]) * np.clip((t - 0.45) / 0.55, 0, 1)
        face[..., i] = np.where(t < 0.45, top, bot)
    rim_w = 2.4 * SS
    rim = np.clip((dist - (r - rim_w)) / SS, 0, 1)[..., None]  # 0 inside .. 1 on the rim
    colour = face * (1 - rim) + np.array(RIM_DARK, np.float32) * rim
    # soft inner highlight just inside the rim along the top
    hl = np.clip(1 - np.abs(dist - (r - rim_w - 0.9 * SS)) / (1.2 * SS), 0, 1) * np.clip(1 - t * 2.2, 0, 1) * 0.35
    colour = colour + (255 - colour) * hl[..., None]
    cover = np.clip(r - dist, 0, SS) / SS  # antialiased disc edge
    a_disc = cover
    out_a = a_disc + img[..., 3] * (1 - a_disc)
    out_rgb = colour * a_disc[..., None]  # shadow is black, so it adds nothing to the colour
    safe = np.maximum(out_a, 1e-6)[..., None]
    rgba = np.concatenate([out_rgb / safe, out_a[..., None] * 255], -1)

    base = Image.fromarray(np.clip(rgba, 0, 255).astype(np.uint8), "RGBA")
    # the glyph ("C"), centred on the face
    glyph = Image.new("L", (n, n), 0)
    f = font(int(DISC * SS * 0.78))
    d = ImageDraw.Draw(glyph)
    if draw_glyph:
        draw_glyph(d, cx, cy, r)
    else:
        bbox = d.textbbox((0, 0), glyph_char, font=f)
        gw, gh = bbox[2] - bbox[0], bbox[3] - bbox[1]
        d.text((cx - gw / 2 - bbox[0], cy - gh / 2 - bbox[1]), glyph_char, font=f, fill=255)
    ink = Image.new("RGBA", (n, n), GLYPH + (0,))
    ink.putalpha(glyph)
    base.alpha_composite(ink)

    # straight-alpha downscale (premultiply so the shadow does not bleed black into the rim)
    arr = np.asarray(base, np.float32)
    pm = arr[..., :3] * (arr[..., 3:] / 255)
    stack = np.concatenate([pm, arr[..., 3:]], -1).reshape(SIZE, SS, SIZE, SS, 4).mean((1, 3))
    a = stack[..., 3:]
    rgb = np.where(a > 0, stack[..., :3] / np.maximum(a / 255, 1e-6), 0)
    final = np.concatenate([rgb, a], -1)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    Image.fromarray(np.clip(final + 0.5, 0, 255).astype(np.uint8), "RGBA").save(out)
    subprocess.run([sys.executable, os.path.join(HERE, "compress-tga.py"), out], check=True)
    print("wrote", out)


if __name__ == "__main__":
    main()
