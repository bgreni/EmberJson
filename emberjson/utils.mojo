from .constants import *
from utils import Variant
from memory import Span
from memory import memcmp, memcpy, UnsafePointer
from utils.write import _WriteBufferStack, _TotalWritableBytes
from .traits import JsonValue, PrettyPrintable
from os import abort
from sys import sizeof
from sys.intrinsics import unlikely
from sys.intrinsics import _type_is_eq
from utils._select import _select_register_value as select
from .parser_helper import ptr_dist
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
    ) -> ref [self.p.origin, self.p.address_space] Byte:
        self.expect_remaining(1)
        return self.p[]

    @always_inline("nodebug")
    fn __getitem__(
        ref self, i: Int
    ) -> ref [self.p.origin, self.p.address_space] Byte:
        self.expect_remaining(1 + i)
        return self.p[i]

    @always_inline("nodebug")
    fn dist(self) -> Int:
        return ptr_dist(self.p, self.end)

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
            StringSlice(ptr=self.start, length=ptr_dist(self.start, self.end)),
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
fn to_byte(s: StringSlice) -> Byte:
    return Byte(ord(s))


@always_inline
fn is_space(char: Byte) -> Bool:
    return char == ` ` or char == `\n` or char == `\t` or char == `\r`


@always_inline
fn to_string(b: ByteView[_]) -> String:
    return String(StringSlice(unsafe_from_utf8=b))


fn to_string(out s: String, v: ByteVec):
    s = String()
    s.reserve(v.size)

    @parameter
    for i in range(v.size):
        s.append_byte(v[i])


@always_inline
fn to_string(b: Byte) -> String:
    return chr(Int(b))


@always_inline
fn to_string(owned i: UInt32) -> String:
    # This is meant to be a sequence of 4 characters
    return to_string(UnsafePointer(to=i).bitcast[Byte]().load[width=4]())


@always_inline
fn unsafe_memcpy[
    T: AnyType, //, len: Int = sizeof[T]()
](mut dest: T, src: UnsafePointer[Byte]):
    """Copy bytes from a byte array directly into another value by doing a sketchy
    bitcast to get around the type system restrictions on the mojo stdlib memcpy.
    """
    memcpy(UnsafePointer(to=dest).bitcast[Byte](), src, len)


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
