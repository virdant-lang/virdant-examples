#!/usr/bin/env python3
"""Golden model for the Life design: LFSR mirror, B3/S23, VT100 render.

This mirrors three pieces of `src/life.vir` and `src/render.vir`
bit-for-bit:

    - the 64-bit Fibonacci LFSR (taps at degrees 64, 63, 61, 60,
      fixed seed 1) that seeds the grid on `randomize`;
    - the B3/S23 rule stepped on an 8x8 torus;
    - the VT100 frame layout: an optional clear-screen/hide-cursor
      preamble (boot frame only), 16 terminal rows of zoomed grid
      (rows 3..18, columns 33..48), and a one-line status readout
      (row 22).  (The help line in the original plan was cut to
      clear the phase-3 synthesis gate -- see `src/render.vir`.)

Usage:
    python3 scripts/life.py                 # print the boot frame
    python3 scripts/life.py --generations 3  # step and print 3 frames

This is a reference / documentation tool.  `verilog/tb.sv` validates
the real hardware a different way: it parses the grid back out of
actual rendered frames and cross-checks an independent B3/S23 torus
stepper against the live UART output, which does not require
replicating the LFSR's exact free-running cycle count in two
languages at once.
"""

import argparse
import sys

SEED = 1

# Taps at degrees 64, 63, 61, 60 (0-indexed bit positions 63, 62, 60, 59).
TAPS = (63, 62, 60, 59)


def lfsr_step(value):
    """One shift-left-with-feedback step of the 64-bit Fibonacci LFSR."""
    feedback = 0
    for tap in TAPS:
        feedback ^= (value >> tap) & 1
    return ((value << 1) | feedback) & 0xFFFFFFFFFFFFFFFF


def seed_grid(lfsr_value):
    """Bit i of `lfsr_value` seeds cell i (bit y*8+x = cell (x, y))."""
    return [(lfsr_value >> i) & 1 for i in range(64)]


def step_generation(grid):
    """One B3/S23 generation on the 8x8 torus; `grid` is a 64-list,
    index y*8 + x = cell (x, y)."""
    def at(x, y):
        return grid[(y % 8) * 8 + (x % 8)]

    new_grid = [0] * 64
    for y in range(8):
        for x in range(8):
            n = (
                at(x - 1, y - 1) + at(x, y - 1) + at(x + 1, y - 1)
                + at(x - 1, y) + at(x + 1, y)
                + at(x - 1, y + 1) + at(x, y + 1) + at(x + 1, y + 1)
            )
            alive = grid[y * 8 + x]
            new_grid[y * 8 + x] = 1 if (n == 3 or (alive and n == 2)) else 0
    return new_grid


def bcd_digits(generation):
    """Four BCD digits (thousands, hundreds, tens, ones) for a
    generation count 0..9999, matching `LifeBlock`'s wraparound."""
    g = generation % 10000
    return (g // 1000) % 10, (g // 100) % 10, (g // 10) % 10, g % 10


def render_frame(grid, running, speed_level, generation, first_frame):
    """The exact byte sequence `Vt100Renderer` emits for one frame."""
    out = bytearray()

    if first_frame:
        out += b"\x1b[2J"       # clear screen
        out += b"\x1b[?25l"     # hide cursor

    for row in range(16):
        term_row = row + 3
        out += f"\x1b[{term_row:02d};33H".encode("ascii")
        grid_row = row // 2
        for col in range(8):
            ch = b"#" if grid[grid_row * 8 + col] else b" "
            out += ch + ch

    out += b"\x1b[22;1H"
    out += b"R" if running else b"P"
    out += b" SPEED:"
    out += f"{speed_level:X}".encode("ascii")
    out += b" GEN:"
    thousands, hundreds, tens, ones = bcd_digits(generation)
    out += f"{thousands}{hundreds}{tens}{ones}".encode("ascii")

    return bytes(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", type=lambda s: int(s, 0), default=SEED,
                         help="64-bit LFSR seed (default: 1, matching the RTL)")
    parser.add_argument("--shifts", type=int, default=1,
                         help="LFSR shifts applied before the boot randomize "
                              "(default: 1, matching the RTL's reset timing)")
    parser.add_argument("--generations", type=int, default=0,
                         help="additional generations to step and print")
    parser.add_argument("--speed-level", type=int, default=8)
    parser.add_argument("--running", action="store_true")
    args = parser.parse_args()

    lfsr = args.seed
    for _ in range(args.shifts):
        lfsr = lfsr_step(lfsr)

    grid = seed_grid(lfsr)
    generation = 0

    frame = render_frame(grid, args.running, args.speed_level, generation,
                          first_frame=True)
    sys.stdout.buffer.write(frame)
    sys.stdout.write("\n")

    for _ in range(args.generations):
        grid = step_generation(grid)
        generation += 1
        frame = render_frame(grid, args.running, args.speed_level, generation,
                              first_frame=False)
        sys.stdout.buffer.write(frame)
        sys.stdout.write("\n")


if __name__ == "__main__":
    main()
