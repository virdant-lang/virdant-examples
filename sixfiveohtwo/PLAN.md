# PLAN — NMOS 6502 CPU in Virdant (`sixfiveohtwo`)

A fully-featured NMOS 6502 (all 151 documented opcodes, decimal mode,
interrupts) in idiomatic Virdant, verified with self-checking smoke tests per
stage and Klaus Dormann's functional test as the final gate.

## Locked-in decisions

1. **Accuracy**: functional correctness only — no cycle-exactness, no
   dummy-bus-cycle emulation.
2. **Fidelity**: fully faithful NMOS quirks —
   - JMP (ind) page-wrap bug (high byte of pointer never increments),
   - B-flag push semantics (BRK pushes B=1, IRQ/NMI push B=0),
   - NMOS decimal-mode flag model (Bruce Clark; SBC flags come from the
     binary subtract, only result and C are decimal).
3. **Staging**: 7 fine-grained stages (below), each ending green
   (`vir check` clean + passing smoke test) before the next.
4. **Verification**: self-checking ca65 test programs (pass marker + distinct
   failure codes per check) each stage; Klaus Dormann
   `6502_functional_test.bin` as the final gate only.
5. **Layout**: self-contained `sixfiveohtwo/` subproject, not wired into the
   repo's root `make test`.
6. **Code shape**: decode logic inlined in `core.vir` (no Decoder submodule);
   ALU stays its own module.
7. **Bus**: async-read real-chip style (see socket below).
8. **Assembler**: `ca65`/`ld65` (V2.18, installed) → flat bin → hex for
   `$readmemh` via `tools/mkhex.py` (or `xxd`).

## Project layout

```
sixfiveohtwo/
  Virdant.toml          top = "top::Top"
  Makefile              check / build / asm / tb-sN / klaus targets
  tb.sv                 64K async RAM, reset driver, marker/failure-code monitor,
                        hierarchical-peek debug support, Klaus loader mode
  src/
    types.vir           enum type Instruction, AddressingMode, AluOp; socket Bus
    alu.vir             mod Alu — Or/And/Xor/Adc/Sbc/Pass (+ decimal in S7)
    core.vir            union type CpuState (grows per stage) + mod Core:
                        registers, inline 256-entry decode match (illegal→NOP),
                        bus driver match, one driver block per register
    top.vir             export mod Top wrapping Core
  asm/                  s1.s … s7.s ca65 sources + shared conventions include
  tools/mkhex.py        bin → $readmemh hex
  klaus/                fetched 6502_functional_test.bin (64K flat image)
```

## Bus contract

Async-read memory (like the real 6502): the CPU drives `addr` combinationally
from state; `data` must be valid in the same cycle. Writes commit at the
rising edge when `write = @Valid(data)`; `write = @Invalid()` means read.

```virdant
socket Bus {
    cosi addr  : Word[16]
    cosi write : Valid[Word[8]]
    soci data  : Word[8]
}
```

Interrupt pins on Top: `irq_n`, `nmi_n` (active-low `Bit`). IRQ is
level-sensitive, NMI is edge-triggered (falling edge).

## Stages

| # | Adds | New CpuState states | Gate |
|---|---|---|---|
| S1 | LDA/LDX/LDY, STA/STX/STY (imm/zp/abs), transfers, flag ops, INX/INY/DEX/DEY, NOP | FetchOpcode, FetchOperand, FetchLow, FetchHigh, Access | smoke s1 |
| S2 | 6 indexed modes, 8 branches | ReadPointerLow/High | smoke s2 |
| S3 | ORA/AND/EOR/ADC/SBC/CMP/CPX/CPY/BIT (binary) | — (ALU wired in) | smoke s3 |
| S4 | PHA/PLA/PHP/PLP, JMP abs + JMP (ind) wrap bug, JSR/RTS | PushValue, PullAccumulator, PullProcessorStatus, PullPcLow/High, PushPcHigh/Low (push path shared with S6) | smoke s4 |
| S5 | RMW: ASL/LSR/ROL/ROR (acc+mem), INC/DEC mem | WriteModified (+`operand_latch`) | smoke s5 |
| S6 | BRK, RTI, NMI (edge), IRQ (level), interrupt hijack | PushStatusInterrupt, FetchVectorLow/High, NMI detect regs | smoke s6 (vector $FFFA/$FFFE, B-flag on stack, I-masking, RTI resume) |
| S7 | Decimal ADC/SBC (NMOS model) | — | smoke s7, then **Klaus functional test full pass** |

