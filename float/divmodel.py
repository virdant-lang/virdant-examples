"""Fraction-exact reference and bit-exact datapath model for divide and
square root (DivSqrtRecFnBinary32, DIVSQRTRECFN.plan).

The reference (ref_div / ref_sqrt) computes exact rational results and
rounds them with fuzz.round_scaled (the same arbiter the FMA fuzzer
uses), so flag semantics stay identical across ops. The bit-exact model
(model_div / model_sqrt) transcribes the planned RTL recurrence cycle
by cycle -- including register widths -- so datapath mismatches dissect
per stage (the pipemodel.py role for the FMA).

CLI mirrors fuzz.py: `python3 divmodel.py [n] [seed]` runs the corner
battery in all five modes plus n random cases.
"""

import math
import random
import sys
from fractions import Fraction as F

from fputils import FLAG_NAMES, recode, run_packet
from tests import corpus as dcorpus
import fuzz

MODES = ["NearestEven", "TowardZero", "TowardPositive",
         "TowardNegative", "MaxMagnitude"]

MIN_NORMAL_SCALED = fuzz.MIN_NORMAL_SCALED


# ---------------------------------------------------------------------
# IEEE binary32 decode helpers
# ---------------------------------------------------------------------

def f32_class(bits):
    """Decode IEEE bits into (sign, recExp, sig24, kind, snan).

    kind is one of 'zero', 'sub', 'norm', 'inf', 'nan'. recExp/sig24
    follow the recoded format uniformly (sig24 = 2^23 + fract), with
    sig24 meaningless for zero/special classes.
    """
    sign = (bits >> 31) & 1
    exp_in = (bits >> 23) & 0xFF
    fract = bits & 0x7F_FFFF
    if exp_in == 0xFF:
        if fract == 0:
            return sign, 384, None, "inf", False
        return sign, 448, None, "nan", not (fract & 0x40_0000)
    if exp_in == 0 and fract == 0:
        return sign, 0, None, "zero", False
    rec = recode(bits)
    rec_exp = (rec >> 23) & 0x1FF
    sig24 = (1 << 23) + (rec & 0x7F_FFFF)
    kind = "sub" if rec_exp < 130 else "norm"
    return sign, rec_exp, sig24, kind, False


def value_of(rec_exp, sig24):
    """Exact value of a nonzero finite recoded operand."""
    return F(sig24) * (F(2) ** (rec_exp - 279))


# ---------------------------------------------------------------------
# Exact rounding of an irrational-free sqrt
# ---------------------------------------------------------------------

def _floor_sqrt_over(va, eulp):
    """t = floor(sqrt(va) / 2^eulp) for exact rational va > 0, plus the
    remainder classification of sqrt(va)/2^eulp - t against the unit
    grid (zero / exactly-one-half / greater). All integer arithmetic."""
    # t = floor(sqrt(va) / 2^eulp): square the ratio, so the shift is
    # 2*eulp (sqrt(va)/2^eulp = sqrt(va * 2^(-2*eulp))).
    kN = max(0, -2 * eulp)
    kD = max(0, 2 * eulp)
    N = va.numerator << kN
    D = va.denominator << kD
    t = math.isqrt(N * D) // D
    rem_zero = N == t * t * D
    four_N = N << 2
    rhs = (2 * t + 1) ** 2 * D
    rem_half = four_N == rhs
    rem_gt_half = four_N > rhs
    return t, rem_zero, rem_half, rem_gt_half



def _floor_over_lin(va, eulp):
    """t = floor(va / 2^eulp) for exact rational va > 0, plus the
    remainder classification of va/2^eulp - t (zero / exactly-one-half /
    greater). All integer arithmetic; works for ANY denominator (the
    quotient's denominator is not a power of two in general, so
    fuzz.round_scaled cannot be reused here)."""
    kN = max(0, -eulp)
    kD = max(0, eulp)
    N = va.numerator << kN
    D = va.denominator << kD
    t = N // D
    rem_zero = N == t * D
    two_N = N << 1
    rhs = (2 * t + 1) * D
    rem_half = two_N == rhs
    rem_gt_half = two_N > rhs
    return t, rem_zero, rem_half, rem_gt_half


