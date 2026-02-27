# Mojo port of the Teju Jagua algorithm by Cassio Neri.
# Original implementation: https://github.com/cassioneri/teju_jagua
# Licensed under the Apache License, Version 2.0.
from .tables import MINIVERSE
from ..utils import lut, select

comptime LOG10_POW2_MAX: Int32 = 112815
comptime LOG10_POW2_MIN: Int32 = -LOG10_POW2_MAX


@always_inline
fn remove_trailing_zeros(var m: UInt64, var e: Int32) -> Fields:
    # Fastest algorithm for removing trailing zeroes:
    # https://github.com/jk-jeon/rtz_benchmark
    # Adapted from Mojo stdlib Dragonbox implementation.

    var r = _rotr(m * 28999941890838049, 8)
    var b = r < 184467440738
    var s = Int(b)
    m = select(b, r, m)

    r = _rotr(m * 182622766329724561, 4)
    b = r < 1844674407370956
    s = s * 2 + Int(b)
    m = select(b, r, m)

    r = _rotr(m * 10330176681277348905, 2)
    b = r < 184467440737095517
    s = s * 2 + Int(b)
    m = select(b, r, m)

    r = _rotr(m * 14757395258967641293, 1)
    b = r < 1844674407370955162
    s = s * 2 + Int(b)
    m = select(b, r, m)

    return Fields(m, e + Int32(s))


@always_inline
fn _rotr(n: UInt64, r: UInt64) -> UInt64:
    var r_masked = r & 63
    return (n >> r_masked) | (n << ((64 - r_masked) & 63))


@always_inline
fn is_small_integer(m: UInt64, e: Int32, mantissa_size: Int32) -> Bool:
    if e >= 0:
        return e + mantissa_size <= 64
    return (Int32(0) <= -e < mantissa_size) and is_multiple_of_pow2(m, -e)


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
