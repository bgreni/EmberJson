from std.bit import pop_count, count_trailing_zeros
from std.memory.unsafe import pack_bits
from .constants import ` `, `\n`, `\t`, `\r`, `\b`, `\f`, `"`, `\\`
from std.utils import Variant
from std.utils.numerics import FPUtils
from std.math import log10, log2
from std.memory import Span
from std.memory import memcmp, memcpy, memset, UnsafePointer
from std.format._utils import _WriteBufferStack
from .traits import JsonValue, PrettyPrintable
from .object import Object
from .array import Array
from .value import Null
from std.sys import size_of
from std.sys.intrinsics import unlikely
from std.utils._select import _select_register_value as select
from .simd import SIMD8xT, SIMD8_WIDTH
from std.builtin.globals import global_constant

comptime ByteVec = SIMD[DType.uint8, _]
comptime ByteView = Span[Byte, _]
comptime BytePtr[origin: ImmutOrigin] = UnsafePointer[Byte, origin]


@always_inline
def lut[A: StackArray](i: Some[Indexer]) -> A.ElementType:
    return global_constant[A]().unsafe_get(i).copy()


@fieldwise_init
struct CheckedPointer[origin: ImmutOrigin](Comparable, TrivialRegisterPassable):
    var p: BytePtr[Self.origin]
    var start: BytePtr[Self.origin]
    var end: BytePtr[Self.origin]

    @always_inline("nodebug")
    def __add__(self, v: Int) -> Self:
        return {self.p + v, self.start, self.end}

    @always_inline("nodebug")
    def __iadd__(mut self, v: Int):
        self.p += v

    @always_inline("nodebug")
    def __eq__(self, other: Self) -> Bool:
        return self.p == other.p

    @always_inline("nodebug")
    def __ne__(self, other: Self) -> Bool:
        return self.p != other.p

    @always_inline("nodebug")
    def __gt__(self, other: Self) -> Bool:
        return self.p > other.p

    @always_inline("nodebug")
    def __lt__(self, other: Self) -> Bool:
        return self.p < other.p

    @always_inline("nodebug")
    def __ge__(self, other: Self) -> Bool:
        return self.p >= other.p

    @always_inline("nodebug")
    def __le__(self, other: Self) -> Bool:
        return self.p <= other.p

    @always_inline("nodebug")
    def __add__(self, v: SIMD) -> Self:
        comptime assert v.dtype.is_integral()
        return {self.p + v, self.start, self.end}

    @always_inline("nodebug")
    def __iadd__(mut self, v: SIMD):
        comptime assert v.dtype.is_integral()
        self.p += v

    @always_inline("nodebug")
    def __sub__(self, i: Int) -> Self:
        return {self.p - i, self.start, self.end}

    @always_inline("nodebug")
    def __isub__(mut self, i: Int):
        self.p -= i

    @always_inline("nodebug")
    def __getitem__(
        ref self,
    ) raises -> ref[Self.origin, self.p.address_space] Byte:
        if unlikely(self.dist() <= 0):
            raise Error("Unexpected EOF")
        return self.p[]

    @always_inline("nodebug")
    def __getitem__(
        ref self, i: Int
    ) raises -> ref[Self.origin, self.p.address_space] Byte:
        if unlikely(self.dist() - i <= 0):
            raise Error("Unexpected EOF")
        return self.p[i]

    @always_inline("nodebug")
    def unsafe_get(self) -> Byte:
        """Reads the current byte without a bounds check.

        Safety:
            Only valid when the underlying buffer is known to extend past
            `end` (see `PaddedBuffer`), so reads at or beyond `end` land in
            NUL padding instead of unmapped memory.
        """
        return self.p[]

    @always_inline("nodebug")
    def unsafe_get(self, i: Int) -> Byte:
        """Reads the byte at offset `i` without a bounds check.

        Safety:
            See `unsafe_get()`.
        """
        return self.p[i]

    @always_inline("nodebug")
    def dist(self) -> Int:
        return Int(self.end) - Int(self.p)

    @always_inline("nodebug")
    def load_chunk(self) -> SIMD8xT:
        if self.dist() < SIMD8_WIDTH:
            v = SIMD8xT(0)
            for i in range(self.dist()):
                v[i] = self.p[i]
            return v
        return self.p.load[width=SIMD8_WIDTH]()

    @always_inline("nodebug")
    def unsafe_load_chunk(self) -> SIMD8xT:
        """Loads a full SIMD chunk without the partial-tail fallback.

        Safety:
            Only valid when the underlying buffer extends at least
            `SIMD8_WIDTH` bytes past `end` (see `PaddedBuffer`).
        """
        return self.p.load[width=SIMD8_WIDTH]()


comptime PAD_INPUT_THRESHOLD = 128
"""Input size below which the DOM entry points skip the `PaddedBuffer`
copy and parse the caller's buffer directly with bounds checks.

For tiny documents (single scalars, small objects) the buffer allocation,
memcpy and NUL memset cost more than the whole parse; above this size the
unchecked hot loops win."""