def _round_up_signed(mode, sign, rem_zero, rem_half, rem_gt_half, t):
    if rem_zero:
        return False
    if mode == 0:      # NearestEven
        return rem_gt_half or (rem_half and (t & 1))
    if mode == 1:      # TowardZero
        return False
    if mode == 4:      # MaxMagnitude
        return rem_half or rem_gt_half
    if mode == 2:      # TowardPositive: magnitude grows for +results
        return sign == 0
    return sign == 1   # TowardNegative


def round_div_exact(va, sign, mode):
    """Round the exact quotient VALUE (Fraction, may be any rational)
    at the binary32 grid. Returns (p, inexact, overflow) with p in
    units of 2^-149, mirroring fuzz.round_scaled's contract."""
    num, den = va.numerator, va.denominator
    E = num.bit_length() - den.bit_length()
    while F(2) ** E > va:
        E -= 1
    while F(2) ** (E + 1) <= va:
        E += 1
    eulp = E - 23 if E >= -126 else -149
    t, rem_zero, rem_half, rem_gt_half = _floor_over_lin(va, eulp)
    up = _round_up_signed(mode, sign, rem_zero, rem_half, rem_gt_half, t)
    p = (t + 1 if up else t) << (eulp + 149)
    overflow = p > fuzz.MAXF_SCALED
    # Overflow implies inexact: the rounded result (inf or max finite)
    # differs from the exact value even when it lands exactly on the
    # unbounded grid past max finite.
    return p, (not rem_zero) or overflow, overflow


def round_sqrt(va, mode):
    """Round sqrt(va) (va > 0, exact Fraction) at the binary32 grid.

    Returns (p, inexact) where p is the rounded magnitude in units of
    2^-149 (0 < p <= max finite; sqrt never overflows). All decisions
    are integer comparisons on va, so no irrational arithmetic is used.
    """
    # Result exponent class: floor(log2(sqrt(va))) = floor(log2(va)) >> 1.
    e_num, e_den = va.numerator, va.denominator
    E = e_num.bit_length() - e_den.bit_length()  # floor(log2(va)) +- 1
    while F(2) ** E > va:
        E -= 1
    while F(2) ** (E + 1) <= va:
        E += 1
    e_res = E >> 1  # floor for both parities
    eulp = e_res - 23 if e_res >= -126 else -149
    t, rem_zero, rem_half, rem_gt_half = _floor_sqrt_over(va, eulp)
    # sqrt's rounding path always has sign 0 (negatives are invalid),
    # so toward-positive always rounds up and toward-negative never
    # does; _round_up relies on that.
    up = _round_up(mode, rem_zero, rem_half, rem_gt_half, t)
    p = (t + 1 if up else t) << (eulp + 149)
    return p, not rem_zero


def _round_up(mode, rem_zero, rem_half, rem_gt_half, t):
    if rem_zero:
        return False
    if mode == 0:      # NearestEven
        return rem_gt_half or (rem_half and (t & 1))
    if mode == 1:      # TowardZero
        return False
    if mode == 4:      # MaxMagnitude
        return rem_half or rem_gt_half
    return mode == 2   # caller applies the sign filter


# ---------------------------------------------------------------------
# Fraction-exact reference
# ---------------------------------------------------------------------

