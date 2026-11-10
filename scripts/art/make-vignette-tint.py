"""Build the tintable copy of the vignette art.

Usage: python scripts/art/make-vignette-tint.py
       python scripts/art/compress-tga.py CombatMode/Assets/ui/vignette-tint.tga

The vignette (CombatMode/Assets/atlas/Artifacts-BG-Shadow.tga, Blizzard's
Artifacts-BG-Shadow atlas) is black with the shape in its alpha channel. A
vertex color multiplies the texture's own color, so black art can't be tinted.
This writes CombatMode/Assets/ui/vignette-tint.tga: the same alpha with white
RGB, which Core/Vignette.lua tints with the Support Mode crosshair color.
Rerun it (then compress) only if the source art is exported again.
"""
import os
import struct

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
SOURCE = os.path.join(ROOT, "CombatMode", "Assets", "atlas", "Artifacts-BG-Shadow.tga")
TARGET = os.path.join(ROOT, "CombatMode", "Assets", "ui", "vignette-tint.tga")


def load(path):
    b = open(path, "rb").read()
    idlen, cmap, itype = b[0], b[1], b[2]
    w, h = struct.unpack("<HH", b[12:16])
    bpp, desc = b[16], b[17]
    if cmap != 0 or itype not in (2, 10) or bpp != 32:
        raise SystemExit("expected a 32-bit truecolor TGA, got type %d, %d bpp" % (itype, bpp))
    data = b[18 + idlen:]
    count = w * h
    if itype == 10:
        out = bytearray()
        i = 0
        while len(out) < count * 4:
            head = data[i]
            i += 1
            n = (head & 0x7F) + 1
            if head & 0x80:
                out += data[i:i + 4] * n
                i += 4
            else:
                out += data[i:i + n * 4]
                i += n * 4
        data = bytes(out)
    return w, h, desc, data[:count * 4]


def main():
    w, h, desc, data = load(SOURCE)
    out = bytearray(len(data))
    for i in range(0, len(data), 4):
        out[i] = out[i + 1] = out[i + 2] = 255  # B, G, R
        out[i + 3] = data[i + 3]  # A
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, w, h, 32, desc)
    with open(TARGET, "wb") as f:
        f.write(header + bytes(out))
    print("wrote %s (%dx%d)" % (os.path.relpath(TARGET, ROOT), w, h))


if __name__ == "__main__":
    main()
