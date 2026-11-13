#!/usr/bin/env python3
"""Convert a 64K program image into the SPI-flash hex the Fomu boot
flows preload (models/build/flash_image.hex).

The Fomu flash layout: the bitstream (padded to 256 KiB) at 0x40000,
the program image at 0x80000. The native flash model
(models/src/models.vir) takes a flat hex image, one byte per line, so
the $080000 offset is expressed by that many leading zero bytes.

Usage: mkflash.py <program.bin> <out.hex>
"""

import os
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
    os.makedirs(os.path.dirname(sys.argv[2]) or ".", exist_ok=True)
    with open(sys.argv[2], "w") as f:
        # The program lives at flash offset $080000: that many zero
        # bytes, then the 64K image.
        f.write("00\n" * 0x080000)
        for b in data:
            f.write(f"{b:02x}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
