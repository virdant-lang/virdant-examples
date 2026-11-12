#!/usr/bin/env python3
"""Convert a 64K program image into the sparse SPI-flash hex the boot
testbench preloads.

The Fomu flash layout: the bitstream (padded to 256 KiB) at 0x40000,
the program image at 0x80000. This emits only the program region.

Usage: mkflash.py <program.bin> <out.hex>
"""

import sys


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 1
    data = bytearray(open(sys.argv[1], "rb").read())
    if len(data) != 0x10000:
        print(f"expected a 65536-byte image, got {len(data)}", file=sys.stderr)
        return 1
    # Patch the reset vector to $0200 (the smoke-test code origin): the
    # CPU fetches it from RAM after the boot ROM copies the image.
    data[0xFFFC] = 0x00
    data[0xFFFD] = 0x02
    with open(sys.argv[2], "w") as f:
        f.write("@080000\n")
        for i in range(0, len(data), 16):
            row = data[i:i + 16]
            f.write(" ".join(f"{b:02x}" for b in row) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())