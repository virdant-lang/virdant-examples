"""Checked-in regression corpus for the binary32 HardFloat project.

Single source of truth for the deterministic batteries that fuzz.py
(FMA) and divmodel.py (divide/sqrt) replay in all five rounding modes.
fuzz_worker.py picks the lists up through fuzz.py.

Everything here is IEEE binary32 operand bits, not recoded; the
converters in fputils.py handle the recoding at the RTL boundary.

Layout:
    FMA_CORNER_VECTORS    (a, b, c) triples hitting the documented risk
                          seams of MulAddRecFnBinary32 (underflow ties,
                          overflow ties, zero-sign cancellation seams,
                          NaN/sNaN suppression rules, f32-range edges).
    DIV_CORNER_VECTORS    (a, b) pairs for divide: exact/tie shapes,
                          underflow/overflow regions, all special cases
                          (0/0, inf/inf, inf/0, finite/0, qNaN, sNaN).
    SQRT_CORNER_VECTORS   (a,) tuples for square root: exact roots,
                          irrational tails, odd/even exponents, all
                          special cases including sqrt(-inf) invalid.
    HISTORICAL_FMA        FMA cases that once failed and were fixed.
                          None survived from the pre-git debugging
                          sessions (the fuzz logs recorded only
                          summaries); add cases here whenever a future
                          mismatch is reproduced and fixed.
    HISTORICAL_DIV        Divide/sqrt cases that once failed. The one
                          entry is the overflow-implies-inexact
                          reference bug in round_div_exact (a
                          near-max-finite quotient by a tiny divisor
                          landing exactly on the unbounded grid past
                          max finite under TowardPositive).
"""

# (a, b, c) hitting the documented risk seams, run in all 5 modes.
FMA_CORNER_VECTORS = [
    (0x00800001, 0x3F7FFFFF, 0x00000000),  # just under min normal, rounds up
    (0x00800001, 0x3F800000, 0x00000000),  # min normal exactly
    (0x00000001, 0x3F000000, 0x00000000),  # exact tie 0.5*minsub
    (0x00000001, 0x3F000001, 0x00000000),  # just above the tie
    (0x00000003, 0x3F000000, 0x00000000),  # 1.5*minsub tie -> even
    (0x00000001, 0x3E800000, 0x00000000),  # 0.25*minsub: deep underflow
    (0x00000002, 0x3F000000, 0x00000000),  # exactly minsub
    (0x007FFFFF, 0x3F000000, 0x00000000),  # 0.5*maxsubnormal
    (0x7F7FFFFF, 0x3F800000, 0x47800000),  # overflow tie
    (0x7F7FFFFF, 0x3F800001, 0x47800000),  # just past overflow tie
    (0x7F7FFFFF, 0xBF800000, 0x47800000),  # maxf - 2^104
    (0x7F7FFFFF, 0x3F800000, 0x00000000),  # exactly maxf
    (0x7F7FFFFF, 0xBF800000, 0x00000000),  # one ulp below maxf
    (0xBF800000, 0x40000000, 0x40400000),  # -1.5*2 + 3 = +0 / -0 seam
    (0x3FC00000, 0x40000000, 0xC0400000),  # +1.5*2 - 3 = +0 / -0 seam
    (0x3F800000, 0xBF800000, 0x3F800001),  # 1*-1 + (1+ulp): tiny subnormal
    (0x3F800000, 0x3F800000, 0xBF800001),  # 1*1 - (1+ulp)
    (0x00000000, 0x00000000, 0x80000000),  # (+0)*(+0) + (-0)
    (0x80000000, 0x00000000, 0x80000000),  # (-0)*(+0) + (-0)
    (0x7F800000, 0x00000000, 0x3F800000),  # inf * 0 + 1: invalid
    (0x7F800000, 0x3F800000, 0xFF800000),  # inf + (-inf): invalid
    (0x7F800000, 0x3F800000, 0x7FC00000),  # inf * 1 + qNaN: NaN, no invalid
    (0x7FC00000, 0x3F800000, 0x3F800000),  # qNaN operand: no invalid
    (0x7F800001, 0x3F800000, 0x3F800000),  # sNaN operand: invalid
    (0x3F800000, 0x3F800000, 0x7F800001),  # sNaN as c: invalid
    (0x00800000, 0x7F000000, 0x00000000),  # min normal * 2^126: overflow
    (0x00800000, 0x7F000000, 0x80000000),  # with -0 c
    (0x4F000000, 0x4F000000, 0x00000000),  # 2^31 * 2^31 (exact f32 range edge)
    (0x33800000, 0x33800000, 0x00000000),  # 2^24 * 2^24
    (0x3F800001, 0xBF800000, 0x3F800000),  # (1+ulp)*-1 + 1: -ulp
]