struct PaddedBuffer(Movable):
    """Owns a copy of parser input followed by `PAD` NUL bytes.

    The padding lets the parser's SIMD/SWAR hot loops read past the logical
    end of input without bounds checks: NUL is not a digit, not whitespace,
    not a structural character, and is an unescaped control character inside
    strings, so every scan loop terminates within the pad with the same
    error it would have raised at a checked end-of-input. The layout
    (round up to 64 bytes + 128-byte pad) also satisfies a future stage-1
    structural indexer reading whole 64-byte chunks.
    """

    comptime PAD = 128

    var _data: List[Byte]
    var _len: Int

    def __init__(out self, s: ByteView):
        var n = len(s)
        var total = (n + 63) // 64 * 64 + Self.PAD
        self._data = List[Byte](unsafe_uninit_length=total)
        memcpy(dest=self._data.unsafe_ptr(), src=s.unsafe_ptr(), count=n)
        memset(self._data.unsafe_ptr() + n, 0, total - n)
        self._len = n

    @always_inline
    def span(ref self) -> ByteView[origin_of(self._data)]:
        """The logical input: `len` bytes, with readable NUL padding after."""
        return Span(ptr=self._data.unsafe_ptr(), length=self._len)


comptime DefaultPrettyIndent = 4

comptime StackArray[T: Copyable & ImplicitlyDeletable, size: Int] = InlineArray[
    T, size
]


@always_inline
def will_overflow(i: UInt64) -> Bool:
    return i > UInt64(Int64.MAX)


def write(out s: String, v: Some[JsonValue]):
    s = String()  # FIXME(modular/#4573): once it is optimized, return String(v)
    var writer = _WriteBufferStack(s)
    v.write_to(writer)
    writer.flush()


@no_inline
def write_pretty(
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
def is_space(char: Byte) -> Bool:
    return char == ` ` or char == `\n` or char == `\t` or char == `\r`


@always_inline
def to_string(b: ByteView[_]) -> StringSlice[b.origin]:
    return StringSlice(unsafe_from_utf8=b)


@always_inline
def to_string(v: ByteVec, out s: String):
    s = String(capacity=v.size)

    comptime for i in range(v.size):
        s.append(Codepoint(v[i]))


@always_inline
def to_string(b: Byte, out s: String):
    s = String(capacity=1)
    s.append(Codepoint(b))
    return s^


@always_inline
def to_string(var i: UInt32) -> String:
    # This is meant to be a sequence of 4 characters
    return to_string(UnsafePointer(to=i).bitcast[Byte]().load[width=4]())


def constrain_json_type[T: Copyable]():
    comptime valid = T == Int64 or T == UInt64 or T == Float64 or T == String or T == Bool or T == Object or T == Array or T == Null
    comptime assert valid, "Invalid type for JSON"


@always_inline
def _handle_escape(c: Byte, mut writer: Some[Writer]):
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
        writer.write(r"\u00")
        _write_hex_byte(c, writer)


@always_inline
def _needs_escape(bytes: Span[Byte, _], n: Int) -> Bool:
    var ptr = bytes.unsafe_ptr()
    var i = 0
    while i + SIMD8_WIDTH <= n:
        var chunk = ptr.load[width=SIMD8_WIDTH](i)
        if pack_bits(chunk.eq(`"`) | chunk.eq(`\\`) | chunk.lt(` `)) != 0:
            return True
        i += SIMD8_WIDTH
    while i < n:
        var c = ptr[i]
        if c == `"` or c == `\\` or c < 32:
            return True
        i += 1
    return False


def write_escaped_string(s: String, mut writer: Some[Writer]):
    var bytes = s.as_bytes()
    var n = s.byte_length()

    # Fast path: no escaping needed — single batched write
    if not _needs_escape(bytes, n):
        writer.write('"', s, '"')
        return

    # Slow path: string contains characters that need escaping
    writer.write('"')
    var ptr = bytes.unsafe_ptr()
    var i = 0
    var start = 0

    while i + SIMD8_WIDTH <= n:
        var chunk = ptr.load[width=SIMD8_WIDTH](i)
        var escape_bits = pack_bits(
            chunk.eq(`"`) | chunk.eq(`\\`) | chunk.lt(` `)
        )
        if escape_bits == 0:
            i += SIMD8_WIDTH
            continue
        var bits = escape_bits
        while bits != 0:
            var pos = Int(count_trailing_zeros(bits))
            if i + pos > start:
                writer.write(
                    StringSlice(unsafe_from_utf8=bytes[start : i + pos])
                )
            start = i + pos + 1
            _handle_escape(ptr[i + pos], writer)
            bits &= bits - 1
        i += SIMD8_WIDTH

    while i < n:
        var c = ptr[i]
        if c == `"` or c == `\\` or c < 32:
            if i > start:
                writer.write(StringSlice(unsafe_from_utf8=bytes[start:i]))
            start = i + 1
            _handle_escape(c, writer)
        i += 1

    if start < n:
        writer.write(StringSlice(unsafe_from_utf8=bytes[start:n]))

    writer.write('"')


comptime hex_chars = "0123456789abcdef".as_bytes()


def get_hex_bytes(out s: StackArray[Byte, 16]):
    s = StackArray[Byte, 16](uninitialized=True)
    for i in range(16):
        s.unsafe_get(i) = hex_chars[i]


@always_inline
def _write_hex_byte(b: Byte, mut writer: Some[Writer]):
    var bytes = materialize[get_hex_bytes()]()
    var h1 = bytes.unsafe_get(Int(b >> 4))
    var h2 = bytes.unsafe_get(Int(b & 0xF))
    writer.write(Codepoint(h1))
    writer.write(Codepoint(h2))


def _generate_digit_pairs(out s: StackArray[SIMD[DType.uint8, 2], 100]):
    s = StackArray[SIMD[DType.uint8, 2], 100](uninitialized=True)
    for i in range(100):
        s.unsafe_get(i) = SIMD[DType.uint8, 2](
            UInt8(0x30 + (i // 10)), UInt8(0x30 + (i % 10))
        )


comptime DIGIT_PAIRS: StackArray[
    SIMD[DType.uint8, 2], 100
] = _generate_digit_pairs()
