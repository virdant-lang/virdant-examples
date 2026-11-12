#!/usr/bin/env python3
"""Faithful Python model of the MulAddRecFnBinary32 datapath.

Mirrors src/muladdrecfn.vir stage by stage so failing fuzz cases can
be dissected: model == RTL means the model reproduces the bug and the
divergence from the exact reference localizes the stage.
"""

REC_ZERO = 64
REC_INF = 384
REC_NAN = 448
MAX_FINITE_REC = 0b101_111_111

# flag bits (bit 0 first: invalid, dz, overflow, underflow, inexact)
F_INV, F_DZ, F_OF, F_UF, F_IX = 1 << 0, 1 << 1, 1 << 2, 1 << 3, 1 << 4


def decode(x):
    sign = (x >> 32) & 1
    rec_exp = (x >> 23) & 0x1FF
    fract = x & 0x7F_FFFF
    is_zero = rec_exp < REC_ZERO
    is_special = (rec_exp >> 7) == 3
    is_nan = is_special and ((rec_exp >> 6) & 1)
    return dict(
        sign=sign,
        s_exp=rec_exp + 1769,
        sig=0 if is_zero else (1 << 23) | fract,
        is_zero=is_zero,
        is_inf=is_special and not is_nan,
        is_nan=is_nan,
        is_snan=is_nan and not ((fract >> 22) & 1),
    )


