# HardFloat Algorithms (IEEE 754-2008, binary32)

This document lists the functionality IEEE 754-2008 requires of a
binary32 implementation, with an algorithm for each, in a uniform
pseudocode style.

Operands and results are recoded `Word[33]` values (binary32:
1 sign bit + 8-bit exponent + 24-bit significand). The recoded format
means "unpack" and "pack" are pure slicing with no case analysis on
exponent-field extremes.

Module mapping:

| Required function group      | Module in this project          |
|------------------------------|---------------------------------|
| add / sub / mul / fma        | `MulAddRecFnBinary32`           |
| divide / squareRoot          | `DivSqrtRecFnBinary32`          |
| roundToIntegral*             | `MulAddRecFnBinary32` (variant) |
| copy / negate / abs / copySign | pure bit ops (no module needed) |
| int conversions              | `IntToRecFnBinary32`, `RecFnToIntBinary32` |
| format conversions           | `FnToRecFnBinary32`, `RecFnToFnBinary32` |
| comparisons                  | `comparerecfn::CompareRecFnBinary32` (COMPARERECFN.plan) |
| exception signaling          | `exception_flags : Word[5]` ports |

## 1. Fused multiply-add

The heart of floating-point arithmetic:

```
out = round32(a * b + c)    // one rounding, total
```

There are no separate add and multiply units. One FMA unit serves all
four arithmetic operations:

| Operation    | How to get it from the FMA |
|--------------|----------------------------|
| `a + c`      | `FMA(a, 1.0, c)`           |
| `a - c`      | `FMA(a, -1.0, c)`          |
| `a * b`      | `FMA(a, b, 0.0)`           |
| `a * b + c`  | `FMA(a, b, c)`             |

The recoded format makes this workable because `1.0`, `-1.0`, and `0.0`
are ordinary encodings with no special cases to detect.

```virdant
//> Pseudocode for FMA(a, b, c) on binary32.
//> All operands are recoded Word[33] — no IEEE special cases yet.

function fma32(a, b, c) -> (Word[33], Word[5]) {

    // 1. Unpack: recoded fields are uniform, so this is just
    //    slicing, no case analysis on exponent_field extremes.
    (a_sign, a_exp, a_sig) = decode(a)     // 24-bit significand, incl. leading bit
    (b_sign, b_exp, b_sig) = decode(b)
    (c_sign, c_exp, c_sig) = decode(c)

    // 2. Exact product: 24 x 24 -> 48 bits. This is the "fused" part.
    //    No rounding is possible here: 48 bits holds the exact product.
    prod_sig = a_sig * b_sig               // 48 bits
    prod_exp = a_exp + b_exp               // plain exponent add, no rounding

    // 3. Align: shift c's significand to line up with prod_sig.
    //    The shift can be hundreds of bits — but only the top ~24 bits
    //    of the shifted path matter, plus a sticky bit.
    shift = prod_exp - c_exp
    (aligned_sig, sticky) = shift_right(c_sig, shift)   // sticky = OR of lost bits

    // 4. Sign-magnitude add: prod and c may have opposite signs.
    //    If signs differ, the wider magnitude is negated (2's complement)
    //    and the sum is taken; the sticky bit is folded into the carry.
    sum = magnitude_add(prod_sig, aligned_sig, prod_sign, c_sign, sticky)

    // 5. Normalize: one leading-zero count + one shift. That's it.
    //    (The recoded format's job is to guarantee this is ONE step.)
    (sum_sig, sum_exp) = normalize(sum, sum_exp)

    // 6. Round — ONCE, at the very end:
    //    guard bits off the bottom + sticky decide RNE/RZ/Rup/Rdn/Rmm.
    (rounded_sig, rounded_exp, inexact) = round(sum_sig, sum_exp, rounding_mode)

    // 7. Overflow/underflow checks, then re-encode.
    (out, exception_flags) = encode(rounded_sig, rounded_exp, sum_sign, inexact)
}
```

Key design facts:

1. **Steps 2–5 carry no rounding error.**
   The only information loss in the entire datapath is the single
   `round()` in step 6. That is why the FMA is more accurate than
   multiply-then-add, and why the alignment in step 3 must keep the
   shifted-out bits (`sticky`) instead of discarding them.