def _finish(mag, sign, mode, flags, scale_shift):
    """Shared rounding tail: mag is the exact positive Fraction value;
    scale_shift folds the caller's power-of-two into round_scaled via
    fuzz's grid (mag is already in absolute value units)."""
    p, inexact, overflow = fuzz.round_scaled(mag, sign, mode)
    if inexact:
        flags.add("inexact")
    if overflow:
        flags.add("overflow")
        if mode in (0, 4) or (mode == 2 and sign == 0) \
                or (mode == 3 and sign == 1):
            return ("inf", sign), flags
        return ("num", 0xFF7FFFFF if sign else 0x7F7FFFFF), flags
    if p == 0:
        if inexact:
            flags.add("underflow")
        return ("zero", sign), flags
    if p < MIN_NORMAL_SCALED and inexact:
        flags.add("underflow")
    return ("num", fuzz.u32_from_scaled(p) | (sign << 31)), flags


def ref_div(a_bits, b_bits, mode):
    """Exact-reference divide. Returns ((kind, ...), flag-name set)."""
    flags = set()
    sa, ea, fa, ka, sna = f32_class(a_bits)
    sb, eb, fb, kb, snb = f32_class(b_bits)
    any_snan = sna or snb
    any_nan = ka == "nan" or kb == "nan"
    if any_nan:
        if any_snan:
            flags.add("invalid")
        return ("nan",), flags
    a_zero, b_zero = ka == "zero", kb == "zero"
    a_inf, b_inf = ka == "inf", kb == "inf"
    if (a_zero and b_zero) or (a_inf and b_inf):
        flags.add("invalid")
        return ("nan",), flags
    sign = sa ^ sb
    if a_inf:
        return ("inf", sign), flags
    if b_zero:
        flags.add("divide_by_zero")
        return ("inf", sign), flags
    if a_zero:
        return ("zero", sign), flags
    # b is inf: finite a / inf = signed zero (no flags).
    if b_inf:
        return ("zero", sign), flags
    va = value_of(ea, fa)
    vb = value_of(eb, fb)
    q = va / vb
    p, inexact, overflow = round_div_exact(q, sign, mode)
    if inexact:
        flags.add("inexact")
    if overflow:
        flags.add("overflow")
        if mode in (0, 4) or (mode == 2 and sign == 0) \
                or (mode == 3 and sign == 1):
            return ("inf", sign), flags
        return ("num", 0xFF7FFFFF if sign else 0x7F7FFFFF), flags
    if p == 0:
        if inexact:
            flags.add("underflow")
        return ("zero", sign), flags
    if p < MIN_NORMAL_SCALED and inexact:
        flags.add("underflow")
    return ("num", fuzz.u32_from_scaled(p) | (sign << 31)), flags


def ref_sqrt(a_bits, mode):
    """Exact-reference square root."""
    flags = set()
    sa, ea, fa, ka, sna = f32_class(a_bits)
    if ka == "nan":
        if sna:
            flags.add("invalid")
        return ("nan",), flags
    if ka == "zero":
        return ("zero", sa), flags
    if sa:
        # Negative (covers -inf and negative finite): invalid.
        flags.add("invalid")
        return ("nan",), flags
    if ka == "inf":
        return ("inf", 0), flags
    va = value_of(ea, fa)
    p, inexact = round_sqrt(va, mode)
    if inexact:
        flags.add("inexact")
    if p < MIN_NORMAL_SCALED and inexact:
        flags.add("underflow")
    return ("num", fuzz.u32_from_scaled(p)), flags


# ---------------------------------------------------------------------
# RTL runners
# ---------------------------------------------------------------------

def rtl_div(a_bits, b_bits, mode):
    packet = run_packet([
        recode(a_bits), recode(b_bits),
        mode << 2,    # word 2: rounding mode in bits 4..2
        8,            # operation selector: divide
        0,
    ], cycles=45)
    out_recoded = packet >> 31
    flag_bits = (packet >> 26) & 0x1F
    latency = (packet >> 18) & 0xFF
    return out_recoded, {name for i, name in enumerate(FLAG_NAMES)
                         if flag_bits & (1 << i)}, latency


