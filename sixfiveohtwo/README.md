# sixfiveohtwo — an NMOS 6502 CPU in Virdant

A complete, fully-faithful NMOS MOS 6502 central processing unit written in
[Virdant](https://virdant.org), a modern hardware description language. The
core implements **all 151 documented opcodes**, **NMOS decimal (BCD) mode**
with its exact flag semantics, and the **full interrupt system** (IRQ, NMI,
BRK, RTI, and the interrupt-hijack behavior), verified to pass **Klaus
Dormann's 6502 functional test** — the de-facto industry acceptance test for
6502 implementations.

```
+----------------------------------------------------------------+
|  Status: COMPLETE                                              |
|    - 151/151 documented opcodes                                |
|    - 7/7 stage smoke tests green (671 expectation records)     |
|    - Klaus Dormann functional test: PASSED                     |
|      (success loop $3469 reached after 76,758,978 cycles)      |
|    - vir check: clean, zero warnings                           |
+----------------------------------------------------------------+
```

---

## Table of contents

1. [What this is](#1-what-this-is)
2. [Quick start](#2-quick-start)
3. [Project layout](#3-project-layout)
4. [Toolchain](#4-toolchain)
5. [Design overview](#5-design-overview)
6. [The bus contract](#6-the-bus-contract)
7. [Module by module](#7-module-by-module)
8. [The state machine](#8-the-state-machine)
9. [Registers and flags](#9-registers-and-flags)
10. [Decode](#10-decode)
11. [The ALU: binary and decimal](#11-the-alu-binary-and-decimal)
12. [Interrupts](#12-interrupts)
13. [Faithfully implemented NMOS quirks](#13-faithfully-implemented-nmos-quirks)
14. [What is *not* implemented](#14-what-is-not-implemented)
15. [Verification strategy](#15-verification-strategy)
16. [The smoke tests](#16-the-smoke-tests)
17. [The expectation protocol](#17-the-expectation-protocol)
18. [The differential checker](#18-the-differential-checker)
19. [The Klaus Dormann gate](#19-the-klaus-dormann-gate)
20. [Debugging guide](#20-debugging-guide)
21. [Makefile reference](#21-makefile-reference)
22. [Tool scripts](#22-tool-scripts)
23. [Virdant language notes and compiler quirks](#23-virdant-language-notes-and-compiler-quirks)
24. [Design decisions and their rationale](#24-design-decisions-and-their-rationale)
25. [Ideas for future work](#25-ideas-for-future-work)

---

## 1. What this is

This project answers one question: *can you write a real, complete, correct
CPU in Virdant — idiomatically, with the compiler doing real work for you?*

The answer, it turns out, is yes, with some interesting discoveries along the
way (see section 23). The CPU is:

- **Complete** — every one of the 151 documented NMOS 6502 opcodes, across
  all 13 addressing modes, plus decimal mode and the interrupt system.
- **Faithful** — the famous NMOS hardware quirks are implemented *on purpose*
  and are observable: the `JMP (ind)` page-wrap bug, the B-flag push
  semantics (BRK pushes B=1, hardware interrupts push B=0), and the exact
  NMOS decimal-mode flag behavior (Bruce Clark's model).
- **Functional, not cycle-exact** — every instruction produces the same
  register, flag, and memory results as the real chip, and accesses memory
  in the same order, but the CPU does not reproduce the real chip's
  per-cycle bus activity (no dummy reads, no double-write on RMW, no fixed
  instruction timing). This was a deliberate scoping decision (section 24).
- **Idiomatic Virdant** — union-typed FSM states with payload-carrying
  variants, one driver block per register, sockets for the external bus, a
  separate combinational ALU module, and no structs (a compiler bug
  dictated that choice — sections 7 and 23).

Everything lives in a self-contained subproject (`sixfiveohtwo/`) inside the
Virdant compiler's repository; the project is *not* wired into the
repository's own `make test` — it stands alone with its own `Virdant.toml`,
`Makefile`, sources, tests, and tooling.

## 2. Quick start

```sh
cd sixfiveohtwo

# Typecheck (expect: "Check OK", zero warnings)
vir check

# Generate Verilog into build/
vir build

# Run all seven smoke tests (assembles + simulates each)
make test

# Run a single stage's smoke test
make test-s3

# Klaus Dormann functional test (the acceptance gate)
make klaus            # build/klaus.hex from the 64K image
make klaus-run        # iverilog: SLOW — expect hours
# ...or the fast path (recommended):
verilator --binary --timing -Wno-fatal --top-module Tb -o run-klaus-vl \
    build/*.sv tb.sv
./obj_dir/run-klaus-vl +hex=build/klaus.hex +klaus=1
# expected final line:  Klaus functional test PASSED in 76758978 cycles
```

Note the `-g2012` flag: the testbench uses SystemVerilog constructs
(`void'(...)`, tasks with typed args) that iverilog's default `-g2005`
dialect rejects.

### On the Fomu board (hardware)

The same CPU also runs on the **Fomu PVT** (iCE40 UltraPlus) board: 64K of
memory on two `SB_SPRAM256KA` hard cells, a boot ROM that copies the program
from SPI flash at `$080000` into SPRAM at reset, and memory-mapped I/O at
`$FF00` (the RGB LED on writes, the touch pads on reads; touch1 → NMI,
touch2 → IRQ). All logic runs on a derived 6 MHz clock (the pad clock ÷ 8).

```sh
cd sixfiveohtwo

# Full-stack simulation: FomuTop (boot ROM + SPRAM + I/O) against the
# native flash model, running the hw1 LED/touch demo. No board needed.
make fomu-sim
# expected final line:  FOMU SIM PASS in 8389513 cycles

# Synthesis: yosys + nextpnr-ice40 + icepack, timing-checked
# (pad clock 48 MHz, derived system clock 6 MHz)
make fomu-build
# → build/sixfiveohtwo.bin      the bitstream

# The upload image: bitstream at $00000 + 64K program at $080000
make build/sixfiveohtwo.img
# → build/sixfiveohtwo.img      what actually gets uploaded

# Upload over USB (needs the board)
make fomu-upload
```

**What the upload does — and its one-way nature.** Foboot (the board's DFU
bootloader) downloads to flash offset 0, so the image must carry *both* the
new bitstream and the program image the boot ROM reads at `$080000`
(`tools/mkimg.py` assembles them and patches the program's reset vector to
`$0200`). Because the download lands at offset 0, uploading **replaces
Foboot's own bitstream**: this design holds the USB pins low, so afterwards
the board's USB and DFU are gone — the only way back is reflashing over SPI
with an external programmer (restore Foboot at `$00000`, or re-upload a
combined image with one). dfu-util may report `unable to read DFU status
after completion` when the board reboots into the new bitstream mid-poll:
that is *success*, not failure. If dfu-util instead reports `Permission
denied` (or lists nothing with `dfu-util -l`), install the udev rule the
repository ships: `./install-fomu-udev-rules.sh` from the repo root, then
unplug/replug the board and retry. (`vir upload` is not suitable here: it
uploads the bare bitstream and would not carry the program.)

**How to flash a different program.** Set `PROG` (default `hw1`): the Fomu
flows assemble `asm/$(PROG).s` — ordinary ca65/ld65 assemblies;
`asm/6502.cfg` emits a full 64K image with CODE at `$0200` — and use
`build/$(PROG).bin` as the program image:

```sh
make fomu-build                              # bitstream (once)
make fomu-upload PROG=myprog                 # assembles + flashes myprog
make fomu-sim   PROG=myprog                  # ...or simulate it first
```

The contract the boot ROM relies on:

- The program image is exactly 64K (`asm/6502.cfg` fills it).
- Execution starts at **`$0200`** (the boot ROM patches the reset vector
  there); install your own interrupt vectors at runtime — the boot ROM
  touches only `$FFFC`/`$FFFD`.
- Memory map: `$0000-$FFFF` RAM; `$FF00` I/O (write: LED byte, bit0 red /
  bit1 green / bit2 blue, set = on; read: touch pads in bits 3:0,
  active-low, 0 = pressed). Reads of `$FF00` return the *pads*, not the LED
  byte — keep your own LED shadow.
- Avoid `$0000-$000F` (boot scratch). See `asm/hw1.s` for a complete
  example.
- Expect ~175 ms of boot after power-up (1,048,576 SPI cycles at 3 MHz)
  before the CPU starts. For hw1: red lights at reset, touch1 toggles
  green, touch2 toggles blue.

## 3. Project layout

```
sixfiveohtwo/
  Virdant.toml              Virdant project manifest (top = "fomu_top::FomuTop")
  Makefile                  check / build / asm / smoke-test / klaus /
                            fomu-sim / fomu-build / upload-image targets
  PLAN.md                   the design plan: decisions, staging, state
                            machine spec, opcode table, compiler quirks
  README.md                 this file
  tb.sv                     the generic SystemVerilog testbench (283 lines)
  tb-fomu.sv                the full-stack Fomu testbench (boot ROM +
                            SPRAM + I/O against the flash model)
  src/
    types.vir   (178 ln)    enum type Instruction (56 mnemonics), AluOp,
                            AddressingMode (13 modes); socket Bus
    alu.vir     (206 ln)    mod Alu: combinational, binary + NMOS decimal
    core.vir   (1495 ln)    union type CpuState (18 states) + mod Core:
                            the FSM, all registers, the inline decode
                            tables, the bus driver
    top.vir      (26 ln)    export mod Top: the CPU as a chip
    fomu_memory.vir         mod Memory: two ice40::SbSpram256ka hard cells
                            (one per 32K half) + byte-lane decode
    fomu_boot.vir           mod Boot: SPI boot ROM (flash $080000 -> RAM)
    fomu_io.vir             mod Io: the $FF00 LED/touch register, NMI/IRQ
    fomu_top.vir            export mod FomuTop for ice40::Fomu + BusBridge
                            + the ClkDiv ext mod (pad/8 system clock)
  ext/
    Spram.sv                the former Verilog SPRAM cell model — kept as
                            the differential reference for the native
                            rewrite (yosys supplies the cell itself)
    ClkDiv.sv               the registered divide-by-eight (sim + synthesis)
  models/
    virdant.toml            the native simulation models as their own
                            Virdant project (their Verilog must never
                            appear in the main build/ — yosys supplies
                            the SB_SPRAM256KA cell itself)
    src/models.vir          the ext/ memories rewritten natively with the
                            `memory` construct, same module names: Memory
                            (the 64K x 8 RAM), SB_SPRAM256KA (the SPRAM
                            cell), Flash (the SPI flash, image via
                            @image_hex)
    shim/sb_spram256ka_sim.sv
                            plain-name wrapper binding the emitted
                            \models::SB_SPRAM256KA to the SB_SPRAM256KA
                            cell instances fomu_memory.vir emits
    tb/                     differential testbenches: each native model
                            against the former ext/ Verilog model
  asm/
    README.md               smoke-test conventions (the contract every
                            test program and expectation file follows)
    6502.cfg                ca65/ld65 linker configuration (full 64K image)
    s1.s / s1.exp           stage 1: loads/stores/transfers/flags
    s2.s / s2.exp           stage 2: indexed modes + branches
    s3.s / s3.exp           stage 3: ALU ops (binary)
    s4.s / s4.exp           stage 4: stack + jumps
    s5.s / s5.exp           stage 5: read-modify-write
    s6.s / s6.exp           stage 6: interrupts
    s7.s / s7.exp           stage 7: decimal mode
    hw1.s / hw1.exp         the Fomu demo: LEDs, touch, interrupts
  tools/
    mkhex.py                flat binary -> $readmemh hex
    exp.py                  expectation text -> binary hex records
    mkklaus.py              Klaus 64K image -> hex
    diffklaus.py            differential checker (DUT vs Python reference)
    mkflash.py              64K program -> flat flash hex at $080000
                            (reset vector patched to $0200; the image the
                            native flash model loads via @image_hex)
    mkimg.py                bitstream + 64K program -> the upload image
  klaus/
    README.md               Klaus gate mechanics + the passing result
    6502_functional_test.bin  the test as a full 64K memory image
    6502_functional_test.lst  assembler listing (address cross-reference)
    6502_functional_test.a65  the test's assembly source (reference)
  build/                    generated Verilog + test artifacts (git-clean)
  obj_dir/                  Verilator build output (git-clean)
```

## 4. Toolchain

| Tool | Version / path | Role |
|---|---|---|
| `vir` | `~/.local/virdant/bin/vir` | the Virdant compiler (`check`, `build`) |
| `ca65` / `ld65` | V2.18 (system) | 6502 assembler/linker for the smoke tests |
| `iverilog` | `~/.local/iverilog/bin/iverilog` | simulator (use `-g2012`) |
| `verilator` | 5.038 (`~/.local/verilator/bin/verilator`) | fast simulator for the Klaus run |
| `python3` | system | test tooling |

Everything works from the `sixfiveohtwo/` directory. `vir` resolves the
multi-file project automatically: a file `src/foo.vir` is imported as
`import foo` and referenced as `foo::Name`.

## 5. Design overview

The design goals, in order:

1. **Correctness first.** Every documented instruction produces the real
   chip's registers/flags/memory effects.
2. **Simplicity of proof.** The FSM has exactly one state per bus
   transaction; each register has exactly one driver block; every
   expectation in every test is checked by an independent reference model
   before it is ever run against the hardware.
3. **Idiomatic Virdant.** The language's union types carry the FSM state
   (with payloads like the effective address), sockets express the bus,
   and driver blocks keep each register's clocked behavior in one place.
4. **Functional, not cycle-exact.** (Deliberate; see section 24.)

The resulting shape:

```
                 +------------------------------------------+
                 |                Top (top.vir)             |
   clock ------> |  incoming clock : Clock                  |
   reset ------> |  incoming reset : Bit                    |
   irq_n ------> |  incoming irq_n : Bit   (active-low)     |
   nmi_n ------> |  incoming nmi_n : Bit   (active-low)     |
                 |                                          |
                 |   client socket bus of types::Bus        |
                 |        ^                                 |
                 |        |  (bulk-connected)               |
                 |   mod cpu of core::Core                  |
                 |        - FSM state (union type)          |
                 |        - pc, ir, a, x, y, sp, ...        |
                 |        - inline 151-opcode decode        |
                 |        - mod math of alu::Alu            |
                 +------------------------------------------+
                       |            |            |
                 bus.addr     bus.write    bus.data
                 (Word[16])   (Valid[8])   (Word[8], same cycle)
```

The CPU executes roughly one bus transaction per state transition. Loads
take 2-7 cycles depending on addressing depth; the FSM sequences address
computation, pointer fetches, the memory access, and (for read-modify-write)
a second access — but the *number* of cycles is not guaranteed to match the
real chip's, and internal states exist purely for sequencing.

## 6. The bus contract

The external interface is a Virdant socket, defined in `src/types.vir`:

```virdant
socket Bus {
    cosi addr  : Word[16]
    cosi write : Valid[Word[8]]
    soci data  : Word[8]
}
```

- `cosi` = channels the **client** (the CPU) drives; `soci` = channels the
  **server** (memory) drives.
- `addr` is driven combinationally from the FSM state and registers — the
  CPU never waits for memory.
- `data` must be valid **in the same cycle** `addr` is driven (async-read
  memory, like the real 6502's bus). This makes the timing model
  "one wait state maximum" and keeps the FSM small.
- `write` is a `Valid[Word[8]]`: `@Invalid()` = read cycle; `@Valid(d)` =
  store cycle. **The store commits at the rising clock edge** — the testbench
  memory model does exactly this:

```systemverilog
    // Async read: data valid in the same cycle as addr.
    assign bus_data = mem[bus_addr];

    // Stores commit at the rising edge.
    always @(posedge clock) begin
        if (bus_write[8]) mem[bus_addr] <= bus_write[7:0];
    end
```

In generated Verilog, `Valid[Word[8]]` flattens to 9 bits: **bit 8 is the
valid tag**, bits 7..0 the payload. The socket channels flatten to escaped
Verilog port names (`\bus.addr `, `\bus.write `, `\bus.data `), which the
testbench connects positionally.

## 7. Module by module

### `src/types.vir` — shared types

- `enum type Instruction` — the 56 instruction mnemonics (each with a
  stable integer tag; values are arbitrary, not opcodes).
- `enum type AluOp` — `Or, And, Xor, Adc, Sbc, Pass`.
- `enum type AddressingMode` — all 13: `Implied, Immediate, ZeroPage,
  Absolute, ZeroPageX, ZeroPageY, AbsoluteX, AbsoluteY, IndirectX,
  IndirectY, Indirect, Relative, Accumulator`.
- `socket Bus` — above.

### `src/alu.vir` — `mod Alu`

Purely combinational. Inputs: `a` (accumulator/X/Y), `b` (always the bus
data), `op`, `carry_in`, `decimal` (the D flag). Outputs: `result` (the
write-back value), `nz_source` (the value Z is computed from),
`negative` (the value N is computed from), `carry`, `overflow`.

The two extra flag-source outputs exist because of NMOS decimal mode
(section 11): the result alone cannot express where N and Z come from.

### `src/core.vir` — `union type CpuState` + `mod Core`

The whole processor: state machine, all registers, the two inline decode
tables, the bus driver, the flag computation, the interrupt machinery.
No separate Decoder module — the decode match lives inside `Core` (see
section 24 for why).

### `src/top.vir` — `export mod Top`

The chip: four pins (`clock`, `reset`, `irq_n`, `nmi_n`) plus the client
`bus` socket. Instantiates `core::Core` and bulk-connects the socket
(`cpu.bus :=: bus`). In earlier stages the interrupt pins did not exist;
they were added with stage 6 to keep every intermediate state warning-free.

## 8. The state machine

The FSM state is a Virdant **union type** — 18 variants, several with
payloads:

```virdant
union type CpuState {
    FetchOpcode()                          // opcode at PC
    FetchOperand()                         // imm / rel / zp base byte
    FetchLow()                             // absolute address low byte
    FetchHigh()                            // absolute address high byte
    ReadPointerLow(pointer_addr : Word[16])   // (zp,X)/(zp),Y/JMP(ind)
    ReadPointerHigh(pointer_addr : Word[16])
    Access(addr : Word[16])                // load / store / RMW read
    WriteModified(addr : Word[16])         // RMW write-back
    PushValue()                            // PHA/PHP
    PushPcHigh(software : Bit)             // JSR/BRK/interrupt: push PC hi
    PushPcLow(software : Bit)              // push PC lo
    PushStatusInterrupt(software : Bit)    // push P, set I, choose vector
    PullAccumulator()                      // PLA
    PullProcessorStatus()                  // PLP (and RTI's P pull)
    PullPcLow()                            // RTS/RTI
    PullPcHigh()                           // RTS/RTI
    FetchVectorLow(vector_addr : Word[16]) // reset / IRQ / NMI vector
    FetchVectorHigh(vector_addr : Word[16])
}
```

The state register has one driver block whose arms are, in order:

1. **reset** → `@FetchVectorLow(0xFFFCw16)` (with `sp <= $FD`, `i <= 1`,
   `a/x/y/n/z/c/v/d <= 0` in their own driver blocks),
2. **else** → a `match it : CpuState` with one arm per state.

The payload variants keep *addresses* inside the state (e.g. the effective
address being accessed), so the bus driver is a pure `match state` with no
extra latching. The classification wires (`is_fetching_opcode`,
`is_accessing_memory`, `is_pushing`, ...) are tiny `match state` wires used
by the register drivers.

The most important timing subtlety: **during a FetchOpcode cycle the fresh
opcode is on `bus.data`, not yet in `ir`**. The decode is therefore fed by:

```virdant
wire decode_opcode : Word[8] {
    it := mux(is_fetching_opcode, bus.data, ir)
}
```

so that everything evaluated *at the fetch edge* (next-state dispatch, the
implied-instruction inline execution, BRK's `pc+2`) sees the new opcode,
while everything in later states sees the latched one.

### Per-state behavior summary

| State | Bus | At the clock edge |
|---|---|---|
| FetchOpcode | `addr = pc` | latch opcode into `ir`, `pc+1`, dispatch by decoded mode (or execute implied/Accumulator instructions inline); **interrupt hijack** may intercept (section 12) |
| FetchOperand | `addr = pc` | `pc+1`; Immediate → execute; Relative → take branch (`pc+1+sext(off)`); zp/zp,X/zp,Y → `@Access`; IndirectX/IndirectY → `@ReadPointerLow` |
| FetchLow | `addr = pc` | `addr_low <= data`, `pc+1`; JSR → `@PushPcHigh(false)`; else `@FetchHigh` |
| FetchHigh | `addr = pc` | `pc+1`; JMP/JSR abs → `pc <= word(hi, addr_low)`; Absolute → `@Access`; AbsoluteX/AbsoluteY → `@Access(+index)`; Indirect → `@ReadPointerLow` |
| ReadPointerLow | `addr = pointer_addr` | `addr_low <= data`; next pointer-high address: `JMP (ind)` uses `word(ptr[15:8], ptr[7:0]+1)` (the **page-wrap bug**), `(zp,X)`/`(zp),Y` wrap within page zero: `word(0, ptr[7:0]+1)` |
| ReadPointerHigh | `addr = pointer_addr+1` | effective = `word(data, addr_low)`; IndirectX → `@Access`; IndirectY → `@Access(+y)`; Indirect → `pc <= effective` |
| Access | `addr = payload` | store: `write = @Valid(A/X/Y)`; RMW: `operand_latch <= data`, `@WriteModified`; read: execute |
| WriteModified | `addr = payload` | `write = @Valid(rmw_result)`, flags from it, back to FetchOpcode |
| PushValue | `addr = $0100+sp` | `write = @Valid(PHA ? a : P)`, `sp-1` |
| PushPcHigh / PushPcLow | `addr = $0100+sp` | push `pc[15:8]` / `pc[7:0]`, `sp-1`; JSR returns to `@FetchHigh` (it still has the high operand byte to read), BRK/interrupt go to `@PushStatusInterrupt` |
| PushStatusInterrupt | `addr = $0100+sp` | push P with `B = software`, set `I`, → `@FetchVectorLow($FFFA if NMI else $FFFE)` |
| PullAccumulator | `addr = $0100+sp+1` | `a <= data` (+NZ), `sp+1` |
| PullProcessorStatus | `addr = $0100+sp+1` | flags from data bits 7,6,3,2,1,0 (bits 4,5 ignored), `sp+1`; PLP → FetchOpcode, RTI → `@PullPcLow` |
| PullPcLow / PullPcHigh | `addr = $0100+sp+1` | latch `addr_low` / `pc = word(data, addr_low) + (RTS ? 1 : 0)`, `sp+1` each |
| FetchVectorLow / High | `addr = vector` | latch / `pc <= word(data, addr_low)`; `serving_nmi` cleared at the high edge |

## 9. Registers and flags

Each is a `reg ... on clock` with exactly one driver block (arms are
first-match-wins):

| Register | Width | Notes |
|---|---|---|
| `pc` | Word[16] | incremented on all PC-consuming fetches; branch target, JMP/JSR/RTS/RTI targets, BRK's `pc+2`, the **hijack hold** (arm ordering matters — see section 23) |
| `ir` | Word[8] | latched at FetchOpcode; **forced to `0x00` on interrupt hijack** (the classic trick) |
| `a`, `x`, `y` | Word[8] | written by loads, ALU-A results, PLA, transfers, acc-mode shifts |
| `sp` | Word[8] | reset `$FD`; TXS writes it (no flags); TSX reads it |
| `addr_low` | Word[8] | scratch for FetchLow / ReadPointerLow / FetchVectorLow / PullPcLow |
| `operand_latch` | Word[8] | RMW operand between the Access and WriteModified states |
| `flag_n/z/c/v/d/i` | Bit | one register each |
| `state` | CpuState | the FSM |
| `nmi_prev` | Bit | previous-cycle `nmi_n` for edge detection |
| `nmi_pending` | Bit | latched falling NMI edge; cleared at the hijack |
| `serving_nmi` | Bit | which interrupt is being serviced; cleared at the vector-fetch high edge |

**The status byte** (`P`, as pushed by PHP/BRK/interrupts):
bit 7 N, 6 V, 5 always 1, 4 B (always 1 for PHP; `software` for
BRK/interrupt pushes; ignored by PLP/RTI), 3 D, 2 I, 1 Z, 0 C.

N/Z update paths (all funneled through `nz_write` / `nz_value` /
`negative`):
loads (imm or memory), implied transfers/increments, ALU results, PLA,
RMW write-backs, accumulator-mode shifts, and — special-cased — BIT
(`Z = (A & M) == 0`, `N = M[7]`, `V = M[6]`) and PLP (direct bit loads).

## 10. Decode

There is no Decoder module (section 24). Inside `Core`, the decode is
**two parallel 256-arm `match` expressions** over `decode_opcode`: one
producing the `Instruction`, one producing the `AddressingMode`. They are
adjacent and must be kept in sync (a comment says so). Unknown opcodes
decode as `#Nop / #Implied` — harmless one-cycle NOPs; the CPU never jams.

The class wires derived from the instruction:

- `reads_operand` — consumes a memory/immediate operand (loads + all ALU
  ops incl. compares + BIT): gates `memory_execute`.
- `writes_memory` — STA/STX/STY: gates the store side of `Access`.
- `is_rmw` — ASL/LSR/ROL/ROR/INC/DEC in non-Accumulator modes.
- `is_acc_shift` — the same mnemonics in Accumulator mode (execute inline
  at the fetch edge).
- `alu_execute`, `alu_carry_execute`, `alu_v_execute`, `bit_execute`,
  `mode_relative`, `branch_taken`, `implied_nz`, `load_nz` — execution and
  flag gating.

Execution happens on **two edges only** for memory data: the
`FetchOperand` edge (Immediate) and the `Access` edge (everything else).
The ALU instance is always active (`it.b := bus.data`), gated consumption
makes it correct.

## 11. The ALU: binary and decimal

### Binary mode

ADC: 9-bit sum `a + b + carry_in`; `C = sum[8]`,
`V = (a7 == b7) && (r7 != a7)`, N/Z from the 8-bit result.
SBC: the same sum with `~b`; `C` = no-borrow;
`V = (a7 != b7) && (r7 != a7)` — note the flipped sign condition versus
ADC. ORA/AND/EOR: bitwise; Pass: forwards `a` (unused by the core, kept
for the load path's shape).

### NMOS decimal mode (the D flag set)

Implemented exactly as Bruce Clark's model (the reference for NMOS BCD
behavior; the comment in `alu.vir` cites it):

**Decimal ADC** — the result and carry are decimal; N/V come from the
*intermediate high-nibble sum*, Z from the *final BCD result*:

```
low       = (a & $0F) + (b & $0F) + C           (5 bits)
low_carry = low >= 10
low_adj   = low_carry ? low + 6 : low
high      = (a & $F0) + (b & $F0) + (low_carry ? $10 : 0)   (9 bits)
N         = high[7]
V         = (a7 == b7) && (high[7] != a7)
C         = high >= $A0
result    = ((C ? high + $60 : high) & $F0) | (low_adj & $0F)
Z         = result == 0
```

**Decimal SBC** — **all of N, V, Z come from the binary subtract**; only
the result and C are decimal (this is the NMOS behavior; CMOS differs —
the comment in `alu.vir` says so):

```
bin       = a + (~b) + C                        (9 bits)
N, V, Z   = from bin (as in binary SBC)
low       = (a & $0F) - (b & $0F) - (1 - C)     (5-bit two's complement)
if low < 0:  low -= 6;  borrow = 1
high      = (a & $F0) - (b & $F0) - (borrow ? $10 : 0)      (9-bit two's comp)
C         = (high >= 0)                          (i.e. carry = no borrow)
if high < 0: high -= $60                          -- correction keys on the
result    = (high & $F0) | (low & $0F)            HIGH nibble's borrow only
```

Two implementation subtleties that cost real debugging time and are now
baked into the code:

1. The SBC `- $60` correction keys on the **high nibble's borrow**
   (`high[8]`), *not* the low nibble's borrow. Keying on the wrong one
   produces e.g. `$C5` instead of `$25` for `50 - 25`.
2. Decimal ADC's N comes from the intermediate high sum, not the result
   (`50 + 50 = $00` has **N=1** and **Z=1** simultaneously — impossible in
   binary). This is why the ALU exposes `negative` and `nz_source`
   separately from `result`.

Sanity anchors verified by s7: `58 + 46 = $04, C=1`;
`99 + 01 = $00, C=1, Z=1`; `50 + 50 = $00, N=1 V=1 C=1 Z=1`;
`00 - 01 = $99, C=0, N=1`; `50 - 25 = $25, C=1`; `50 - 50 = $00, Z=1, C=1`.

## 12. Interrupts

Pins are active-low: `irq_n` (level-sensitive) and `nmi_n`
(edge-triggered, falling).

- **IRQ** is taken at an opcode-fetch edge when `!irq_n && !flag_i`.
- **NMI** is latched by the falling-edge detector
  (`!nmi_n && nmi_prev` — *low now, high before*; getting this backwards
  re-triggers every cycle the line stays low — a bug that was caught by s6),
  is unmaskable, and may hijack a fetch that IRQ cannot.
- **Hijack** (the classic NMOS trick): at the fetch edge with an interrupt
  pending, the CPU *holds PC* (it becomes the pushed return address, so the
  interrupted instruction re-executes after RTI), **forces `ir <= $00`**
  so the sequence is exactly a BRK with `software = 0`, sets
  `serving_nmi <= nmi_pending` and clears `nmi_pending`, and enters
  `@PushPcHigh(false)`. One PC-driver subtlety: the "hold" must be
  expressed by *excluding the hijack case from the increment arm*, because
  an empty `when` arm is silently optimized away by the compiler (section
  23).
- **BRK** (`$00` as a real instruction): `pc <= pc + 2` (skips the padding
  byte), pushes with `B = 1`, uses the IRQ vector. Its `pc+2` arm must be
  ordered *before* the generic increment arm (first-match-wins).
- **Pushed status**: `B = 1` for BRK/PHP, `B = 0` for IRQ/NMI; bit 5 always
  1. `I` is set as part of the interrupt entry.
- **Vectors**: `$FFFE/$FFFF` (IRQ/BRK), `$FFFA/$FFFB` (NMI), fetched via
  `FetchVectorLow/High`; `serving_nmi` selects and is cleared after the
  vector is consumed (otherwise a later BRK would use the NMI vector —
  another real bug caught by s6).
- **RTI** pulls P (ignoring bits 4,5), pulls PC (no `+1` — that is RTS's
  behavior; the `+1` is keyed on `instruction == #Rts`), and resumes.

## 13. Faithfully implemented NMOS quirks

| Quirk | Where |
|---|---|
| `JMP ($xxFF)` reads the pointer high byte from `$xx00` (same page — the pointer address's high byte is never incremented) | `ReadPointerLow`'s Indirect arm |
| `(zp,X)` / `(zp),Y` pointer fetch wraps **within page zero** | `ReadPointerLow`'s else arm |
| BRK pushes `B = 1`; IRQ/NMI push `B = 0`; PLP/RTI ignore bits 4,5 | status push/pull |
| Bit 5 of a pushed P is always 1 | `status_byte` / `interrupt_status` |
| TXS does not set flags; every other transfer does | `implied_nz` |
| NMOS decimal flag model (ADC: N/V from the intermediate high sum; SBC: N/V/Z from the binary subtract) | `alu.vir` |
| The interrupt hijack (forced-BRK fetch with PC held) | FetchOpcode arm |
| Unknown opcodes act as one-cycle NOPs (never jam) | decode `else` arms |

## 14. What is *not* implemented

- **Cycle accuracy.** Instruction timing differs from the real chip (see
  section 24). The bus *order* is faithful; the *count* is not.
- **Undocumented opcodes** (`LAX`, `SAX`, `ANC`, the `NOPs` with operands,
  the unstable ones, `JAM`, ...): all decode as one-cycle NOPs. Klaus's
  functional test only tests documented behavior, so this is sufficient for
  the gate — a "65C02 extended" or "dead test" style suite would not pass.
- **RDY / SO / etc.** — not part of the design brief.
- **The interrupt-hijack corner cases** (NMI hijacking a BRK, IRQ during
  RMW write-back, etc.) work by construction of the shared push sequence
  but are not individually smoke-tested — the hardware-interrupt timing
  scenarios in Klaus's *interrupt* test binary (a separate, optional test)
  would be the place to verify them; that test was deliberately out of
  scope (section 24).

## 15. Verification strategy

Three independent layers, each with its own failure mode:

1. **Stage smoke tests** (s1–s7): a 6502 program per stage, written in
   ca65, that *self-checks by construction* — the program's own control
   flow (branches taken/not-taken guards, fail-marker stores, checkpoint
   stores) plus the testbench's expectation protocol. Every expectation
   record is first validated against a **Python reference simulator**
   written alongside each test (the reference implements the real 6502
   semantics, so wrong expectations are caught before simulation).
2. **The differential checker** (`tools/diffklaus.py`): runs a full
   reference 6502 (all 151 opcodes, stack, interrupts) over the *Klaus
   image itself* and compares `(pc, a, x, y)` at every opcode fetch against
   the DUT's debug trace. This proved 3756/3756 early fetches agree before
   the (expensive) full test ran.
3. **The Klaus Dormann functional test**: the acceptance gate. It exercises
   all 151 opcodes across all addressing modes, flag corner cases,
   self-modifying code, decimal mode (valid operands), and RTI — with
   `report = 0`, every error *and* success is a self-trap loop; success is
   the loop at `$3469`.

The layering is deliberate: smoke tests localize failures to features, the
differential check catches integration-level desyncs cheaply, and Klaus is
the final arbiter.

## 16. The smoke tests

| Test | Program | Records | Cycles | Covers |
|---|---|---|---|---|
| s1 | 104 lines | 42 | 190 | LDA/LDX/LDY/STA/STX/STY imm/zp/abs; TAX/TAY/TXA/TYA/TSX/TXS; INX/INY/DEX/DEY incl. wraps; CLC/SEC/CLI/SEI/CLV/CLD/SED; two flag snapshots via testbench peeks |
| s2 | 230 | 50 | 454 | zp,X; zp,Y; abs,X; abs,Y; (zp,X); (zp),Y — each with 8-bit zp wrap, 16-bit page cross, and pointer-page-zero wrap; STA indexed; all 8 branches taken + not-taken; a backward-branch loop |
| s3 | 455 | 137 | 977 | ADC/SBC imm (carry-in/out, V, Z, borrow-in/out) + all 7 non-immediate modes with decoy operands; ORA/AND/EOR results + N/Z; CMP/CPX/CPY equal/less/greater with C probes and register-unmodified proofs; BIT N/V/Z in zp and abs with A-unchanged proofs; V=1 fail-guards |
| s4 | 218 | 124 | 278 | PHA/PLA round trip + PLA N/Z; PHP→PLA exact P bytes (B=1, bit5=1); PLP restore; SP tracking via TSX; stack byte verification at `$01FC/$01FD` during JSR; two-level nested JSR/RTS; JMP abs over poison; JMP (ind) normal + the `$10FF` page-wrap; subroutine-internal stack discipline |
| s5 | 494 | 146 | 1097 | acc-mode ASL/LSR/ROL/ROR (C-out 0/1, zero results, C-in); mem-mode in all four modes with decoy neighbors; INC/DEC wraps ($FF→$00, $00→$FF); carry handoff chains; PHP/PLA flag checkpoints; zp,X page-zero wrap; A/X untouched by mem ops |
| s6 | 178 | 92 | 324 | IRQ masked by I; IRQ taken after CLI (counter, stacked P with B=0, register preservation); NMI edge with I=1; BRK with PC+2 + B=1 + padding-byte tripwire; RTI flag restore (I=0 restored); ISR register preservation |
| s7 | 309 | 80 | 482 | decimal ADC/SBC imm/zp/abs/(zp),Y with carry-in/borrow-in 0/1; all six anchors; SED/CLD toggling; SBC's binary N/V/Z vs decimal result proven via PHP/PLA bytes; ORA/shifts unaffected by D |

Total: **671 expectation records**. Each was validated against a Python
reference simulator before running on the DUT (the references live in each
test's development history; the conventions live in `asm/README.md`).

## 17. The expectation protocol

Smoke tests are **data-driven**: the testbench has *no per-test logic*.
Each test is a program (`asm/sN.s`, assembled by ca65/ld65 into a full 64K
image) plus an expectation file (`asm/sN.exp`) describing, in order, what
must be observed.

Memory conventions (documented in `asm/README.md`):

- Code at `$0200` (the testbench writes the reset vector `$0200` into
  `$FFFC/$FFFD`).
- `$F000` — the **final marker** (the last data write of every program).
- `$F001`+ — intermediate markers (ordered wait points).
- `$F100-$F1FF` — the checkpoint area (one store per verified fact).
- Scratch: zero page `$10-$5F`, absolute `$F200-$F5FF`.
- Never write `$0000-$000F` or `$F000-$F0FF` except markers/checkpoints;
  never write the stack page directly.

Expectation line types:

```
M <addr4> <byte2>   wait until the program stores exactly <byte> at <addr>
F <N|Z|C|V|D|I> <0|1>   check a CPU flag at the current point
R <A|X|Y|S|P> <hex>     check a register (S = SP, P = PC) at the current point
C <addr4> <hex2>        compare memory at the current point
P <I|N> <0|1>           drive the active-low irq_n (I) or nmi_n (N) pin
                        right after the preceding marker is observed
# comment line
```

The first line is always the *first* marker the program stores; the last
section is always the final marker with the complete final snapshot
(six flags + A/X/Y/SP/PC). `tools/exp.py` compiles the text into a compact
hex record stream (`type, lineno, args` per record, `0xFF`-terminated) that
the testbench `while`-loop consumes — avoiding all text parsing inside
SystemVerilog (an earlier `$fgets`-based parser failed because iverilog
right-justifies strings in wide regs).

Plusargs: `+hex=<image.hex>`, `+exp=<exp.hex>`, `+debug=1` (cycle trace),
`+vcd=1` (waveform dump, off by default), `+klaus=1` (the Klaus mode:
patch the reset vector to `$0400`, watch for the success loop, no exp file
needed).

## 18. The differential checker

`tools/diffklaus.py <klaus.hex> <debug-trace.txt>`:

1. Loads the Klaus image as the memory (patching the reset vector to
   `$0400` like the tb).
2. Runs a complete reference 6502 in Python — all 151 opcodes decoded via
   the real `aaabbbcc` instruction encoding (`cc = op & 3`, `bbb =
   (op >> 2) & 7`), the full flag/stack/interrupt semantics.
3. Parses the DUT's `+debug=1` trace, selecting the **FetchOpcode
   boundaries** (state tag bits).
4. Compares `(pc, a, x, y)` at every fetch.

It agreed on **3756/3756 fetches** for the traced prefix (the first several
Klaus test sections). The reference is also a useful pedagogical artifact —
the 6502's addressing-mode encoding table lives in ~30 lines.

## 19. The Klaus Dormann gate

- **Image**: `klaus/6502_functional_test.bin` — a full 64K memory image
  (exactly 65536 bytes; `report = 0`, `I_flag = 3`, `load_data_direct = 1`,
  `ROM_vectors = 1`).
- **Start**: `$0400` (the test expects a monitor to jump there; the tb
  patches the reset vector).
- **Success**: PC parked at `$3469` (`4c 69 34` = `jmp $3469` — the final
  `success` macro expansion; confirmed against the shipped `.lst`,
  line 13377). Every *error* trap is also a self-loop, so a parked PC that
  is *not* `$3469` identifies the failing test section — the timeout
  handler prints it (with registers) as the diagnostic.
- **Result**: **PASSED** — 76,758,978 cycles (Verilator 5.038,
  `--binary --timing`; the heartbeat prints every 10M cycles with the live
  PC). iverilog reaches the same verdict but at ~10k cycles/s it needs
  hours; use Verilator.

## 20. Debugging guide

**The debug trace** (`+debug=1`, one line per cycle):

```
t    sim time
pc   the program counter
ir   the instruction register (stale during the fetch cycle — by design)
st   the raw FSM state (payload + tag bits; tag 1 = FetchOpcode)
al   addr_low
md   the decoded addressing mode (8-bit enum value)
a/x/y    registers
NZCVID   the six flag registers
wr   the 9-bit bus write (bit 8 = store valid tag, payload = store data)
ad   the bus address
ov   the ALU overflow output
nz   the ALU nz_source output
alu_a/alu_b  the ALU operand inputs
dec  the D flag into the ALU
op   the ALU op (0=Or 1=And 2=Xor 3=Adc 4=Sbc 5=Pass)
```

also available: `m1fd`/`m1fc` style probes were used during development to
watch stack bytes (`mem[$01FD]`, `mem[$01FC]`).

**Reading a failure**: the testbench prints `FAIL: line <N>: ...` with the
*expectation-file line number*; cross-reference `asm/sN.exp` (the record
format preserves source line numbers), then re-run with `+debug=1` and find
the last store to the failing address. A `TIMEOUT waiting for store of X at
Y` means the program never reached that marker — trace from the last
healthy marker. `mem = xx` values in the trace mean the CPU read
uninitialized memory (usually a desynced PC or a wrong pointer).

**The VCD** (`+vcd=1`) is written to `dump.vcd` and dumps the DUT
hierarchy only (not the 64K RAM array).

**Klaus failures**: the timeout message's parked PC is the trap address;
find it in `klaus/6502_functional_test.lst` to identify the test section,
then reproduce with `tools/diffklaus.py` over a longer `+debug=1` window.

## 21. Makefile reference

```
make check        vir check (typecheck, expect clean)
make build        vir build (Verilog into build/)
make test         all seven smoke tests (s1..s7)
make test-sN      one smoke test (assembles if needed)
make klaus        build/klaus.hex from the 64K image
make klaus-run    iverilog Klaus run (SLOW — prefer Verilator, section 19)
make models-test  differential tests: the native models (models/) against
                  the former ext/ Verilog models they replace
make fomu-sim     full-stack Fomu simulation (boot + the PROG demo, default hw1)
make fomu-build   bitstream: yosys + nextpnr-ice40 + icepack, timing-checked
make build/sixfiveohtwo.img   upload image (bitstream + program at $080000)
make fomu-upload  dfu-suffix + dfu-util upload (needs the board)
make clean        remove build/ and models/build/
```

Build rules: `asm/%.s` → ca65 → ld65 (`asm/6502.cfg`: one 64K RAM region,
fill, CODE at offset `$0200`) → `build/%.bin` → `tools/mkhex.py` →
`build/%.hex`. Expectation files compile via `tools/exp.py` to
`build/%.exp.hex`. The Fomu flows consume the *unmodified* 64K `build/%.bin`
(`tools/mkflash.py` for the sim's flash hex, `tools/mkimg.py` for the upload
image; both patch the reset vector to `$0200`). Constraints: the platform's
`@pin` annotations produce `build/sixfiveohtwo.pcf`, and
`sixfiveohtwo.extra.pcf` (in the project root) is appended to it by
`vir bitstream` — that is where the derived clock's
`set_frequency sys_clk 6.0` lives.

## 22. Tool scripts

| Script | Purpose |
|---|---|
| `tools/mkhex.py` | flat binary → `$readmemh` hex (16 bytes/line, optional `@origin` overlay) |
| `tools/exp.py` | expectation text → FF-terminated hex record stream (preserves line numbers for failure messages) |
| `tools/mkklaus.py` | the 64K Klaus image → hex (validates the 65536-byte size) |
| `tools/diffklaus.py` | the differential checker (section 18) |
| `tools/mkflash.py` | 64K program → sparse flash hex at `$080000`, reset vector patched to `$0200` (the sim's `+flashhex` image) |
| `tools/mkimg.py` | bitstream + 64K program → the Fomu upload image (program at `$080000`, reset vector patched to `$0200`) |

## 23. Virdant language notes and compiler quirks

These were discovered the hard way during this project and are recorded
here (and in `PLAN.md`) for future Virdant CPU work:

1. **Bit indexing vs slicing.** Single-bit index `x[k]` is valid for
   `k` in `0..W-1` (the MSB of `Word[8]` is `x[7]`), while slices are
   *top-exclusive*: `x[8..0]` is the full byte, `x[8..1]` = bits 7..1,
   `x[7..0]` = bits 6..0. Shift idioms:
   `ASL = word(v[7..0], 0w1)`; `LSR = word(0w1, v[8..1])`;
   `ROL = word(v[7..0], C)`; `ROR = word(C, v[8..1])`.
   Confusing these produces exactly the right-shifted-with-carry-duplicated
   results that cost the first ALU debugging session.
2. **Struct literals and projections disagree.** `${ a = x, b = y }`
   packs fields in *declaration order, MSB-first*, but `->field`
   projection reads the *first declared field from the LSB end*. The two
   are mutually inconsistent (verified with a minimal test: `${high=$11,
   low=$22}` reads back `high=$22`). **Avoid structs**; this project uses
   two parallel decode matches instead.
3. **Empty `when` arms are silently optimized away.** An arm meant to
   *hold* a register (the interrupt hijack's PC hold) compiled to nothing,
   letting the following arm fire. Never express a hold as an empty arm —
   exclude the case from the neighboring arm's condition instead.
4. **`types::#Variant` is a syntax error.** Enum variants are always bare
   `#Variant`, resolved through the module import. (`types::Bus` for
   *types* is fine.)
5. **`match` as a direct `&&`/`||` operand needs parentheses**:
   `x && (match y { ... })`.
6. **`//>` doc comments are illegal between match arms** (they parse as a
   declaration doc); plain `//` comments work anywhere.
7. **Enum variants require `= expr` values** — bare names do not parse.
8. **Payload bindings** (`case @PushPcLow(software) => ...`) work in
   expression positions (including `mux(...)` arguments) but are unreliable
   as `match` scrutinees; prefer payload BitLit patterns
   (`case @PushPcLow(false)`) or `mux` on the binding.
9. **Redundant-else checking**: a `match` whose arms already cover every
   enum value *rejects* an `else` arm; a non-exhaustive match requires one.
   Growing an enum per stage turns previously-exhaustive matches into
   non-exhaustive ones — expect to re-add `else` arms.
10. **Nested part-selects generate illegal Verilog**: slicing a *payload
    binding* directly (`case @ReadPointerLow(addr) => addr[16..8]`) emits
    `state[24:9][15:8]`, which iverilog rejects. Extract the payload into a
    wire first, then slice the wire.
11. **`iverilog` needs `-g2012`** for `void'(...)`, tasks with typed args,
    and other SV constructs.
12. **`$value$plusargs` strings are right-justified** (NUL-padded) in wide
    regs: `$readmemh` tolerates this, `$fopen` does not — hence the
    binary-record expectation format.
13. **`word()` is MSB-first** with mixed Bit/Word arguments summing their
    widths: `word(flag_n, flag_v, true, software, flag_d, flag_i, flag_z,
    flag_c)` builds the status byte in one expression.
14. **`dontcare` as an expression** is legal in `match` arms (emits as
    all-ones in payload positions) but avoid it as a `when`-arm body.

## 24. Design decisions and their rationale

- **Functional, not cycle-exact.** The interview locked this in: every
  documented instruction must behave correctly, but per-instruction cycle
  counts may differ. This halved the FSM's state count (no dummy reads,
  no double-write emulation) and removed the need for a cycle-by-cycle
  reference — while Klaus (a functional test) still passes. Consequence:
  the *interrupt* test binary (which asserts on cycle timing) is out of
  scope, and "cycle budget" assertions in the tb were replaced by a global
  timeout.
- **Async-read bus.** Mirrors the real chip's bus protocol, makes the
  testbench RAM trivial, and keeps `addr` independent of `data`
  (the compiler's combinational-cycle check is satisfied by construction).
- **No Decoder module / inline decode.** The decode is two adjacent
  256-arm matches inside `Core`. A struct-typed single decode (tidier)
  was precluded by quirk #2; a submodule returning separate ports would
  have added an import and port plumbing for no verification benefit —
  the FSM reads the two wires identically either way.
- **Two parallel decode matches, not a packed-Word table.** Considered a
  single `match` into `word(instruction, mode)` sliced at the far end
  (immune to quirk #2 by construction, single table) — chosen against for
  readability: the two-table form states each fact directly and the
  sync-drift risk is contained by a comment and the smoke tests.
- **Enums grow per stage; the FSM grows per stage.** Every stage ends with
  `vir check` clean (zero warnings — the exhaustiveness checker re-arms
  itself as enums grow) and its smoke test green. The final source contains
  *only* reachable states and arms; there is no dead dispatch code.
- **FetchVectorLow/High exist from stage 1.** Although only used by reset
  until stage 6, having the real reset sequence (vector fetch at `$FFFC`)
  from the first test avoided ever shipping a "fake" reset that would need
  reworking later.
- **Python reference simulators per test.** The single highest-leverage
  verification decision: expectations are *checked twice* — against the
  reference (semantic ground truth) and against the DUT (the thing under
  test) — so a wrong expectation is distinguishable from a wrong CPU.
- **Verilator for the long run.** iverilog runs this design at ~10k
  cycles/s; the Klaus test needs ~77M cycles. Verilator's `--binary
  --timing` mode runs the *same testbench source* orders of magnitude
  faster. The iverilog path remains as the cross-check (it produced the
  same PASS verdict on smoke tests).

## 25. Ideas for future work

- **Cycle-accurate mode**: re-introduce the dummy reads (RMW double
  access, page-cross penalties, the fixed 2/3/4/5/6/7-cycle instruction
  timings) — the FSM already has the right state *skeleton*; this is
  mostly bus-driver and pc-driver surgery plus a cycle-budget expectation
  format.
- **The 6502 interrupt test** (`6502_interrupt_test.bin`) and **decimal
  test** (`6502_decimal_test.bin`) binaries from the same upstream repo
  (already understood mechanically; the interrupt one needs a feedback
  register model in the tb to inject IRQ/NMI).
- **Undocumented opcodes** as a "dead test" variant (the upstream
  `65C02_extended_opcodes_test` covers the CMOS set instead).
- **Fomu board support**: done — the async-read bus was adapted to the
  SPRAM's one-cycle latency with a wait-state, and the platform target
  (boot-from-flash, memory-mapped LEDs, bitstream flow) now passes
  simulation and synthesis (Quick start, "On the Fomu board"). What
  remains is real-hardware bring-up.
- **Performance**: the decode's two 256-arm casez chains synthesize to
  two 256-way multiplexers; a ROM-based decode (or splitting on the
  `aaabbbcc` bits) would shrink it if it ever went to hardware.