Per-stage loop: `vir check` → `vir build` → `ca65+ld65` → hex →
`iverilog build/*.sv tb.sv` → run → pass marker.

The `CpuState` union, enums, and decode table grow strictly per stage so
matches stay exhaustive with zero warnings throughout.

## CPU state machine (`union type CpuState`)

```virdant
union type CpuState {
    FetchOpcode()
    FetchOperand()                             // imm operand | rel offset | zp base byte
    FetchLow()                                 // abs low byte at PC
    FetchHigh()                                // abs high byte at PC
    ReadPointerLow(pointer_addr : Word[16])    // (zp,X)/(zp),Y/JMP(ind): ptr low
    ReadPointerHigh(pointer_addr : Word[16])   // ptr high
    Access(addr : Word[16])                    // load / store / RMW-read
    WriteModified(addr : Word[16])             // RMW write-back
    PushValue()                                // PHA/PHP (value from instr match)
    PushPcHigh(software : Bit)                 // JSR/BRK/IRQ/NMI: push PC hi
    PushPcLow(software : Bit)                  // push PC lo
    PushStatusInterrupt(software : Bit)        // push P (B=software), set I
    PullAccumulator()                          // PLA
    PullProcessorStatus()                      // PLP/RTI: pull P
    PullPcLow()                                // RTS/RTI
    PullPcHigh()                               // RTS/RTI (+1 for RTS)
    FetchVectorLow(vector_addr : Word[16])     // reset/IRQ/NMI vector lo
    FetchVectorHigh(vector_addr : Word[16])    // vector hi
}
```

Not cycle-exact vs the real chip (functional correctness is the bar; document
this in the module docstring).

Key per-state edge behavior:

- **reset**: `state <= @FetchVectorLow(0xFFFCw16)`, `sp <= 0xFD`, `flag_i <=
  true`, other flags false, `a/x/y <= 0`. (PC comes from the vector fetch.)
- **FetchOpcode**: bus addr = PC.
  - Interrupt hijack (`nmi_pending || (irq && !flag_i)`): `ir <= 0x00`
    (BRK-forcing trick), **PC held**, `serving_nmi <= nmi_pending`,
    `nmi_pending <= false`, `state <= @PushPcHigh(false)`.
  - BRK (opcode 00): `ir <= bus.data`, `pc <= pc + 2` (skips padding byte),
    `state <= @PushPcHigh(true)`.
  - JSR (20): `state <= @FetchLow()` (push happens mid-sequence).
  - PHA/PHP → `@PushValue()`; PLA → `@PullAccumulator()`; PLP →
    `@PullProcessorStatus()`; RTS → `@PullPcLow()`; RTI →
    `@PullProcessorStatus()`.
  - Implied/Accumulator mode → execute inline at this edge,
    `state <= @FetchOpcode()`.
  - Immediate/Relative/ZeroPage*/IndirectX/IndirectY → `@FetchOperand()`.
  - Absolute/AbsoluteX/AbsoluteY/Indirect → `@FetchLow()`.
  - Else (normal): `ir <= bus.data`, `pc <= pc + 1`, state per decoded mode.
- **FetchOperand**: bus addr = PC; `pc <= pc + 1`; by mode:
  - Immediate → execute with `bus.data` → `@FetchOpcode()`.
  - Relative → if taken: `pc <= pc + 1 + sext(bus.data)` → `@FetchOpcode()`.
  - ZeroPage → `@Access(word(0w8, bus.data))`;
    ZeroPageX → `@Access(word(0w8, bus.data + x))`;
    ZeroPageY → `@Access(word(0w8, bus.data + y))`.
  - IndirectX → `@ReadPointerLow(word(0w8, bus.data + x))` (8-bit wrap).
  - IndirectY → `@ReadPointerLow(word(0w8, bus.data))`.
