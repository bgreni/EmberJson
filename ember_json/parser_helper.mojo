from .utils import *
from memory import UnsafePointer
from math import iota
from .simd import *
from .tables import *
from memory import memcpy

alias BytePtr = UnsafePointer[Byte, mut=False]


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
var acceptable_escapes = ByteVec[16](QUOTE, RSOL, SOL, B, F, N, R, T, U, U, U, U, U, U, U, U)
alias DOT = to_byte(".")
alias PLUS = to_byte("+")
alias NEG = to_byte("-")
alias ZERO_CHAR = to_byte("0")


@always_inline
@parameter
fn is_numerical_component(char: Byte) -> Bool:
    var componenents = ByteVec[8](DOT, LOW_E, UPPER_E, PLUS, NEG, NEG, NEG, NEG)
    return isdigit(char) or char in componenents


@always_inline
fn get_non_space_bits[Size: Int, //](out v: ByteVec[Size]._Mask, s: ByteVec[Size]):
    v = (s == SPACE) | (s == NEWLINE) | (s == TAB) | (s == LINE_FEED)
    return ~v


fn index(simd: SIMD, item: Scalar[simd.type]) -> Int:
    var seq = iota[simd.type, simd.size]()
    var result = (simd == item).select(seq, simd.MAX).reduce_min()
    var found = bool(result != item.MAX)
    return (-1 * ~found) | (int(result) * found)


fn ind(simd: SIMD, item: Scalar[simd.type]) -> Int:
    var seq = iota[simd.type, simd.size]()
    var result = (simd == item).select(seq, simd.MAX).reduce_min()
    var found = bool(result != item.MAX)
    if found:
        return int(result)
    return Int.MAX


fn ind(simd: SIMDBool) -> Int:
    return ind(simd.cast[DType.uint8](), UInt8(1))


fn first_true(simd: SIMD[DType.bool, _]) -> Int:
    return index(simd.cast[DType.uint8](), UInt8(1))


fn ptr_dist(start: UnsafePointer[Byte], end: UnsafePointer[Byte]) -> Int:
    return int(end) - int(start)


@value
struct StringBlock:
    alias BitMask = SIMD8xT._Mask

    var bs_bits: Self.BitMask
    var quote_bits: Self.BitMask
    var unescaped_bits: Self.BitMask

    fn quote_index(self) -> Int:
        return first_true(self.quote_bits)

    fn bs_index(self) -> Int:
        return first_true(self.bs_bits)

    fn unescaped_index(self) -> Int:
        return first_true(self.unescaped_bits)

    fn has_quote_first(self) -> Bool:
        return ind(self.quote_bits) < ind(self.bs_bits) and not self.has_unescaped()

    fn has_backslash(self) -> Bool:
        return ind(self.bs_bits) < ind(self.quote_bits)

    fn has_unescaped(self) -> Bool:
        return ind(self.unescaped_bits) < ind(self.quote_bits)

    @staticmethod
    fn find(src: UnsafePointer[UInt8]) -> StringBlock:
        var v = src.load[width=SIMD8_WIDTH]()
        alias I_DONT_KNOW_WHAT_THIS_IS: UInt8 = 31
        return StringBlock(v == RSOL, v == QUOTE, v <= I_DONT_KNOW_WHAT_THIS_IS)


fn hex_to_u32(v: ByteVec[4]) -> UInt32:
    var other = ByteVec[4](630, 420, 210, 0)
    var out = UInt32(0)

    @parameter
    for i in range(4):
        out |= digit_to_val32[int(v[i] + other[i])]
    return out


fn copy_to_string(out s: String, p: BytePtr, length: Int):
    var l = Bytes(capacity=length + 1)
    memcpy(l.unsafe_ptr(), p, length)
    l.size = length
    l.append(0)
    s = l


@always_inline
fn is_exp_char(char: Byte) -> Bool:
    return char == LOW_E or char == UPPER_E


@always_inline
fn is_sign_char(char: Byte) -> Bool:
    return char == PLUS or char == NEG


