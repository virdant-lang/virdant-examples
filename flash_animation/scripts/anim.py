#!/usr/bin/env python3
"""Compile a LED animation script into SPI flash content.

Usage:
    python3 scripts/anim.py content/anim.txt
    python3 scripts/anim.py content/showcase.txt

Writes three files next to the input, named after its stem (for
content/showcase.txt: content/showcase.bin, .hex, and .expect):
    .bin     raw bytes, for `iceprog -o 0x40000 <stem>.bin`
    .hex     a $readmemh image for the Icarus testbench
    .expect  the expected LED transitions, derived by simulating
             the bytecode the same way the player runs it; the
             testbench checks the design against this file

Select which animation to build, simulate, and upload by pointing
the Makefile at it:

    make test ANIM=content/showcase.txt
    make upload-content ANIM=content/showcase.txt

Script format -- one command per line; '#' starts a comment:

    label:          define a jump target (a byte offset in the image)
    set PATTERN     light the LEDs given by PATTERN, e.g. 0b10101
    wait TICKS      hold for TICKS ticks; one tick is 2^17 clock
                    cycles, about 10.9 ms at 12 MHz
    pause SECONDS   hold for SECONDS, from 0.25 to 1.00 in 0.25 s
                    steps (0.25, 0.5, 0.75, 1, ...)
    jump LABEL      continue executing at LABEL
    halt            freeze the LEDs

PATTERN is a 5-bit LED mask: bit 0 is LED 1, bit 4 is LED 5.
Binary (0b...), hexadecimal (0x...), and decimal literals all work.

The image begins with the magic byte 0x56 ('V'), which the player
checks at boot; without it the board runs its built-in demo.  Byte
offsets (and so jump targets) count from the magic: the first
instruction sits at offset 1.
"""

import sys
from pathlib import Path

MAGIC = 0x56

OP_HALT = 0x00
OP_SET = 0x01
OP_WAIT = 0x02
OP_JUMP = 0x03
OP_PAUSE = 0x04

# Clock cycles the player counts for each unit of delay,
# matching the RTL (src/anim.vir): 2^17 per tick, a
# quarter-second per pause step at the 12 MHz system clock.
CYCLES_PER_TICK = 2 ** 17
CYCLES_PER_QUARTER = 3_000_000

# Encoded size of each command, in bytes.
SIZE = {"set": 2, "wait": 2, "pause": 2, "jump": 3, "halt": 1}

SOURCE = "anim.txt"


def fail(lineno, message):
    print(f"{SOURCE}:{lineno}: error: {message}", file=sys.stderr)
    sys.exit(1)


def parse_value(lineno, text, limit, what):
    try:
        value = int(text, 0)
    except ValueError:
        fail(lineno, f"{what} must be an integer, not {text!r}")
    if not 0 <= value <= limit:
        fail(lineno, f"{what} must be between 0 and {limit}, not {value}")
    return value


def parse_quarters(lineno, text):
    """Parse a pause length in seconds into quarter-seconds, 1 to 4."""
    try:
        seconds = float(text)
    except ValueError:
        fail(lineno, f"pause must be a number of seconds, not {text!r}")
    quarters = seconds * 4
    if quarters != int(quarters) or not 1 <= quarters <= 4:
        fail(lineno, "pause must be 0.25 to 1.00 seconds in 0.25 s steps")
    return int(quarters)