- **FetchLow**: bus addr = PC; `addr_low <= bus.data`; `pc <= pc + 1`;
  JSR → `@PushPcHigh(false)`; else → `@FetchHigh()`.
  (For JSR: pc = opcode+2 = address of the high byte = the value JSR pushes;
  RTS later adds 1.)
- **FetchHigh**: bus addr = PC; `pc <= pc + 1` (overwritten for JMP/JSR); by mode:
  - Absolute: JMP/JSR → `pc <= word(bus.data, addr_low)`, `@FetchOpcode()`;
    else → `@Access(word(bus.data, addr_low))`.
  - AbsoluteX → `@Access(word(bus.data, addr_low) + zext(x))` (full 16-bit add).
  - AbsoluteY → same with `zext(y)`.
  - Indirect (JMP) → `@ReadPointerLow(word(bus.data, addr_low))`.
- **ReadPointerLow(addr)**: `addr_low <= bus.data`; next:
  - Indirect → `@ReadPointerHigh(word(addr[16..8], addr[8..0] + 1))`
    — NMOS page-wrap bug (high byte unchanged).
  - IndirectX/IndirectY → `@ReadPointerHigh(word(0x01w8, addr[8..0] + 1))`.
- **ReadPointerHigh(addr)**: effective = `word(bus.data, addr_low)`:
  - Indirect (JMP) → `pc <= effective`, `@FetchOpcode()`.
  - IndirectX → `@Access(effective)`.
  - IndirectY → `@Access(effective + zext(y))`.
- **Access(addr)**: bus addr = addr.
  - store (`writes_memory`) → `bus.write = @Valid(store_value)` (A/X/Y per
    STA/STX/STY); write commits at this edge → `@FetchOpcode()`.
  - RMW → `operand_latch <= bus.data` → `@WriteModified(addr)`.
  - read (`reads_operand`) → execute with `bus.data` at this edge →
    `@FetchOpcode()`.
- **WriteModified(addr)**: bus write = `@Valid(modified)` computed from
  `operand_latch`; flags update at this edge → `@FetchOpcode()`.
- **PushValue()**: addr = `word(0x01w8, sp)`, write = `@Valid(a)` for PHA /
  `@Valid(status)` for PHP; `sp <= sp - 1` → `@FetchOpcode()`.
- **PushPcHigh/PushPcLow(software)**: addr = `word(0x01w8, sp)`,
  write = `@Valid(pc[15..8])` / `@Valid(pc[8..0])`; `sp <= sp - 1`;
  PushPcHigh → `@PushPcLow(software)`; PushPcLow → JSR: `@FetchHigh()`,
  else `@PushStatusInterrupt(software)`.
- **PushStatusInterrupt(software)**: write =
  `@Valid(word(n, v, true, software, d, i, z, c))` (bit5 always 1; B =
  software: BRK pushes 1, IRQ/NMI push 0); `sp <= sp - 1`; `flag_i <= true` →
  `@FetchVectorLow(mux(serving_nmi, 0xFFFAw16, 0xFFFEw16))`.
- **PullAccumulator**: addr = `word(0x01w8, sp + 1)`; `a <= bus.data`, NZ from
  it; `sp <= sp + 1` → `@FetchOpcode()`.
- **PullProcessorStatus**: addr = `word(0x01w8, sp + 1)`; flags <= bus.data
  bits (n=v=d=i=z=c; ignore bits 4,5); `sp <= sp + 1` → PLP:
  `@FetchOpcode()`; RTI: `@PullPcLow()`.
- **PullPcLow/PullPcHigh**: addr = `word(0x01w8, sp + 1)`; PullPcLow:
  `addr_low <= bus.data`, `sp <= sp + 1` → `@PullPcHigh()`. PullPcHigh:
  `sp <= sp + 1`, `pc <= word(bus.data, addr_low) + mux(instruction == #Rts, 1, 0)`
  → `@FetchOpcode()`.