def model_fma(a33, b33, c33, mode):
    A, B, C = decode(a33), decode(b33), decode(c33)

    any_nan = A["is_nan"] or B["is_nan"] or C["is_nan"]
    any_snan = A["is_snan"] or B["is_snan"] or C["is_snan"]
    product_inf = A["is_inf"] or B["is_inf"]
    zero_times_inf = ((A["is_inf"] and B["is_zero"])
                      or (B["is_inf"] and A["is_zero"]))
    conflict = product_inf and C["is_inf"] and \
        ((A["sign"] ^ B["sign"]) != C["sign"])
    result_is_nan = any_nan or zero_times_inf or conflict
    result_is_inf = (not result_is_nan) and (product_inf or C["is_inf"])
    result_inf_sign = (A["sign"] ^ B["sign"]) if product_inf else C["sign"]
    invalid_exc = any_snan or ((not any_nan) and (zero_times_inf or conflict))

    # ---- datapath ----
    prod = A["sig"] * B["sig"]                      # 48 bits
    product_sign = A["sign"] ^ B["sign"]
    product_exp = A["s_exp"] + B["s_exp"] - 2048

    c_is_big = C["s_exp"] > product_exp
    big_sig = C["sig"] if c_is_big else prod
    big_exp = C["s_exp"] if c_is_big else product_exp
    big_sign = C["sign"] if c_is_big else product_sign
    small_sig = prod if c_is_big else C["sig"]
    small_exp = product_exp if c_is_big else C["s_exp"]
    small_sign = product_sign if c_is_big else C["sign"]

    # AlignAddend
    diff = max(big_exp - small_exp, 0)
    if diff >= 64:
        small_in_window = 0
        sticky = 1 if small_sig else 0
    else:
        small_in_window = (small_sig >> diff) << 32
        dropped = small_sig & ((1 << diff) - 1)
        sticky = 1 if (dropped or (diff >= 48 and small_sig)) else 0
    big_in_window = big_sig << 32

    # SignMagAdd
    a_mag, b_mag = big_in_window, small_in_window
    same = not (big_sign ^ small_sign)
    if same:
        sum_mag, sum_sign, sticky_out = a_mag + b_mag, big_sign, sticky
    elif a_mag > b_mag:
        sum_mag, sum_sign, sticky_out = a_mag - b_mag - sticky, big_sign, 0
    elif b_mag > a_mag:
        sum_mag, sum_sign, sticky_out = b_mag - a_mag - sticky, small_sign, 0
    else:
        sum_mag, sum_sign, sticky_out = 0, big_sign, sticky
    sum_sign = result_inf_sign if result_is_inf else sum_sign

    # Normalize
    sum_exp = big_exp - 32
    lz = 81 if sum_mag == 0 else 80 - (sum_mag - 1).bit_length() if sum_mag else 81
    lz = 81 if sum_mag == 0 else 80 - (sum_mag.bit_length() - 1)
    exp = (sum_exp + 57) - lz
    shifted = sum_mag << lz
    sig = (shifted >> 57) & 0xFF_FFFF
    guard = (shifted >> 56) & 1
    psticky = 1 if (shifted & ((1 << 56) - 1)) else 0
    psticky_total = psticky | sticky_out

    # ---- Encode: single rounding at effective precision ----
    exp_diff = exp - 1769
    borrow = exp_diff < 0
    s_exp = exp_diff & 0x3FF

    class_normal = (not borrow) and exp_diff >= 130
    class_sub = (not borrow) and 107 <= exp_diff <= 129
    deep106 = (not borrow) and exp_diff == 106

    if class_normal:
        lsb_e, guard_e, st_low = sig & 1, guard, 0
        zeroed, increment = sig, 1
    elif class_sub:
        k = exp_diff
        lsb_e = (sig >> (130 - k)) & 1
        guard_e = (sig >> (129 - k)) & 1
        st_low = 1 if (sig & ((1 << (129 - k)) - 1)) else 0
        zeroed = sig & ~((1 << (130 - k)) - 1)
        increment = 1 << (130 - k)
    elif deep106:
        lsb_e, guard_e, st_low = 0, (sig >> 23) & 1, \
            1 if (sig & 0x7F_FFFF) else 0
        zeroed, increment = 0, 0
    else:
        lsb_e, guard_e, st_low = 0, 0, 1 if sig else 0
        zeroed, increment = 0, 0

    sticky_e = st_low | psticky_total | (guard if not class_normal else 0)
    inexact_e = guard_e | sticky_e

    if mode == 0:
        up = guard_e and (lsb_e or sticky_e)
    elif mode == 1:
        up = False
    elif mode == 2:
        up = (not sum_sign) and (guard_e or sticky_e)
    elif mode == 3:
        up = sum_sign and (guard_e or sticky_e)
    else:
        up = guard_e

    rounded_sum = zeroed + (increment if up else 0)
    deep_up = (not class_normal) and (not class_sub) and up
    carry = ((rounded_sum >> 24) & 1) or deep_up
    rounded = rounded_sum & 0xFFFFFF

    # zero-sign rule (exact zeros)
    if big_sign == small_sign:
        zero_sign = big_sign
    else:
        zero_sign = 1 if mode == 3 else 0
    zero_sign_eff = sum_sign if inexact_e else zero_sign

    post_diff = exp + (1 if carry else 0) - 1769
    is_zero_out = (not carry) and rounded == 0
    overflow = (not is_zero_out) and post_diff >= 0 and post_diff > 383

    if result_is_nan:
        out = (sum_sign << 32) | (REC_NAN << 23) | 0x40_0000
        return out, (F_INV if invalid_exc else 0)
    if result_is_inf:
        return (result_inf_sign << 32) | (REC_INF << 23), 0
    if is_zero_out:
        return ((zero_sign_eff << 32),
                (F_IX | F_UF) if inexact_e else 0)
    if overflow:
        if mode in (0, 4):
            out = (sum_sign << 32) | (REC_INF << 23)
        elif mode == 1:
            out = (sum_sign << 32) | (MAX_FINITE_REC << 23) | 0x7F_FFFF
        elif mode == 2:
            out = ((sum_sign << 32) | (MAX_FINITE_REC << 23) | 0x7F_FFFF) \
                if sum_sign else ((sum_sign << 32) | (REC_INF << 23))
        else:
            out = ((sum_sign << 32) | (REC_INF << 23)) if sum_sign \
                else ((sum_sign << 32) | (MAX_FINITE_REC << 23) | 0x7F_FFFF)
        return out, F_IX | F_OF
    if not class_normal:
        if carry:
            rec = (s_exp + 1) if (not borrow and exp_diff >= 106) else 107
            out = (sum_sign << 32) | (rec << 23)
        else:
            out = (sum_sign << 32) | (s_exp << 23) | (rounded & 0x7F_FFFF)
        uf = inexact_e and ((not carry) or borrow or exp_diff <= 128)
        return out, (F_IX | F_UF if (inexact_e and uf) else
                     (F_IX if inexact_e else 0))
    out = (sum_sign << 32) | (post_diff << 23) | (rounded & 0x7F_FFFF)
    return out, (F_IX if inexact_e else 0)
