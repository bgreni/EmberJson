from bit import pop_count
from .constants import ` `, `\n`, `\t`, `\r`
from utils import Variant
from utils.numerics import FPUtils
from math import log10, log2
from memory import Span
from memory import memcmp, UnsafePointer
from utils.write import _WriteBufferStack, _TotalWritableBytes
from .traits import JsonValue, PrettyPrintable
from os import abort
from sys import sizeof
from sys.intrinsics import unlikely
from sys.intrinsics import _type_is_eq
from utils._select import _select_register_value as select
from .simd import SIMD8xT, SIMD8_WIDTH

alias Bytes = List[Byte, True]
alias ByteVec = SIMD[DType.uint8, _]
alias ByteView = Span[Byte, _]
alias BytePtr = UnsafePointer[Byte, mut=False]


@fieldwise_init
@register_passable("trivial")
struct CheckedPointer(Copyable, Comparable):
    var p: BytePtr
    var start: BytePtr
    var end: BytePtr

    @always_inline("nodebug")
    fn __add__(self, v: Int) -> Self:
        return {self.p + v, self.start, self.end}

    @always_inline("nodebug")
    fn __iadd__(mut self, v: Int):
        self.p += v

    @always_inline("nodebug")
    fn __eq__(self, other: Self) -> Bool:
        return self.p == other.p

    @always_inline("nodebug")
    fn __ne__(self, other: Self) -> Bool:
        return self.p != other.p

    @always_inline("nodebug")
    fn __gt__(self, other: Self) -> Bool:
        return self.p > other.p

    @always_inline("nodebug")
    fn __lt__(self, other: Self) -> Bool:
        return self.p < other.p

    @always_inline("nodebug")
    fn __ge__(self, other: Self) -> Bool:
        return self.p >= other.p

    @always_inline("nodebug")
    fn __le__(self, other: Self) -> Bool:
        return self.p <= other.p

    @always_inline("nodebug")
    fn __add__(self, v: SIMD) -> Self:
        constrained[v.dtype.is_integral()]()
        return {self.p + v, self.start, self.end}

    @always_inline("nodebug")
    fn __iadd__(mut self, v: SIMD):
        constrained[v.dtype.is_integral()]()
        self.p += v

    @always_inline("nodebug")
    fn __sub__(self, i: Int) -> Self:
        return {self.p - i, self.start, self.end}

    @always_inline("nodebug")
    fn __isub__(mut self, i: Int):
        self.p -= i

    @always_inline("nodebug")
    fn __getitem__(
        ref self,
    ) raises -> ref [self.p.origin, self.p.address_space] Byte:
        if unlikely(self.dist() <= 0):
            raise Error("Unexpected EOF")
        return self.p[]

    @always_inline("nodebug")
    fn __getitem__(
        ref self, i: Int
    ) raises -> ref [self.p.origin, self.p.address_space] Byte:
        if unlikely(self.dist() - i <= 0):
            raise Error("Unexpected EOF")
        return self.p[i]

    @always_inline("nodebug")
    fn dist(self) -> Int:
        return Int(self.end) - Int(self.p)

    @always_inline("nodebug")
    fn load_chunk(self) -> SIMD8xT:
        if self.dist() < SIMD8_WIDTH:
            v = SIMD8xT(0)
            for i in range(self.dist()):
                v[i] = self.p[i]
            return v
        return self.p.load[width=SIMD8_WIDTH]()

    @always_inline("nodebug")
    fn expect_remaining(self, i: Int):
        debug_assert(
            self.dist() + 1 >= i,
            "Expected at least: ",
            i,
            " bytes remaining, received: ",
            self.dist() + 1,
            "\ninput:\n\n",
            StringSlice(ptr=self.start, length=Int(self.end) - Int(self.start)),
        )


alias DefaultPrettyIndent = 4

alias WRITER_DEFAULT_SIZE = 4096

alias StackArray = InlineArray[_, _, run_destructors=False]


@always_inline
fn will_overflow(i: UInt64) -> Bool:
    return i > UInt64(Int64.MAX)


