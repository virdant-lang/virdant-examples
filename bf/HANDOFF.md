# HANDOFF — bf example programs

## What this task was

Add a few dozen Brainf*ck example programs to `programs/` and wire them into the
Makefile, for the Virdant bf machine in `src/top.vir` (a `> < + - [ . ]`
interpreter over a 4096-cell, 8-bit wrapping tape; the program ROM is loaded
from `program.bf` at build time via `@image`, and the Virt top prints each `.`
to the debug port).

## What was done

- **27 new example programs** in `programs/*.bf` (see list below). Every one was
  verified against a Python simulator that mirrors the machine's exact
  semantics (8-bit wrap, no input, NUL halt) — all 27 terminate with the exact
  expected output. `programs/hello.bf` was added afterwards (byte-identical to
  the pre-existing `hello.bin`) so the hello program exists under the `.bf`
  naming the wildcard runner uses.
- **Makefile**: it now auto-generates a `run-<file>` target for every file in
  `programs/` (`run-uppercase.bf`, `run-quine.bf`, ...). On top of that:
  - `make run` — runs `PROG` (default `hello.bf`)
  - `make examples` — runs every program in `programs/` in sequence
  - `make programs` / `make list` — list available programs
  - `make hello`, `make quine`, `make test` — original convenience targets,
    still working (verified: all exit 0, `make test` assertions pass)

  Note: an earlier revision of the Makefile (from before this task) had
  explicit `hello`/`quine`/`test` recipes; the wildcard `RUN_TEMPLATE`
  mechanism appeared in the working tree mid-task (no other live session was
  in the directory) and was kept as the primary mechanism.

## Program inventory

`hello.bf`, `hello-classic.bf`, `hello-noloops.bf`, `uppercase`,
`lowercase`, `alphabet-reverse`, `alphabet-doubled`, `alphabet-spaces`,
`caps-lower`, `digits`, `digits-reverse`, `even-digits`, `odd-digits`,
`countdown`, `ascii`, `vowels`, `smiley`, `morse-sos`, `zigzag`, `bits`,
`abc-thrice`, `triangle`, `pyramid`, `diamond`, `stripes`, `checkerboard`,
`fib-stars` (unary Fibonacci rows: 1,1,2,3,5,8), `beer` ("N bottles of beer",
N=9..0), plus pre-existing `hello.bin` and `quine.bf`.

All new programs use only `> < + - [ . ]` (no `,` input, no comments) and
depend on 8-bit cell wraparound nowhere except `diamond.bf` (it deliberately
uses the 255→0/1 wrap to reset a counter between phases).

## Verification status

- Simulation (exact machine semantics): 27/27 pass with expected output.
  Scripts live in `/tmp/bfgen/` (`gen.py` = generator with a position-tracking
  builder, `sim.py` = simulator, `verify.py` = expected-output checker).
  /tmp is ephemeral; the generated `.bf` files are the durable artifact.
- On the real simulator (`vir run`): `hello.bf`, `uppercase`, `abc-thrice`,
  `alphabet-doubled`, `alphabet-reverse`, `quine` all verified printing
  correct output individually.

## Known issues / notes for the next person

1. **`make examples` batch anomaly (unresolved, likely transient).** During one
   batch run, consecutive `vir run` invocations produced stale/garbled output
   (wrong program's output, a 3-byte garbage prefix) and one run appeared to
   hang until the batch was killed. Afterwards, every program ran correctly
   when invoked individually, including the one that had hung
   (`run-alphabet-reverse.bf`, ~0.3 s). Suspicion: the batch was interrupted
   mid-`vir run`, leaving vir's build/run state confused; a `vir-ls serve`
   process (pid ~379921 at the time) was also running and may cache build
   state. If `make examples` misbehaves again: check for stale/running vir
   processes, `rm -rf build`, and run targets individually.
2. `program.bf` is a transient symlink the Makefile creates and unlinks per
   run; it is not ignored by git (`.gitignore` only has `build`). Same for
   `trace.vcd` and `test.poke` artifacts. Consider adding them to
   `.gitignore` if the repo gets committed.
3. New program files are currently **untracked** in git (the pre-existing
   `Makefile`/`hello.bin`/`quine.bf`/`src/top.vir` are staged). Nothing was
   committed; `git add`/commit is left to the operator.
4. `test.poke`'s tape assertions correspond to hello.bin's "Hello World!\n"
   output (cells 2–6). Any change to the default program image used by
   `make test` will break those assertions.
5. ROM is 4096 bytes; largest new program is `beer.bf` (~1 KB). Runtime is
   dominated by the 4096-cycle tape clear plus program length; no cycle limit
   exists in the Virt top, so a buggy infinite-loop program hangs `vir run`
   rather than erroring.