- **FetchVectorLow(addr)**: `addr_low <= bus.data` → `@FetchVectorHigh(addr + 1)`.
- **FetchVectorHigh(addr)**: `pc <= word(bus.data, addr_low)` → `@FetchOpcode()`.

Status byte: bit7 N, 6 V, 5 (always 1), 4 B (always 1 on PHP; software on
interrupt push; ignored on PLP/RTI), 3 D, 2 I, 1 Z, 0 C.

## Registers & helper wires (`mod Core`)

Registers: `pc : Word[16]`, `ir : Word[8]`, `a/x/y/sp : Word[8]`,
`addr_low : Word[8]` (reused by FetchLow, ReadPointerLow, FetchVectorLow),
`operand_latch : Word[8]` (RMW), `flag_n/v/d/i/z/c : Bit` (one reg each),
`state : CpuState`, `nmi_prev/nmi_pending/serving_nmi : Bit`.

- NMI edge detector: `nmi_pending <= (nmi_pending && !committed) ||
  (!nmi_active && nmi_prev_active)`; cleared at hijack commit (`serving_nmi`
  set there, vector selected from `serving_nmi`).
- Decode mux: during FetchOpcode the fresh opcode is on `bus.data`, `ir` is
  stale until the edge. Feed the decoder:
  `decode_opcode := mux(is_fetching_opcode, bus.data, ir)`.
- State-classification wires: `is_fetching_opcode`, `is_fetching_operand`,
  `is_fetching_low`, `is_fetching_high`, `is_reading_pointer`,
  `is_accessing_memory`, `is_writing_modified`, `is_pushing`, `is_pulling`,
  `is_fetching_vector`.
- Stack addr wires: `stack_push_addr := word(0x01w8, sp)`,
  `stack_pull_addr := word(0x01w8, sp + 1)`.
- The `client socket bus of Bus` driver: `addr` = big match on `state`;
  `write` = match per above (`@Invalid()` default).
- Execution gating: `immediate_execute := is_fetching_operand && mode ==
  #Immediate`, `memory_execute := is_accessing_memory && reads_operand`.
