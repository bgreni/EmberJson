from .constants import *
from utils import Span
from memory import memcmp

alias Bytes = String._buffer_type
alias Byte = UInt8
alias ByteVec = SIMD[DType.uint8, _]


@always_inline
fn to_byte(s: String) -> Byte:
    return Byte(ord(s))

@always_inline
fn is_space(char: Byte) -> Bool:
    # making this static breaks docstring tests for some reason?
    var spaces = ByteVec[4](SPACE, NEWLINE, TAB, LINE_FEED)
    return char in spaces

@always_inline
fn bytes_to_string[origin: MutableOrigin, //](b: Span[Byte, origin]) -> String:
    var s = String(b)
    s._buffer.append(0)
    return s

@always_inline
fn byte_to_string(b: Byte) -> String:
    return chr(int(b))


@always_inline
fn compare_bytes[o1: MutableOrigin, o2: MutableOrigin, //](l: Span[Byte, o1], r: Span[Byte, o2]) -> Bool:
    if len(l) != len(r):
        return False
    return memcmp(l.unsafe_ptr(), r.unsafe_ptr(), len(l)) == 0

@always_inline
fn compare_simd[origin: MutableOrigin, size: Int, //](s: Span[Byte, origin], r: SIMD[DType.uint8, size]) -> Bool:
    if len(s) != size:
        return False
    return (s.unsafe_ptr().load[width=size]() == r).reduce_and()