2. **The alignment shift is huge but cheap.**
   Exponents can differ by a few hundred, but the datapath only needs
   the top ~24 bits of the shifted addend plus a sticky bit — carrying
   a 300-bit adder would be wasteful, and the extra bits cannot change
   the final rounded answer anyway.

## 2. roundToIntegral operations

Required and correctly rounded: `roundToIntegralTiesToEven` and
`roundToIntegralTiesToAway`. Recommended: the `TowardZero`,
`TowardPositive`, and `TowardNegative` variants.

Important: the required variants are *quiet* — they do **not** signal
`inexact`. (The recommended `roundToIntegralExact` variant does.)

```virdant
//> Round to an integral value in the same format.

function roundToIntegral32(a, mode) -> (Word[33], Word[5]) {

    (sign, exp, sig) = decode(a)

    // Already integral, infinite, or NaN: unchanged, no flags.
    if exp >= sig_width - 1 {
        return (a, 0)
    }

    // Number of fractional significand bits remaining.
    frac_bits = sig_width - 1 - exp

    // Round in place: zero out the low frac_bits of the significand,
    // using guard/sticky from exactly those bits plus the mode.
    discarded = sig[frac_bits..0]
    (rounded_sig, carry, _) = round(sig >> frac_bits << frac_bits,
                                    discarded, mode)
    rounded_exp = exp + carry              // carry can bump 1.99.. to 2.0

    return (encode(rounded_sig, rounded_exp, sign), 0)
}
```

## 3. Sign and NaN manipulation

Required, and trivially cheap — pure bit operations with **no
exceptions ever raised**, even for signaling NaNs:

```virdant
//> These are one-gate-per-bit ops on the raw Word[33].
//> No decode, no normalize, no rounding.

function copy(a) -> Word[33] {
    return a
}

function negate(a) -> Word[33] {
    return a ^ word(1, 0w32)              // flip sign bit only
}

function abs(a) -> Word[33] {
    return a & word(0, ones(32))          // clear sign bit only
}

function copySign(a, b) -> Word[33] {
    return (b & sign_mask) | (a & ~sign_mask)
}
```

## 4. Conversions

Required, correctly rounded in both directions.

### 4a. Integer to recoded binary32

```virdant
//> Convert a 32-bit integer (signed or unsigned) to recoded binary32.
//> Note: no overflow or underflow is possible — every 32-bit integer
//> lands inside binary32's normal range. Rounding is the only issue.

function intToFloat32(n, signed_in) -> (Word[33], Word[5]) {

    magnitude = signed_in ? abs(n) : n          // careful: most-negative value

    // Find the leading one: position k in [0, 32).
    k = leading_one_position(magnitude)

    // Align to a 24-bit significand; bits below become sticky.
    (sig, sticky) = align(magnitude, k)          // 24 bits + sticky
    exact = (sticky == 0)

    // Round once. Exponent: value = 1.sig x 2^(k - 23), re-biased.
    (rounded_sig, _, inexact) = round(sig, sticky, rounding_mode)

    return (encode(rounded_sig, k + 127 - 23, sign_bit), flags(inexact))
}
```

### 4b. Recoded binary32 to integer

```virdant
//> Convert recoded binary32 to a 32-bit integer.
//> signed_out is an INPUT selecting the target signedness.
//> int_exception_flags is three bits, most significant first:
//> invalid (NaN or infinity input), overflow (out of target range),
//> inexact. Invalid or overflowing results saturate: positive to
//> the target maximum, negative to the signed minimum or unsigned
//> zero (matching the reference RecFNToIN).
//>
//> Rounding note, applying to every rounder in this project:
//> max-magnitude (RMM) is nearest with ties away — the guard bit
//> alone decides; values below the halfway point round down even
//> when sticky is set.

function float32ToInt(a, mode) -> (Word[32], Bit, Word[2]) {

    (sign, exp, sig) = decode(a)

    // NaN or infinity: out of range for any integer.
    if is_nan(a) or is_inf(a) {
        return (max_int, sign, word(is_inf, is_nan))
    }

    // Exponent too small: rounds to 0 (or ±1 for round-away modes).
    if exp < 0 {
        (rounded, sticky) = round(0, sig, mode)
        return (rounded, sign, 0)
    }

    // Exponent too large: the true value exceeds 2^32 — invalid.
    if exp >= 31 (or 32 for unsigned) {
        return (max_int, sign, word(1, 0))       // invalid
    }

    // Otherwise: shift the significand left into integer position,
    // rounding the (fractional) excess bits.
    shift = exp - (sig_width - 1)
    (rounded, inexact) = round(sig << shift, 0, mode)

    return (apply_sign(rounded, sign), sign, flags(inexact))
}
```

