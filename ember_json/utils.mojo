from .constants import *
from utils import Span
from memory import memcmp, memcpy

alias Bytes = String._buffer_type
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
fn bytes_to_string(b: Span[Byte, _]) -> String:
    var s = String(b)
    s._buffer.append(0)
    return s


@always_inline
fn byte_to_string(b: Byte) -> String:
    return chr(int(b))


@always_inline
fn compare_bytes(l: Span[Byte, _], r: Span[Byte, _]) -> Bool:
    if len(l) != len(r):
        return False
    return memcmp(l.unsafe_ptr(), r.unsafe_ptr(), len(l)) == 0


@always_inline
fn compare_simd[size: Int, //](s: Span[Byte, _], r: SIMD[DType.uint8, size]) -> Bool:
    if len(s) != size:
        return False
    return (s.unsafe_ptr().load[width=size]() == r).reduce_and()


struct StringBuilder(Writer):
    var s: Bytes

    fn __init__(inout self, capacity: Int):
        self.s = Bytes(capacity=capacity + 1)  # going to add null terminator at the end

    @always_inline
    fn write_bytes(inout self, bytes: Span[Byte, _]):
        var new_size = len(self.s) + len(bytes)
        if new_size > self.s.capacity:
            self.s.reserve(new_size + int(new_size * 0.40))

        memcpy(dest=self.s.unsafe_ptr() + len(self.s), src=bytes.unsafe_ptr(), count=len(bytes))
        self.s.size += len(bytes)

    fn write[*Ts: Writable](inout self, *args: *Ts):
        @parameter
        fn write_arg[W: Writable](arg: W):
            arg.write_to(self)

        args.each[write_arg]()

    fn build(inout self) -> String:
        var s = self.s^
        s.append(0)
        self.s = Bytes()
        return String(s^)
