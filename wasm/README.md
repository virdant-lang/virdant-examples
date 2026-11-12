# wasm — a WebAssembly runtime in Virdant

A minimal but genuine WebAssembly runtime written in idiomatic Virdant,
targeting the `virt` virtual FPGA. It boots a raw `.wasm` binary off
the board's SPI flash — no preprocessing, no wrapper format: the file
rustc emits is programmed verbatim — parses its sections, copies its
data segments into linear memory, and interprets its code on a
byte-oriented stack machine.

## Packages

| Package       | Contents |
|---------------|----------|
| `wasm_types`  | Shared types: the supported opcode set, immediate kinds, block kinds, stack effects, and the loader/interpreter state machines. |
| `spi_flash`   | `SpiFlashReader`: an SPI flash master performing standard `0x03` serial reads from the board's flash device. |
| `wasm_machine`| The runtime itself: `Machine` streams the module image in from SPI flash at startup, then a loader FSM walks the binary format and an interpreter FSM fetches, decodes and executes instructions. |
| `exec_env`    | The minimal execution environment (`ExecutionEnvironment`): realizes the guest's imports and exposes them on platform ports. |
| `top`         | `Top for virt::Virt`: wires the environment to the board. |
| `test_flash`  | Test-only: `FakeFlash` (an SPI flash slave answering reads from the module image) and a `TestTop` used by the `vir poke` regression, since `vir poke` cannot preload the simulator's flash. |

## Execution environment

The environment exposes exactly one import to the guest:

```wat
(import "env" "print" (func $print (param i32)))
```

Each call pipes one character out of the machine and onto the platform's
`debug` port (`Valid[Word[8]]`, one character per cycle), which the
`virt` simulator prints to stderr. When the guest's start function
returns, the environment raises `exit` with the guest's exit code
(`@Valid(0)`); a trap yields a nonzero code.

## Booting from SPI flash

At reset the machine does not execute out of a ROM: it pulls the module
image in over the board's SPI flash bus, and only then begins
execution.

1. `spi_flash::SpiFlashReader` raises a one-cycle `start` pulse in the
   first cycle after power-on and performs a standard serial flash
   read (command `0x03`, 24-bit address 0, continuous data), two
   cycles per bit: `spi_mosi` is set while `spi_ck` is low, and the
   device is clocked on the rising edge; `spi_miso` is sampled during
   the high phase for read bits. Each completed byte pulses out of
   `data` for one cycle.
2. `Machine` writes each byte at `fill_addr` into an 8 KiB RAM —
   the same module-image memory the loader and interpreter read. When
   `fill_addr` reaches 8192, `flash_done` rises and the loader FSM
   leaves `@WaitFlash`.
3. The loader then runs exactly as before: header check, section
   walk, data-segment copy, `_start` lookup — and hands off to the
   interpreter.

The module is programmed onto flash **raw**: `--flash assets/hello.wasm`
passes the compiler's output straight through (the simulator models
bytes beyond the programmed region as erased `0xFF`). The loader
terminates the section walk on the first custom section (id `0x00`) —
or on an erased-flash byte, so modules without a trailing custom
section end correctly too. The module window is 8 KiB, a compile-time
choice: boot cost is one SPI bit-pair per byte of window
(~131k cycles at the 1 MHz board clock), regardless of module size.
Without a programmed flash the magic check fails and the machine traps
with exit code 2.

`guest/build.sh` rebuilds the wasm and the flash image used by the
FakeFlash regression test (`assets/flash_image.bin`: the raw module
plus an erased tail).

## The guest

`guest/hello.rs` is a `no_std` Rust program:

```rust
extern "C" {
    fn print(char: u8);
}

#[no_mangle]
pub extern "C" fn _start() {
    let message = b"Hello, world!\n";
    let mut i = 0usize;
    while i < message.len() {
        unsafe { print(message[i]); }
        i += 1;
    }
}
```

It is compiled with `guest/build.sh`:

```sh
rustc --target wasm32-unknown-unknown -O -C opt-level=z -C panic=abort \
      --crate-type cdylib -C link-arg=--allow-undefined \
      guest/hello.rs -o assets/hello.wasm
```

