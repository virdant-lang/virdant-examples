#!/usr/bin/env python3
"""Convert a smoke-test expectation file into the binary format the
testbench consumes.

Input format (one directive per line, '#' starts a comment):
  M <addr-hex> <byte-hex>   wait until the program stores <byte> at <addr>
  F <flag> <0|1>            check a CPU flag (N Z C V D I)
  R <reg> <hex>             check a register (A X Y S=SP P=PC)
  C <addr-hex> <byte-hex>   compare memory

Output record format (hex text, one byte per line for $readmemh):
type(1), lineno(2 BE), args
  0x01 marker: addr(2 BE), byte(1)
  0x02 flag:   letter(1), value(1)
  0x03 reg:    letter(1), value(2 BE)
  0x04 memcmp: addr(2 BE), byte(1)
  0x05 pin:    letter(1: I=irq_n N=nmi_n), level(1)
Terminated by a final 0xFF byte.
"""

import sys


def parse(path):
    out = bytearray()
    with open(path) as f:
        for lineno, raw in enumerate(f, 1):
            line = raw.split("#")[0].strip()
            if not line:
                continue
            parts = line.split()
            t = parts[0].upper()
            if t == "M":
                addr = int(parts[1], 16)
                val = int(parts[2], 16)
                out += bytes([1]) + lineno.to_bytes(2, "big")
                out += addr.to_bytes(2, "big") + bytes([val])
            elif t == "F":
                letter = parts[1].encode()
                val = int(parts[2])
                out += bytes([2]) + lineno.to_bytes(2, "big")
                out += letter + bytes([val])
            elif t == "R":
                letter = parts[1].encode()
                val = int(parts[2], 16)
                out += bytes([3]) + lineno.to_bytes(2, "big")
                out += letter + val.to_bytes(2, "big")
            elif t == "P":
                letter = parts[1].encode()
                val = int(parts[2])
                out += bytes([5]) + lineno.to_bytes(2, "big")
                out += letter + bytes([val])
            elif t == "C":
                addr = int(parts[1], 16)
                val = int(parts[2], 16)
                out += bytes([4]) + lineno.to_bytes(2, "big")
                out += addr.to_bytes(2, "big") + bytes([val])
            else:
                sys.exit(f"{path}:{lineno}: unknown type {t!r}")
    return out


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 1
    with open(sys.argv[2], "w") as f:
        for b in parse(sys.argv[1]) + b"\xff":
            f.write(f"{b:02x}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())