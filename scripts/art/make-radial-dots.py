"""Draw the Radial Menu's slice action dots: radial_dot.tga and radial_dot_glow.tga.

Usage: python scripts/art/make-radial-dots.py [out_dir]
Default out_dir is CombatMode/Assets/radial. Run compress-tga.py afterwards.

Both are white (tinted in game). The canvases are kept close to the size they're drawn at
(the dot is about 6-12 screen pixels): TGAs have no mipmaps, so a large source scaled down
turns jagged. The dot's soft edge does the anti-aliasing, and the white colour under
transparent pixels keeps filtering from darkening its rim.
"""
import os
import struct
import sys

DOT_CANVAS, DOT_DIAMETER, DOT_FEATHER = 16, 12.0, 1.5
GLOW_CANVAS = 32


def dot_alpha(distance):
    return min(1.0, max(0.0, (DOT_DIAMETER / 2 - distance) / DOT_FEATHER + 0.5))


def glow_alpha(distance):
    t = min(1.0, distance / (GLOW_CANVAS / 2))
    return (1.0 - t * t) ** 2


def write_tga(path, size, alpha):
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, size, size, 32, 8)
    pixels = bytearray()
    for y in range(size):
        for x in range(size):
            distance = ((x + 0.5 - size / 2) ** 2 + (y + 0.5 - size / 2) ** 2) ** 0.5
            pixels += bytes((255, 255, 255, round(alpha(distance) * 255)))
    with open(path, "wb") as f:
        f.write(header + pixels)
    print(path)


def main():
    default = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "CombatMode", "Assets", "radial")
    out_dir = sys.argv[1] if len(sys.argv) > 1 else default
    write_tga(os.path.join(out_dir, "radial_dot.tga"), DOT_CANVAS, dot_alpha)
    write_tga(os.path.join(out_dir, "radial_dot_glow.tga"), GLOW_CANVAS, glow_alpha)


main()
