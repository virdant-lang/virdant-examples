#!/usr/bin/env python3
"""Convert a flat binary image into a Verilog $readmemh hex file.

Usage: mkhex.py <image.bin> [<origin-hex>]

The image is the complete 64K memory contents. With no origin, the
whole image is emitted from address 0. With an origin, only the bytes
from the origin onward are emitted, prefixed with an @origin directive
(so the image can overlay a default-filled memory).
"""

import sys


def main() -> int:
    if len(sys.argv) not in (2, 3):
        print(__doc__, file=sys.stderr)
        return 1
    path = sys.argv[1]
    data = open(path, "rb").read()
    origin = 0
    if len(sys.argv) == 3:
        origin = int(sys.argv[2], 16)
        data = data[origin:]
    print(f"@{origin:04X}")
    for i in range(0, len(data), 16):
        row = data[i:i + 16]
        print(" ".join(f"{b:02x}" for b in row))
    return 0


if __name__ == "__main__":
    sys.exit(main())