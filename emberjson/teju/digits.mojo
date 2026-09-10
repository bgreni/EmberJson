"""Decimal digit generation for the float writer.

Digits are produced as whole 8-digit words (`digits_word`) and stored with
plain pointer writes; every helper is generic over the destination's
origin so callers can hand it a stack scratch and keep that scratch alive
through the borrow.
"""

from std.bit import count_leading_zeros
from std.memory.unsafe import bitcast
from ..utils import StackArray, lut, DIGIT_PAIRS
from emberjson.constants import `0`, `.`


def _gen_pow10(out s: StackArray[UInt64, 20]):
    s = StackArray[UInt64, 20](uninitialized=True)
    var p = UInt64(1)
    for i in range(20):
        s.unsafe_get(i) = p
        p *= 10


comptime _POW10: StackArray[UInt64, 20] = _gen_pow10()


@always_inline
def digit_count(u: UInt64) -> Int:
    """Number of decimal digits in `u` (1 for zero)."""
    # `u | 1` makes zero behave like one (one digit) in both steps.
    var v = u | 1
    var bits = 64 - Int(count_leading_zeros(v))
    var t = (bits * 1233) >> 12
    return t + 1 - Int(v < lut[_POW10](t))


@always_inline
def _pair_bits(v: UInt32) -> UInt64:
    return UInt64(bitcast[DType.uint16, 1](lut[DIGIT_PAIRS](Int(v))))


@always_inline
def digits_word(v: UInt32) -> UInt64:
    """The eight zero-padded ASCII digits of `v` (< 10^8) as one little-
    endian word, most significant digit in the lowest byte, so a single
    8-byte store writes them in order.

    Two short independent dependency chains instead of a serial loop; the
    compiler turns each `//` into a multiply-high.
    """
    var hi = v // 10000
    var lo = v - hi * 10000
    var a = hi // 100
    var b = hi - a * 100
    var c = lo // 100
    var d = lo - c * 100
    return (
        _pair_bits(a)
        | (_pair_bits(b) << 16)
        | (_pair_bits(c) << 32)
        | (_pair_bits(d) << 48)
    )


@always_inline
def _store_word[o: MutOrigin](p: Pointer[Byte, o], w: UInt64):
    p.unsafe_bitcast[UInt64]().unsafe_store[alignment=1](0, w)


@always_inline
def _store_with_point[o: MutOrigin](p: Pointer[Byte, o], w: UInt64, k: Int):
    """Stores the digit word `w` at `p` with a `.` inserted after its first
    `k` (0..7) bytes: nine bytes, the last being `w`'s top byte."""
    var mask = (UInt64(1) << UInt64(8 * k)) - 1
    var out = (w & mask) | (UInt64(`.`) << UInt64(8 * k)) | ((w & ~mask) << 8)
    _store_word(p, out)
    p[unsafe_offset=8] = Byte(w >> 56)


@always_inline
def _write8[o: MutOrigin](v: UInt32, p: Pointer[Byte, o]):
    """Writes exactly eight digits of `v` (< 10^8) at `p`, zero padded."""
    _store_word(p, digits_word(v))


@always_inline
def _write_digits[o: MutOrigin](var u: UInt64, var end: Pointer[Byte, o]):
    """Writes exactly the decimal digits of `u`, last digit at `end - 1`.

    Numbers of nine or more digits peel off their low eight digits as a
    fixed block (which then converts in parallel with the rest); what is
    left is under 10^8 and goes through a 32-bit two-digits-per-step loop.
    """
    comptime E8 = UInt64(100000000)
    if u >= E8:
        var hi = u // E8
        _write8(UInt32(u - hi * E8), end.unsafe_offset(-8))
        end = end.unsafe_offset(-8)
        u = hi
        if u >= E8:
            hi = u // E8
            _write8(UInt32(u - hi * E8), end.unsafe_offset(-8))
            end = end.unsafe_offset(-8)
            u = hi
    var v = UInt32(u)
    if v >= 10000000:
        # Exactly eight digits left: one more block beats four loop steps.
        _write8(v, end.unsafe_offset(-8))
        return
    while v >= 100:
        var q = v // 100
        var r = v - q * 100
        end = end.unsafe_offset(-2)
        end.unsafe_store(0, lut[DIGIT_PAIRS](Int(r)))
        v = q
    if v >= 10:
        end = end.unsafe_offset(-2)
        end.unsafe_store(0, lut[DIGIT_PAIRS](Int(v)))
    else:
        end = end.unsafe_offset(-1)
        end[] = Byte(v) + `0`
