from .utils import *
from memory import UnsafePointer
from math import iota
from .simd import *
from .tables import *
from memory import memcpy
from memory.unsafe import bitcast, pack_bits
from bit import count_trailing_zeros

alias BytePtr = UnsafePointer[Byte]
alias smallest_power: Int64 = -342
alias largest_power: Int64 = 308


alias TRUE = ByteVec[4](to_byte("t"), to_byte("r"), to_byte("u"), to_byte("e"))
alias ALSE = ByteVec[4](to_byte("a"), to_byte("l"), to_byte("s"), to_byte("e"))
alias NULL = ByteVec[4](to_byte("n"), to_byte("u"), to_byte("l"), to_byte("l"))
alias SOL = to_byte("/")
alias B = to_byte("b")
alias F = to_byte("f")
alias N = to_byte("n")
alias R = to_byte("r")
alias T = to_byte("t")
alias U = to_byte("u")
alias acceptable_escapes = ByteVec[16](QUOTE, RSOL, SOL, B, F, N, R, T, U, U, U, U, U, U, U, U)
alias DOT = to_byte(".")
alias PLUS = to_byte("+")
alias NEG = to_byte("-")
alias ZERO_CHAR = to_byte("0")

fn isdigit(char: Byte) -> Bool:
    alias ord_0 = to_byte("0")
    alias ord_9 = to_byte("9")
    return ord_0 <= char <= ord_9

@always_inline
fn is_numerical_component(char: Byte) -> Bool:
    return isdigit(char) or char == PLUS or char == NEG


