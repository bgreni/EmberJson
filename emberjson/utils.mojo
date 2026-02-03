from bit import pop_count
from .constants import ` `, `\n`, `\t`, `\r`, `\b`, `\f`, `"`, `\\`
from utils import Variant
from utils.numerics import FPUtils
from math import log10, log2
from memory import Span
from memory import memcmp, UnsafePointer
from std.format._utils import _WriteBufferStack
from .traits import JsonValue, PrettyPrintable
from sys import size_of
from sys.intrinsics import unlikely
from sys.intrinsics import _type_is_eq
from sys.compile import is_compile_time
from utils._select import _select_register_value as select
from .simd import SIMD8xT, SIMD8_WIDTH
from builtin.globals import global_constant

comptime ByteVec = SIMD[DType.uint8, _]
comptime ByteView = Span[Byte, _]
comptime BytePtr[origin: ImmutOrigin] = UnsafePointer[Byte, origin]


@always_inline
fn lut[A: StackArray](i: Some[Indexer]) -> A.ElementType:
    return global_constant[A]().unsafe_get(i).copy()


@fieldwise_init
struct CheckedPointer[origin: ImmutOrigin](Comparable, TrivialRegisterType):
    var p: BytePtr[Self.origin]
    var start: BytePtr[Self.origin]
    var end: BytePtr[Self.origin]

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
    ) raises -> ref[Self.origin, self.p.address_space] Byte:
        if unlikely(self.dist() <= 0):
            raise Error("Unexpected EOF")
        return self.p[]

    @always_inline("nodebug")
    fn __getitem__(
        ref self, i: Int
    ) raises -> ref[Self.origin, self.p.address_space] Byte:
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


comptime DefaultPrettyIndent = 4

comptime StackArray[
    T: Copyable & Movable & ImplicitlyDestructible, size: Int
] = InlineArray[T, size]


@always_inline
fn will_overflow(i: UInt64) -> Bool:
    return i > UInt64(Int64.MAX)


fn write(out s: String, v: Some[JsonValue]):
    s = String()  # FIXME(modular/#4573): once it is optimized, return String(v)
    var writer = _WriteBufferStack(s)
    v.write_to(writer)
    writer.flush()


@no_inline
fn write_pretty(
    value: Some[PrettyPrintable],
    indent: Variant[Int, String] = DefaultPrettyIndent,
    out s: String,
):
    var ind = String(" ") * indent[Int] if indent.isa[Int]() else indent[String]
    s = String()
    var writer = _WriteBufferStack(s)
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
        s.append(Codepoint(v[i]))


@always_inline
fn to_string(b: Byte, out s: String):
    s = String(capacity=1)
    s.append(Codepoint(b))
    return s^


@always_inline
fn to_string(var i: UInt32) -> String:
    # This is meant to be a sequence of 4 characters
    return to_string(UnsafePointer(to=i).bitcast[Byte]().load[width=4]())


fn constrain_json_type[T: Movable & Copyable]():
    comptime valid = _type_is_eq[T, Int64]() or _type_is_eq[
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


fn write_escaped_string(s: String, mut writer: Some[Writer]):
    writer.write('"')
    var start = 0
    var p = s.as_bytes()
    var len = len(s)

    for i in range(len):
        var c = p[i]
        if c == `"` or c == `\\` or c < 32:
            if i > start:
                writer.write(StringSlice(unsafe_from_utf8=p[start:i]))

            start = i + 1
            if c == `"`:
                writer.write(r"\"")
            elif c == `\\`:
                writer.write(r"\\")
            elif c == `\b`:
                writer.write(r"\b")
            elif c == `\f`:
                writer.write(r"\f")
            elif c == `\n`:
                writer.write(r"\n")
            elif c == `\r`:
                writer.write(r"\r")
            elif c == `\t`:
                writer.write(r"\t")
            else:
                # Control chars
                writer.write(r"\u00")
                _write_hex_byte(c, writer)

    if start < len:
        writer.write(StringSlice(unsafe_from_utf8=p[start:len]))

    writer.write('"')


comptime hex_chars = "0123456789abcdef"


fn get_hex_bytes(out o: InlineArray[Byte, len(hex_chars)]):
    o = {fill = 0}
    for i in range(len(hex_chars)):
        o[i] = hex_chars.as_bytes()[i]


@always_inline
fn _write_hex_byte(b: Byte, mut writer: Some[Writer]):
    var bytes = materialize[get_hex_bytes()]()
    var h1 = bytes[Int(b >> 4)]
    var h2 = bytes[Int(b & 0xF)]
    writer.write(Codepoint(h1))
    writer.write(Codepoint(h2))
