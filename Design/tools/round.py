"""Cut iOS-style rounded corners (radius 22.4 % of the side) into a square PNG.

Used by export-icons.sh for the launch-screen icons, which sit on a plain background
and would otherwise show as a hard square.

Usage: python3 -I round.py in.png out.png
Standard library only; reuses the PNG reader/writer in matte.py.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from matte import read_png, write_png  # noqa: E402


def main(src, out):
    w, h, bpp, rows = read_png(src)
    r = 0.224 * min(w, h)
    result = []
    for y in range(h):
        line = rows[y]
        row = bytearray(w * 4)
        for x in range(w):
            px = line[x * bpp:x * bpp + bpp]
            a = px[3] if bpp == 4 else 255
            # Distance from the nearest corner centre; only matters inside the corner squares.
            cx = min(max(x + 0.5, r), w - r)
            cy = min(max(y + 0.5, r), h - r)
            d = ((x + 0.5 - cx) ** 2 + (y + 0.5 - cy) ** 2) ** 0.5
            cover = max(0.0, min(1.0, r - d + 0.5))  # 1 px anti-aliased edge
            row[x * 4:x * 4 + 4] = bytes((px[0], px[1], px[2], round(a * cover)))
        result.append(row)
    write_png(out, w, h, result)


if __name__ == '__main__':
    main(*sys.argv[1:3])
