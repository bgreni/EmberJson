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
from ..utils import StackArray, lut
from emberjson.format_int import write_int


# Mojo port of the Teju Jagua algorithm https://github.com/cassioneri/teju_jagua

comptime MANTISSA_SIZE: UInt64 = 53
comptime EXPONENT_MIN: Int32 = -1074
comptime STORAGE_INDEX_OFFSET = -324


@always_inline
fn write_f64(d: Float64, mut writer: Some[Writer]):
    comptime TOP_BIT = 1 << 63
    if bitcast[DType.uint64](d) & TOP_BIT != 0:
        writer.write("-")

    if d == 0.0:
        writer.write("0.0")
        return

    var fields = teju(f64_to_binary(abs(d)))

    var sig = fields.mantissa
    var exp = fields.exponent

    var orig_sig = sig
    var abs_exp = abs(exp)
    var digits = StackArray[UInt64, 21](fill=0)
    var idx = 0
    while sig > 0:
        digits[idx] = sig % 10
        sig //= 10
        idx += 1
        if sig > 0:
            exp += 1
    var leading_zeroes = abs_exp - idx

    # Write in scientific notation if < 0.0001 or exp > 15
    if (exp < 0 and leading_zeroes > 3) or exp > 15:
        # Handle single digit case
        if orig_sig < 10:
            writer.write(orig_sig)
        else:
            # Write digit before decimal point
            writer.write(digits[idx - 1])
            writer.write(".")
        # Write digits after decimal point
        for i in reversed(range(idx - 1)):
            writer.write(digits[i])
        # Write exponent
        if exp < 0:
            writer.write("e-")
            exp = -exp
        else:
            writer.write("e")
        # Pad exponent with a 0 if less than two digits
        if exp < 10:
            writer.write("0")
        var exp_digits = StackArray[Int32, 10](fill=0)
        var exp_idx = 0
        while exp > 0:
            exp_digits[exp_idx] = exp % 10
            exp //= 10
            exp_idx += 1
        for i in reversed(range(exp_idx)):
            writer.write(exp_digits[i])
    # If between 0 and 0.0001
    elif exp < 0 and leading_zeroes > 0:
        writer.write("0.")
        for _ in range(leading_zeroes):
            writer.write("0")
        for i in reversed(range(idx)):
            writer.write(digits[i])
    # All other floats > 0.0001 with an exponent <= 15
    else:
        var point_written = False
        for i in reversed(range(idx)):
            if leading_zeroes < 1 and exp == idx - i - 2:
                # No integer part so write leading 0
                if i == idx - 1:
                    writer.write("0")
                writer.write(".")
                point_written = True
            writer.write(digits[i])

        # If exp - idx + 1 > 0 it's a positive number with more 0's than the
        # sig
        for _ in range(exp - idx + 1):
            writer.write("0")
        if not point_written:
            writer.write(".0")


@fieldwise_init
struct Fields(TrivialRegisterPassable):
    var mantissa: UInt64
    var exponent: Int32


@always_inline
fn teju(binary: Fields, out dec: Fields):
    var e = binary.exponent
    var m = binary.mantissa

    if is_small_integer(m, e):
        return remove_trailing_zeros(m >> Int(-e), 0)

    var f = log10_pow2(e)
    var r = log10_pow2_residual(e)
    var i = f - STORAGE_INDEX_OFFSET

    var mult = lut[MULTIPLIERS](i)
    var u = mult[0]
    var l = mult[1]

    var m_0: UInt64 = 1 << (MANTISSA_SIZE - 1)

    if m != m_0 or e == EXPONENT_MIN:
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

        var log2_m_c = UInt64(MANTISSA_SIZE) + UInt64(r) + 1
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
fn f64_to_binary(d: Float64, out bin: Fields):
    var bits = bitcast[DType.uint64](d)
    comptime k = MANTISSA_SIZE - 1
    comptime MANTISSA_MASK = (((1) << (k)) - 1)

    var mantissa = bits & MANTISSA_MASK

    bits >>= k
    var exponent = Int32(bits)

    if exponent != 0:
        exponent -= 1
        comptime `1 << k` = 1 << k
        mantissa |= `1 << k`

    exponent += EXPONENT_MIN

    return Fields(mantissa, exponent)