@always_inline
fn get_non_space_bits[Size: Int, //](out v: SIMDBool[Size], s: ByteVec[Size]):
    v = (s == SPACE) | (s == NEWLINE) | (s == TAB) | (s == LINE_FEED)
    return ~v


@always_inline
fn pack_into_int(simd: SIMDBool) -> Int:
    return Int(pack_bits(simd))


@always_inline
fn first_true(simd: SIMD[DType.bool, _]) -> Int:
    return count_trailing_zeros(pack_into_int(simd))


@always_inline
fn ptr_dist(start: BytePtr, end: BytePtr) -> Int:
    return Int(end) - Int(start)


@register_passable("trivial")
struct StringBlock:
    alias BitMask = SIMD8xT._Mask

    var bs_bits: Int
    var quote_bits: Int
    var unescaped_bits: Int

    fn __init__(out self, bs: SIMDBool, qb: SIMDBool, un: SIMDBool):
        self.bs_bits = pack_into_int(bs)
        self.quote_bits = pack_into_int(qb)
        self.unescaped_bits = pack_into_int(un)

    @always_inline
    fn quote_index(self) -> Int:
        return count_trailing_zeros(self.quote_bits)

    @always_inline
    fn bs_index(self) -> UInt64:
        return count_trailing_zeros(self.bs_bits)

    @always_inline
    fn unescaped_index(self) -> Int:
        return count_trailing_zeros(self.unescaped_bits)

    @always_inline
    fn has_quote_first(self) -> Bool:
        return count_trailing_zeros(self.quote_bits) < count_trailing_zeros(self.bs_bits) and not self.has_unescaped()

    @always_inline
    fn has_backslash(self) -> Bool:
        return count_trailing_zeros(self.bs_bits) < count_trailing_zeros(self.quote_bits)

    @always_inline
    fn has_unescaped(self) -> Bool:
        return count_trailing_zeros(self.unescaped_bits) < count_trailing_zeros(self.quote_bits)

    @staticmethod
    @always_inline
    fn find(out block: StringBlock, src: BytePtr):
        var v = src.load[width=SIMD8_WIDTH]()
        alias LAST_ESCAPE_CHAR: UInt8 = 31
        block = StringBlock(v == RSOL, v == QUOTE, v <= LAST_ESCAPE_CHAR)


@always_inline
fn hex_to_u32(out out: UInt32, p: BytePtr):
    alias other = ByteVec[4](630, 420, 210, 0)
    out = 0
    var v = p.load[width=4]().cast[DType.uint32]()
    v = (v & 0xF) + 9 * (v >> 6)
    alias shifts = SIMD[DType.uint32, 4](12, 8, 4, 0)
    v <<= shifts
    out = v.reduce_or()


fn handle_unicode_codepoint(mut p: BytePtr, mut dest: Bytes) raises:
    var c1 = hex_to_u32(p)
    p += 4
    if c1 >= 0xD800 and c1 < 0xDC00:
        if unlikely(p[] != RSOL and (p + 1)[] != U):
            raise Error("Bad unicode codepoint")

        p += 2
        var c2 = hex_to_u32(p)

        if unlikely(Bool((c1 | c2) >> 16)):
            raise Error("Bad unicode codepoint")

        c1 = (((c1 - 0xD800) << 10) | (c2 - 0xDC00)) + 0x10000
        p += 4
    if c1 <= 0x7F:
        dest.append(c1.cast[DType.uint8]())
        return
    elif c1 <= 0x7FF:
        dest.append(((c1 >> 6) + 192).cast[DType.uint8]())
        dest.append(((c1 & 63) + 128).cast[DType.uint8]())
        return
    elif c1 <= 0xFFFF:
        dest.append(((c1 >> 12) + 224).cast[DType.uint8]())
        dest.append((((c1 >> 6) & 63) + 128).cast[DType.uint8]())
        dest.append(((c1 & 63) + 128).cast[DType.uint8]())
        return
    elif c1 <= 0x10FFFF:
        dest.append(((c1 >> 18) + 240).cast[DType.uint8]())
        dest.append((((c1 >> 12) & 63) + 128).cast[DType.uint8]())
        dest.append((((c1 >> 6) & 63) + 128).cast[DType.uint8]())
        dest.append(((c1 & 63) + 128).cast[DType.uint8]())
        return
    else:
        raise Error("Invalid unicode")


@always_inline
fn copy_to_string(out s: String, start: BytePtr, end: BytePtr) raises:
    var length = ptr_dist(start, end)
    var l = Bytes(capacity=length + 1)
    var p = start

    while p < end:
        if p[] == RSOL and p + 1 != end and (p + 1)[] == U:
            p += 2
            handle_unicode_codepoint(p, l)
        else:
            l.append(p[])
            p += 1

    l.size = length
    l.append(0)
    s = String(l^)


@always_inline
fn is_exp_char(char: Byte) -> Bool:
    return char == LOW_E or char == UPPER_E


@always_inline
fn is_sign_char(char: Byte) -> Bool:
    return char == PLUS or char == NEG


@always_inline
fn is_made_of_eight_digits_fast(src: BytePtr) -> Bool:
    """Don't ask me how this works."""
    var val: UInt64 = 0
    unsafe_memcpy(val, src)
    return ((val & 0xF0F0F0F0F0F0F0F0) | (((val + 0x0606060606060606) & 0xF0F0F0F0F0F0F0F0) >> 4)) == 0x3333333333333333


@always_inline
fn to_double(out d: Float64, owned mantissa: UInt64, real_exponent: UInt64, negative: Bool):
    alias `1 << 52` = 1 << 52
    mantissa &= ~(`1 << 52`)
    mantissa |= real_exponent << 52
    mantissa |= Int(negative) << 63
    d = bitcast[DType.float64](mantissa)


@always_inline
fn parse_eight_digits(out val: UInt64, p: BytePtr):
    """Don't ask me how this works."""
    val = 0
    unsafe_memcpy(val, p)
    val = (val & 0x0F0F0F0F0F0F0F0F) * 2561 >> 8
    val = (val & 0x00FF00FF00FF00FF) * 6553601 >> 16
    val = (val & 0x0000FFFF0000FFFF) * 42949672960001 >> 32


@always_inline
fn parse_digit(p: BytePtr, mut i: Scalar) -> Bool:
    var dig = isdigit(p[])
    i = branchless_ternary(i * 10 + (p[] - ZERO_CHAR).cast[i.type](), i, dig)
    return dig


@always_inline
fn significant_digits(p: BytePtr, digit_count: Int) -> Int:
    var start = p
    while start[] == ZERO_CHAR or start[] == DOT:
        start += 1

    return digit_count - ptr_dist(p, start)