### 4c. Format to format

```virdant
//> Widen or narrow between recoded formats.
//> Widening (binary32 -> binary64) is exact: re-bias the exponent,
//> pad the significand with zeros. No rounding, no flags.
//>
//> Narrowing (binary64 -> binary32) is a genuine rounding: treat the
//> excess significand bits as guard+sticky and round once.

function convert(a, mode) -> (Word[33], Word[5]) {
    (sign, exp, sig) = decode_wide(a)
    new_exp = exp - old_bias + new_bias        // plain integer subtract
    if new_exp fits normal range {
        (rounded_sig, inexact) = round(pad_or_trim(sig), sticky, mode)
        return (encode(rounded_sig, new_exp, sign), flags(inexact))
    }
    // Exponent out of range: overflow -> ±inf; underflow -> 0/subnormal.
}
```

## 5. Comparisons

Required: quiet comparisons (`==`, `!=`, `<`, `<=`, `>`, `>=`) and
signaling comparisons (which raise `invalid` on any NaN input).

Rule: any comparison involving a NaN is *unordered*; signaling
comparisons raise `invalid`, quiet ones do not.

The recoded format's payoff lands here. The key is a monotone map
from the raw `Word[33]` to an unsigned integer, so that the entire
comparison is one unsigned compare:

```virdant
//> Map a recoded value to a key whose unsigned order matches the
//> desired total order over all values.
//>
//> For non-negative values (sign bit clear): set the sign bit.
//> For negative values (sign bit set): invert ALL bits.
//>
//> Result: -inf < ... < -1 < -0 < +0 < +1 < ... < +inf.
//> (Earlier I claimed this was a single XOR on the sign bit — that
//> was wrong: flipping only the sign bit orders negatives backwards.
//> The correct trick is the conditional invert below. Still cheap:
//> one XOR layer plus one mux.)

function order_key(a : Word[33]) -> Word[33] {
    if a[33..32] == 1 {          // negative
        return ~a
    } else {
        return a | word(1, 0w32)
    }
}

//> Quiet comparison: unordered when either operand is a NaN.
function compare(a, b) -> (lt, eq, gt, unordered) {
    if is_nan(a) or is_nan(b) {
        return (0, 0, 0, 1)
    }
    ka = order_key(a)
    kb = order_key(b)
    return (ka < kb, ka == kb, ka > kb, 0)
}
```

Signaling comparisons run the same `compare` but also raise
`invalid` when `unordered` is true.

## 6. Exception signaling

Five flags, in HardFloat's fixed bit order — the `Word[5]` on every
module's output:

| Bit | Flag             | Raised when                                       |
|-----|------------------|---------------------------------------------------|
| [0] | `invalid`        | NaN operand, 0/0, inf-inf, sqrt(-x), int overflow |
| [1] | `divide_by_zero` | finite / ±0                                       |
| [2] | `overflow`       | rounded result exceeds max finite                 |
| [3] | `underflow`      | tiny + inexact (tininess per `detect_tininess`)   |
| [4] | `inexact`        | rounded result differs from exact result          |

Rules that matter for the datapath:

- **Overflow** delivers `±inf` (round-to-nearest) or `±max_finite`
  (round-toward-zero), and always raises `inexact` too.
- **Underflow** is `tininess AND inexact`: a tiny-but-exact result
  (e.g. an exact subnormal from `1.0 - 0.999...`) does not raise it.
  Whether tininess is judged before or after rounding is the
  `detect_tininess` input.
- **Invalid** and **divide_by_zero** are detected at unpack time from
  the recoded fields — another place where the uniform encoding pays
  off: special values are just exponent-field patterns, not deep
  case analyses.