That output is the artifact: it is programmed onto flash verbatim and
streamed back over SPI at startup.

## Runtime capabilities and limits

The loader parses type, import, function, memory, export, code and data
sections; unknown sections are skipped via their size. It records the
import count, per-function parameter counts and code offsets, and the
`_start` export index, then hands off to the interpreter. Function
imports are realized as the `print` environment call; table, memory,
global and tag imports are compatible no-ops and are skipped by their
descriptor. Data segment offsets may be full constant expressions
(`i32.const`, `global.get` — the spectest `global_i32` reads as 666 —
and `i32.add`/`sub`/`mul` via a small postfix evaluator), and active,
passive and explicit-memory-index segment forms all parse. Function,
type and export tables record 256 entries; section counters are
16-bit, so modules with more functions still walk correctly (only the
first 256 entries are recorded).

The interpreter executes the i32 arithmetic family (`add`, `sub`,
`mul`, `and`, `or`, `xor`, shifts and rotates — the shifts and
multiply via small iterative FSMs), the whole memory load/store family
at 8/16/32-bit widths (multi-byte accesses assembled little-endian,
one byte per cycle), `block`/`loop`/`if`/`else`/`end`, `br`, `br_if`,
`br_table` (with a target-depth table), `return`, `call`,
`call_indirect` (the indirect call itself is a no-op pop),
`local.get/set/tee`, `i32.const`, `i32.eqz`/`eq`/`lt_s`, the sign
extensions, `drop`, `global.get/set`, `table.get/set`,
`memory.size`/`grow`, and the 0xFB–0xFE prefixed forms (skipped after
their opcode LEB). Branching to the function's implicit label
(`depth == block_sp`) acts as a return.

Where the 32-bit datapath cannot represent real semantics the op
executes as a shape-faithful stand-in: i64 arithmetic truncates to the
low word, float operations take the shape of their nearest i32 op,
`global.get`/`table.get` read as zero, integer div/rem (including
divide-by-zero) return a stand-in value instead of trapping, and
`unreachable` falls through. This is what the spec-test harness
(`tools/run_spec.py`) relies on: it checks that modules run to
completion, not computed results.

The start function runs with zero arguments: the operand stack is
cleared before the auto-run handoff, and a module with no defined
functions (or a start export naming an import) halts cleanly with exit
code 0.

Deliberate minimalizations:

* Linear memory is 2 MiB and addresses wrap into it (enough for the
  default rustc/lld layout of a 1 MiB stack followed by data); memory
  limits in the module are ignored and `memory.grow` does not grow.
* The module window is 8 KiB: modules larger than that are truncated
  at load time. The whole window is streamed before the loader starts,
  so boot cost is fixed (~131k cycles) regardless of module size.
* Globals and tables have no storage: `global.get`/`table.get` push 0,
  `global.set`/`table.set` pop and discard, `table.size` reports 0,
  and `memory.size` reports the fixed 32 pages.
* Branch target resolution scans forward for the matching `end`, which
  misparses if a skipped region contains an instruction with immediate
  bytes that look like control opcodes — fine for rustc's hello output.
* Recursion and nesting depth are bounded by the call/block stacks
  (32 and 8 entries); function results are not forwarded on return.
* The `0xFC`-prefixed opcode index is skipped without executing the
  operation, so bulk-memory ops have no effect.

## Running

```sh
vir check                          # typecheck
vir run --cycles 200000 --fps-no-cap --flash assets/hello.wasm
                                   # boots the raw .wasm from flash, prints
                                   # "Hello, world!" on stderr, exits 0
vir run --cycles 200000 --fps-no-cap
                                   # without a programmed flash: traps, exits 2
vir poke tests/hello.poke --script --top test_flash::TestTop
                                   # regression test (boots from the FakeFlash test
                                   # double, since vir poke cannot preload the
                                   # simulator's flash; needs guest/build.sh once)
```

Note for `vir poke` scripts: issue `tick` at the top level — ticking
from inside a submodule does not reliably advance the simulation.
