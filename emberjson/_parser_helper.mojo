from .utils import BytePtr, CheckedPointer, select
from memory import UnsafePointer
from .simd import SIMDBool, SIMD8_WIDTH, SIMD8xT
from .constants import (
    `0`,
    `9`,
    ` `,
    `\n`,
    `+`,
    `-`,
    `\t`,
    `\r`,
    `\\`,
    `"`,
    `u`,
    `e`,
    `E`,
    `.`,
)
from memory.unsafe import bitcast, pack_bits, _uint
from bit import count_trailing_zeros
from sys.info import bitwidthof
from sys.intrinsics import _type_is_eq, likely, unlikely

alias smallest_power: Int64 = -342
alias largest_power: Int64 = 308

alias TRUE: UInt32 = _to_uint32("true")
alias ALSE: UInt32 = _to_uint32("alse")
alias NULL: UInt32 = _to_uint32("null")


fn _to_uint32(s: StaticString) -> UInt32:
    debug_assert(s.byte_length() > 3, "string is too small")
    return s.unsafe_ptr().bitcast[UInt32]()[0]


@always_inline
fn append_digit(v: Scalar, to_add: Scalar) -> __type_of(v):
    return (10 * v) + to_add.cast[v.dtype]()


fn isdigit(char: Byte) -> Bool:
    return `0` <= char <= `9`


@always_inline
fn is_numerical_component(char: Byte) -> Bool:
    return isdigit(char) or char == `+` or char == `-`


alias Bits_T = Scalar[_uint(SIMD8_WIDTH)]


@always_inline
fn get_non_space_bits(s: SIMD8xT) -> Bits_T:
    var vec = (s == ` `) | (s == `\n`) | (s == `\t`) | (s == `\r`)
    return ~pack_into_integer(vec)


@always_inline
fn pack_into_integer(simd: SIMDBool) -> Bits_T:
    return Bits_T(pack_bits(simd))


@always_inline
fn first_true(simd: SIMDBool) -> Bits_T:
    return count_trailing_zeros(pack_into_integer(simd))


@always_inline
fn ptr_dist(start: BytePtr, end: BytePtr) -> Int:
    return Int(end) - Int(start)


@register_passable("trivial")
struct StringBlock:
    alias BitMask = SIMD[DType.bool, SIMD8_WIDTH]

    var bs_bits: Bits_T
    var quote_bits: Bits_T
    var unescaped_bits: Bits_T

    fn __init__(out self, bs: Self.BitMask, qb: Self.BitMask, un: Self.BitMask):
        self.bs_bits = pack_into_integer(bs)
        self.quote_bits = pack_into_integer(qb)
        self.unescaped_bits = pack_into_integer(un)

    @always_inline
    fn quote_index(self) -> Bits_T:
        return count_trailing_zeros(self.quote_bits)

    @always_inline
    fn bs_index(self) -> Bits_T:
        return count_trailing_zeros(self.bs_bits)

    @always_inline
    fn unescaped_index(self) -> Bits_T:
        return count_trailing_zeros(self.unescaped_bits)

    @always_inline
    fn has_quote_first(self) -> Bool:
        return (
            count_trailing_zeros(self.quote_bits)
            < count_trailing_zeros(self.bs_bits)
            and not self.has_unescaped()
        )

    @always_inline
    fn has_backslash(self) -> Bool:
        return count_trailing_zeros(self.bs_bits) < count_trailing_zeros(
            self.quote_bits
        )

    @always_inline
    fn has_unescaped(self) -> Bool:
        return count_trailing_zeros(self.unescaped_bits) < count_trailing_zeros(
            self.quote_bits
        )

    @staticmethod
    @always_inline
    fn find(src: CheckedPointer) -> StringBlock:
        var v = src.load_chunk()
        # NOTE: ASCII first printable character ` ` https://www.ascii-code.com/
        return StringBlock(v == `\\`, v == `"`, v < ` `)

    @staticmethod
    @always_inline
    fn find(src: BytePtr) -> StringBlock:
        # FIXME: Port minify to use CheckedPointer
        var v = src.load[width=SIMD8_WIDTH]()
        # NOTE: ASCII first printable character ` ` https://www.ascii-code.com/
        return StringBlock(v == `\\`, v == `"`, v < ` `)


@always_inline
fn hex_to_u32(p: BytePtr) -> UInt32:
    var v = p.load[width=4]().cast[DType.uint32]()
    v = (v & 0xF) + 9 * (v >> 6)
    alias shifts = SIMD[DType.uint32, 4](12, 8, 4, 0)
    v <<= shifts
    return v.reduce_or()