- ALU instantiation: `op` from instruction match (Ora→#Or, And, Eor, Adc, Sbc,
  Cmp/Cpx/Cpy→#Sbc with left operand x/y, Lda/Ldx/Ldy→#Pass),
  `carry_in := flag_c`, `decimal := flag_d`, right = `bus.data`.
  CMP/CPX/CPY consume only flags (C, NZ) — result unused.
- BIT is special: Z=(a&operand)==0, N=operand[7], V=operand[6].

## ALU & decimal mode (NMOS semantics)

Binary: ADC: 9-bit sum, C=sum[8], V=(a7==b7)&&(r7!=a7), N=r7, Z=(r==0).
SBC: same with `~b`; C = no-borrow.

**Decimal ADC (NMOS)** — result & carry decimal; N/V from the intermediate
high-nibble sum; Z from the final BCD result (Bruce Clark model):

```
low = (a & 0F) + (b & 0F) + c              // 5-bit
low_carry = low >= 10
low_adj = low + 6 if low_carry
high = (a & F0) + (b & F0) + (low_carry ? 10 : 0)   // 9-bit
N = high[7]; V = (a7 == b7) && (high[7] != a7)
carry = high >= A0
result = ((carry ? high + 60 : high) & F0) | (low_adj & 0F)
Z = result == 0
```

**Decimal SBC (NMOS)** — all flags from the binary subtraction; only the
result and C are decimal:

```
bin = a + ~b + c (9-bit)  → N, V, Z from bin
low = (a & 0F) - (b & 0F) - !c      // signed, Word[6]
if low < 0: low -= 6 and borrow into high
high = (a & F0) - (b & F0) - (borrow ? 10 : 0)   // signed, Word[9]
if high < 0: high -= 60, carry = 0 else carry = 1
result = (high & F0) | (low & 0F)
```

Sanity checks: 00−01 (c=1) → 99, C=0; 50−25 → 25, C=1.
Add a `//` comment in alu.vir citing the chosen model (NMOS, not CMOS which
fixes flags to the BCD result). Result+C correctness matters most for real
software.

## Opcode table (151 documented opcodes, verified)

| Instr | imm | zp | zp,X | zp,Y | abs | abs,X | abs,Y | (zp,X) | (zp),Y | acc | impl |
|---|---|---|---|---|---|---|---|---|---|---|---|
| ADC | 69 | 65 | 75 | – | 6D | 7D | 79 | 61 | 71 | – | – |
| AND | 29 | 25 | 35 | – | 2D | 3D | 39 | 21 | 31 | – | – |
| ASL | – | 06 | 16 | – | 0E | 1E | – | – | – | 0A | – |
| CMP | C9 | C5 | D5 | – | CD | DD | D9 | C1 | D1 | – | – |
| EOR | 49 | 45 | 55 | – | 4D | 5D | 59 | 41 | 51 | – | – |
| LDA | A9 | A5 | B5 | – | AD | BD | B9 | A1 | B1 | – | – |
| LDX | A2 | A6 | – | B6 | AE | – | BE | – | – | – | – |
| LDY | A0 | A4 | B4 | – | AC | BC | – | – | – | – | – |
| ORA | 09 | 05 | 15 | – | 0D | 1D | 19 | 01 | 11 | – | – |
| SBC | E9 | E5 | F5 | – | ED | FD | F9 | E1 | F1 | – | – |
| STA | – | 85 | 95 | – | 8D | 9D | 99 | 81 | 91 | – | – |
| CPX | E0 | E4 | – | – | EC | – | – | – | – | – | – |
| CPY | C0 | C4 | – | – | CC | – | – | – | – | – | – |
| DEC | – | C6 | D6 | – | CE | DE | – | – | – | – | – |
| INC | – | E6 | F6 | – | EE | FE | – | – | – | – | – |
| LSR | – | 46 | 56 | – | 4E | 5E | – | – | – | 4A | – |
| ROL | – | 26 | 36 | – | 2E | 3E | – | – | – | 2A | – |
| ROR | – | 66 | 76 | – | 6E | 7E | – | – | – | 6A | – |
| BIT | – | 24 | – | – | 2C | – | – | – | – | – | – |
| STX | – | 86 | – | 96 | 8E | – | – | – | – | – | – |
| STY | – | 84 | 94 | – | 8C | – | – | – | – | – | – |

Implied-mode opcodes (single-byte):

```
CLC 18   SEC 38   CLI 58   SEI 78   CLV B8   CLD D8   SED F8
PHP 08   PLP 28   PHA 48   PLA 68
TAY A8   TAX AA   TSX BA   TYA 98
DEY 88   TXA 8A   TXS 9A
INX E8   INY C8   DEX CA   NOP EA
```

Special-flow opcodes: `BRK 00` (hijacks into the interrupt sequence with
`pc <= pc + 2` and B=1 pushed), `JSR 20` (abs), `JMP 4C` (abs), `JMP 6C`
(ind), `RTS 60`, `RTI 40`.

Branches (relative): `BPL 10 (N=0), BMI 30 (N=1), BVC 50 (V=0), BVS 70 (V=1),
BCC 90 (C=0), BCS B0 (C=1), BNE D0 (Z=0), BEQ F0 (Z=1)`.

Undocumented opcodes → behave as NOP (never JAM).

## Klaus gate mechanics (verified)

- Shipped `6502_functional_test.bin` is a full 64K image (65,536 bytes);
  tb loads it as flat memory, patches reset vector to `$0400` (our CPU
  fetches the vector; the test expects a monitor-set PC).
- With `report=0`, all traps and success are self-loops (`jmp *`): success =
  PC parked at the shipped build's known success address (confirm the exact
  value — expected `$3469` — from the shipped `.lst` at implementation time);
  failure = any other parked PC or timeout.
- tb `$finish`es on detection; cycle cap ~200M as backstop (functional-only
  timing makes the count differ from real-chip figures).

## Virdant rules (non-negotiables while coding)

