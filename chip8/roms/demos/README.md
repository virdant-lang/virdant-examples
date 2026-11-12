# Demos

Famous public-domain CHIP-8 demos from the [kripod/chip8-roms]
(https://github.com/kripod/chip8-roms) collection — all self-running,
no user input needed.  Converted to `.flash` images with
`tools/make_flash.py` (classic font at 0x000, program at 0x200).

| demo | what it is |
|---|---|
| `trip8` | **Trip8 Demo (2008)** by Martijn Wenting / Revival Studios — the most famous CHIP-8 demo: intro, 3D vectorballs, randomized dot-effects. Runs ~143M cycles (~20 wall minutes) of attract mode before its FX0A key wait, so just let it play. |
| `maze` | David Winter's classic maze generator — draws a new random maze over and over (34 bytes!). |
| `stars` | Starfield by Sergey Naydenov. |
| `sierpinski` | Sierpinski triangle by Sergey Naydenov. |
| `particle` | Particle effect by zeroZshadow. |
| `zero` | Tiny effect demo by zeroZshadow. |

## Running

```
vir run --flash roms/demos/trip8.flash
```

No keys required.  (If a demo does stop on a key prompt, the UART
keypad toggle means you press the same key twice to register a
press-and-release — see `roms/games/README.md` for the key map and
caveats.  The core runs ~200x slower than wall time in the simulator:
delay-timer-driven animation ticks once per ~8 wall seconds.)
