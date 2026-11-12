#!/usr/bin/env python3
"""Differential check: reference 6502 (documented ISA, functional) vs the
DUT debug trace over the Klaus functional-test image.

Compares (pc, a, x, y) at every opcode fetch.

Usage: diffklaus.py <klaus.hex> <trace.txt>
"""

import sys


def load_image(path):
    data = open(path).read().split()
    mem = [0] * 65536
    i = 0
    base = 0
    while i < len(data):
        tok = data[i]
        if tok.startswith("@"):
            base = int(tok[1:], 16)
            i += 1
            continue
        mem[base] = int(tok, 16)
        base += 1
        i += 1
    # the tb patches the reset vector to $0400
    mem[0xFFFC] = 0x00
    mem[0xFFFD] = 0x04
    return mem


def parse_trace(path):
    dut = []
    for ln in open(path).read().splitlines():
        f = {}
        for p in ln.split()[1:]:
            k, v = p.split("=", 1)
            f[k] = v
        st = f["st"]
        if st[-8:] == "00000001":
            dut.append((int(f["pc"], 16), int(f["a"], 16),
                        int(f["x"], 16), int(f["y"], 16)))
    return dut


def run(mem, n):
    C = Z = I = D = V = N = 0
    I = 1
    A = X = Y = 0
    SP = 0xFD
    pc = mem[0xFFFC] | mem[0xFFFD] << 8
    trace = []

    def fetch(a):
        return mem[a & 0xFFFF]

    def push(v):
        nonlocal SP
        mem[0x100 + SP] = v & 0xFF
        SP = (SP - 1) & 0xFF

    def pop():
        nonlocal SP
        SP = (SP + 1) & 0xFF
        return mem[0x100 + SP]

    def setnz(v):
        nonlocal N, Z
        N = 1 if v & 0x80 else 0
        Z = 1 if (v & 0xFF) == 0 else 0

    def imm():
        nonlocal pc
        v = fetch(pc)
        pc = (pc + 1) & 0xFFFF
        return v

    def zp():
        return fetch(fetch(pc) if False else fetch(imm()))

    def zpx():
        nonlocal pc
        b = fetch(pc)
        pc = (pc + 1) & 0xFFFF
        return fetch((b + X) & 0xFF)

    def zpy():
        nonlocal pc
        b = fetch(pc)
        pc = (pc + 1) & 0xFFFF
        return fetch((b + Y) & 0xFF)

    def abso():
        nonlocal pc
        lo = fetch(pc)
        hi = fetch((pc + 1) & 0xFFFF)
        pc = (pc + 2) & 0xFFFF
        return lo | hi << 8

    def absx():
        return (abso() + X) & 0xFFFF

    def absy():
        return (abso() + Y) & 0xFFFF

    def ipx():
        nonlocal pc
        b = fetch(pc)
        pc = (pc + 1) & 0xFFFF
        pa = (b + X) & 0xFF
        return fetch(pa) | fetch((pa + 1) & 0xFF) << 8

    def ipy():
        nonlocal pc
        b = fetch(pc)
        pc = (pc + 1) & 0xFFFF
        pa = b
        return (fetch(pa) | fetch((pa + 1) & 0xFF) << 8) + Y & 0xFFFF

    def ind():
        p = abso()
        lo = fetch(p)
        hi = fetch((p & 0xFF00) | ((p + 1) & 0xFF))
        return lo | hi << 8

    while len(trace) < n:
        trace.append((pc, A, X, Y))
        op = fetch(pc)
        pc = (pc + 1) & 0xFFFF
        if op == 0x00:
            pc = (pc + 1) & 0xFFFF
            push((pc >> 8) & 0xFF)
            push(pc & 0xFF)
            push(N << 7 | V << 6 | 0x20 | 0x10 | D << 3 | I << 2 | Z << 1 | C)
            I = 1
            pc = fetch(0xFFFE) | fetch(0xFFFF) << 8
            continue
        if op == 0x40:
            p = pop()
            N = (p >> 7) & 1
            V = (p >> 6) & 1
            D = (p >> 3) & 1
            I = (p >> 2) & 1
            Z = (p >> 1) & 1
            C = p & 1
            lo = pop()
            hi = pop()
            pc = lo | hi << 8
            continue
        if op == 0x20:  # JSR
            lo = fetch(pc)
            hi = fetch((pc + 1) & 0xFFFF)
            ret = (pc + 1) & 0xFFFF
            push((ret >> 8) & 0xFF)
            push(ret & 0xFF)
            pc = lo | hi << 8
            continue
        if op == 0x60:  # RTS
            lo = pop()
            hi = pop()
            pc = ((lo | hi << 8) + 1) & 0xFFFF
            continue
        if op == 0x48:  # PHA
            push(A)
            continue
        if op == 0x68:  # PLA
            A = pop()
            setnz(A)
            continue
        if op == 0x08:  # PHP
            push(N << 7 | V << 6 | 0x20 | 0x10 | D << 3 | I << 2 | Z << 1 | C)
            continue
        if op == 0x28:  # PLP
            p = pop()
            N = (p >> 7) & 1
            V = (p >> 6) & 1
            D = (p >> 3) & 1
            I = (p >> 2) & 1
            Z = (p >> 1) & 1
            C = p & 1
            continue
        if op in (0x4C, 0x6C):  # JMP
            pc = ind() if op == 0x6C else abso()
            continue
        if op == 0x18:
            C = 0
            continue
        if op == 0x38:
            C = 1
            continue
        if op == 0x58:
            I = 0
            continue
        if op == 0x78:
            I = 1
            continue
        if op == 0xB8:
            V = 0
            continue
        if op == 0xD8:
            D = 0
            continue
        if op == 0xF8:
            D = 1
            continue
        if op == 0xAA:
            X = A
            setnz(X)
            continue
        if op == 0xA8:
            Y = A
            setnz(Y)
            continue
        if op == 0x8A:
            A = X
            setnz(A)
            continue
        if op == 0x98:
            A = Y
            setnz(A)
            continue
        if op == 0xBA:
            X = SP
            setnz(X)
            continue
        if op == 0x9A:  # TXS
            SP = X
            continue
        if op == 0xE8:
            X = (X + 1) & 0xFF
            setnz(X)
            continue
        if op == 0xC8:
            Y = (Y + 1) & 0xFF
            setnz(Y)
            continue
        if op == 0xCA:
            X = (X - 1) & 0xFF
            setnz(X)
            continue
        if op == 0x88:
            Y = (Y - 1) & 0xFF
            setnz(Y)
            continue
        if op == 0xEA:
            continue
        # branches
        if op in (0x10, 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0, 0xF0):
            off = imm()
            cond = {0x10: not N, 0x30: N, 0x50: not V, 0x70: V,
                    0x90: not C, 0xB0: C, 0xD0: not Z, 0xF0: Z}[op]
            if cond:
                pc = (pc + ((off ^ 0x80) - 0x80)) & 0xFFFF
            continue
        # addressing: 6502 = aaabbbcc
        cc = op & 0x03
        bbb = (op >> 2) & 0x07
        addr = None
        if cc == 0x01:
            if bbb == 0:
                addr = ("mem", ipx())
            elif bbb == 1:
                addr = ("mem", zp())
            elif bbb == 2:
                addr = ("imm", imm())
            elif bbb == 3:
                addr = ("mem", abso())
            elif bbb == 4:
                addr = ("mem", ipy())
            elif bbb == 5:
                addr = ("mem", zpx())
            elif bbb == 6:
                addr = ("mem", absy())
            else:
                addr = ("mem", absx())
        elif cc == 0x02:
            if bbb == 0:
                addr = ("imm", imm())
            elif bbb == 1:
                addr = ("mem", zp())
            elif bbb == 3:
                addr = ("mem", abso())
            elif bbb == 5:
                addr = ("mem", zpy())
            elif bbb == 7:
                addr = ("mem", absy())
        elif cc == 0x00:
            if bbb == 0 and (op & 0x1F) == 0x00:
                addr = ("imm", imm())  # LDY/CPY/CPX immediate
            elif bbb == 1:
                addr = ("mem", zp())
            elif bbb == 2:
                addr = ("acc", None)  # acc-mode shifts
            elif bbb == 3:
                addr = ("mem", abso())
            elif bbb == 5:
                addr = ("mem", zpx())
            elif bbb == 7:
                addr = ("mem", absx())
        val = None
        target = None
        if addr:
            kind, a = addr
            if kind == "imm":
                val = a
            elif kind == "mem":
                val = fetch(a)
                target = a
        if op in (0x85, 0x95, 0x8D, 0x9D, 0x99, 0x81, 0x91):
            mem[target] = A
            continue
        if op in (0x86, 0x96, 0x8E):
            mem[target] = X
            continue
        if op in (0x84, 0x94, 0x8C):
            mem[target] = Y
            continue
        if op in (0x24, 0x2C):  # BIT
            Z = 1 if (A & val) == 0 else 0
            N = (val >> 7) & 1
            V = (val >> 6) & 1
            continue
        if op in (0xA9, 0xA5, 0xB5, 0xAD, 0xBD, 0xB9, 0xA1, 0xB1):
            A = val
            setnz(A)
            continue
        if op in (0xA2, 0xA6, 0xB6, 0xAE, 0xBE):
            X = val
            setnz(X)
            continue
        if op in (0xA0, 0xA4, 0xB4, 0xAC, 0xBC):
            Y = val
            setnz(Y)
            continue
        if op in (0x06, 0x0A, 0x0E, 0x16, 0x1E):  # ASL
            v = val if addr and addr[0] == "mem" else A
            c = (v >> 7) & 1
            r = (v << 1) & 0xFF
            if target is not None:
                mem[target] = r
            else:
                A = r
            setnz(r)
            C = c
            continue
        if op in (0x46, 0x4A, 0x4E, 0x56, 0x5E):  # LSR
            v = val if addr and addr[0] == "mem" else A
            c = v & 1
            r = v >> 1
            if target is not None:
                mem[target] = r
            else:
                A = r
            setnz(r)
            C = c
            continue
        if op in (0x26, 0x2A, 0x2E, 0x36, 0x3E):  # ROL
            v = val if addr and addr[0] == "mem" else A
            c = (v >> 7) & 1
            r = ((v << 1) | C) & 0xFF
            if target is not None:
                mem[target] = r
            else:
                A = r
            setnz(r)
            C = c
            continue
        if op in (0x66, 0x6A, 0x6E, 0x76, 0x7E):  # ROR
            v = val if addr and addr[0] == "mem" else A
            c = v & 1
            r = (v >> 1) | (C << 7)
            if target is not None:
                mem[target] = r
            else:
                A = r
            setnz(r)
            C = c
            continue
        if op in (0xE6, 0xF6, 0xEE, 0xFE):  # INC
            mem[target] = (val + 1) & 0xFF
            setnz(mem[target])
            continue
        if op in (0xC6, 0xD6, 0xCE, 0xDE):  # DEC
            mem[target] = (val - 1) & 0xFF
            setnz(mem[target])
            continue
        # ALU ops
        if op in (0x09, 0x05, 0x15, 0x0D, 0x1D, 0x19, 0x01, 0x11):  # ORA
            A |= val
            setnz(A)
            continue
        if op in (0x29, 0x25, 0x35, 0x2D, 0x3D, 0x39, 0x21, 0x31):  # AND
            A &= val
            setnz(A)
            continue
        if op in (0x49, 0x45, 0x55, 0x4D, 0x5D, 0x59, 0x41, 0x51):  # EOR
            A ^= val
            setnz(A)
            continue
        if op in (0x69, 0x65, 0x75, 0x6D, 0x7D, 0x79, 0x61, 0x71):  # ADC
            s = A + val + C
            V = 1 if (~(A ^ val) & (A ^ s) & 0x80) else 0
            A = s & 0xFF
            C = 1 if s > 0xFF else 0
            setnz(A)
            continue
        if op in (0xE9, 0xE5, 0xF5, 0xED, 0xFD, 0xF9, 0xE1, 0xF1):  # SBC
            s = A + (~val & 0xFF) + C
            V = 1 if ((A ^ val) & (A ^ s) & 0x80) else 0
            A = s & 0xFF
            C = 1 if s > 0xFF else 0
            setnz(A)
            continue
        if op in (0xC9, 0xC5, 0xD5, 0xCD, 0xDD, 0xD9, 0xC1, 0xD1):  # CMP
            s = A + (~val & 0xFF) + 1
            C = 1 if s > 0xFF else 0
            setnz(s & 0xFF)
            continue
        if op in (0xE0, 0xE4, 0xEC):  # CPX
            s = X + (~val & 0xFF) + 1
            C = 1 if s > 0xFF else 0
            setnz(s & 0xFF)
            continue
        if op in (0xC0, 0xC4, 0xCC):  # CPY
            s = Y + (~val & 0xFF) + 1
            C = 1 if s > 0xFF else 0
            setnz(s & 0xFF)
            continue
        print(f"UNKNOWN OP {op:02X} at pc={pc - 1:04X}")
        break
    return trace


def main():
    mem = load_image(sys.argv[1])
    dut = parse_trace(sys.argv[2])
    ref = run(mem, len(dut))
    bad = 0
    for i, (r, d) in enumerate(zip(ref, dut)):
        if r != d:
            print(f"MISMATCH at fetch #{i}: ref=(pc={r[0]:04X} a={r[1]:02X} "
                  f"x={r[2]:02X} y={r[3]:02X}) "
                  f"dut=(pc={d[0]:04X} a={d[1]:02X} x={d[2]:02X} y={d[3]:02X})")
            bad += 1
            if bad > 3:
                break
    if bad == 0:
        print(f"DIFF OK: {len(ref)} fetches agree")
    else:
        print(f"{bad} mismatches (of {len(ref)} compared)")


if __name__ == "__main__":
    main()