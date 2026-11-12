# HANDOFF — Berkeley HardFloat in Virdant (binary32)

A from-scratch implementation of the RISC-V F extension's datapath in
the Virdant HDL, modeled on John Hauser's berkeley-hardfloat. All
operands use HardFloat's 33-bit *recoded* format internally; IEEE
binary32 lives only at the boundary.

Everything except divide/square-root is combinational; div/sqrt is the
project's first sequential module (digit recurrence, ~28 cycles).
All modules are verified by differential simulation against
independent references: a Fraction-exact Python model (`fuzz.py` for
the FMA, `divmodel.py` for div/sqrt) and, for IEEE corner semantics,
the correctly-rounded glibc oracle pattern (`fmaf`, `fesetround` +
`fetestexcept`).

## Layout

    ALGORITHM.md          All IEEE 754 algorithms in Virdant-style
                          pseudocode (rounding rules, flags, corners)
    MULADDRECFN.plan      Plan for the FMA (superseded by code, but the
                          recoded-format ground truth in section 1 is
                          still the reference)
    COMPARERECFN.plan     Plan for the comparator
    DIVSQRTRECFN.plan     Plan for divide/sqrt, including section 11
                          (post-implementation corrections — read it,
                          it overrides sections 3/4 in places)
    HANDOFF.md            This file
    fputils.py            Shared Python: IEEE<->recoded conversion
                          (independent of the RTL), image writing,
                          vir-run packet plumbing; `IMAGE_DIR` lets
                          parallel workers redirect the image path
    fuzz.py               FMA fuzzer: Fraction-exact mode-aware
                          reference (values AND flags), corner-vector
                          battery, biased random generator
    divmodel.py           Divide/sqrt reference + fuzz battery: exact
                          rational results rounded by pure integer
                          comparisons (quotients have non-power-of-two
                          denominators, so fuzz.round_scaled does NOT
                          apply — see DIVSQRTRECFN.plan 11.3); CLI:
                          `python3 divmodel.py [n_random] [seed]`,
                          `python3 divmodel.py model` = datapath-model
                          cross-check
    add_mult, compare,
    select, divide, sqrt,
    fntorec, rectofn,
    itof, ftoi, classify  CLI drivers, one per operation; every run
                          self-checks against a Python reference and
                          exits nonzero on mismatch. divide/sqrt take
                          an optional rounding mode (rne/rz/rup/rdn/rmm
                          or 0..4); itof/ftoi take an optional
                          signed|unsigned before the mode. rectofn
                          models the documented sNaN->IEEE-infinity
                          boundary quirk in its self-check.
    add_mult.img          Generated testbench input image (gitignored
                          artifacts: do not edit by hand)
    src/*.vir             One package per module family (see inventory)
    tests/corpus.py       Checked-in regression corpus: the FMA and
                          div/sqrt corner batteries plus historical
                          fixed-failure cases; fuzz.py/divmodel.py
                          replay it deterministically every run

The C oracle for IEEE corner semantics (zero-sign rule, tininess,
overflow thresholds) lived at /tmp/coracle{,2}.c — recreate if gone:
`fmaf()` under `fesetround` + `fetestexcept`, reading 3 hex u32
operands + a mode index, printing result bits + flags. It was
cross-checked against `fuzz.ref_fma` on 1500 random cases (0
mismatches). Ground truth for div/sqrt algorithms: the reference Scala
in /tmp/berkeley-hardfloat (`DivSqrtRecFN_small.scala` — submodules
berkeley-softfloat-3 and berkeley-testfloat-3 are EMPTY; only the
Scala is checked out).

## The recoded binary32 format (the one thing to internalize)

    [32]      sign
    [31..23]  recExp : Word[9]
    [22..0]   fract  : Word[23]

Decode-equivalence classes of recExp (comparison and conversion must
respect the *classes*, not canonical encodings):

    0..63    zero      (any low bits decode as signed zero)
    107..129 subnormal
    130..383 normal
    384..447 infinity (any low bits decode as signed infinity)
    448..511 NaN

Uniform value formula, valid for subnormal and normal alike:

    value = (2^23 + fract) * 2^(recExp - 279)

Canonical encodings this project emits: zero = 33'h0 with the sign bit
for -0, infinity recExp = 384, NaN recExp = 448 with the quiet bit
(fract bit 22) SET — without it, RecFnToFn round-trips the value to
IEEE infinity. The quiet bit defines sNaN: a NaN with fract bit 22
CLEAR is signaling (`Decode` exports `is_snan`); note the quiet bit is
word bit **22** (a former off-by-one: it is NOT bit 23).

## Module inventory and status

All modules `vir check` clean (0 warnings).

| Module (package) | F extension | Status |
|---|---|---|
| `MulAddRecFnBinary32` (muladdrecfn) | FADD/FSUB/FMUL/FMADD-FNMADD | **done**: fuzz was ~1.1% mismatches, now 0 failures/0 flaky on full batteries (seeds 1000-1007 + 1008-1015 fresh seeds); corner battery 150/150 |
| `CompareRecFnBinary32` (comparerecfn) | FLT/FLE/FEQ | done, 20+ vectors |
| `SelectRecFnBinary32` (selectrecfn) | FMIN/FMAX | done, 20 vectors |
| `FnToRecFnBinary32` (fntorecfn) | (boundary) | done, 21 round-trips |
| `RecFnToFnBinary32` (recfntofn) | (boundary) | done, bit-exact |
| `IntToRecFnBinary32` (inttorecfn) | FCVT.S.W/WU | done, ~30 vectors |
| `RecFnToIntBinary32` (recfntointfn) | FCVT.W/WU.S | done, ~80 vectors |
| `ClassifyRecFnBinary32` (classifyrecfn) | FCLASS.S | done, all 10 classes |
| `RecFnClassBinary32` (recfnclass) | (shared helper) | done |
| `EncodeRecFnBinary32` (muladdrecfn, **pub**) | (shared rounder) | done; now shared by FMA and div/sqrt; gained a `divide_by_zero` input (threaded only into the NaN/inf flag paths; FMA passes false — re-fuzzed, bit-identical) |
| `DivSqrtRecFnBinary32` (hardfloat) | FDIV/FSQRT | **implemented, in final verification**: corners 225/225, seed-777 600-case fuzz running at handoff time; check /tmp/divfuzz2.log or rerun |

Non-pub helpers stay in their own package's file (project rule).

## What fixed the FMA (the debugging record)

Three RTL bugs + two reference bugs, found by the fuzz methodology:

1. **`invalid_exc` qNaN gate**: a qNaN operand must SUPPRESS the
   0*inf / inf-inf invalids; only sNaN raises unconditionally.
   `invalid_exc = any_snan || (!any_nan && (conflicts))`.
2. **SignMagAdd sticky fold**: the effective-subtraction arms folded
   the incoming sticky as a full window ulp and reported
   `sticky_out = 0`, misplacing the true remainder (±1-ulp errors).
   Correct: a>b folds one ulp off the integer part and keeps sticky;
   b>a keeps the remainder as-is with sticky out; equal magnitudes
   cancel to zero with the sticky carrying the whole magnitude.
3. **`SignMagAdd.sum_sign` zero-cancellation sign**: when a zero-class
   operand with a high recExp acts as the "big" operand (sig=0) and
   both windows collapse to 0, the result magnitude is the small
   operand's dropped fraction — the sign must be the SMALL operand's
   sign (was taking the big operand's), which flipped directed-round
   direction (RNE gave +0 instead of −0).
4. **Reference: overflow implies inexact** (fuzz.py `ref_fma`): an
   exact value landing exactly on the unbounded grid past max finite
   still rounds to inf/max-finite ≠ exact.
5. **Reference: inf·inf is well-defined** (fuzz.py `ref_fma`): invalid
   comes only from inf·0 and the ADDITION conflict inf + (−inf);
   glibc `fmaf` confirmed on 4800 fresh cases.

## Divide/sqrt architecture (DivSqrtRecFnBinary32)

Read DIVSQRTRECFN.plan first — section 11 (implementation
corrections) OVERRIDES sections 3/4 where they differ. Short form:

- Hauser digit recurrence, one digit per cycle, uniform 27 digits
  (c_1 = integer bit, weight 2^(1-i) for division; sqrt digits at
  2^(-i) with the odd-exponent prescale arg' = 2*a_frac).
- Workspace rem = r * 2^(i+28) (Word[31]); division terms are
  constants (term = sig_b<<5, sub = <<6); sqrt keeps x28 = x*2^27
  (Word[28]) and a shifting weight register w = 2^(27-i),
  term = 2*x28 + w, sub = 2*term. Everything integral and exact
  through all 27 digits; sticky = (final exact remainder != 0).
- Delivery at cycle 2: normalize (division: c_1=0 means shift the
  digits up one and recExp_out -= 1), then ONE rounding inside the
  shared `EncodeRecFnBinary32` at the effective precision.
- Exponents: division recExp_out = recA - recB + 256 (-1 more when
  c_1=0; computed as zext(recA) + (512 - recB) + 1512/1513 to stay
  positive); sqrt recExp_out = (recA >> 1) + 128 for BOTH parities —
  the result is always normal class (never over/underflows).
- Special cases (DIVSQRTRECFN.plan section 2): qNaN/sNaN per the FMA
  rules (sNaN → invalid; qNaN silent); 0/0 and inf/inf → invalid;
  finite/±0 → ±inf + divide_by_zero; **inf/0 → inf, no flags**;
  **finite/inf → ±0, no flags**; 0/normal → ±0; sqrt(±0) = ±0;
  sqrt(negative incl. -inf) → invalid.
- FSM: cycle 0 idle (req.ready high), 29..3 = digits, 2 = delivery
  (result.valid = cycle==2, combinational payload), then 0. Latency:
  28 cycles recurrence path, 2 specials. Backpressure: ready only in
  idle (untested by the testbench — single-request images only).

## IEEE corner semantics (probed empirically, trust these)

Established with the C oracle (glibc) and encoded in the references:

- **Zero-sign rule**: like operand signs keep that sign; opposite
  signs give +0, except toward-negative gives -0. NOT "sign of the
  product" and NOT sign XOR. Tiny values flushed to zero keep their
  own (magnitude) sign.
- **Tininess is after rounding**: exact just-below-min-normal that
  rounds UP sets inexact but NOT underflow; flushed-to-zero (or
  delivered subnormal) with inexact sets underflow.
- **Overflow is post-rounding**: flagged iff the rounded value reaches
  the inf class. RNE/RMM round up at the tie → inf + overflow;
  directed modes that round magnitude DOWN deliver max_finite with no
  overflow flag when the exact value is within half an ulp above max
  finite. **Overflow implies inexact** (both references enforce it).
- **qNaN operands propagate silently** (result NaN, no flags); sNaN
  operands raise invalid. A qNaN operand SUPPRESSES the 0*inf /
  inf-inf invalid. inf·inf is well-defined (no invalid).

## Testbench protocol (src/top.vir)

One image (`add_mult.img`, 8 slots of Word[64], MSB-first raw bytes),
one 64-bit result packet streamed out the debug channel LSB-first,
then exit(0). Image layout:

    word 0..2   operands (33-bit recoded values, or 32-bit IEEE/int)
    word 2      control bits for ops 4..9 (see below)
    word 3      operation selector, now Word[4] = bits [3..0] of word 3
    word 4      FMA rounding mode, bits 4..2 (word 2 is the FMA's `c`)

IMPORTANT: unwritten image words read as *pseudorandom* — always
write words 0..4 explicitly.

Operations: 0 = FMA (mode in word 4), 1 = compare, 2 = IEEE->recoded,
3 = recoded->IEEE, 4 = FMIN/FMAX, 5 = int->float, 6 = float->int,
7 = classify, **8 = divide, 9 = square root** (multi-cycle: the packet
samples when the unit's result turns valid; use cycles=45).

For ops 4..9: word 2 bit 0 = select_max / signed flag (unused for
8/9); word 2 bits 4..2 = rounding mode (0 RNE, 1 RZ, 2 Rup, 3 Rdn,
4 RMM), wired through `cast()`. div/sqrt read the mode from word 2.

**Div/sqrt two-request mode** (backpressure test): for ops 8/9, word 2
bit 0 = second-request enable. When set, a second request is issued
from image words 5/6 (mode in word 7 bits 4..2) the cycle after the
first result is consumed, and a second 8-byte packet follows (16 bytes
total, exit at step 17; use cycles=90). The first request stays valid
through the whole computation (the unit must ignore it while not
ready); the second exercises the return-to-idle path. divmodel.py
runs a 35-case battery over this in every invocation.

Packet layouts (payloads at the TOP of the word, MSB-first):

    FMA / int->float:  [63..31] recoded out, [30..26] exception flags
    divide / sqrt:     [63..31] recoded out, [30..26] exception flags,
                       [25..18] latency in cycles (1 special, 28
                       recurrence)
    compare:           [3..0] = unordered, gt, eq, lt
    converters:        [63..31] (33-bit) or [63..32] (32-bit) result
    select:            [63..31] selected operand
    float->int:        [63..32] integer, [31..29] int exception flags
    classify:          [63..54] one-hot class bits

`vir run` writes the debug bytes to the simulator's **stderr** stream
(stdout is empty); the packet is the first 8 stderr bytes,
little-endian. `fputils.run_packet(words, cycles)` handles all of
this. Div/sqrt need ~38 cycles (fire + 28 + stream + exit at step 9);
45 is safe.

Exception-flag bit order (Word[5]): bit 4 = inexact, bit 3 =
underflow, bit 2 = overflow, bit 1 = divide_by_zero, bit 0 = invalid
(HardFloat order, `word()` packs MSB-first so the FIRST word() arg is
bit 4). Int exception flags (Word[3]): invalid, overflow, inexact.

Rounding modes (hardfloat::RoundMode): NearestEven=0, TowardZero=1,
TowardPositive=2, TowardNegative=3, MaxMagnitude=4. NOTE: this is
HardFloat's order, which differs from RISC-V frm encoding (2/3 are
swapped).

## Conventions and hard-won Virdant gotchas

Style: CamelCase modules, snake_case ports, `//>` doc comments,
4-space indent, `vir check` clean (warnings are bugs), `vir format`
reflows aligned colons — run it after structural edits, and re-read
regions before editing (format moves text; text-match edits silently
no-op after a reformat — always assert/grep that your edit applied).

Original gotchas (still true):

- Slices are exclusive on top: `x[hi..lo]` = bits hi-1..lo. A single
  bit is `x[k]`. So `x[14..13]` is ONE bit; `x[27..0]` on Word[28] is
  bits 26..0, NOT the whole word — this caused a stuck shift register
  (the "shift" reproduced its own input).
- Never read an outgoing port inside its own module ("Read from
  sink") — mirror into a wire.
- `unused` statements must attach right after a declaration item.
- `dependson` is transitive through instance inputs AND if-statement
  conditions. Only declare what the checker asks for.
- `word()` is MSB-first: the FIRST arg is the TOP bit. Getting this
  backwards moved a flag bit — real bug caught by the fuzzer.
- Barrel shifters need one mux stage per shift-amount bit.
- No `*`, no `<<`/`>>`, no loops, no functions, no Nat-generic
  modules. Shifts are `word()`+slices (constant) or mux-stage barrels
  (dynamic).
- `memory` images: unwritten words are pseudorandom; `@image` paths
  resolve from the project root (or the worker copy's root).
- Enum cross-package: `import hardfloat` then `#NearestEven`;
  `cast(word_slice)` converts bits to enums.
- `vir run` can transiently return wrong results under system load
  (observed again this session: a correct-packet trace and a failing
  compare on the SAME image). The fuzz workers RETRY every mismatch
  twice and only count reproduced failures. If a mismatch vanishes on
  rerun, it is the simulator, not the design.

NEW gotchas from the div/sqrt work (see DIVSQRTRECFN.plan 11.6 for
detail):

- Statement conditionals are ALWAYS `if { when ... }`. A bare `when`
  inside a reg driver body is a syntax error whose cascade reports
  nonsense ("Unresolved type" far away, "Missing on clause for reg",
  everything "unused"). Sequential `when` arms in one if are legal;
  `else` binds to the last when.
- Struct field projection is `->` (e.g. `r->out`), not `.`; struct
  literals are `${field = expr, ...}`.
- `+.`/`-.` widen by a carry/borrow bit; plain `+`/`-` keep width.
  Use plain ops when no carry can occur and `zext` for width
  matching (incrementing a counter is `it + 1w4`, not `+.`).
- A `client socket` on the platform-top module becomes undeclared
  platform ports — drive an instance's server-socket channels
  directly (`it.req.data := ...`) instead.
- `initial` applies only when NO driver assigns that cycle: gate
  "hold" arms explicitly or cycle 0 latches pseudorandom (this ate a
  packet once).
- Registers are pruned from the VCD unless their full value is read
  somewhere.
- `vir run --trace <file>` writes a VCD — but timestamps are
  half-cycle; combinational settle values appear between register
  edges. Cross-check register values at their change timestamps only.

## Known issues and deferred work (in priority order)

1. **Div/sqrt final verification** — DONE. Seed-777 600-case fuzz:
   825 total cases (225 corners + 600 random), 0 failures, 1 flaky
   (simulator transient, passed on retry). Cycle-count assertions:
   every div/sqrt packet now carries its request's measured latency
   in bits [25..18], asserted by divmodel (1 cycle special path, 28
   recurrence -- note the HANDOFF's old "2 specials" was the FSM
   STATE number, not the measured latency). Two-request backpressure
   test: 35-case battery in every divmodel.py run (see testbench
   protocol below), exercising the return-to-idle path with all
   special/recurrence first/second combinations.
2. **Persist the regression corpus** — DONE: the corner batteries and
   the historical failing cases now live in `tests/corpus.py`; fuzz.py
   and divmodel.py import them (single source of truth) and replay
   them as the `corners:`/`historical:` phases of every run. Add any
   future reproduced-and-fixed case to HISTORICAL_FMA/DIV/SQRT there.
   The full working tree is now committed (first commit includes the
   corpus); keep committing after each verified change.
3. **fcsr plumbing**: frm -> rounding mode everywhere (the FMA takes
   its mode from image word 4; div/sqrt and the other ops from word
   2), sticky flag accumulation into fflags (currently per-op),
   NaN-boxing for RV32. Then pipelining the FMA (stage boundaries
   already exist as module seams).
4. **Optional cleanup**: promote RecFnClassBinary32 into
   compare/select/recfntofn (they predate it and keep local copies);
   decide EncodeRecFnBinary32's home (currently pub inside
   muladdrecfn; a shared `rawencode` package was the plan's option
   (b)). CLI drivers are DONE — one per operation (see Layout);
   divmodel.py could still reuse fuzz.py's corner-battery
   scaffolding.

## How to verify a change

Every driver self-checks; the batteries are the regression suite.
Minimum after touching anything:

    vir check
    ./add_mult 2 3 1          # 7.0
    ./add_mult 0.5 0.25 0.1   # 0.22499999403953552 (exact-tie, RNE)
    ./compare 0 -0            # eq=1
    ./select 0 -0 min         # -0.0
    ./select nan 1 max         # 1.0

Then the batteries (fast):

    python3 fuzz.py 0         # FMA corners, all 5 modes (150 cases)
    python3 divmodel.py 0     # div/sqrt corners, all 5 modes (225)

Random fuzz (FMA; 8 workers, ~10 min — ONE battery per pass, the
timeout lesson):

    rm -rf /tmp/fuzzw*; for i in 0 1 2 3 4 5 6 7; do
      [ $i -eq 0 ] && C=corners || C=
      python3 fuzz_worker.py $i 600 $((1000+i)) $C > /tmp/fuzzw$i.log 2>&1 &
    done; wait; grep -h "WORKER\|corners done\|FAIL" /tmp/fuzzw*.log

Random fuzz (div/sqrt; sequential, ~1.5s/case):

    python3 divmodel.py 500 <seed>

Exit codes are nonzero on reproduced mismatch; the `flaky` counter
reports simulator transients (should stay 0). Retry any direct
compare twice before believing it.

To dissect a div/sqrt failure: `divmodel.model_div` / `model_sqrt`
reproduce the RTL bit-for-bit (verified against exact arithmetic);
diff their per-digit state against the Fraction-exact reference. For
the FMA: pipemodel.py + fuzz.py (note pipemodel is STALE post-rework —
the subnormal agent kept a corrected model in /tmp/model2.py; promote
or delete it).