def rtl_sqrt(a_bits, mode):
    packet = run_packet([
        recode(a_bits), 0,
        mode << 2,    # word 2: rounding mode in bits 4..2
        9,            # operation selector: square root
        0,
    ], cycles=45)
    out_recoded = packet >> 31
    flag_bits = (packet >> 26) & 0x1F
    latency = (packet >> 18) & 0xFF
    return out_recoded, {name for i, name in enumerate(FLAG_NAMES)
                         if flag_bits & (1 << i)}, latency


def div_is_special(a_bits, b_bits):
    """True iff the pair takes the RTL's special-case path (latency 2):
    any NaN/zero/infinity operand covers every section-2 special
    (qNaN/sNaN, 0/0, inf/inf, inf/0, finite/0, finite/inf, 0/normal).
    """
    ka = f32_class(a_bits)[3]
    kb = f32_class(b_bits)[3]
    return "nan" in (ka, kb) or "zero" in (ka, kb) or "inf" in (ka, kb)


def sqrt_is_special(a_bits):
    """True iff the operand takes the special-case path: NaN, zero,
    infinity, or negative (negative finite and -inf are invalid)."""
    sign, _, _, kind, _ = f32_class(a_bits)
    return kind in ("nan", "zero", "inf") or sign == 1


def _compare(ref_result, ref_flags, out, rtl_flags, what):
    kind = fuzz.recoded_class(out)
    problems = []
    if ref_result[0] == "nan":
        if kind != "nan":
            problems.append("expected NaN, got recoded {:#x}".format(out))
    elif ref_result[0] == "inf":
        if kind != "inf" or (out >> 32) != ref_result[1]:
            problems.append("expected {}inf, got recoded {:#x}"
                            .format("-" if ref_result[1] else "+", out))
    elif ref_result[0] == "zero":
        if kind != "zero" or (out >> 32) != ref_result[1]:
            problems.append("expected {}0, got recoded {:#x}"
                            .format("-" if ref_result[1] else "+", out))
    else:
        expect = recode(ref_result[1])
        if out != expect:
            problems.append("expected {:#010x} (recoded {:#x}), got recoded {:#x}"
                            .format(ref_result[1], expect, out))
    if rtl_flags != ref_flags:
        problems.append("flags: expected {} got {} ({})"
                        .format(sorted(ref_flags), sorted(rtl_flags),
                                fuzz.format_flags(rtl_flags)))
    return problems


def compare_div(a_bits, b_bits, mode):
    ref_result, ref_flags = ref_div(a_bits, b_bits, mode)
    out, rtl_flags, latency = rtl_div(a_bits, b_bits, mode)
    problems = _compare(ref_result, ref_flags, out, rtl_flags, "div")
    expected = 1 if div_is_special(a_bits, b_bits) else 28
    if latency != expected:
        problems.append("latency: expected {} cycles, got {}"
                        .format(expected, latency))
    return problems


def compare_sqrt(a_bits, mode):
    ref_result, ref_flags = ref_sqrt(a_bits, mode)
    out, rtl_flags, latency = rtl_sqrt(a_bits, mode)
    problems = _compare(ref_result, ref_flags, out, rtl_flags, "sqrt")
    expected = 1 if sqrt_is_special(a_bits) else 28
    if latency != expected:
        problems.append("latency: expected {} cycles, got {}"
                        .format(expected, latency))
    return problems


# ---------------------------------------------------------------------
# Bit-exact datapath model (transcription of the planned RTL)
# ---------------------------------------------------------------------

M31 = (1 << 31) - 1
M28 = (1 << 28) - 1
M27 = (1 << 27) - 1
M24 = (1 << 24) - 1


