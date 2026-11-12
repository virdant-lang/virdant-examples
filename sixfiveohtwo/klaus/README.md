# Klaus Dormann 6502 functional test

This directory holds the Klaus Dormann 6502 functional test, used as a
final acceptance gate for the sixfiveohtwo CPU.

Files:

* `6502_functional_test.bin` - the test as a full 64K memory image
  (exactly 65536 bytes, from
  `bin_files/6502_functional_test.bin` in the upstream repo).
* `6502_functional_test.lst` - assembler listing (source of the
  addresses below).
* `6502_functional_test.a65` - the assembler source, for reference.

## Addresses

* **Start address: `$0400`** (`code_segment = $400`, `a65` line 113;
  listing line 740: `0400 : d8  start  cld`). The test expects a
  monitor to load the image and jump to `$0400`.
* **Success-loop address: `$3469`** - listing line 13377:

      3469 : 4c6934          >        jmp *           ;test passed, no errors

  This is the final `success` macro expansion (source line 5384,
  "if you get here everything went well"). `4c 69 34` is `jmp $3469`,
  jumping to itself.

* Shipped trap vectors in the image (the tb overwrites the reset
  vector, this is only a record of the image contents):
  NMI -> `$379D` (`nmi_trap`), RESET -> `$37A3` (`res_trap`),
  IRQ/BRK -> `$37AB` (`irq_trap`).

## Trap semantics

With `report = 0` (as assembled in the distributed binary), every error
trap macro (`trap_eq`, `trap_ne`, `trap_cs`, ..., and the generic
`trap`) expands to a **self-loop** (e.g. `beq *`, `jmp *`), and the
`success` macro expands to `jmp *` as well. Therefore:

* The test **passes** iff the CPU eventually parks with PC == `$3469`
  (the success self-loop).
* Any parked PC that is **not** `$3469` means the test **failed** at
  that address (the parked PC identifies the trap site; the listing
  maps it back to the failing opcode).
* Because a parked PC can only be observed by timeout, the gate also
  applies a **cycle-count timeout**: if the CPU has not parked at the
  success address within the cycle budget (the full test runs on the
  order of tens of millions of 6502 cycles), it fails.

## Building the hex image

    make klaus

produces `build/klaus.hex` via `tools/mkklaus.py` (a `$readmemh` file
with an `@0000` directive and 16 bytes per line, covering all 64K).

## How the testbench is invoked

The generic testbench is built and run as (matching the `test-%`
targets in the `Makefile`):

    iverilog -g2012 build/*.sv tb.sv -o build/run
    ./build/run +hex=build/klaus.hex +exp=<expectations> [+debug=1]

Notes for using this as the Klaus gate:

* `tb.sv` currently hardcodes the reset vector to `$0200` for the
  smoke test (`mem[16'hFFFC] = 00; mem[16'hFFFD] = 02;`). The Klaus
  gate requires the CPU to start at **`$0400`** instead, so the
  acceptance runner must point the reset vector at `$0400` (small
  variant/wrapper of `tb.sv`; the core tb logic is unchanged).
* The gate does not use an `+exp=` expectation file. Instead, after
  loading `build/klaus.hex`, it runs until the PC parks (stops
  changing) or the cycle timeout expires, then compares the parked PC
  against `$3469` as described above.

## Result

**PASSED** — the CPU reaches the success loop at `$3469` after
76,758,978 simulated cycles (Verilator 5.038 run; iverilog works too
but takes hours). Run it with:

    verilator --binary --timing -Wno-fatal --top-module Tb -o run-klaus-vl build/*.sv tb.sv
    ./obj_dir/run-klaus-vl +hex=build/klaus.hex +klaus=1
