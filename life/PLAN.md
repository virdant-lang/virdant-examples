# Conway's Game of Life for the iCEstick -- one circuit per cell

An 8x8 Game of Life where **the rule is hardware in every cell**: one
`LifeCell` module per cell, each with its own flip-flop and the B3/S23
logic built in.  All 64 cells update simultaneously on a tick.  The
world plays out on a VT100 terminal over the iCEstick's USB UART, with
keyboard control: pause/run, single-step, sixteen speed levels, and
randomize.  Four LEDs show the speed level, the fifth shows run/pause.

The cell array is deliberately built as an 8x8 **tile with its
boundary exposed as ports** -- no wrap logic inside -- so the same
block can later be tiled (2x2 -> 16x16 on a bigger chip) or reused as
a bus-attached Life accelerator (see Future work).

Built with Virdant, following the structure of the existing example
projects (`echo`, `morse`, `flash_animation`).

## User interface

Serial terminal at 115200 baud, 8N1, at least 80x24.

Screen layout (VT100 rows):

```
 rows 3..18    the 8x8 world, zoomed 2x2: each cell is two terminal
               rows by two columns ('##' alive, '  ' dead),
               i.e. a 16x16-character block, columns 33..48
 row 20        help line: key summary
 row 22        status line: state, speed, generation
```

Keys (letters accepted in either case; unknown bytes ignored):

| Key   | Action                                                  |
|-------|---------------------------------------------------------|
| `S`   | toggle run/pause                                        |
| ` `   | single-step one generation (pauses first if running)    |
| `-`   | slow down (speed level -1, saturating at 0)             |
| `=` / `+` | speed up (speed level +1, saturating at 15)          |
| `0`   | restore default speed (~0.5 s per tick, level 8)        |
| `R`   | randomize the grid from the LFSR, reset generation     |