fn handle_unicode_codepoint(
    mut p: BytePtr, mut dest: String, end: BytePtr
) raises:
    # TODO: is this check necessary or just being paranoid?
    # because theoretically no string can be built with "\u" only
    # But if this points to bytes received over the wire, it makes sense
    # unless we use _is_valid_utf8 at the beginning of where this is called
    if unlikely(p + 3 >= end):
        raise Error("Bad unicode codepoint")
    var c1 = hex_to_u32(p)
    p += 4
    # NOTE: incredibly, this is part of the JSON standard (thanks javascript...)
    # ECMA-404 2nd Edition / December 2017. Section 9:
    # To escape a code point that is not in the Basic Multilingual Plane, the
    # character may be represented as a twelve-character sequence, encoding the
    # UTF-16 surrogate pair corresponding to the code point. So for example, a
    # string containing only the G clef character (U+1D11E) may be represented
    # as "\uD834\uDD1E". However, whether a processor of JSON texts interprets
    # such a surrogate pair as a single code point or as an explicit surrogate
    # pair is a semantic decision that is determined by the specific processor.
    if c1 >= 0xD800 and c1 < 0xDC00:
        # TODO: same as the above TODO
        if unlikely(p + 5 >= end):
            raise Error("Bad unicode codepoint")
        elif unlikely(not (p[0] == `\\` and p[1] == `u`)):
            raise Error("Bad unicode codepoint")

        p += 2
        var c2 = hex_to_u32(p)

        if unlikely(Bool((c1 | c2) >> 16)):
            raise Error("Bad unicode codepoint")

        c1 = (((c1 - 0xD800) << 10) | (c2 - 0xDC00)) | 0x10000
        p += 4

    if likely(c1 <= 0x7F):
        dest.append_byte(c1.cast[DType.uint8]())
    elif c1 <= 0x7FF:
        dest.append_byte(((c1 >> 6) | 192).cast[DType.uint8]())
        dest.append_byte(((c1 & 63) | 128).cast[DType.uint8]())
    elif c1 <= 0xFFFF:
        dest.append_byte(((c1 >> 12) | 224).cast[DType.uint8]())
        dest.append_byte((((c1 >> 6) & 63) | 128).cast[DType.uint8]())
        dest.append_byte(((c1 & 63) | 128).cast[DType.uint8]())
    else:
        if unlikely(c1 > 0x10FFFF):
            raise Error("Invalid unicode")
        dest.append_byte(((c1 >> 18) | 240).cast[DType.uint8]())
        dest.append_byte((((c1 >> 12) & 63) | 128).cast[DType.uint8]())
        dest.append_byte((((c1 >> 6) & 63) | 128).cast[DType.uint8]())
        dest.append_byte(((c1 & 63) | 128).cast[DType.uint8]())


@always_inline
fn copy_to_string[
    ignore_unicode: Bool = False
](
    out s: String, start: BytePtr, end: BytePtr, found_unicode: Bool = True
) raises:
    var length = ptr_dist(start, end)

    @parameter
    fn decode_unicode(out res: String) raises:
        # This will usually slightly overallocate if the string contains
        # escaped unicode
        var l = String(capacity=length)
        var p = start

        while p < end:
            if p[0] == `\\` and p[Int(p + 1 != end)] == `u`:
                p += 2
                handle_unicode_codepoint(p, l, end)
            else:
                l.append_byte(p[0])
                p += 1
        res = l^

    @parameter
    if not ignore_unicode:
        if found_unicode:
            return decode_unicode()
        else:
            return String(StringSlice(ptr=start, length=length))
    else:
        return String(StringSlice(ptr=start, length=length))


@always_inline
fn is_exp_char(char: Byte) -> Bool:
    return char == `e` or char == `E`


@always_inline
fn is_sign_char(char: Byte) -> Bool:
    return char == `+` or char == `-`


@always_inline
fn unsafe_is_made_of_eight_digits_fast(src: BytePtr) -> Bool:
    """Don't ask me how this works.

    Safety:
        This is only safe if there are at least 8 bytes remaining.
    """
    var val = src.bitcast[UInt64]()[0]
    return (
        (val & 0xF0F0F0F0F0F0F0F0)
        | (((val + 0x0606060606060606) & 0xF0F0F0F0F0F0F0F0) >> 4)
    ) == 0x3333333333333333


@always_inline
fn to_double(
    owned mantissa: UInt64, real_exponent: UInt64, negative: Bool
) -> Float64:
    alias `1 << 52` = 1 << 52
    mantissa &= ~(`1 << 52`)
    mantissa |= real_exponent << 52
    mantissa |= Int(negative) << 63
    return bitcast[DType.float64](mantissa)


@always_inline
fn unsafe_parse_eight_digits(out val: UInt64, p: BytePtr):
    """Don't ask me how this works.

    Safety:
        This is only safe if there are at least 8 bytes remaining.
    """
    val = p.bitcast[UInt64]()[0]
    val = (val & 0x0F0F0F0F0F0F0F0F) * 2561 >> 8
    val = (val & 0x00FF00FF00FF00FF) * 6553601 >> 16
    val = (val & 0x0000FFFF0000FFFF) * 42949672960001 >> 32


@always_inline
fn parse_digit(out dig: Bool, p: CheckedPointer, mut i: Scalar) raises:
    if p.dist() <= 0:
        return False
    dig = isdigit(p[])
    i = select(dig, i * 10 + (p[] - `0`).cast[i.dtype](), i)


@always_inline
fn significant_digits(p: BytePtr, digit_count: Int) -> Int:
    var start = p
    while start[] == `0` or start[] == `.`:
        start += 1

    return digit_count - ptr_dist(p, start)