def model_div(sign, rec_a, sig_a, rec_b, sig_b):
    """Cycle-exact model of the RTL division datapath.

    Returns (recExp_out, sig24, guard, round, sticky) -- the raw values
    the RTL hands its encoder. All register widths match the RTL.
    """
    rem = (sig_a << 5) & M31          # r_0 * 2^(0+28) = sig_a * 2^5
    # Digit c_i has weight 2^(1-i); decision c_i <=> r_{i-1} >= 2^(1-i)*b:
    # in R = r*2^(i+28) units the term is b_frac * 2^28 = sig_b << 5.
    term = (sig_b << 5) & M31
    sub = (sig_b << 6) & M31          # 2 * term
    sigx = 0
    sticky = False
    for _ in range(27):
        c = rem >= term
        rem = ((rem << 1) - (sub if c else 0)) & M31
        sigx = ((sigx << 1) | c) & M27
        if c:
            sticky = rem != 0
    c1 = (sigx >> 26) & 1
    if c1:
        sig24 = (sigx >> 3) & M24
        guard = (sigx >> 2) & 1
        rnd = (sigx >> 1) & 1
        sticky = sticky or (sigx & 1)
        rec_exp = rec_a - rec_b + 256
    else:
        sig24 = (sigx >> 2) & M24
        guard = (sigx >> 1) & 1
        rnd = sigx & 1
        rec_exp = rec_a - rec_b + 255
    return sign, rec_exp, sig24, guard, rnd, sticky


def model_sqrt(sign, rec_a, sig_a):
    odd = rec_a & 1
    if odd:
        rem = (((sig_a << 1) - (1 << 23)) << 5) & M31
    else:
        rem = ((sig_a - (1 << 23)) << 5) & M31
    x28 = 1 << 27
    w = 1 << 26
    sticky = False
    for _ in range(27):
        term = ((x28 << 1) + w) & M31
        c = rem >= term
        rem = ((rem << 1) - ((term << 1) if c else 0)) & M31
        if c:
            x28 = (x28 + w) & M28
            sticky = rem != 0
        w >>= 1
    sig24 = (x28 >> 4) & M24          # {1, c_1..c_23}
    guard = (x28 >> 3) & 1            # c_24
    rnd = (x28 >> 2) & 1              # c_25
    sticky = sticky or bool(x28 & 0b11)  # c_26, c_27
    rec_exp = (rec_a >> 1) + 128
    return sign, rec_exp, sig24, guard, rnd, sticky


def check_model(cases=4000, seed=0xD1CE):
    """Cross-check the bit-exact datapath model against exact arithmetic
    at the raw-value level (no encoder involved): the delivered
    (sig24, guard, round, sticky) must be the 24-bit truncation of the
    exact result on the ulp grid, with the next two bits and a sticky
    that is exactly 'anything beyond the round bit is nonzero'."""
    rng = random.Random(seed)
    bad = 0
    n = 0
    for it in range(cases):
        sqrt_op = it % 2 == 1
        a_bits = _rand_operand(rng)
        b_bits = 0 if sqrt_op else _rand_operand(rng)
        sa, ea, fa, ka, _ = f32_class(a_bits)
        sb, eb, fb, kb, _ = f32_class(b_bits)
        if sqrt_op:
            if ka not in ("norm", "sub"):
                continue
            _, rec_exp, sig24, guard, rnd, sticky = model_sqrt(sa, ea, fa)
            root = _sqrt_frac(value_of(ea, fa))
            # root/ulp = x * 2^23 for any recExp_out (x = the root's
            # significand in [1,2)); sig24 is its 24-bit truncation.
            frac = root * F(2) ** (279 - rec_exp) - sig24
        else:
            if ka not in ("norm", "sub") or kb not in ("norm", "sub"):
                continue
            _, rec_exp, sig24, guard, rnd, sticky = model_div(sa, ea, fa, eb, fb)
            # The digits describe the SIGNIFICAND ratio fa/fb; the
            # delivered recExp_out re-aligns it, so value/ulp =
            # (fa/fb) * 2^(279 + recA - recB - recExp_out).
            q_sig = F(fa, fb)
            frac = q_sig * F(2) ** (279 + ea - eb - rec_exp) - sig24
        n += 1
        g = int(frac * 2)
        r2 = frac * 2 - g
        rr = int(r2 * 2)
        st = (frac * 4 - g * 2 - rr) != 0
        ok = (0 <= frac < 1) and g == guard and rr == rnd and st == sticky
        if not ok:
            bad += 1
            if bad <= 3:
                print("MODEL FAIL sqrt={} a={:#010x} b={:#010x} "
                      "model g/r/st={}{}{} check={}{}{}"
                      .format(sqrt_op, a_bits, b_bits,
                              guard, rnd, sticky, g, rr, st))
    print("model-vs-exact: {}/{} consistent".format(n - bad, n))
    return bad


