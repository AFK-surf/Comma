#!/usr/bin/env python3
"""Reproducible, synthetic PNG test data. No downloaded media or image-library dependency."""
from pathlib import Path
import struct
import zlib

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'app/src/fixtures/res/drawable-nodpi'
SIZES = [(640, 640), (960, 540), (540, 960), (1024, 256), (256, 1024)]


def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    for index in range(25):
        width, height = SIZES[index % len(SIZES)]
        rows = bytearray()
        for y in range(height):
            rows.append(0)
            for x in range(width):
                tile = ((x // 48) + (y // 48) + index) % 2
                rows.extend(((x * 191 // width + index * 19) % 256,
                             (y * 181 // height + index * 31) % 256, 72 + tile * 120))
        header = struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)
        png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', header) + chunk(b'IDAT', zlib.compress(rows, 9)) + chunk(b'IEND', b'')
        (OUTPUT / f'fixture_image_{index + 1:02d}.png').write_bytes(png)


if __name__ == '__main__':
    main()
