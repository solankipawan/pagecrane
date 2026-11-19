"""Recover a transparent PNG from two opaque renders of the same artwork.

QuickLook (qlmanage) always paints SVGs onto white, so export-icons.sh renders each
transparent layer twice (once over black, once over white) and this script solves
for the original colour and alpha per pixel:

    alpha = 1 - (white - black) / 255        (averaged over R, G, B)
    color = black / alpha

Usage: python3 -I matte.py on_black.png on_white.png out.png
Standard library only (zlib + struct), no Pillow needed.
"""
import struct
import sys
import zlib


def read_png(path):
    data = open(path, 'rb').read()
    pos, idat = 8, b''
    while pos < len(data):
        n = struct.unpack('>I', data[pos:pos + 4])[0]
        kind, chunk = data[pos + 4:pos + 8], data[pos + 8:pos + 8 + n]
        pos += 12 + n
        if kind == b'IHDR':
            w, h, depth, ctype = struct.unpack('>IIBB', chunk[:10])
            if depth != 8 or ctype not in (2, 6):
                raise SystemExit(f'{path}: need 8-bit RGB/RGBA, got depth {depth} type {ctype}')
        elif kind == b'IDAT':
            idat += chunk
    bpp = 4 if ctype == 6 else 3
    stride = w * bpp
    raw = zlib.decompress(idat)
    rows, prev, i = [], bytearray(stride), 0
    for _ in range(h):
        f = raw[i]
        line = bytearray(raw[i + 1:i + 1 + stride])
        i += 1 + stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if f == 1:
                line[x] = (line[x] + a) & 255
            elif f == 2:
                line[x] = (line[x] + b) & 255
            elif f == 3:
                line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line)
        prev = line
    return w, h, bpp, rows


def write_png(path, w, h, rows):
    raw = b''.join(b'\x00' + bytes(r) for r in rows)

    def chunk(kind, body):
        return struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body) & 0xFFFFFFFF)

    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n')
        f.write(chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)))
        f.write(chunk(b'IDAT', zlib.compress(raw, 9)))
        f.write(chunk(b'IEND', b''))


def main(on_black, on_white, out):
    w, h, bb, black = read_png(on_black)
    w2, h2, bw, white = read_png(on_white)
    if (w, h) != (w2, h2):
        raise SystemExit('renders differ in size')
    rows = []
    for y in range(h):
        kb, kw = black[y], white[y]
        line = bytearray(w * 4)
        for x in range(w):
            r0, g0, b0 = kb[x * bb], kb[x * bb + 1], kb[x * bb + 2]
            r1, g1, b1 = kw[x * bw], kw[x * bw + 1], kw[x * bw + 2]
            alpha = 255 - ((r1 - r0) + (g1 - g0) + (b1 - b0)) / 3
            alpha = max(0.0, min(255.0, alpha))
            o = x * 4
            if alpha > 0:
                k = 255 / alpha
                line[o] = min(255, round(r0 * k))
                line[o + 1] = min(255, round(g0 * k))
                line[o + 2] = min(255, round(b0 * k))
            line[o + 3] = round(alpha)
        rows.append(line)
    write_png(out, w, h, rows)


if __name__ == '__main__':
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    main(*sys.argv[1:])
