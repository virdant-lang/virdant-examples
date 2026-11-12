#!/usr/bin/env python3
"""Convert a 64K program image into the two 16-bit-word hex files the
Fomu memory model preloads.

The memory is two 16K x 16 arrays: the low half ($0000-$7FFF) and the
high half ($8000-$FFFF). Word at byte address A (even) = {byte[A+1],
byte[A]} (big-endian word).

Usage: mkspram.py <program.bin> <out_lo.hex> <out_hi.hex>
"""

import sys


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        return 1
    data = open(sys.argv[1], "rb").read()
    if len(data) != 0x10000:
        print(f"expected a 65536-byte image, got {len(data)}", file=sys.stderr)
        return 1
    lo = [int.from_bytes(data[2 * i:2 * i + 2], "big") for i in range(8192)]
    hi = [int.from_bytes(data[0x8000 + 2 * i:0x8000 + 2 * i + 2], "big")
          for i in range(8192)]
    # pad to the full 16384 words per array
    lo += [0] * (16384 - len(lo))
    hi += [0] * (16384 - len(hi))
    with open(sys.argv[2], "w") as f:
        f.writelines(f"{w:04x}\n" for w in lo)
    with open(sys.argv[3], "w") as f:
        f.writelines(f"{w:04x}\n" for w in hi)
    return 0


if __name__ == "__main__":
    sys.exit(main())