LEDs (board silkscreen D1-D5; the spec's 0-based "LED 0-3" = `led1..led4`):

- `led1..led4`: speed level, binary (bit 0 on led1, bit 3 on led4)
- `led5`: running (lit) / paused (dark)

Boot behaviour: clear screen, hide cursor, randomize the grid,
start **paused**, draw one frame with the help and status lines.
`S` starts the show.

## Design

### Why one circuit per cell, and why 8x8

The alternative -- a large world in BRAM with a sequential
row-window engine -- was considered and shelved (see Future work).
For this project the point is that the rule lives in the silicon,
cell by cell: a `LifeCell` is a flip-flop plus combinational
neighborhood logic, and the world is exactly 64 of them.

That choice prices the grid in LUTs, not just flip-flops.  On the
iCE40-HX1K (1,280 LUT4s, 1,280 FFs), with the rule costing roughly
8-16 LUTs per cell and ~300 LUTs of fixed overhead (UART, renderer,
control):

| Grid | Cell logic (at ~13 LUTs) | Plus overhead | Fits? |
|------|--------------------------|---------------|-------|
| 6x6  | ~470 | ~770 | easily |
| 8x8  | ~830 | ~1,130 | yes, with margin to golf |
| 9x9  | ~1,050 | ~1,350 | no |
| 10x10 | ~1,300 | ~1,600 | no |

**8x8 is the square power of two that fits.**  It also makes the
boundary cheap to expose: four edges (8 bits each) plus four corner
cells carry every neighborhood a tile ever needs from its neighbors,
with zero wrap logic inside the block (see `LifeBlock` below).

Flip-flops are never the constraint (64 cells need 64 FFs of the
1,280 available) -- the neighbor-counting logic is.  The plan's
synthesis gate (phase 3) measures the real number before anything
else is built on top.

### State representation

There are three kinds of state; they are deliberately kept apart.

**1. The world -- one flip-flop per cell, inside its `LifeCell`.**

Alive = 1, dead = 0.  Each cell's next state is *combinational* from
its eight neighbors' current states and its own; all 64 flip-flops
latch simultaneously on an `advance` pulse.  Because every cell reads
only *current* states and updates at the same instant, one flip-flop
per cell suffices -- there is no in-place update hazard and no need
for the two-flip-flop "current + next" style (a second bank would
only double FF count for no benefit).

No BRAM anywhere.  The whole world is 64 state bits:

- `state_grid : Word[64]` on `LifeBlock`, bit `y*8 + x` = cell (x, y),
  so row y is the slice `state_grid[(y+1)*8 .. y*8]` and the
  renderer reads whole rows straight off the port.

**2. The neighborhood wiring -- pure wires, no state.**

Cell-to-cell connections are just wires: interior neighbors come
from adjacent cells' `state` outputs inside `LifeBlock`, and edge
neighbors come from the block's boundary input ports.  The torus
wrap itself lives in `Top`, outside the tile, as pure wiring.

**3. Derived and control state.**

- `LifeBlock` carries a **64-bit Fibonacci LFSR** (taps 64/63/61/60,
  fixed nonzero seed) for `randomize`, and a 16-bit **BCD**
  `generation` counter (four cascaded decades, wraps at 9999 -- BCD
  so the status line renders it with no conversion logic).  On
  `randomize`, every cell loads its LFSR bit in one cycle and
  `generation` clears.
- Everything else is control state in `KeyboardControl` (see its
  module notes): the run/pause bit, the 4-bit speed level, and
  pending-command flags.  They describe what the *user* wants,
  never what the grid contains.

### `src/life.vir` -- `LifeCell`

The rule, once, in one place:

```virdant
//> One Game of Life cell: a state flip-flop plus the B3/S23 rule.
//> All eight neighbors arrive as wires; `state` updates on `advance`.
mod LifeCell {
    incoming clock   : Clock
    incoming reset   : Reset

    // The eight neighbors (edge/corner positions).
    incoming north     : Bit
    incoming south     : Bit
    incoming west      : Bit
    incoming east      : Bit
    incoming northwest : Bit
    incoming northeast : Bit
    incoming southwest : Bit
    incoming southeast : Bit

    // Update strobes (load_seed wins if both fire).
    incoming advance   : Bit
    incoming load_seed : Bit
    incoming seed_bit  : Bit

    outgoing state : Bit

    reg state_reg : Bit on clock {
        when {
            case reset     { it <= false }
            case load_seed { it <= seed_bit }
            case advance  { it <= next_state }
        }
    }
    state := state_reg

    // B3/S23: born on exactly 3 neighbors, survives on 2 or 3.
    // ... neighbor sum tree + rule, see below ...
}
```

The neighbor sum is the cost center (~8-16 LUTs) and gets golfed:

- Row sums first: north-row trio (NW,N,NE) and south-row trio
  (SW,S,SE) each sum to 2 bits in 2 LUTs; the west+east pair in 2.
- Combine the three partial sums; the rule is folded into the
  comparison rather than computing the full 4-bit count --
  equivalently, over the nine-cell total `t`:
  `next = (t == 3) | (state & (t == 4))`.
- Target after synthesis: **<= ~12 LUTs per cell**.  If the count
  comes in high, further folding tricks apply; the last resort is
  sharing row-sum partials across a row (see Risks).

`LifeCell` is exhaustively testable: the entire input space is 512
combinations (center + 8 neighbors), and phase 2 proves all of them
against a golden table before anything else is built.

### `src/life.vir` -- `LifeBlock`

The 8x8 tile: 64 `LifeCell` instances (Virdant has no generate
loops; the instantiations are written out -- mechanical, and it
makes every torus wire visible in the source), plus the LFSR,
generation counter, and boundary ports.  **No FSM, no `busy`** --
the block is pure state + wiring:

```virdant
//> An 8x8 Game of Life tile with its boundary exposed as ports.
//> Wrap (torus or tiling) is wired by the instantiator.
mod LifeBlock {
    incoming clock     : Clock
    incoming reset     : Reset
    incoming advance   : Bit     // one generation
    incoming randomize : Bit     // load all cells from the LFSR

    // Boundary: each edge is the 8 cells along it; the four corner
    // cells are exposed separately.  "*_out" presents this tile's
    // edge to a neighbor; "*_in" is the neighbor's edge.
    incoming north_in : Word[8]
    incoming south_in : Word[8]
    incoming west_in  : Word[8]   // bit y = cell (0, y)
    incoming east_in  : Word[8]   // bit y = cell (7, y)
    incoming nw_in, ne_in, sw_in, se_in : Bit

    outgoing north_out : Word[8]  // row 0
    outgoing south_out : Word[8]  // row 7
    outgoing west_out  : Word[8]  // column 0
    outgoing east_out  : Word[8]  // column 7
    outgoing nw_out, ne_out, sw_out, se_out : Bit

    outgoing state_grid : Word[64]  // bit y*8+x = cell (x, y)
    outgoing generation : Word[16]  // BCD
}
```

Why ports carry the whole boundary: an interior cell wires to three
neighbors in-file; an edge cell takes its outside neighbors from
`*_in`; a corner cell's diagonal comes from a corner port.  In a
2x2 tile arrangement the corner ports connect to the diagonal
blocks' corners; standalone, `Top` wraps them (below).  Nothing
about the wrap is knowable inside the block -- which is exactly
what makes it reusable as a tile or an accelerator core.

The LFSR: `randomize` loads cell i from `lfsr[i]` in a single cycle
(all cells in parallel, one 64-bit shift, no decode logic) and
`generation <= 0`.  Fixed seed, deterministic, so `scripts/life.py`
can mirror it bit-for-bit.

### Speed control and tick scheduler (`src/control.vir`)

Unchanged from the earlier sketch, minus engine bookkeeping:

- Divide-by-3 prescaler (2-bit state) -> 4 MHz; a 30-bit
  free-running counter on it; `speed_level` selects bit
  `28 - speed_level`: level 8 -> bit 20 -> edges every
  2^21 / 4 MHz = 0.52 s (the "~0.5 s" default).  Edge-detect the
  selected bit, OR it into `tick_pending` only while `running`.
- Levels 0..15: level 0 = 134 s, ..., level 8 = 0.52 s, ...,
  level 15 = 4 ms.  A frame is now only ~460 bytes (~40 ms), so
  even the fast levels stay displayable; `tick_pending` still
  latches if a tick lands mid-frame and the world only advances
  when the renderer is idle (max ~25 generations/s).
- Key decode (both cases): `S` toggles run/pause (drop
  `tick_pending` on pause; restart the counter on resume);
  ` ` pauses if running and sets `step_pending`; `-` / `=` / `+`
  adjust `speed_level` with saturation; `0` loads 8; `R` sets
  `randomize_pending` and clears pending ticks/steps.
- One three-state sequencer issues work: IssueEngine ->
  WaitRenderIdle -> IssueDraw, reused by boot (`randomize` + one
  frame, paused), `S`-resume, ` `, and `R`.  `LifeBlock` has no
  `busy`, so "engine idle" is trivially true; only the renderer
  gates.

### VT100 renderer (`src/render.vir`)

Much simpler than the BRAM design -- the state is on ports with no
read latency:

```virdant
mod Vt100Renderer {
    incoming clock : Clock
    incoming reset : Reset

    incoming draw        : Bit       // pulse: emit one frame
    incoming state_grid  : Word[64]
    incoming running     : Bit
    incoming speed_level : Word[4]
    incoming generation  : Word[16]

    client socket out of UartByte      // to UartSender
    outgoing busy : Bit
}
```

One flat FSM, stalled by `out.ready` per byte:

- `Preamble` (boot frame only): `ESC [ 2 J`, `ESC [ ? 2 5 l`.
- 16 grid rows (rows 3..18): `\x1b[<r>;33H` then 16 characters --
  two rows of terminal per grid row, each cell `"##"` or `"  "`.
  A 3-bit cell counter walks `state_grid[(y+1)*8 .. y*8]`; the
  two characters per cell come from the same bit.
- `HelpLine` (row 20): constant string, at most ~48 bytes, from a
  `match` on a character index (~100-130 LUTs -- the first thing
  to cut if synthesis is tight).
- `StatusLine` (row 22): `RUN`/`PAUSE` mux, `SPEED` as one hex
  nibble, `GEN` as the four BCD digits + `'0'`.
- `Done`: `busy` low; a `draw` mid-frame is latched by control.

Frame: 16x23 + ~90 for help/status ~= 460 bytes ~= 40 ms at
115200 baud.

### `src/top.vir` -- `Top`

Standard iCEstick shell (modeled on `echo`): 16-bit power-on reset
counter, `UartReceiver`, `KeyboardControl`, `LifeBlock`,
`Vt100Renderer`, `UartSender`, LED wiring, flash pins idled.

The torus wrap is eight top-level wires -- the only place the
world's topology exists:

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

## Resource budget (iCE40-HX1K: ~1,280 LUTs, ~1,280 FFs)

| Piece | FFs | LUTs (estimate) |
|-------|-----|------------------|
| 64 x LifeCell | 64 | ~640-1,030 (8-16 each) |
| LFSR 64-bit + BCD generation | 80 | ~25 |
| UART sender + receiver | ~60 | ~150 |
| Renderer | ~30 | ~150 (help line included) |
| Control | ~60 | ~80 |
| Top (reset counter etc.) | 16 | ~10 |
| **Total** | **~310** | **~1,050-1,450** |

FFs are comfortable; **LUTs are the budget** and the per-cell rule
cost decides everything.  Hence the phase-3 synthesis gate:
synthesize `LifeBlock` alone, read the LUT count, and only then
commit to the help line and the renderer's full feature set.

Fallbacks in order if over budget: golf the rule further (share
comparators, fold into adders); cut the help line (~120 LUTs);
share row-sum partials across a row (~30% of cell LUTs, at the
cost of the clean one-module-per-cell structure -- last resort).

## Files

```
life/
  Virdant.toml        (exists: name=life, top=top::Top)
  Makefile            test / upload / clean
  PLAN.md             this file
  src/
    top.vir           top level: reset, pins, torus wrap, LED wiring
    uart.vir          UartSender/UartReceiver (copied from echo/)
    life.vir          LifeCell (the rule) + LifeBlock (8x8 tile)
    render.vir        VT100 frame renderer
    control.vir       key decode, run/pause, speed, tick scheduler
  scripts/
    life.py           golden model: LFSR mirror + Life simulation,
                      emits expected UART byte streams
    connect           minicom helper (copied from echo/)
  verilog/
    tb.sv             testbenches: exhaustive LifeCell (512 cases),
                      end-to-end Top (UART driver, frame capture)
  build/              (generated)
```

## Testing

`make test` -> `vir run-icarus`, following the morse/flash_animation
precedent.

**Bench 1 -- exhaustive `LifeCell`**: instantiate `\life::LifeCell`
directly, drive all 512 combinations of center + 8 neighbors, check
`next_state` against a golden table.  The rule is *proven*, not
sampled.

**Bench 2 -- end-to-end `Top`**: drives real UART frames at 104
cycles/bit, logs every TX byte with cycle stamps framed by each
frame's leading `ESC`, and compares the stream against
`scripts/life.py` -- which mirrors the 64-bit LFSR (same seed,
taps, bit-to-cell order), simulates B3/S23 on the 8x8 torus, and
renders the *identical* VT100 byte stream including the zoomed
layout and status line.  Two independent implementations agreeing
byte-for-byte is the point.

Cases: boot (clear + frame + paused, `led5` dark); `R` matches
golden; ` ` advances exactly one generation; `S` runs at the
default spacing (measured in cycles between frame starts), `led5`
lit; `=`/`-`/`0` change spacing and the LED binary; pause/step;
unknown bytes ignored.

## Implementation phases

1. **Scaffold**: copy `uart.vir`/connect, write the Makefile, build
   a trivial echoing top -- proves the toolchain; `make upload`
   proves the board.
2. **`LifeCell` + exhaustive bench**: the rule, proven over all 512
   neighborhoods, before anything depends on it.
3. **`LifeBlock` + wrap + SYNTHESIS GATE**: 64 instances, LFSR,
   generation, boundary ports, torus wrap in top.  Synthesize the
   block alone, read the LUT count, decide on golf/help-line per
   the resource budget.  Everything downstream assumes this gate
   passed.
4. **Renderer**: frame FSM, zoomed grid, help and status lines.
5. **Control + integration**: keys, speed scheduler, boot
   sequencer, LEDs, flash pins idled; first hardware bring-up
   (randomize + manual stepping).
6. **End-to-end tests**: `verilog/tb.sv` bench 2, `scripts/life.py`.
7. **README**: usage, key table, un-hide-cursor note, future-work
   pointer.

## Future work

- **The accelerator / tile reuse** (the reason the boundary is
  ports): attach `LifeBlock` to a host bus instead of a display --
  a UART/SPI protocol that seeds the LFSR, streams `advance`
  pulses at MHz tick rates (generations in nanoseconds), and reads
  `state_grid` back.  Same block, display bypassed: a Life
  coprocessor.  And on a bigger chip (HX8K: ~7,680 LUTs, UP5K:
  ~5,280), tile 2x2 or 3x3 of the *same* 8x8 block through the
  edge and corner ports for 16x16 / 24x24 worlds.
- **Pattern loading from SPI flash (`L` key)**: reuse the
  `SpiFlashReader` from `flash_animation`; the image is tiny now --
  magic byte plus 64 seed bits written through `load_seed`.  ASCII
  art in, `iceprog` at 0x40000, as in that project.
- **Bigger worlds, software style**: swap `LifeBlock` for the
  sequential BRAM row-window engine (one shared rule unit, one
  cell per cycle, world in ping-pong BRAM) -- 80x22 fits the same
  chip; the `LifeCell` rule module carries over verbatim.
- **Rule variants**: the `LifeCell` seam makes B36/S23 (HighLife),
  B2/S (Seeds), etc. one-line changes -- or a rule select input
  wired from flash or a key.
- **Baud bump**: the FTDI is an FT2232H; 921600 baud is a
  `cycles_per_bit` change (13 at 12 MHz) if frames ever need to
  be faster.

## Risks / notes

- **LUT budget is the whole risk** (see resource budget).  The
  phase-3 gate exists to measure it early, with three fallbacks
  listed in order.  FFs and routing are comfortable at 8x8.
- **Per-cell LUT estimate is the soft number**: 8-16 LUTs spans
  "golfed" to "naive"; yosys's comparator/share optimizations
  decide where in that range we land.  Measure, don't assume.
- **Fast speeds are UART-bound** by design (render throttling,
  ~25 generations/s max); the status line keeps the visible speed
  honest.
- **VT100 variance**: stick to CSI-H / 2J / ?25l; the renderer
  emits real decimal row numbers.
- **64 hand-written cell instances** are verbose but explicit --
  every neighbor wire is visible, which is where Life hardware
  bugs actually live.  The exhaustive cell bench covers the logic;
  the wiring is covered by the end-to-end golden frames.
