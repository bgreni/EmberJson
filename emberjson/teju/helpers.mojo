from .tables import MINIVERSE
from ..utils import lut

comptime LOG10_POW2_MAX: Int32 = 112815
comptime LOG10_POW2_MIN: Int32 = -LOG10_POW2_MAX


@always_inline
fn remove_trailing_zeros(var m: UInt64, var e: Int32) -> Fields:
    comptime minv5: UInt64 = -(UInt64.MAX // 5)
    comptime bound: UInt64 = (UInt64.MAX // 10 + 1)

    while True:
        var q = ror(m * minv5)
        if q >= bound:
            return Fields(m, e)
        e += 1
        m = q


@always_inline
fn ror(m: UInt64) -> UInt64:
    return m << 63 | m >> 1


@always_inline
fn is_small_integer(m: UInt64, e: Int32) -> Bool:
    return (Int32(0) <= -e < Int32(MANTISSA_SIZE)) and is_multiple_of_pow2(
        m, -e
    )


@always_inline
fn div10(n: UInt64) -> UInt64:
    comptime a = UInt128(UInt64.MAX // 10 + 1)
    return UInt64((a * UInt128(n)) >> 64)


@always_inline
fn is_multiple_of_pow2(m: UInt64, e: Int32) -> Bool:
    return (m & ~(UInt64.MAX << UInt64(e))) == 0


comptime LOG10_POW2_MAGIC_NUM = 1292913987


@always_inline
fn log10_pow2(e: Int32) -> Int32:
    return Int32((Int64(LOG10_POW2_MAGIC_NUM) * Int64(e)) >> 32)


@always_inline
fn log10_pow2_residual(e: Int32) -> UInt32:
    return UInt32((LOG10_POW2_MAGIC_NUM * Int64(e))) // LOG10_POW2_MAGIC_NUM


@always_inline
fn mshift(m: UInt64, u: UInt64, l: UInt64) -> UInt64:
    var m_long = UInt128(m)
    var s0 = UInt128(l) * m_long
    var s1 = UInt128(u) * m_long
    return UInt64((s1 + (s0 >> 64)) >> 64)


@always_inline
fn is_tie(m: UInt64, f: Int32) -> Bool:
    comptime LEN_MINIVERSE = 27
    return Int32(0) <= f < LEN_MINIVERSE and is_multiple_of_pow5(m, f)


@always_inline
fn is_multiple_of_pow5(n: UInt64, f: Int32) -> Bool:
    var p = lut[MINIVERSE](f)
    return n * p[0] <= p[1]


@always_inline
fn is_tie_uncentered(m_a: UInt64, f: Int32) -> Bool:
    return Int32(0) <= f and m_a % 5 == 0 and is_multiple_of_pow5(m_a, f)


@always_inline
fn is_div_pow2(val: UInt64, e: Int32) -> Bool:
    return val & UInt64((1 << e) - 1) == 0


@always_inline
fn wins_tiebreak(val: UInt64) -> Bool:
    return val & 1 == 0
