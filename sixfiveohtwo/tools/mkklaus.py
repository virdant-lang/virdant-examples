#!/usr/bin/env python3
"""Convert the Klaus Dormann 6502 functional test image into a
Verilog $readmemh hex file.

Usage: mkklaus.py <image.bin>

The image is the complete 64K memory contents, emitted from address 0
with an @0000 directive, 16 bytes per line.
"""

import sys


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 1
    path = sys.argv[1]
    data = open(path, "rb").read()
    if len(data) != 0x10000:
        print(f"expected 65536-byte image, got {len(data)} bytes",
              file=sys.stderr)
        return 1
    print("@0000")
    for i in range(0, len(data), 16):
        row = data[i:i + 16]
        print(" ".join(f"{b:02x}" for b in row))
    return 0


if __name__ == "__main__":
    sys.exit(main())