def _sqrt_frac(va):
    """Exact-enough sqrt as a Fraction via high-precision isqrt (for
    model checks only; the rounding reference never uses this)."""
    K = 140
    n = va.numerator * (1 << (2 * K)) // va.denominator
    return F(math.isqrt(n), 1 << K)


def _rand_operand(rng):
    bucket = rng.random()
    if bucket < 0.5:
        return (rng.getrandbits(1) << 31) | (rng.randint(1, 254) << 23) \
            | rng.getrandbits(23)
    if bucket < 0.7:  # subnormals
        return (rng.getrandbits(1) << 31) | rng.getrandbits(23)
    if bucket < 0.85:  # exponent extremes
        e = rng.choice([1, 126, 127, 128, 253, 254])
        return (rng.getrandbits(1) << 31) | (e << 23) | rng.getrandbits(23)
    return rng.choice([0x3F800000, 0xBF800000, 0x40000000, 0x40490FDB,
                       0x00800000, 0x007FFFFF, 0x3F000000])


# ---------------------------------------------------------------------
# Corner vectors and CLI
# ---------------------------------------------------------------------

CORNER_DIV = dcorpus.DIV_CORNER_VECTORS
CORNER_SQRT = dcorpus.SQRT_CORNER_VECTORS
HISTORICAL_DIV = dcorpus.HISTORICAL_DIV
HISTORICAL_SQRT = dcorpus.HISTORICAL_SQRT


# ---------------------------------------------------------------------
# Two-request backpressure battery
# ---------------------------------------------------------------------

# Back-to-back request pairs: (op, first_pair, second_pair). Chosen so
# every combination of recurrence/special first and second request is
# exercised, including divide-by-zero, qNaN, and the overflow region.
BACKPRESSURE_SEQUENCES = [
    ("div", (0x40400000, 0x3F800000), (0x3F800000, 0x40400000)),
    ("div", (0x3FC00000, 0x40000000), (0x7F800000, 0x40000000)),
    ("div", (0x40000000, 0x00000000), (0x40400000, 0x3F800000)),
    ("div", (0x00800000, 0x7F800000), (0x7FC00000, 0x3F800000)),
    ("sqrt", (0x40000000, 0), (0x40800000, 0)),
    ("sqrt", (0x00000001, 0), (0xBF800000, 0)),
    ("sqrt", (0x7F800001, 0), (0x41200000, 0)),
]


