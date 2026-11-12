"""Shared helpers for the floating-point test drivers.

Covers the IEEE binary32 <-> HardFloat recoded-format conversions and
the plumbing to run values through the testbench in src/top.vir via
the add_mult.img image and the vir simulator's debug channel.
"""

import math
import os
import struct
import subprocess
import sys

PROJECT_DIR = os.path.dirname(os.path.abspath(__file__))

# Directory the testbench image lives in; parallel fuzz workers point
# this at their own project copy so image writes never collide.
IMAGE_DIR = PROJECT_DIR

# Recoded-exponent class boundaries (MULADDRECFN.plan section 1).
REC_EXP_ZERO_BELOW = 64       # top three recExp bits all zero: zero
REC_EXP_INF = 0b110_000_000   # 384
REC_EXP_NAN = 0b111_000_000   # 448

# Exception flag names, indexed by bit (HardFloat's fixed order).
FLAG_NAMES = ["invalid", "divide_by_zero", "overflow", "underflow", "inexact"]


def to_binary32(value):
    """Round a Python float to an IEEE binary32 bit pattern."""
    return struct.unpack("<I", struct.pack("<f", value))[0]


def recode(ieee_bits):
    """Recode an IEEE binary32 bit pattern into HardFloat's 33-bit format."""
    sign = (ieee_bits >> 31) & 1
    exp_in = (ieee_bits >> 23) & 0xFF
    fract = ieee_bits & 0x7F_FFFF

    if exp_in == 0:
        if fract == 0:
            rec_exp, rec_fract = 0, 0
        else:
            # Subnormal: normalize; the leading one becomes the explicit
            # significand bit and the normalization distance folds into
            # the recoded exponent.
            norm_dist = 23 - fract.bit_length()
            rec_exp = 129 - norm_dist
            rec_fract = ((fract << norm_dist) & 0x3F_FFFF) << 1
    elif exp_in == 0xFF:
        if fract == 0:
            rec_exp, rec_fract = REC_EXP_INF, 0
        else:
            rec_exp, rec_fract = REC_EXP_NAN, fract
    else:
        rec_exp, rec_fract = exp_in + 129, fract

    return (sign << 32) | (rec_exp << 23) | rec_fract


def decode(recoded):
    """Decode a 33-bit recoded value into a Python float."""
    sign = (recoded >> 32) & 1
    rec_exp = (recoded >> 23) & 0x1FF
    fract = recoded & 0x7F_FFFF

    if rec_exp < REC_EXP_ZERO_BELOW:
        value = 0.0
    elif rec_exp >= REC_EXP_NAN:
        value = math.nan
    elif rec_exp >= REC_EXP_INF:
        value = math.inf
    else:
        # The uniform formula, valid for subnormals and normals alike.
        value = (2.0 ** 23 + fract) * 2.0 ** (rec_exp - 279)

    return -value if sign else value


def run_packet(words, cycles=12, n_bytes=8):
    """Write the image words (MSB-first) and run the testbench.

    Returns the n_bytes-byte result packet (default 8) streamed out
    the debug channel, low byte first. Two-request div/sqrt runs
    stream 16 bytes: request 1's packet in bits [63..0], request 2's
    in bits [127..64]. Word layout is fixed by src/top.vir: operands
    in words 0..2, operation selector (0 = FMA, 1 = compare) in word 3.
    """
    image_path = os.path.join(IMAGE_DIR, "add_mult.img")
    with open(image_path, "wb") as img:
        for word in words:
            img.write(struct.pack(">Q", word))

    result = subprocess.run(
        ["vir", "run", "--cycles", str(cycles), "--fps-no-cap"],
        cwd=IMAGE_DIR,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        sys.stderr.write(result.stderr.decode("utf-8", "replace"))
        sys.exit("vir run failed with exit code {}".format(result.returncode))

    # The debug channel emits the raw packet bytes, low byte first,
    # on the simulator's diagnostic (stderr) stream.
    packet_bytes = result.stderr
    if len(packet_bytes) < n_bytes:
        sys.exit("expected {} result bytes, got {!r}"
                 .format(n_bytes, packet_bytes))
    return int.from_bytes(packet_bytes[:n_bytes], "little")