DIV_CORNER_VECTORS = [
    (0x3F800000, 0x3F800000),  # 1 / 1 exact
    (0x40000000, 0x40000000),  # 2 / 2 exact
    (0x3F800000, 0x40000000),  # 1 / 2 exact
    (0x40000000, 0x3F800000),  # 2 / 1 exact
    (0x3F800000, 0x40400000),  # 1 / 3: infinite 0101 tail
    (0x40400000, 0x3F800000),  # 3 / 1: sticky from dropped bits
    (0x3FC00000, 0x40000000),  # 1.5 / 2: exact-tie shape at RNE
    (0x00800000, 0x7F800000),  # min normal / max*2-ish: deep underflow
    (0x7F800000, 0x00800000),  # inf-ish big / tiny: overflow region
    (0x7F7FFFFF, 0x3F800000),  # max finite / 1
    (0x3F800000, 0x7F7FFFFF),  # 1 / max finite: tiny result
    (0x00800000, 0x3F800000),  # min normal / 1
    (0x3F800000, 0x00800000),  # 1 / min normal: huge quotient
    (0x80000000, 0x40000000),  # -0 / 2 = -0
    (0x00000000, 0x40000000),  # +0 / 2 = +0
    (0x00000000, 0x00000000),  # 0 / 0: invalid
    (0x7F800000, 0x7F800000),  # inf / inf: invalid
    (0x7F800000, 0x00000000),  # inf / 0: inf, no flags
    (0x7F800000, 0x40000000),  # inf / 2: inf
    (0x40000000, 0x00000000),  # 2 / 0: divide_by_zero
    (0xBF800000, 0x00000000),  # -1 / 0: -inf + dbz
    (0x7FC00000, 0x3F800000),  # qNaN operand: silent
    (0x7F800001, 0x3F800000),  # sNaN operand: invalid
    (0x3F800000, 0xFFC00001),  # sNaN divisor: invalid
    (0x00800001, 0x00800000),  # subnormal / subnormal-ish
    (0x3F800000, 0x3F000000),  # 1 / 0.5: exact power of two
]

SQRT_CORNER_VECTORS = [
    (0x3F800000,),  # sqrt(1) exact
    (0x40000000,),  # sqrt(2): irrational
    (0x40400000,),  # sqrt(3)
    (0x40800000,),  # sqrt(4) = 2 exact
    (0x41200000,),  # sqrt(10) odd exponent
    (0x3FC00000,),  # sqrt(1.5)
    (0x3F000000,),  # sqrt(0.5): even exponent, sub-exact tie shape
    (0x80000000,),  # sqrt(-0) = -0
    (0x00000000,),  # sqrt(+0) = +0
    (0x7F800000,),  # sqrt(+inf)
    (0xFF800000,),  # sqrt(-inf): invalid
    (0xBF800000,),  # sqrt(-1): invalid
    (0x7FC00000,),  # sqrt(qNaN): silent
    (0x7F800001,),  # sqrt(sNaN): invalid
    (0x00800000,),  # sqrt(min normal)
    (0x00000001,),  # sqrt(min subnormal): tiny result, underflow
    (0x007FFFFF,),  # sqrt(max subnormal)
    (0x7F7FFFFF,),  # sqrt(max finite)
    (0x33800000,),  # sqrt(2^-24)
]

# Cases that once failed (RTL or reference) and now must pass forever.
HISTORICAL_FMA = []  # none recorded pre-git; see module docstring

HISTORICAL_DIV = [
    # Reference bug (overflow implies inexact) in round_div_exact,
    # found by seed-777-era fuzzing: 0xfeb92ccd / min-normal under
    # TowardPositive lands exactly on the unbounded grid past max
    # finite, which must still flag inexact alongside overflow.
    (0xFEB92CCD, 0x00800000),
]

HISTORICAL_SQRT = []
