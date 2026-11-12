#!/usr/bin/env python3
"""Build a CHIP-8 .flash image (4 KiB SPI flash for the loader) from a
.ch8 program.

usage: make_flash.py <program.ch8> [<output.flash>]

Layout matches what the hardware expects (see src/flash_loader.vir and
src/chip8.vir):

  0x000..0x04F  the classic 16-glyph x 5-byte font.  FX29 computes the
                glyph address as 5 * Vx, so the font MUST live at 0x000.
                Baking it into the image also keeps that region from
                being simulator garbage at boot.
  0x050..0x1FF  unused (0xFF)
  0x200..       the program

The loader streams all 4096 bytes into main memory before raising
load_done, and the core starts fetching at pc = 0x200.
"""

import sys

FONT = bytes([
    0xF0, 0x90, 0x90, 0x90, 0xF0,  # 0
    0x20, 0x60, 0x20, 0x20, 0x70,  # 1
    0xF0, 0x10, 0xF0, 0x80, 0xF0,  # 2
    0xF0, 0x10, 0xF0, 0x10, 0xF0,  # 3
    0x90, 0x90, 0xF0, 0x10, 0x10,  # 4
    0xF0, 0x80, 0xF0, 0x10, 0xF0,  # 5
    0xF0, 0x80, 0xF0, 0x90, 0xF0,  # 6
    0xF0, 0x10, 0x20, 0x40, 0x40,  # 7
    0xF0, 0x90, 0xF0, 0x90, 0xF0,  # 8
    0xF0, 0x90, 0xF0, 0x10, 0xF0,  # 9
    0xF0, 0x90, 0xF0, 0x90, 0x90,  # A
    0xE0, 0x90, 0xE0, 0x90, 0xE0,  # B
    0xF0, 0x80, 0x80, 0x80, 0xF0,  # C
    0xE0, 0x90, 0x90, 0x90, 0xE0,  # D
    0xF0, 0x80, 0xF0, 0x80, 0xF0,  # E
    0xF0, 0x80, 0xF0, 0x80, 0x80,  # F
])

BASE = 0x200

def main():
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    src = sys.argv[1]
    dst = sys.argv[2] if len(sys.argv) == 3 else src.rsplit('.', 1)[0] + '.flash'
    code = open(src, 'rb').read()
    if BASE + len(code) > 4096:
        sys.exit(f'{src}: program is {len(code)} bytes; does not fit above 0x200')
    flash = bytearray(b'\xff' * 4096)
    flash[:len(FONT)] = FONT
    flash[BASE:BASE + len(code)] = code
    open(dst, 'wb').write(flash)
    print(f'{src} ({len(code)} bytes) -> {dst}')

if __name__ == '__main__':
    main()
