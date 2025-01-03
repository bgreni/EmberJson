from .utils import *
from memory import UnsafePointer
from math import iota
from .simd import *
from .tables import *
from memory import memcpy
from memory.unsafe import bitcast

alias BytePtr = UnsafePointer[Byte, mut=False]
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


@always_inline
fn is_numerical_component(char: Byte) -> Bool:
    return isdigit(char) or char == PLUS or char == NEG


@always_inline
fn get_non_space_bits[Size: Int, //](out v: SIMDBool[Size], s: ByteVec[Size]):
    v = (s == SPACE) | (s == NEWLINE) | (s == TAB) | (s == LINE_FEED)
    return ~v


@always_inline
fn index[T: DType, //, item: Scalar[T]](simd: SIMD[T, _]) -> Int:
    var seq = iota[simd.type, simd.size]()
    var result = (simd == item).select(seq, simd.MAX).reduce_min()
    var found = bool(result != item.MAX)
    return branchless_ternary(int(result), Int.MAX, found)


@always_inline
fn first_true(simd: SIMD[DType.bool, _]) -> Int:
    return index[UInt8(1)](simd.cast[DType.uint8]())


@always_inline
fn ptr_dist(start: UnsafePointer[Byte], end: UnsafePointer[Byte]) -> Int:
    return int(end) - int(start)


@value
struct StringBlock:
    alias BitMask = SIMD8xT._Mask

    var bs_bits: Self.BitMask
    var quote_bits: Self.BitMask
    var unescaped_bits: Self.BitMask

    @always_inline
    fn quote_index(self) -> Int:
        return first_true(self.quote_bits)

    @always_inline
    fn bs_index(self) -> Int:
        return first_true(self.bs_bits)

    @always_inline
    fn unescaped_index(self) -> Int:
        return first_true(self.unescaped_bits)

    @always_inline
    fn has_quote_first(self) -> Bool:
        return first_true(self.quote_bits) < first_true(self.bs_bits) and not self.has_unescaped()

    @always_inline
    fn has_backslash(self) -> Bool:
        return first_true(self.bs_bits) < first_true(self.quote_bits)

    @always_inline
    fn has_unescaped(self) -> Bool:
        return first_true(self.unescaped_bits) < first_true(self.quote_bits)

    @staticmethod
    @always_inline
    fn find(src: UnsafePointer[UInt8]) -> StringBlock:
        var v = src.load[width=SIMD8_WIDTH]()
        alias LAST_ESCAPE_CHAR: UInt8 = 31
        return StringBlock(v == RSOL, v == QUOTE, v <= LAST_ESCAPE_CHAR)


@always_inline
fn hex_to_u32(out out: UInt32, v: ByteVec[4]):
    alias other = ByteVec[4](630, 420, 210, 0)
    out = 0

    @parameter
    for i in range(4):
        out |= digit_to_val32[int(v[i] + other[i])]


@always_inline
fn copy_to_string(out s: String, p: BytePtr, length: Int):
    var l = Bytes(capacity=length + 1)
    memcpy(l.unsafe_ptr(), p, length)
    l.size = length
    l.append(0)
    s = l^


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
    mantissa |= int(negative) << 63
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