def assemble(text):
    """Return the assembled image as a list of bytes."""
    # Pass 1: parse the commands and assign byte offsets.  The magic
    # byte occupies offset 0, so the program starts at offset 1.
    program = []
    labels = {}
    addr = 1
    for lineno, raw in enumerate(text.splitlines(), start=1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        head = parts[0]
        if head.endswith(":"):
            if len(parts) != 1:
                fail(lineno, "a label must be alone on its line")
            name = head[:-1]
            if name in labels:
                fail(lineno, f"label {name!r} is defined twice")
            labels[name] = addr
        elif head in SIZE:
            if head == "set" and len(parts) == 2:
                program.append((lineno, head, [parse_value(lineno, parts[1], 31, "pattern")]))
            elif head == "wait" and len(parts) == 2:
                program.append((lineno, head, [parse_value(lineno, parts[1], 255, "ticks")]))
            elif head == "pause" and len(parts) == 2:
                program.append((lineno, head, [parse_quarters(lineno, parts[1])]))
            elif head == "jump" and len(parts) == 2:
                program.append((lineno, head, [parts[1]]))
            elif head == "halt" and len(parts) == 1:
                program.append((lineno, head, []))
            else:
                fail(lineno, f"wrong arguments for {head!r}")
            addr += SIZE[head]
        else:
            fail(lineno, f"unknown command {head!r}")

    # Pass 2: emit bytes, resolving labels to offsets.
    data = [MAGIC]
    for lineno, op, args in program:
        if op == "halt":
            data.append(OP_HALT)
        elif op == "set":
            data += [OP_SET, args[0]]
        elif op == "wait":
            data += [OP_WAIT, args[0]]
        elif op == "pause":
            data += [OP_PAUSE, args[0]]
        elif op == "jump":
            target = labels.get(args[0])
            if target is None:
                fail(lineno, f"unknown label {args[0]!r}")
            data += [OP_JUMP, target & 0xFF, target >> 8]
    return data


def simulate(data):
    """Walk the image the way the player does and record the LED
    transitions of one full show: (pattern, gap) pairs, where gap
    is the clock cycles from the previous transition to this one.

    The walk starts at offset 1 with the LEDs dark (their power-up
    state).  When the program counter revisits an offset the loop
    has closed; the walk then continues until the next transition
    fires and records it too, so the testbench can prove that the
    show repeats -- with the gap the repeat actually takes.  A
    program that halts (or runs off the image) yields just the
    transitions up to that point.
    """
    transitions = []
    pattern = 0      # the LEDs' power-up state: all dark
    gap = 0          # cycles accumulated since the previous transition
    pc = 1
    transitions_at = {}   # offset -> len(transitions) when first run
    wrap_pc = None         # the offset where the loop closed
    loop_len = 0
    while 1 <= pc < len(data):
        if wrap_pc is None:
            if pc in transitions_at:
                wrap_pc = pc
                loop_len = len(transitions)
            else:
                transitions_at[pc] = len(transitions)
        elif pc == wrap_pc:
            # A whole extra period with no new transition: the
            # LEDs will not change again.
            return transitions
        op = data[pc]
        if op == OP_SET:
            new = data[pc + 1]
            if new != pattern:
                transitions.append((new, gap))
                pattern = new
                gap = 0
                if wrap_pc is not None and len(transitions) > loop_len:
                    # The transition that proves the loop, carrying
                    # the gap the wrapped show really takes.
                    return transitions
            pc += 2
        elif op == OP_WAIT:
            gap += data[pc + 1] * CYCLES_PER_TICK
            pc += 2
        elif op == OP_PAUSE:
            gap += data[pc + 1] * CYCLES_PER_QUARTER
            pc += 2
        elif op == OP_JUMP:
            pc = data[pc + 1] | (data[pc + 2] << 8)
        else:
            # Halt, or an unknown opcode (which halts the player).
            return transitions
    return transitions


def write_expect(path, transitions):
    """Write the expected transitions as $readmemh words: a count,
    then (pattern, gap) pairs, all 32 bits wide."""
    words = [len(transitions)]
    for pattern, gap in transitions:
        words += [pattern, gap]
    path.write_text("".join(f"{word:08x}\n" for word in words))


def main():
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} ANIM_TXT", file=sys.stderr)
        sys.exit(1)

    source = Path(sys.argv[1])
    global SOURCE
    SOURCE = source.name
    data = assemble(source.read_text())
    transitions = simulate(data)

    stem = source.stem
    bin_path = source.with_name(f"{stem}.bin")
    hex_path = source.with_name(f"{stem}.hex")
    expect_path = source.with_name(f"{stem}.expect")
    bin_path.write_bytes(bytes(data))
    hex_path.write_text("".join(f"{byte:02x}\n" for byte in data))
    write_expect(expect_path, transitions)

    print(f"wrote {bin_path}, {hex_path}, {expect_path} "
          f"({len(data)} bytes, {len(transitions)} LED transitions)")
    print(f"program it with: iceprog -o 0x40000 {bin_path}")


if __name__ == "__main__":
    main()
