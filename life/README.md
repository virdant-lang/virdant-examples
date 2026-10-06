# life

Conway's Game of Life for the iCEstick -- one circuit per cell.

An 8x8 Game of Life world where the B3/S23 rule is hardware in every
cell: a `LifeCell` module per cell, each with its own flip-flop and
neighbor logic built in. All 64 cells update simultaneously on a
tick. The world plays out on a VT100 terminal over the iCEstick's
USB UART, with keyboard control: pause/run, single-step, sixteen
speed levels, and randomize.

## Usage

```
make test      # vir run-icarus: exhaustive LifeCell bench + end-to-end Top bench
make upload    # synthesize, place-and-route, pack, and flash the bitstream
./scripts/connect   # minicom at 115200 baud, 8N1
```

Boot: the screen clears, the cursor hides, the grid randomizes, and
the world starts **paused**. Press `S` to start the show.

The terminal must support at least 80x24 and basic VT100 CSI
sequences (cursor positioning, clear screen, hide cursor). If your
terminal never shows a cursor-hide, or the grid drifts off a VT100
variant with different defaults, it's the `ESC [ ? 2 5 l` /
`ESC [ 2 J` sequences at fault -- those are the only two
non-cursor-addressing codes the renderer emits.

## Keys

Letters are accepted in either case; unknown bytes are ignored.

| Key       | Action                                             |
|-----------|-----------------------------------------------------|
| `S`       | toggle run/pause                                     |
| ` `       | single-step one generation (pauses first if running) |
| `-`       | slow down (speed level -1, saturating at 0)          |
| `=` / `+` | speed up (speed level +1, saturating at 15)          |
| `0`       | restore default speed (level 8, ~0.5 s/tick)         |
| `R`       | randomize the grid from the LFSR, reset generation   |

LEDs (board silkscreen D1-D5):

- `led1..led4`: speed level in binary, bit 0 on `led1`
- `led5`: running (lit) / paused (dark)

## Layout

```
src/top.vir       top level: reset, pins, torus wrap, LED wiring
src/uart.vir       UartSender / UartReceiver (copied from echo/)
src/life.vir       LifeCell (the B3/S23 rule) + LifeBlock (the 8x8 tile)
src/render.vir     VT100 frame renderer
src/control.vir    key decode, run/pause, speed, the tick scheduler
scripts/life.py    golden model: LFSR mirror + B3/S23 + VT100 render
scripts/connect    minicom helper (copied from echo/)
verilog/tb.sv      bench 1 (exhaustive LifeCell) + bench 2 (end-to-end Top)
```

## Design notes

`LifeBlock` is deliberately built as an 8x8 **tile with its boundary
exposed as ports** -- no wrap logic inside. The torus wrap is eight
wires in `src/top.vir`, the only place the world's topology exists:

```virdant
grid.north_in := grid.south_out      // row 7 wraps above row 0
grid.south_in := grid.north_out
grid.west_in  := grid.east_out
grid.east_in  := grid.west_out
grid.nw_in    := grid.se_out         // diagonal corners wrap too
grid.ne_in    := grid.sw_out
grid.sw_in    := grid.ne_out
grid.se_in    := grid.nw_out
```

That design pays off if the block is ever tiled (2x2 for a 16x16
world on a bigger chip) or bus-attached as a Life accelerator
instead of a display -- see Future work.

### The phase-3 synthesis gate

The plan's resource budget priced the 8x8 grid at 8-16 LUTs per
cell. The first working cut of `LifeCell` -- folding the cell's own
state into a nine-cell total and checking `t == 3` / `t == 4` --
measured at **841** `SB_LUT4`s for the 64-cell `LifeBlock`
(including the LFSR and BCD generation counter), and the whole
design came in at **1506** packed `ICESTORM_LC`s against the
HX1K's **1280** -- 226 over budget.

Per the plan's fallback order:

1. Cutting the help line (row 20) saved only 76 LCs -- not enough on
   its own.
