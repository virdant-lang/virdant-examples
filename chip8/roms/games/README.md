# Games

Public-domain CHIP-8 games from the [CHIP-8 Archive]
(https://github.com/JohnEarnest/chip8Archive), converted to `.flash`
images for this machine's SPI-flash loader with `tools/make_flash.py`.

| game | what it is |
|---|---|
| `br8kout` | Breakout |
| `snake` | Snake — plays with **W/A/S/D** |
| `tank` | Two-player tank duel |
| `superpong` | Pong |
| `dodge` | 56-byte reflex dodger |
| `sweetcopter` | One-button helicopter |

Each `.flash` image is 4 KiB: the classic 16-glyph font at 0x000 (FX29
looks glyphs up at `5 * Vx`, so the font must live there), the program
at 0x200, 0xFF padding elsewhere.

## Running

```
vir run --flash roms/games/snake.flash
```

Keystrokes go over the board's UART (115200 8N1): just type into the
terminal.  The UART decoder maps the classic CHIP-8 keypad layout
(both cases accepted):

```
1 2 3 4        1 2 3 C
Q W E R   ->   4 5 6 D
A S D F        7 8 9 E
Z X C V        A 0 B F
```

## Playing notes / caveats

- **Press-and-release.** UART has no release signal, so the decoder
  toggles: a character *presses* its key, the **same character again
  releases it**.  Games that wait for a key with FX0A (press AND
  release — e.g. snake's title screen) want you to hit the key **twice**
  (press, then release).  Typing a different key's character moves the
  press; at most one key is held at a time.
- **Speed.** The core runs 1 instruction per 100 000 board clocks
  (~500 CHIP-8 instructions per simulated second — classic VIP speed).
  The simulator manages roughly 110 000 board cycles per wall second,
  which makes everything about 200x slower than real time: the title
  screen alone takes ~40 wall seconds, and a game paced by its 60 Hz
  delay timer ticks once per ~8 wall seconds.  It is working —
  just very slowly.  See TODO.md for the speed-up options.
