from utils.numerics import FPUtils
from memory.unsafe import bitcast
from .helpers import (
    is_small_integer,
    remove_trailing_zeros,
    log10_pow2,
    log10_pow2_residual,
    mshift,
    div10,
    wins_tiebreak,
    is_tie,
    is_tie_uncentered,
)
from .tables import MULTIPLIERS
from ..utils import StackArray, lut, DIGIT_PAIRS
from emberjson.constants import `-`, `0`, `.`, `e`

# Mojo port of the Teju Jagua algorithm by Cassio Neri.
# Original implementation: https://github.com/cassioneri/teju_jagua
# Licensed under the Apache License, Version 2.0.

comptime STORAGE_INDEX_OFFSET = -324


@always_inline
fn _get_sig_digits[dtype: DType]() -> Int:
    return Int((FPUtils[dtype].mantissa_width() + 1) * 30103 // 100000) + 24


@always_inline
fn _get_exp_digits[dtype: DType]() -> Int:
    var max_exp = (1 << (FPUtils[dtype].exponent_width() - 1)) - 1
    var max_dec_exp = max_exp * 30103 // 100000
    if max_dec_exp < 10:
        return 1
    if max_dec_exp < 100:
        return 2
    if max_dec_exp < 1000:
        return 3
    if max_dec_exp < 10000:
        return 4
    return 5


@always_inline
fn _get_buffer_size[dtype: DType]() -> Int:
    # sign(1) + sig_digits + dec(1) + 'e'(1) + exp_sign(1) + exp_digits + padding(11)
    return 16 + _get_sig_digits[dtype]() + _get_exp_digits[dtype]()


@always_inline
fn write_float[dtype: DType](d: Scalar[dtype], mut writer: Some[Writer]):
    comptime if dtype != DType.float64 and dtype != DType.float32 and dtype != DType.float16:
        # Let stdlib handle exotic float types in case someone is bold enough to use
        # them in JSON.
        writer.write(d)
        return

    comptime buf_size = _get_buffer_size[dtype]()
    var buffer = StackArray[Byte, buf_size](uninitialized=True)
    var buf_idx = 0

    if FPUtils[dtype].get_sign(d):
        buffer.unsafe_get(buf_idx) = `-`
        buf_idx += 1

    if d == 0.0:
        buffer.unsafe_get(buf_idx) = `0`
        buf_idx += 1
        buffer.unsafe_get(buf_idx) = `.`
        buf_idx += 1
        buffer.unsafe_get(buf_idx) = `0`
        buf_idx += 1
        var str_slice = StringSlice(ptr=buffer.unsafe_ptr(), length=buf_idx)
        writer.write(str_slice)
        return

    var fields = teju[dtype](fp_to_binary(abs(d)))

    var sig = fields.mantissa
    var exp = fields.exponent

    var orig_sig = sig
    var abs_exp = abs(exp)

    comptime max_sig = _get_sig_digits[dtype]()
    var digits = StackArray[Byte, max_sig](uninitialized=True)

    var idx = 0
    # Fast 2-digit extraction
    while sig >= 100:
        var q = sig // 100
        var r = Int(sig - (q * 100))
        var pair = lut[DIGIT_PAIRS](r)
        digits.unsafe_get(idx) = pair[1] - `0`
        digits.unsafe_get(idx + 1) = pair[0] - `0`
        sig = q
        idx += 2
        exp += 2

    # Handle remaining digits
    while sig > 0:
        var q = div10(sig)
        digits.unsafe_get(idx) = Byte(sig - (q * 10))
        sig = q
        idx += 1
        if sig > 0:
            exp += 1

    var leading_zeroes = abs_exp - Int32(idx)

    # Write in scientific notation if < 0.0001 or exp > 15
    if (exp < 0 and leading_zeroes > 3) or exp > 15:
        # Handle single digit case
        if orig_sig < 10:
            buffer.unsafe_get(buf_idx) = Byte(orig_sig) + `0`
            buf_idx += 1
        else:
            # Write digit before decimal point
            buffer.unsafe_get(buf_idx) = digits.unsafe_get(idx - 1) + `0`
            buf_idx += 1
            buffer.unsafe_get(buf_idx) = `.`
            buf_idx += 1

        # Write digits after decimal point
        for i in reversed(range(idx - 1)):
            buffer.unsafe_get(buf_idx) = digits.unsafe_get(i) + `0`
            buf_idx += 1

        # Write exponent
        buffer.unsafe_get(buf_idx) = `e`
        buf_idx += 1
        if exp < 0:
            buffer.unsafe_get(buf_idx) = `-`
            buf_idx += 1
            exp = -exp

        # Optimized exponent writing
        if exp < 10:
            buffer.unsafe_get(buf_idx) = `0`
            buffer.unsafe_get(buf_idx + 1) = Byte(exp) + `0`
            buf_idx += 2
        elif exp < 100:
            var pair = lut[DIGIT_PAIRS](Int(exp))
            buffer.unsafe_get(buf_idx) = pair[0]
            buffer.unsafe_get(buf_idx + 1) = pair[1]
            buf_idx += 2
        else:
            comptime max_exp_d = _get_exp_digits[dtype]()
            var exp_digits = StackArray[Byte, max_exp_d](uninitialized=True)
            var exp_idx = 0
            while exp > 0:
                exp_digits.unsafe_get(exp_idx) = Byte(exp % 10)
                exp = Int32(div10(UInt64(exp)))
                exp_idx += 1

            for i in reversed(range(exp_idx)):
                buffer.unsafe_get(buf_idx) = exp_digits.unsafe_get(i) + `0`
                buf_idx += 1

    # If between 0 and 0.0001
    elif exp < 0 and leading_zeroes > 0:
        buffer.unsafe_get(buf_idx) = `0`
        buf_idx += 1
        buffer.unsafe_get(buf_idx) = `.`
        buf_idx += 1
        for _ in range(leading_zeroes):
            buffer.unsafe_get(buf_idx) = `0`
            buf_idx += 1
        for i in reversed(range(idx)):
            buffer.unsafe_get(buf_idx) = digits.unsafe_get(i) + `0`
            buf_idx += 1

    # All other floats > 0.0001 with an exponent <= 15
    else:
        var point_written = False
        for i in reversed(range(idx)):
            if leading_zeroes < 1 and exp == Int32(idx - i) - 2:
                # No integer part so write leading 0
                if i == idx - 1:
                    buffer.unsafe_get(buf_idx) = `0`
                    buf_idx += 1
                buffer.unsafe_get(buf_idx) = `.`
                buf_idx += 1
                point_written = True
            buffer.unsafe_get(buf_idx) = digits.unsafe_get(i) + `0`
            buf_idx += 1

        # If exp - idx + 1 > 0 it's a positive number with more 0's than the
        # sig
        for _ in range(Int(exp) - idx + 1):
            buffer.unsafe_get(buf_idx) = `0`
            buf_idx += 1
        if not point_written:
            buffer.unsafe_get(buf_idx) = `.`
            buf_idx += 1
            buffer.unsafe_get(buf_idx) = `0`
            buf_idx += 1

    var str_slice = StringSlice(ptr=buffer.unsafe_ptr(), length=buf_idx)
    writer.write(str_slice)


@fieldwise_init
struct Fields(TrivialRegisterPassable):
    var mantissa: UInt64
    var exponent: Int32


@always_inline
fn teju[dtype: DType](binary: Fields, out dec: Fields):
    comptime mantissa_size = UInt64(FPUtils[dtype].mantissa_width() + 1)
    comptime min_exponent = Int32(
        1 - FPUtils[dtype].exponent_bias() - FPUtils[dtype].mantissa_width()
    )

    var e = binary.exponent
    var m = binary.mantissa

    if is_small_integer(m, e, Int32(mantissa_size)):
        if e < 0:
            return remove_trailing_zeros(m >> UInt64(-e), 0)
        else:
            return remove_trailing_zeros(m << UInt64(e), 0)

    var f = log10_pow2(e)
    var r = log10_pow2_residual(e)
    var i = f - STORAGE_INDEX_OFFSET

    var mult = lut[MULTIPLIERS](i)
    var u = mult[0]
    var l = mult[1]

    var m_0: UInt64 = 1 << (mantissa_size - 1)

    if m != m_0 or e == min_exponent:
        var m_a = UInt64(2 * m - 1) << UInt64(r)
        var a = mshift(m_a, u, l)
        var m_b = UInt64(2 * m + 1) << UInt64(r)
        var b = mshift(m_b, u, l)
        var q = div10(b)
        var s = 10 * q

        if a < s:
            if s < b or wins_tiebreak(m) or not is_tie(m_b, f):
                return remove_trailing_zeros(q, f + 1)
            elif s == a and wins_tiebreak(m) and is_tie(m_a, f):
                return remove_trailing_zeros(q, f + 1)

        if (a + b) & 1 == 1:
            return Fields((a + b) // 2 + 1, f)

        var m_c = 4 * m << UInt64(r)
        var c_2 = mshift(m_c, u, l)
        var c = c_2 // 2

        if wins_tiebreak(c_2) or (wins_tiebreak(c) and is_tie(c_2, -f)):
            return Fields(c, f)
        return Fields(c + 1, f)

    var m_a = (4 * m_0 - 1) << UInt64(r)
    var a = mshift(m_a, u, l) // 2
    var m_b = (2 * m_0 + 1) << UInt64(r)
    var b = mshift(m_b, u, l)

    if a < b:
        var q = div10(b)
        var s = 10 * q

        if a < s:
            if s < b or wins_tiebreak(m_0) or not is_tie_uncentered(m_b, f):
                return remove_trailing_zeros(q, f + 1)
        elif s == a and wins_tiebreak(m_0) and is_tie_uncentered(m_a, f):
            return remove_trailing_zeros(q, f + 1)

        var log2_m_c = mantissa_size + UInt64(r) + 1
        var c_2 = mshift(log2_m_c, u, l)
        var c = c_2 // 2

        if c == a and not is_tie_uncentered(m_a, f):
            return Fields(c + 1, f)

        if wins_tiebreak(c_2) or (wins_tiebreak(c) and is_tie(c_2, -f)):
            return Fields(c, f)

        return Fields(c + 1, f)

    elif is_tie_uncentered(m_a, f):
        return remove_trailing_zeros(a, f)

    var m_c = 40 * m_0 << UInt64(r)
    var c_2 = mshift(m_c, u, l)
    var c = c_2 // 2

    if wins_tiebreak(c_2) or (wins_tiebreak(c) and is_tie(c_2, -f)):
        return Fields(c, f - 1)
    return Fields(c + 1, f - 1)


@always_inline
fn fp_to_binary[dtype: DType](d: Scalar[dtype], out bin: Fields):
    comptime mantissa_width = FPUtils[dtype].mantissa_width()
    comptime min_exponent = 1 - FPUtils[dtype].exponent_bias() - mantissa_width

    var mantissa = UInt64(FPUtils[dtype].get_mantissa_uint(d))
    var exponent = FPUtils[dtype].get_exponent_biased(d)

    if exponent != 0:
        exponent -= 1
        mantissa |= UInt64(1) << UInt64(mantissa_width)

    exponent += min_exponent

    return Fields(mantissa, Int32(exponent))