- No or-patterns (`case #A | #B` illegal — one pattern per arm, repeat arms).
- No `fn` — factor shared logic into wires or submodules.
- Top-exclusive slices: `x[8..2]` = bits 7..2. Shifts via
  `word(a[7..1], 0w1)` / `word(0w1, a[8..1])`. No `<<`/`>>`.
- Statement-level `case … when/match` chaining without `=>`.
- Avoid `==` on enums/unions — use `match`; enum↔Word via `cast()`.
- Decode feeds from `mux(is_fetching_opcode, bus.data, ir)`.
- `bus.addr` never combinationally depends on `bus.data`
  (combinational-cycle check).
- Driver blocks: hold by omission, never `it <= it`; no empty arms
  (`tests/warnings/empty_driver_block.vir` is a warning case); unused →
  `unused`; `dontcare` patterns OK, `dontcare` payloads avoided (use
  explicit values).
- `//>` doc comments, 4-space indent, camelCase types/modules, snake_case
  everything else.
- Never run formatters without asking; leave the repo root `make test`
  untouched.

## Open items to verify while coding

- `dontcare` as a constructor payload (`@PushPcHigh(dontcare)`) — unverified;
  if it fails, pass `false`/`0` instead.
- Virdant regs presumably start at 0 in Verilog sim; tb holds `reset` high
  for the first posedge regardless.
- iverilog performance during the Klaus run — use success detection with an
  early `$finish` and a cycle cap.
- Socket channel port names in generated Verilog — check `build/*.sv` after
  `vir build` when wiring the tb.

## Implementation status (updated at completion)

All seven stages implemented and green:

| Stage | Smoke test | Result |
|---|---|---|
| S1 loads/stores/transfers/flags | s1 | PASS |
| S2 indexed modes + branches | s2 | PASS |
| S3 ALU ops (binary) | s3 | PASS |
| S4 stack + JSR/RTS/JMP | s4 | PASS |
| S5 RMW shifts + INC/DEC | s5 | PASS |
| S6 BRK/RTI/NMI/IRQ | s6 | PASS |
| S7 decimal mode | s7 | PASS |

Final gate: **Klaus Dormann functional test PASSED** — the CPU reaches
the success loop at `$3469` after 76,758,978 cycles (see
`klaus/README.md`).

## Compiler quirks discovered while coding (beyond the rules above)

- **Struct literal vs projection mismatch**: `${ a = x, b = y }` packs
  fields declaration-order MSB-first, but `->field` projection reads
  the first field from the LSB end — the two disagree. Avoided structs
  entirely (two parallel decode matches, kept in sync).
- **Empty `when` arms are silently optimized away** — a hold-by-empty-arm
  (the interrupt hijack PC hold) compiled to nothing and the next arm
  fired. Fix: exclude the hold case from the neighboring arm's condition
  instead of relying on an empty arm.
- `types::#Variant` is a syntax error; enum variants are always bare
  `#Variant` (resolved through the import).
- A `match` expression as a direct `&&`/`||` operand needs parentheses.
- Bit indexing: single-bit index valid range is 0..W-1 (MSB of Word[8]
  is `[7]`), while slices are top-exclusive (`x[8..0]` = the full byte).
- `//>` doc comments are illegal between match arms; plain `//` is fine.
- Enum variants require an `= expr` value.
- (zp,X)/(zp),Y pointer-high address must wrap **within page zero**:
  `word(0w8, ptr[8..0] + 1w8)` — the HANDOFF's `word(0x01w8, ...)` was
  a typo (it would read page one).
- The `iverilog` on PATH needs `-g2012` for `void'(...)` and other SV.
- NMI edge detect: falling edge = `!nmi_n && nmi_prev` (low now, high
  before); `serving_nmi` must be cleared at the vector-fetch high edge
  so a later BRK uses `$FFFE` again.
- ALU outputs needed a dedicated `nz_source`/`negative` split for the
  NMOS decimal flag model (SBC: N/V/Z strictly from the binary
  subtract; ADC: N from the intermediate high sum, Z from the BCD
  result).
