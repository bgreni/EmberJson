from .constants import *
from utils import Variant, StringSlice
from memory import Span
from memory import memcmp, memcpy, UnsafePointer
from utils.write import _WriteBufferStack
from .traits import JsonValue, PrettyPrintable
from os import abort
from sys import sizeof
from sys.intrinsics import unlikely

alias Bytes = List[Byte, True]
alias ByteVec = SIMD[DType.uint8, _]
alias ByteView = Span[Byte, _]

alias DefaultPrettyIndent = 4


@always_inline
fn write[T: JsonValue, //](v: T) -> String:
    var writer = _WriteBufferStack[4096](String())
    v.write_to(writer)
    writer.flush()
    return writer.writer


fn write_pretty[P: PrettyPrintable, //](v: P, indent: Variant[Int, String] = DefaultPrettyIndent) -> String:
    var writer = _WriteBufferStack[4096](String())
    var ind = String(" ") * indent[Int] if indent.isa[Int]() else indent[String]
    v.pretty_to(writer, ind)
    writer.flush()
    return writer.writer


@always_inline
fn to_byte(s: String) -> Byte:
    return Byte(ord(s))


@always_inline
fn is_space(char: Byte) -> Bool:
    alias spaces = ByteVec[4](SPACE, NEWLINE, TAB, LINE_FEED)
    return char in spaces


@always_inline
fn to_string(b: ByteView[_]) -> String:
    var s = String(StringSlice(unsafe_from_utf8=b))
    return s


@always_inline
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
fn compare_bytes(l: ByteView[_], r: ByteView[_]) -> Bool:
    if unlikely(len(l) != len(r)):
        return False
    return memcmp(l.unsafe_ptr(), r.unsafe_ptr(), len(l)) == 0


@always_inline
fn compare_simd[size: Int, //](s: ByteView[_], r: SIMD[DType.uint8, size]) -> Bool:
    if unlikely(len(s) != size):
        return False
    return (s.unsafe_ptr().load[width=size]() == r).reduce_and()


@always_inline
fn unsafe_memcpy[T: AnyType, //, len: Int = sizeof[T]()](mut dest: T, src: UnsafePointer[Byte]):
    """Copy bytes from a byte array directly into another value by doing a sketchy
    bitcast to get around the type system restrictions on the mojo stdlib memcpy.
    """
    memcpy(UnsafePointer.address_of(dest).bitcast[Byte](), src, len)


@always_inline
fn branchless_ternary(t: Scalar, f: Scalar[t.type], cond: Bool) -> Scalar[t.type]:
    """Returns t if cond is True else f."""

    # Trick doesn't work for floats since (-0.0 + 0.0) fails
    constrained[t.type.is_integral(), "Expected an integral"]()
    # One side of the `|` will always be zero so the returned result is just the
    # other side.
    return (t * Int(cond)) | (f * Int(~cond))


@always_inline
fn branchless_ternary(t: Int, f: Int, cond: Bool) -> Int:
    """Returns t if cond is True else f."""
    # One side of the `|` will always be zero so the returned result is just the
    # other side.
    return (t * cond) | (f * ~cond)
