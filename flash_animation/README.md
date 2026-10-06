# flash_animation

An LED light show for the iCEstick that plays out of SPI flash.

The design in `src/` is a fixed, generic *player*: it never changes
once built. The animation itself is a tiny bytecode program stored in
the configuration flash far above the bitstream, at offset 0x40000
(256 KiB). Reprogram the flash content and the board plays a
different show -- no resynthesis, no rebuild.

## The bytecode

The image starts with the magic byte 0x56 (`V`); the program follows
from byte 1. One instruction at a time, the player fetches and runs:

| Bytes          | Meaning                                           |
|----------------|---------------------------------------------------|
| `00`           | halt: freeze the LEDs                              |
| `01 pattern`   | set: light the LEDs in `pattern` (bit 0 = LED 1)   |
| `02 ticks`     | wait: hold for `ticks` ticks (one tick = 2^17 clock cycles, ~10.9 ms at 12 MHz) |
| `03 low high`  | jump: continue at byte offset `high * 256 + low` of the image |
| `04 quarters` | pause: hold for `quarters` quarter-seconds (0.25 to 1.00 s in 0.25 s steps) |

With `set`, `wait`, `pause`, and `jump` you get loops, chasers,
heartbeats -- anything expressible as timed patterns. If the magic
byte is missing (empty or unprogrammed flash), the player falls
back to a built-in knight-rider sweep, so a freshly programmed
board still does something.

Animations are written in a small text format and assembled by
`scripts/anim.py`:

```
loop:
    set 0b00001      # bit 0 is LED 1, ..., bit 4 is LED 5
    wait 1
    set 0b00010
    wait 1
    ...
    pause 0.5        # hold the current pattern for half a second
    jump loop
```

## Selecting an animation

Any `.txt` in `content/` is an animation; pick one with the
Makefile's `ANIM` variable (the default is `content/anim.txt`):

```
make test ANIM=content/showcase.txt          # simulate a specific show
make upload-content ANIM=content/showcase.txt  # flash a specific show
```

`make upload` and `make upload-content` touch disjoint flash regions,
so the order does not matter, and re-uploading the bitstream leaves
the animation intact.  Only one animation lives in the flash at a
time -- uploading another simply overwrites the same region.

## Usage

Requires a `vir` built from the current virdant checkout (the
IceStick platform needs the SPI-flash pins in `lib/ice40.vir`; run
`make install` in the virdant repo first, or pass
`VIR=../target/release/vir`).

```
make test            # assemble the animation and simulate with Icarus Verilog
make upload          # synthesize and flash the bitstream
make upload-content  # program the animation at flash offset 0x40000
```

## The shows

| Animation            | Bytes | Transitions | Character                                  |
|----------------------|-------|-------------|--------------------------------------------|
| `content/anim.txt`   | 40    | 8 per loop  | a bouncing chaser with two pauses          |
| `content/showcase.txt` | 396 | 98 per loop | a five-movement medley: a slow solo walk, accelerating knight-rider sweeps, edge-to-center convergence, a binary count-up and count-down over the full 5-bit range, and a strobe-heartbeat finale |

## Layout

```
src/flash.vir     SpiFlashReader: one-byte READ (0x03) fetches at 6 MHz SPI
src/anim.vir      AnimationPlayer: fetches, decodes, and executes bytecode
src/top.vir       iCEstick top: reset generation and pin wiring
content/*.txt     the animations, one show per file
scripts/anim.py   assembler + bytecode simulator (see below)
verilog/tb.sv     testbench with a behavioral model of the SPI flash
```

`scripts/anim.py` assembles a `.txt` into `.bin` (for `iceprog`),
`.hex` (a $readmemh image for the flash model), and `.expect`: the
expected LED transitions, derived by simulating the bytecode the
same way the player runs it. The simulation is therefore a full
end-to-end test for any animation -- the bench's flash model plays
the assembled `.hex` and checks the design against `.expect`:
the sequence of patterns, the duration of every wait and pause,
and that `jump` restarts the show.

## Ideas

The player is the fun part to extend: add opcodes for relative
jumps, nested loops, or a `wait` on a switch input; store several
shows and pick one with the DIP switches; or make the animation
region double as a message the board prints over UART. The content
format is the seam -- the hardware never has to change.