fn write[T: JsonValue, //](out s: String, v: T):
    s = String()  # FIXME(modular/#4573): once it is optimized, return String(v)
    var writer = _WriteBufferStack[WRITER_DEFAULT_SIZE](s)
    v.write_to(writer)
    writer.flush()


@no_inline
fn write_pretty[
    P: PrettyPrintable, //, *, buffer_size: Int = WRITER_DEFAULT_SIZE
](value: P, indent: Variant[Int, String] = DefaultPrettyIndent, out s: String):
    var ind = String(" ") * indent[Int] if indent.isa[Int]() else indent[String]
    var arg_bytes = _TotalWritableBytes()
    value.pretty_to(arg_bytes, ind)
    s = String(capacity=arg_bytes.size)
    var writer = _WriteBufferStack[buffer_size](s)
    value.pretty_to(writer, ind)
    writer.flush()


@always_inline
fn is_space(char: Byte) -> Bool:
    return char == ` ` or char == `\n` or char == `\t` or char == `\r`


@always_inline
fn to_string(b: ByteView[_]) -> StringSlice[b.origin]:
    return StringSlice(unsafe_from_utf8=b)


@always_inline
fn to_string(v: ByteVec, out s: String):
    s = String(capacity=v.size)

    @parameter
    for i in range(v.size):
        s.append_byte(v[i])


@always_inline
fn to_string(b: Byte, out s: String):
    s = String(capacity=1)
    s.append_byte(b)
    return s^


@always_inline
fn to_string(owned i: UInt32) -> String:
    # This is meant to be a sequence of 4 characters
    return to_string(UnsafePointer(to=i).bitcast[Byte]().load[width=4]())


fn constrain_json_type[T: Movable & Copyable]():
    alias valid = _type_is_eq[T, Int64]() or _type_is_eq[
        T, UInt64
    ]() or _type_is_eq[T, Float64]() or _type_is_eq[T, String]() or _type_is_eq[
        T, Bool
    ]() or _type_is_eq[
        T, Object
    ]() or _type_is_eq[
        T, Array
    ]() or _type_is_eq[
        T, Null
    ]()
    constrained[valid, "Invalid type for JSON"]()


@parameter
@always_inline
fn _uint_type_of_width[width: Int]() -> DType:
    constrained[
        width in (8, 16, 32, 64, 128, 256),
        "width must be either 8, 16, 32, 64, 128, or 256",
    ]()

    @parameter
    if width == 8:
        return DType.uint8
    elif width == 16:
        return DType.uint16
    elif width == 32:
        return DType.uint32
    elif width == 64:
        return DType.uint64
    elif width == 128:
        return DType.uint128
    else:
        return DType.uint256


fn estimate_bytes_to_write(value: Int) -> UInt:
    return estimate_bytes_to_write(Scalar[DType.index](value))


fn estimate_bytes_to_write(value: UInt) -> UInt:
    alias uint_dtype = _uint_type_of_width[UInt.BITWIDTH]()
    return estimate_bytes_to_write(Scalar[uint_dtype](value))


fn estimate_bytes_to_write(value: Scalar) -> UInt:
    constrained[
        value.dtype.is_floating_point() or value.dtype.is_integral(),
        "Value must be integral or floating point",
    ]()

    @parameter
    if value.dtype.is_floating_point():
        return _estimate_bytes_to_write_float(value)
    else:
        return _estimate_bytes_to_write_int(value)


fn _estimate_bytes_to_write_int(value: Scalar) -> UInt:
    constrained[value.dtype.is_integral(), "Function for integral types only"]()

    @parameter
    if value.dtype.is_unsigned():
        return UInt(Int(log10(Float64(value)))) + 1
    else:
        return UInt(Int(log10(Float64(value)))) + 1 + UInt(value < 0)


fn _estimate_bytes_to_write_float(value: Scalar) -> UInt:
    alias FP = FPUtils[value.dtype]
    alias MANTISSA_SIZE = FP.mantissa_width()
    alias EXPONENT_MASK = FP.exponent_mask()
    alias MANTISSA_MASK = FP.mantissa_mask()

    var is_negative = FP.get_sign(value)
    var exp = (FP.bitcast_to_integer(value) & EXPONENT_MASK) >> MANTISSA_SIZE
    var mant = FP.bitcast_to_uint(value) & MANTISSA_MASK

    alias `log10(2)` = 0.3010299956639812
    # TODO: maybe constraint until we have a more generic way to extract
    # -0, nan, +inf, -inf
    var amnt_exp: UInt
    # usually inf or NaN, both use 3 letters
    if exp == 2 * FP.max_exponent() - 1:
        amnt_exp = 3
    elif exp == 0 and mant == 0:  # usually -0
        amnt_exp = 0
    else:  # normal exponentiation
        var e: Int = exp - FP.exponent_bias()
        # +2 is for `e+/-` or +1 for `.` when abs(e) <= 4
        var est_exp = (Int(log10(Float64(abs(e)) * `log10(2)`) + 1) + 1)
        amnt_exp = UInt((est_exp & -Int(abs(e) > 4)) + 1)

    # +2 is to ensure up to 17 characters (53 * log10(2) ~ 15.95458977)
    var amnt_mantissa = Int(Float64(pop_count(mant)) * `log10(2)`) + 2
    return UInt(is_negative) + UInt(amnt_exp) + UInt(amnt_mantissa)
