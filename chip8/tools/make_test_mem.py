#!/usr/bin/env python3
"""Assemble roms/test_mem.ch8 and roms/test_mem.flash.

usage: make_test_mem.py            (run from the project root)

Exercises the memory write sites no other ROM covers (see
tools/check_vcd_io.py `mem` mode, and bug3/REPORT.md for why each one is
suspect in the simulator):

  - 00E0 Clear edge: light pixel 0 (row at (0,0)) and pixel 2047 (row at
    (56,31)), clear, and expect an empty framebuffer apart from the ok
    marker.
  - FX33: BCD of V5 = 0xFE into [0x300..0x302], read back with F265 and
    checked as V0, V1, V2 = 2, 5, 4.
  - FX55/FX65: V0..V3 = 11 22 33 44 stored at 0x310, the registers
    zeroed with 6XNN, V4 = 0x55, reloaded with F365; every register
    V0..V3 (first and last element included) is checked, and V4 must be
    untouched by F365.  Then F065 from 0x314 must read 0 (F355 must not
    write past V3).

Each check is `3XNN` (skip if equal) followed by `2NNN fail`: the fail
subroutine draws an 8x1 marker at (VA, 20) and moves VA right by 8, so
every failing check leaves a visible marker and execution continues.
When all checks pass, the only lit pixels are the ok marker, an 8x1 row
at (28..35, 14).

The ok marker itself is drawn by a subroutine invoked with a success-
path `2NNN` call: `oksub` draws the marker, sets V9 = 0x88 and returns
with `00EE`; the caller checks V8 == 0x88, so a broken call_stack push
or pop (wrong return address) is caught by the stream check and by the
missing ok marker.
"""

BASE = 0x200
SCRATCH_BCD = 0x300
SCRATCH_REGS = 0x310

program = [
    # Clear edge
    ('00E0',), ('A', 'row'), ('6000',), ('D001',),
    ('6138',), ('621F',), ('D121',), ('00E0',),
    ('6A00',), ('6B14',),                      # fail marker cursor (VA, VB)
    # FX33
    ('65FE',), ('A', SCRATCH_BCD), ('F533',), ('F265',),
    ('3002',), ('2', 'fail'),
    ('3105',), ('2', 'fail'),
    ('3204',), ('2', 'fail'),
    # FX55 / FX65
    ('6011',), ('6122',), ('6233',), ('6344',),
    ('A', SCRATCH_REGS), ('F355',),
    ('6000',), ('6100',), ('6200',), ('6300',), ('6455',),
    ('F365',),
    ('3011',), ('2', 'fail'),
    ('3122',), ('2', 'fail'),
    ('3233',), ('2', 'fail'),
    ('3344',), ('2', 'fail'),
    ('3455',), ('2', 'fail'),
    # F355 must not have written past V3
    ('A', SCRATCH_REGS + 4), ('F065',),
    ('3000',), ('2', 'fail'),
    # ok marker via a success-path subroutine call/ret
    ('2', 'oksub'),
    ('3888',), ('2', 'fail'),                  # V8 == 0x88 set by oksub
    ('label', 'halt'), ('1', 'halt'),
    ('label', 'oksub'), ('A', 'row'), ('601C',), ('610E',), ('D011',),
    ('6888',), ('00EE',),                      # V8 := 0x88 (Vx = low nibble)
    ('label', 'fail'), ('A', 'row'), ('DAB1',), ('7A08',), ('00EE',),
    ('label', 'row'), ('byte', 0xFF),
]

labels, pc = {}, BASE
for item in program:
    if item[0] == 'label':
        labels[item[1]] = pc
    else:
        pc += 1 if item[0] == 'byte' else 2

code = bytearray()
for item in program:
    kind = item[0]
    if kind == 'label':
        continue
    if kind == 'byte':
        code.append(item[1])
        continue
    if len(item) == 1:
        word = int(kind, 16)
    else:
        target = item[1] if isinstance(item[1], int) else labels[item[1]]
        word = (int(kind, 16) << 12) | target
    code += word.to_bytes(2, 'big')

assert BASE + len(code) <= SCRATCH_BCD
open('roms/test_mem.ch8', 'wb').write(code)
flash = bytearray(4096)
flash[BASE:BASE + len(code)] = code
open('roms/test_mem.flash', 'wb').write(flash)
print(f'{len(code)} bytes; halt at {labels["halt"]:#05x}, fail at {labels["fail"]:#05x}, '
      f'row at {labels["row"]:#05x}')