def compare_pair(op, first, second, mode):
    """One two-request sequence: fire request 1, consume its result,
    fire request 2 with fresh operands, and check BOTH packets (value,
    flags, latency) against the exact reference.

    The first request's data stays valid through the whole computation
    (the standing backpressure condition); the second additionally
    exercises the return-to-idle path.
    """
    is_sqrt = op == "sqrt"
    (a1, b1), (a2, b2) = first, second
    if is_sqrt:
        b1 = b2 = 0
    words = [
        recode(a1), recode(b1),
        (mode << 2) | 1,          # word 2: mode bits 4..2, bit 0 = second en
        9 if is_sqrt else 8,      # operation selector
        0,
        recode(a2), recode(b2),
        mode << 2,                # word 7: second request's rounding mode
    ]
    packet = run_packet(words, cycles=90, n_bytes=16)
    problems = []
    for i, (p, (ra, rb)) in enumerate(
            ((packet & 0xFFFF_FFFF_FFFF_FFFF, first),
             (packet >> 64, second)), 1):
        out = p >> 31
        flag_bits = (p >> 26) & 0x1F
        latency = (p >> 18) & 0xFF
        rtl_flags = {name for j, name in enumerate(FLAG_NAMES)
                     if flag_bits & (1 << j)}
        if is_sqrt:
            ref_result, ref_flags = ref_sqrt(ra, mode)
            expected = 1 if sqrt_is_special(ra) else 28
        else:
            ref_result, ref_flags = ref_div(ra, rb, mode)
            expected = 1 if div_is_special(ra, rb) else 28
        problems += ["req{}: {}".format(i, q)
                     for q in _compare(ref_result, ref_flags,
                                       out, rtl_flags, op)]
        if latency != expected:
            problems.append("req{} latency: expected {} cycles, got {}"
                            .format(i, expected, latency))
    return problems


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 0xD1CE
    rng = random.Random(seed)

    failures = 0
    flaky = 0
    total = 0

    def run_div(a, b, mode):
        nonlocal failures, total, flaky
        total += 1
        problems = compare_div(a, b, mode)
        if problems:
            if not compare_div(a, b, mode):
                flaky += 1
                return
            if not compare_div(a, b, mode):
                flaky += 1
                return
        if problems:
            failures += 1
            print("FAIL div #{}: a={:#010x} b={:#010x} mode={}({})"
                  .format(total, a, b, mode, MODES[mode]))
            for p in problems:
                print("      " + p)

    def run_sqrt(a, mode):
        nonlocal failures, total, flaky
        total += 1
        problems = compare_sqrt(a, mode)
        if problems:
            if not compare_sqrt(a, mode):
                flaky += 1
                return
            if not compare_sqrt(a, mode):
                flaky += 1
                return
        if problems:
            failures += 1
            print("FAIL sqrt #{}: a={:#010x} mode={}({})"
                  .format(total, a, mode, MODES[mode]))
            for p in problems:
                print("      " + p)

    for (a, b) in CORNER_DIV:
        for mode in range(5):
            run_div(a, b, mode)
    for (a,) in CORNER_SQRT:
        for mode in range(5):
            run_sqrt(a, mode)
    print("corners: {} cases, {} failures, {} flaky"
          .format(total, failures, flaky))

    # Historical fixed failures (tests/corpus.py).
    hist_total = total
    for (a, b) in HISTORICAL_DIV:
        for mode in range(5):
            run_div(a, b, mode)
    for (a,) in HISTORICAL_SQRT:
        for mode in range(5):
            run_sqrt(a, mode)
    print("historical: {} cases, {} failures, {} flaky"
          .format(total - hist_total, failures, flaky))

    # Back-to-back two-request protocol test (return-to-idle path).
    bp_total = total
    for mode in range(5):
        for op, first, second in BACKPRESSURE_SEQUENCES:
            total += 1
            problems = compare_pair(op, first, second, mode)
            if problems:
                if not compare_pair(op, first, second, mode):
                    flaky += 1
                    continue
                if not compare_pair(op, first, second, mode):
                    flaky += 1
                    continue
            if problems:
                failures += 1
                print("FAIL pair {}: {} {} then {} {} mode={}({})"
                      .format(total, op, first, second, mode, MODES[mode]))
                for p in problems:
                    print("      " + p)
    print("backpressure: {} cases, {} failures, {} flaky"
          .format(total - bp_total, failures, flaky))

    for i in range(n):
        mode = rng.randrange(5)
        if rng.random() < 0.5:
            run_div(_rand_operand(rng), _rand_operand(rng), mode)
        else:
            run_sqrt(_rand_operand(rng), mode)
        if (i + 1) % 250 == 0:
            print("  ... {} random cases ({} failures, {} flaky so far)"
                  .format(i + 1, failures, flaky))

    print("total: {} cases, {} failures, {} flaky"
          .format(total, failures, flaky))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "model":
        sys.exit(1 if check_model() else 0)
    main()
