from .constants import *
from utils import Span
from memory import memcmp, memcpy
from utils.write import _WriteBuffer
from .traits import JsonValue

alias Bytes = String._buffer_type
alias ByteVec = SIMD[DType.uint8, _]
alias ByteView = Span[Byte, _]


@always_inline
fn write[T: JsonValue, //](v: T) -> String:
    var writer = _WriteBuffer[4096](String())
    v.write_to(writer)
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
fn bytes_to_string(b: ByteView[_]) -> String:
    var s = String(b)
    s._buffer.append(0)
    return s


@always_inline
fn byte_to_string(b: Byte) -> String:
    return chr(int(b))


@always_inline
fn compare_bytes(l: ByteView[_], r: ByteView[_]) -> Bool:
    if len(l) != len(r):
        return False
    return memcmp(l.unsafe_ptr(), r.unsafe_ptr(), len(l)) == 0


@always_inline
fn compare_simd[size: Int, //](s: ByteView[_], r: SIMD[DType.uint8, size]) -> Bool:
    if len(s) != size:
        return False
    return (s.unsafe_ptr().load[width=size]() == r).reduce_and()
