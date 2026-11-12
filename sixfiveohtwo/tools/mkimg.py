#!/usr/bin/env python3
"""Assemble the Fomu flash image: bitstream at $00000, program at $080000.

Foboot's DFU download goes to flash offset 0, so the uploaded image
must carry the new bitstream AND the program image the boot ROM reads
at $080000. The program's reset vector is patched to $0200 (where the
boot ROM releases the CPU), matching tools/mkflash.py.

Warning: uploading replaces the Foboot bitstream -- the board's
USB/DFU bootloader stops working until re-flashed with an external SPI
programmer.

Usage: mkimg.py <bitstream.bin> <program.bin> <output.img>
"""

import sys

PROGRAM_OFFSET = 0x80000


def main():
    bitstream_path, program_path, out_path = sys.argv[1:4]
    with open(bitstream_path, 'rb') as f:
        bitstream = f.read()
    with open(program_path, 'rb') as f:
        program = bytearray(f.read())
    if len(program) != 65536:
        sys.exit(f"program image must be 64K, got {len(program)} bytes")
    program[0xFFFC] = 0x00
    program[0xFFFD] = 0x02

    image = bytearray(PROGRAM_OFFSET)
    image[:len(bitstream)] = bitstream
    image += program
    with open(out_path, 'wb') as f:
        f.write(image)
    print(f"wrote {out_path}: bitstream {len(bitstream)} bytes, "
          f"program 64K at ${PROGRAM_OFFSET:x}, total {len(image)} bytes")


main()
