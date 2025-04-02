from .constants import *
from utils import Variant, StringSlice
from memory import Span
from memory import memcmp, memcpy, UnsafePointer
from utils.write import _WriteBufferStack
from .traits import JsonValue, PrettyPrintable
from os import abort
from sys import sizeof
from sys.intrinsics import unlikely
from sys.intrinsics import _type_is_eq

alias Bytes = List[Byte, True]
alias ByteVec = SIMD[DType.uint8, _]
alias ByteView = Span[Byte, _]
alias BytePtr = UnsafePointer[Byte, mut=False]

alias DefaultPrettyIndent = 4

alias WRITER_DEFAULT_SIZE = 4096


fn will_overflow(i: UInt64) -> Bool:
    return i > UInt64(Int64.MAX)


@always_inline
fn write[T: JsonValue, //](out s: String, v: T):
    s = String()
    var writer = _WriteBufferStack[WRITER_DEFAULT_SIZE](s)
    v.write_to(writer)
    writer.flush()


fn write_pretty[P: PrettyPrintable, //](out s: String, v: P, indent: Variant[Int, String] = DefaultPrettyIndent):
    s = String()
    var writer = _WriteBufferStack[WRITER_DEFAULT_SIZE](s)
    var ind = String(" ") * indent[Int] if indent.isa[Int]() else indent[String]
    v.pretty_to(writer, ind)
    writer.flush()


@always_inline
fn to_byte(s: String) -> Byte:
    return Byte(ord(s))


@always_inline
fn is_space(char: Byte) -> Bool:
    return char == SPACE or char == NEWLINE or char == TAB or char == CARRIAGE


@always_inline
fn to_string(b: ByteView[_]) -> String:
    var s = String(StringSlice(unsafe_from_utf8=b))
    return s


fn to_string(out s: String, v: ByteVec):
    s = String()
    s.reserve(v.size)

    @parameter
    for i in range(v.size):
        s += to_string(v[i])


@always_inline
fn to_string(b: Byte) -> String:
    return chr(Int(b))


@always_inline
fn to_string(owned i: UInt32) -> String:
    # This is meant to be a sequence of 4 characters
    return to_string(UnsafePointer.address_of(i).bitcast[Byte]().load[width=4]())


@always_inline
fn unsafe_memcpy[T: AnyType, //, len: Int = sizeof[T]()](mut dest: T, src: UnsafePointer[Byte]):
    """Copy bytes from a byte array directly into another value by doing a sketchy
    bitcast to get around the type system restrictions on the mojo stdlib memcpy.
    """
    memcpy(UnsafePointer.address_of(dest).bitcast[Byte](), src, len)


@always_inline
fn branchless_ternary(cond: Bool, t: Scalar, f: Scalar[t.dtype]) -> Scalar[t.dtype]:
    """Returns t if cond is True else f."""

    # Trick doesn't work for floats since (-0.0 + 0.0) fails
    constrained[t.dtype.is_integral(), "Expected an integral"]()
    # One side of the `|` will always be zero so the returned result is just the
    # other side.
    return (t * Int(cond)) | (f * Int(~cond))


@always_inline
fn branchless_ternary(cond: Bool, t: Int, f: Int) -> Int:
    """Returns t if cond is True else f."""
    # One side of the `|` will always be zero so the returned result is just the
    # other side.
    return (t * cond) | (f * ~cond)


fn constrain_json_type[T: CollectionElement]():
    alias valid = _type_is_eq[T, Int64]() or _type_is_eq[T, UInt64]() or _type_is_eq[T, Float64]() or _type_is_eq[
        T, String
    ]() or _type_is_eq[T, Bool]() or _type_is_eq[T, Object]() or _type_is_eq[T, Array]() or _type_is_eq[T, Null]()
    constrained[valid, "Invalid type for JSON"]()
