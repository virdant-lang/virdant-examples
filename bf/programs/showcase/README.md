# Showcase: famous brainfuck programs

Famous programs pulled from the web (Daniel B. Cristofani's archive at
brainfuck.org, CC BY-SA 4.0; mandelbrot.bf by Erik Bosman). These are here for
reading/admiration — most **cannot run on this project's machine**, for the
reasons noted. Each was verified with a faithful Python simulator
(8-bit wrapping cells) before being stored here.

| File | What it is | Why it can't `vir run` here |
|---|---|---|
| `mandelbrot.bf` | Erik Bosman's legendary ASCII Mandelbrot renderer (11.6 KB) | Program ROM is 4096 bytes; this is ~11.7 KB |
| `utm.bf` | Universal Turing machine (Rogozhin's 4-state UTM) — a direct proof that bf is Turing-complete | 18.8 KB > ROM; also needs `,` input (verified in sim: input `b1b1bbb1c1c11111d` → exactly the documented output `1c11111`) |
| `dbfi.bf` | A complete brainfuck interpreter written in 596 bytes of brainfuck (Cristofani/Mazonka) | Needs `,` input — feed it `CODE!DATA`; verified in sim: it ran a hello-world *inside itself* and printed `Hello World!` |
| `life.bf` | Conway's Game of Life (interactive, Linus Akesson-style interface) | Needs `,` input — verified in sim: toggled a blinker, advanced generations, watched it oscillate |
| `e.bf` | Computes e with unbounded precision, one digit at a time | Never halts (infinite digit stream) — would hang `vir run`; digits verified in sim: `2.718281828459045...` |
| `golden.bf` | Same idea for the golden ratio | Never halts; verified: `1.6180339887498948...` |
| `thuemorse.bf` | Thue–Morse sequence in provably optimal O(lg n) space | Never halts |
| `squares2.bf` | All square numbers, forever | Never halts |
| `factorial2.bf` | Unbounded factorials | Needs `,` input to start |
| `tictactoe.bf` | Playable tic-tac-toe | Needs `,` input (interactive) |
| `numwarp.bf` | Renders numbers in a big ASCII digit font | Needs `,` input |
| `xmastree.bf` | Animated ASCII Christmas tree | Needs `,` input (keypresses) |

The one archive piece that *does* run on this machine is installed as
`programs/sierpinski.bf` (309 bytes incl. its comment header — comments are
no-op bytes on the machine; verified on hardware: full 33-line Sierpiński
triangle in ~6 s).

Known quirk when running several programs back-to-back (e.g. `make examples`):
`vir run` can replay a stale program image if runs happen in rapid succession
(suspected mtime-granularity caching; a respawned `vir-ls serve` may also be
involved). Single runs are always correct — space them out if output looks
like the wrong program.
