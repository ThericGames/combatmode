"""Build the NEW tag pill: CombatMode/Assets/ui/new-badge.tga.

    python scripts/art/make-new-badge.py

The same gold button as the character and help badges (make-char-badge.py), stretched into a pill:
lit top edge, gold gradient face, dark rim, soft shadow. It carries a dark italic "NEW" (not
translated: it is part of the art). 64x32, RGBA, RLE-compressed. Needs Pillow + numpy.
"""
import importlib.util
import os
import subprocess
import sys

import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("make_char_badge", os.path.join(HERE, "make-char-badge.py"))
badge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(badge)

OUT = os.path.join(os.path.dirname(os.path.dirname(HERE)), "CombatMode", "Assets", "ui", "new-badge.tga")
W, H = 64, 32
SS = 8
PILL_H = 27  # pill height inside the canvas (shadow room at the bottom)
PILL_W = 62


def main():
    nw, nh = W * SS, H * SS
    cx = nw / 2
    cy = nh / 2 - 0.8 * SS
    r = PILL_H * SS / 2
    half = PILL_W * SS / 2 - r
    yy, xx = np.mgrid[0:nh, 0:nw].astype(np.float32)

    def capsule(dy):
        return np.hypot(np.maximum(np.abs(xx - cx) - half, 0), yy - (cy + dy))

    dist = capsule(0)
    sh = np.clip(1 - (capsule(1.4 * SS) - r * 0.92) / (2.0 * SS), 0, 1) * 0.35

    t = np.clip((yy - (cy - r)) / (2 * r), 0, 1)
    face = np.zeros((nh, nw, 3), np.float32)
    for i in range(3):
        top = badge.FACE_TOP[i] + (badge.FACE_MID[i] - badge.FACE_TOP[i]) * np.clip(t / 0.45, 0, 1)
        bot = badge.FACE_MID[i] + (badge.FACE_BOTTOM[i] - badge.FACE_MID[i]) * np.clip((t - 0.45) / 0.55, 0, 1)
        face[..., i] = np.where(t < 0.45, top, bot)
    rim_w = 2.2 * SS
    rim = np.clip((dist - (r - rim_w)) / SS, 0, 1)[..., None]
    colour = face * (1 - rim) + np.array(badge.RIM_DARK, np.float32) * rim
    hl = np.clip(1 - np.abs(dist - (r - rim_w - 0.9 * SS)) / (1.2 * SS), 0, 1) * np.clip(1 - t * 2.2, 0, 1) * 0.35
    colour = colour + (255 - colour) * hl[..., None]
    cover = np.clip(r - dist, 0, SS) / SS
    out_a = cover + sh * (1 - cover)
    out_rgb = colour * cover[..., None]
    safe = np.maximum(out_a, 1e-6)[..., None]
    rgba = np.concatenate([out_rgb / safe, out_a[..., None] * 255], -1)

    base = Image.fromarray(np.clip(rgba, 0, 255).astype(np.uint8), "RGBA")
    glyph = Image.new("L", (nw, nh), 0)
    f = badge.font(int(PILL_H * SS * 0.5))
    d = ImageDraw.Draw(glyph)
    bbox = d.textbbox((0, 0), "NEW", font=f)
    gw, gh = bbox[2] - bbox[0], bbox[3] - bbox[1]
    d.text((cx - gw / 2 - bbox[0], cy - gh / 2 - bbox[1]), "NEW", font=f, fill=255)
    ink = Image.new("RGBA", (nw, nh), badge.GLYPH + (0,))
    ink.putalpha(glyph)
    base.alpha_composite(ink)

    arr = np.asarray(base, np.float32)
    pm = arr[..., :3] * (arr[..., 3:] / 255)
    stack = np.concatenate([pm, arr[..., 3:]], -1).reshape(H, SS, W, SS, 4).mean((1, 3))
    a = stack[..., 3:]
    rgb = np.where(a > 0, stack[..., :3] / np.maximum(a / 255, 1e-6), 0)
    final = np.concatenate([rgb, a], -1)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    Image.fromarray(np.clip(final + 0.5, 0, 255).astype(np.uint8), "RGBA").save(OUT)
    subprocess.run([sys.executable, os.path.join(HERE, "compress-tga.py"), OUT], check=True)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