2. Golfing the rule itself was the real win: `next = (n == 3) |
   (state & (n == 2))`, where `n` is the plain 8-neighbor count,
   is algebraically identical to the nine-cell-total form but drops
   one term from the adder. In isolation this barely moved the
   needle (13 to 14 `SB_LUT4`s for one cell -- synthesis noise), but
   across all 64 cells `yosys`'s global optimizer found a
   dramatically better shared mapping: `LifeBlock` dropped from 841
   to **658** `SB_LUT4`s.
3. Shortening the status line (dropping "RUNNING"/"PAUSED" to a
   single `R`/`P`) shaved the last few LCs.

The design now packs at **1256 / 1280 ICESTORM_LCs (98%)** on the
HX1K, confirmed with `nextpnr-ice40 --hx1k`, with the one-module-
per-cell structure fully intact -- no cross-cell sharing, which the
plan reserved as the last resort. The help line never came back;
the key table lives here instead.

### A bug the end-to-end bench caught

`KeyboardControl`'s work sequencer (`Idle -> IssueEngine ->
WaitRenderIdle -> IssueDraw`) is supposed to never advance the grid
while a frame is still mid-draw. `WaitRenderIdle` does gate on
`!render_busy` before issuing a `draw` -- but the first version of
`Idle` didn't *also* check `render_busy` before consuming the next
pending tick. At the default speed this never mattered (a frame
draws in ~40 ms; the default tick is ~0.5 s). At the fastest speed
level the tick period (~4 ms) is shorter than one frame's draw time
(~40 ms), and `Idle` would consume an already-pending tick the
instant it saw the sequencer return from `IssueDraw` -- the same
cycle the renderer's own `busy` flag went high in response -- and
pulse a second `advance` while the first frame was still being
serialized. The result was a torn frame: the rows drawn before the
second `advance` showed one generation, the rows after showed the
next.

`verilog/tb.sv`'s auto-run check (switch to the fastest speed level,
`S` to run, and compare the next un-keyed frame against an
independently computed B3/S23 step) caught this immediately; the
fix is gating the pending-request consumption on `!render_busy` too,
not just on the sequencer being `Idle`.

## Testing

`make test` runs both benches in `verilog/tb.sv` against Icarus
Verilog:

- **Bench 1** instantiates `\life::LifeCell` directly and drives all
  512 combinations of center + 8 neighbors against a golden B3/S23
  table -- the rule is proven, not sampled.
- **Bench 2** drives real UART frames into `\top::Top` at 104
  cycles/bit, captures every TX byte, and parses the grid back out
  of the rendered VT100 frames. Rather than replicate the 64-bit
  LFSR's exact free-running cycle count in both Verilog and Python
  (fragile -- it depends on exact UART timing down to the cycle),
  the bench cross-checks an independent B3/S23-on-a-torus stepper
  against what the hardware actually draws after a step: two
  different implementations of the rule agreeing is the point.
  It also exercises boot (paused, generation 0), `R`, `S`
  (run/pause and the LEDs), `+`/`-`/`0` speed saturation, and an
  un-keyed tick advancing the grid on its own at the fastest speed
  level (the scenario that caught the bug above).

`scripts/life.py` is a standalone reference: it mirrors the LFSR,
the B3/S23 rule, and the exact VT100 byte layout, and prints the
predicted boot frame (and, with `--generations`, however many
frames after it) for offline cross-checking against a waveform.

## Future work

- **The accelerator / tile reuse** (the reason the boundary is
  ports): attach `LifeBlock` to a host bus instead of a display, or
  tile 2x2 of the same block on a bigger chip (HX8K, UP5K) for a
  16x16 world through the edge and corner ports.
- **Pattern loading from SPI flash (`L` key)**: reuse the
  `SpiFlashReader` from `flash_animation` to seed specific patterns
  rather than only the LFSR.
- **Bigger worlds, software style**: swap `LifeBlock` for a
  sequential BRAM row-window engine; the `LifeCell` rule module
  carries over verbatim.
- **Rule variants**: the `LifeCell` seam makes B36/S23 (HighLife),
  B2/S (Seeds), etc. one-line changes.
- **Baud bump**: 921600 baud is a `cycles_per_bit` change (13 at
  12 MHz) if frames ever need to be faster than ~25 generations/s.
