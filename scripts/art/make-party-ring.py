"""Build the Party Wheel health ring art from the status bar art.

Usage: python scripts/art/make-party-ring.py
       python scripts/art/compress-tga.py CombatMode/Assets/radial

Sweeps the middle column of Blizzard's widgetstatusbar bgcenter, fill-white and
bordercenter round a circle (the bar's top is the outer edge), so the three
line up like a status bar's layers. Writes radial_health_{bg,fill,ring}.tga and
radial_health_spark.tga into CombatMode/Assets/radial. The spark is
widgetstatusbar-spark standing across the band's bottom.

The canvas is drawn at 88 UI units (RING_SIZE * 4 / 3 in View.lua), a little
over 100 screen px on a typical setup. It is only 128 px, with a filter a bit
wider than a texel, because the game shrinking a much larger texture leaves the
thin gold lines jagged.
"""
import math
import os
import struct

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
ATLAS = os.path.join(ROOT, "CombatMode", "Assets", "atlas")
RADIAL = os.path.join(ROOT, "CombatMode", "Assets", "radial")

CANVAS = 128
TEXELS_PER_UNIT = CANVAS / 88.0  # canvas texels per UI unit
MID = 27.75 * TEXELS_PER_UNIT  # the band's middle radius
ROW = 0.5 * TEXELS_PER_UNIT  # one bar-art pixel
SPARK_ROWS = 23.0  # the spark's whole art, this many bar rows tall
SAMPLES = 6  # supersamples per texel side
FILTER = 1.35  # texels each output texel averages over, per side
CLEAR = (0.0, 0.0, 0.0, 0.0)


def load(path):
    """Returns (width, height, rows of (r, g, b, a) floats, top row first)."""
    b = open(path, "rb").read()
    idlen, cmap, itype = b[0], b[1], b[2]
    w, h = struct.unpack("<HH", b[12:16])
    bpp, desc = b[16], b[17]
    if cmap != 0 or itype not in (2, 10) or bpp != 32:
        raise SystemExit("%s: expected a 32-bit truecolor TGA, got type %d, %d bpp" % (path, itype, bpp))
    data = b[18 + idlen:]
    size = w * h * 4
    if itype == 10:
        out = bytearray()
        i = 0
        while len(out) < size:
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
    rows = []
    for y in range(h):
        row = []
        for x in range(w):
            blue, green, red, alpha = data[(y * w + x) * 4:(y * w + x) * 4 + 4]
            row.append((float(red), float(green), float(blue), float(alpha)))
        rows.append(row)
    if not desc & 0x20:
        rows.reverse()
    return w, h, rows


def save(path, pixels):
    """Writes CANVAS x CANVAS (r, g, b, a) rows, top row first."""
    out = bytearray()
    for row in pixels:
        for r, g, b, a in row:
            out += bytes((int(b + 0.5), int(g + 0.5), int(r + 0.5), int(a + 0.5)))
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, CANVAS, CANVAS, 32, 0x28)
    with open(path, "wb") as f:
        f.write(header + bytes(out))
    print("wrote %s (%dx%d)" % (os.path.relpath(path, ROOT), CANVAS, CANVAS))


def premultiply(p):
    r, g, b, a = p
    k = a / 255.0
    return (r * k, g * k, b * k, a)


def mix(p, q, t):
    return tuple(p[i] + (q[i] - p[i]) * t for i in range(4))


def sample(image, u, v, clamp_u=False):
    """Bilinear, premultiplied; u, v in source pixels from the top left corner."""
    w, h, rows = image
    if v < 0 or v > h or (not clamp_u and (u < 0 or u > w)):
        return CLEAR
    x, y = u - 0.5, v - 0.5
    x0, y0 = int(math.floor(x)), int(math.floor(y))

    def at(i, j):
        return premultiply(rows[min(max(j, 0), h - 1)][min(max(i, 0), w - 1)])

    top = mix(at(x0, y0), at(x0 + 1, y0), x - x0)
    bottom = mix(at(x0, y0 + 1), at(x0 + 1, y0 + 1), x - x0)
    return mix(top, bottom, y - y0)


def render(color_at):
    """Supersampled canvas; color_at(dx, dy) is premultiplied, from the centre, y down."""
    half = CANVAS / 2.0
    total = SAMPLES * SAMPLES
    pixels = []
    for py in range(CANVAS):
        row = []
        for px in range(CANVAS):
            acc = [0.0, 0.0, 0.0, 0.0]
            for sy in range(SAMPLES):
                for sx in range(SAMPLES):
                    dx = px + 0.5 + ((sx + 0.5) / SAMPLES - 0.5) * FILTER - half
                    dy = py + 0.5 + ((sy + 0.5) / SAMPLES - 0.5) * FILTER - half
                    c = color_at(dx, dy)
                    for i in range(4):
                        acc[i] += c[i]
            a = acc[3] / total
            if a < 0.5:
                row.append(CLEAR)
            else:
                k = 255.0 / a / total
                row.append((min(acc[0] * k, 255.0), min(acc[1] * k, 255.0), min(acc[2] * k, 255.0), a))
        pixels.append(row)
    return pixels


def sweep(image):
    w, h, _ = image
    column = w // 2 + 0.5
    reach = h / 2.0 * ROW

    def color_at(dx, dy):
        radius = math.hypot(dx, dy)
        if abs(radius - MID) > reach:
            return CLEAR
        return sample(image, column, h / 2.0 - (radius - MID) / ROW, clamp_u=True)

    return render(color_at)


def spark(image):
    w, h, _ = image
    scale = SPARK_ROWS * ROW / h  # canvas texels per source pixel

    def color_at(dx, dy):
        # Upright at the bottom of the ring: the art's top is the outer (lower) end.
        return sample(image, w / 2.0 + dx / scale, h / 2.0 - (dy - MID) / scale)

    return render(color_at)


def source(name):
    image = load(os.path.join(ATLAS, "widgetstatusbar-%s.tga" % name))
    print("read widgetstatusbar-%s (%dx%d)" % (name, image[0], image[1]))
    return image


def main():
    save(os.path.join(RADIAL, "radial_health_bg.tga"), sweep(source("bgcenter")))
    save(os.path.join(RADIAL, "radial_health_fill.tga"), sweep(source("fill-white")))
    save(os.path.join(RADIAL, "radial_health_ring.tga"), sweep(source("bordercenter")))
    save(os.path.join(RADIAL, "radial_health_spark.tga"), spark(source("spark")))


if __name__ == "__main__":
    main()
