"""EmberJson's reflection `Deserializer`, in simdjson On Demand's shape.

`from_json` runs the SIMD stage-1 indexer over the input first, and
`EmberJsonDeserializer` then hops token to token through the structural
index, the way simdjson's On Demand API feeds its C++26 reflection
deserializer: whitespace is never touched, the next token is one index load
away, and a string's closing quote is the next index entry, so its span is
known before it is read.

Scalars are read by the hand-written `Parser`, which a read repositions
at the token's offset. Grammar errors are the cursor's own, found on the
index and raised through the shared `_errors` constructors, so the messages
and `DerErrorKind`s are the ones the `Value` parser raises for the same
input (`test/emberjson/test_error_parity.mojo`), and emberserde adds the
paths. Nesting depth is counted on that `Parser`, container for container,
against `options.max_depth`.
"""

from std.sys.intrinsics import unlikely, likely
from std.collections import Set

from emberjson._deserialize import Parser, ParseOptions, StrictOptions
from emberjson._deserialize._parser_helper import (
    copy_to_string,
    ptr_dist,
    isdigit,
    pack_into_integer,
    Bits_T,
    _TOKEN_END_OK,
    value_error,
    string_error,
    check_string_body,
    glued,
)
from emberjson._deserialize._errors import (
    unexpected_eof,
    after_value,
    expected_separator,
    trailing_comma,
    expected_key,
    expected_colon,
    expected_enum_tag,
    trailing_content,
    duplicate_key,
    malformed_string,
    expected_length,
    expected_single_key,
    too_deep,
    invalid_value,
)
from emberjson._deserialize._number import try_parse_int, try_parse_float64
from emberjson._index import (
    structural_index_with_flags,
    structural_index_into,
    INDEX_SLACK,
)
from emberjson.constants import (
    `[`,
    `]`,
    `{`,
    `}`,
    `"`,
    `:`,
    `,`,
    `n`,
    `t`,
    `f`,
    `-`,
    `+`,
)
from emberjson.utils import BytePtr, CheckedPointer, lut, StackArray
from emberjson.value import Value

from emberserde.deserialize import (
    BorrowingDeserializer,
    Deserializable,
    RawKind,
    SelfDescribingDeserializer,
    SeqDerState,
    MapDerState,
    StructDerState,
    TupleDerState,
    EnumDerState,
    deserialize,
)
from emberserde.error import DeserializationError
from emberserde.field import Alias
from emberserde.field_meta import (
    field_annotations,
    field_index,
    wire_field_names,
)
from std.reflection import reflect
from emberjson.simd import SIMD8_WIDTH
from emberserde.utils import Base
from std.collections.string.string_span import get_static_string


# The cursor's errors. Each is detected on the index and the input bytes
# and raised through the shared `_errors` constructors, deciding between
# them as the `Value` parser does at the same byte (the parity test holds
# them to it). They take the cursor's address as an `Int` and return the
# error for the caller to raise: cold calls that pass only scalars leave
# the hot readers' registers and stack frames alone (see
# `EmberJsonCursor.token_error`).

comptime _CursorAt[origin: ImmOrigin, options: ParseOptions] = Pointer[
    EmberJsonCursor[origin, options], ImmutAnyOrigin
]


@no_inline
def _token_error[
    origin: ImmOrigin, options: ParseOptions
](cursor: Int, expected: Byte, close: Byte) -> DeserializationError:
    """The error for a next token that is not the grammar token `expected`
    (`:`, `,` or `close`), inside a container that `close` ends."""
    ref c = _CursorAt[origin, options](unsafe_from_address=cursor)[]
    if c.i >= c.n:
        return unexpected_eof()
    var b = c.byte(c.peek_off())
    if expected == `:`:
        return expected_colon(b)
    return expected_separator(close, b)


@no_inline
def _value_error[
    origin: ImmOrigin, options: ParseOptions
](cursor: Int, what: StaticString) -> DeserializationError:
    """The error for a next token that does not open a `what`."""
    ref c = _CursorAt[origin, options](unsafe_from_address=cursor)[]
    if c.i >= c.n:
        return unexpected_eof()
    var off = c.peek_off()
    return value_error(c.p.data.start.unsafe_offset(off), c.p.size - off, what)


@no_inline
def _string_error[
    origin: ImmOrigin, options: ParseOptions
](cursor: Int, open: Int) -> DeserializationError:
    """The error for the string opening at `open`, which holds a control
    byte or which the index never closes."""
    ref c = _CursorAt[origin, options](unsafe_from_address=cursor)[]
    return string_error(
        c.p.data.start.unsafe_offset(open + 1), c.p.size - open - 1
    )


@no_inline
def _field_key_error[
    origin: ImmOrigin, options: ParseOptions
](cursor: Int, first: Bool) -> DeserializationError:
    """The error for an object member that `next_field_key` rejected, found
    in the order the `Value` parser meets it: the separator, the key's
    opening quote, the key itself (a malformed key can pair quotes
    differently in the index: `"a\\:1` runs to the next quote), then the
    colon."""
    ref c = _CursorAt[origin, options](unsafe_from_address=cursor)[]
    var base = c.p.data.start
    var k = c.i
    if not first:
        if k >= c.n:
            return unexpected_eof()
        var b = c.byte(c.entry_off(k))
        if b != `,`:
            return expected_separator(`}`, b)
        k += 1
        if k < c.n and c.byte(c.entry_off(k)) == `}`:
            return trailing_comma()
    if k >= c.n:
        return unexpected_eof()
    var open = c.entry_off(k)
    if c.byte(open) != `"`:
        return expected_key(c.byte(open))
    if k + 1 >= c.n:
        return string_error(base.unsafe_offset(open + 1), c.p.size - open - 1)
    var close = c.entry_off(k + 1)
    try:
        check_string_body(base.unsafe_offset(open + 1), close - open - 1)
        _ = copy_to_string[options.ignore_unicode](
            base.unsafe_offset(open + 1), base.unsafe_offset(close)
        )
    except e:
        return e^
    if k + 2 >= c.n:
        return unexpected_eof()
    return expected_colon(c.byte(c.entry_off(k + 2)))


@no_inline
def _tuple_error[
    origin: ImmOrigin, options: ParseOptions
](cursor: Int, count: Int) -> DeserializationError:
    """The error for a tuple element's separator that is not `,`: a `]`
    ends a well-formed array too short for the tuple."""
    ref c = _CursorAt[origin, options](unsafe_from_address=cursor)[]
    if c.i < c.n and c.byte(c.peek_off()) == `]`:
        return expected_length(count)
    return _token_error[origin, options](cursor, `,`, `]`)


@no_inline
def _tuple_element_error[
    origin: ImmOrigin, options: ParseOptions
](
    cursor: Int, at: Int, count: Int, var e: DeserializationError
) -> DeserializationError:
    """The error for a tuple element that failed to read with `e` from
    index entry `at`. A `]` there ends the array: after a `,` it is a
    trailing comma, otherwise an array too short for the tuple."""
    ref c = _CursorAt[origin, options](unsafe_from_address=cursor)[]
    if at >= c.n or c.byte(c.entry_off(at)) != `]`:
        return e^
    comptime if not (StrictOptions.ALLOW_TRAILING_COMMA in options.strict_mode):
        if at > 0 and c.byte(c.entry_off(at - 1)) == `,`:
            return trailing_comma()
    return expected_length(count)


@no_inline
def _trailing_error[
    origin: ImmOrigin, options: ParseOptions
](cursor: Int) -> DeserializationError:
    """The error for a token after the root value. (One glued to a root
    scalar, `12x`, is the scalar's `check_token_end` error.)"""
    ref c = _CursorAt[origin, options](unsafe_from_address=cursor)[]
    var off = c.peek_off()
    return trailing_content(c.p.data.start.unsafe_offset(off), c.p.size - off)


@always_inline
def _key_hash(p: BytePtr, n: Int) -> UInt64:
    """A fast, non-cryptographic hash of the `n` bytes at `p` (in bounds)."""
    var h = UInt64(n) * 0x9E3779B97F4A7C15
    var i = 0
    while i + 8 <= n:
        h = (h ^ p.unsafe_offset(i).unsafe_bitcast[UInt64]()[]) * (
            0xFF51AFD7ED558CCD
        )
        h ^= h >> 29
        i += 8
    var tail: UInt64 = 0
    var shift: UInt64 = 0
    while i < n:
        tail |= UInt64(p[unsafe_offset=i]) << shift
        shift += 8
        i += 1
    h = (h ^ tail) * 0xC4CEB9FE1A85EC53
    return h ^ (h >> 32)


def _names_have_control[T: AnyType]() -> Bool:
    """Whether any name a wire key of `T` can match -- a field's wire name
    or one of its aliases -- holds a byte below 0x20."""
    var names = wire_field_names[T]()
    comptime for i in range(reflect[T].field_count()):
        comptime anns = field_annotations[T, i]
        comptime Ts = type_of(anns).Ts
        comptime for j in range(Ts.length):
            comptime if Ts[j] == Alias:
                comptime al = rebind[Alias](anns[j]).name
                names.append(String(al))
    for name in names:
        for b in name.as_bytes():
            if b < 0x20:
                return True
    return False


@always_inline
def _de[
    T: AnyType
](mut sub: EmberJsonDeserializer) raises DeserializationError -> T:
    """`deserialize[T]` without the dispatcher's call: a type's own
    `deserialize` inlines as far as it is marked to (a scalar's read, an
    empty list's check) into the state that reads it."""
    comptime if conforms_to(T, Deserializable):
        return T.deserialize(sub)
    else:
        return deserialize[T](sub)


comptime _INLINE_INDEX = 1024
"""Index slots a cursor holds inline: an input shorter than this by
`INDEX_SLACK` is indexed without a heap allocation (small documents are
where one costs most, relative to the parse)."""


struct EmberJsonCursor[
    origin: ImmOrigin, options: ParseOptions = ParseOptions()
](Movable):
    """Stage-1 index over the caller's (unpadded) input plus a `Parser`
    that scalar reads reposition onto a token's offset. An
    `EmberJsonDeserializer` reads through a pointer to one.

    `peek()` is the next token's first byte and `advance()` consumes it.
    Past the last token `peek()` is 0, which every consumer rejects before
    advancing, and the entry index then rests on a sentinel slot, so no
    read ever leaves the index or the input. (Holding the next token's
    byte pre-loaded in the cursor was measured slower: the extra stores
    sit on the same dependency chain the preload was meant to hide.)
    """

    var p: Parser[Self.origin, Self.options]
    # The index lives in `small` when `inline`, else in `positions`.
    var small: Array[UInt32, _INLINE_INDEX]
    var positions: List[UInt32]
    var inline: Bool
    # Ascending offsets of every backslash; `bs_i` indexes the first one
    # the (monotonic) string reads have not yet passed, `next_bs` is its
    # offset (`Int.MAX` once none remain).
    var backslashes: List[UInt32]
    var bs_i: Int
    var next_bs: Int
    # Entry index of the next unread token; `n` is the number of real
    # entries, and `positions[n]` is the sentinel slot.
    var i: Int
    var n: Int

    def __init__(
        out self: EmberJsonCursor[Self.origin, Self.options],
        ref[Self.origin] s: String,
    ):
        self = Self(StringSlice(s).as_bytes())

    def __init__(out self, s: StringSlice[Self.origin]):
        self = Self(s.as_bytes())

    def __init__(out self, var b: Span[Byte, Self.origin]):
        """Indexes `b`.

        An empty input is read as a lone space, which holds no token, so
        every read raises the end-of-input error and the sentinel slot has
        a byte to point at. (The constructor does not raise itself: a
        typed-`raises` constructor called from a plain `raises` function
        crashes the Mojo 1.1 compiler.)
        """
        if unlikely(len(b) == 0):
            b = rebind[Span[Byte, Self.origin]](StaticString(" ").as_bytes())
        self.p = Parser[Self.origin, Self.options](b)
        self.small = Array[UInt32, _INLINE_INDEX](uninitialized=True)
        self.positions = List[UInt32]()
        self.backslashes = List[UInt32]()
        self.bs_i = 0
        self.inline = self.p.size + INDEX_SLACK <= _INLINE_INDEX
        if self.inline:
            self.n = structural_index_into[False](
                self.p.data.start,
                self.p.size,
                self.small.unsafe_ptr(),
                self.backslashes,
            )
        else:
            _ = structural_index_with_flags[False](
                self.p.data.start, self.p.size, self.positions, self.backslashes
            )
            self.n = len(self.positions)
        self.next_bs = Int(self.backslashes.unsafe_ptr()[]) if len(
            self.backslashes
        ) else Int.MAX
        # The sentinel slot (the count is at most the input's length, so
        # an inline index has room). Offset 0 is in bounds: the input is
        # not empty.
        if self.inline:
            self.small.unsafe_ptr()[unsafe_offset=self.n] = 0
        else:
            self.positions.append(0)
        self.i = 0

    @always_inline
    def byte(self, off: Int) -> Byte:
        # Every index entry, the sentinel included, is `< size`.
        return self.p.data.start[unsafe_offset=off]

    @always_inline
    def entry_off(self, j: Int) -> Int:
        """Offset of index entry `j` (`j <= n`)."""
        if self.inline:
            return Int(self.small.unsafe_ptr()[unsafe_offset=j])
        return Int(self.positions.unsafe_ptr()[unsafe_offset=j])

    @always_inline
    def peek_off(self) -> Int:
        """Offset of the next unread token (the sentinel's past the end)."""
        return self.entry_off(self.i)

    @always_inline
    def peek(self) -> Byte:
        """First byte of the next unread token, or 0 past the last one."""
        var b = self.byte(self.peek_off())
        return b if self.i < self.n else 0

    @always_inline
    def advance(mut self):
        """Consumes the next token. Callers first check `peek()` against a
        non-zero byte, which fails at the sentinel, so `i` never passes
        `n`."""
        self.i += 1

    @always_inline
    def expect(
        mut self, expected: Byte, close: Byte
    ) raises DeserializationError:
        """Consumes the next token, which must be the grammar token
        `expected` (`:`, `,` or `close`) inside a container that `close`
        ends."""
        if unlikely(self.peek() != expected):
            raise self.token_error(expected, close)
        self.advance()

    @always_inline
    def expect_open(mut self, expected: Byte) raises DeserializationError:
        """`expect` for the `[` or `{` that opens a value, where a different
        complete value is a shape mismatch rather than malformed JSON."""
        if unlikely(self.peek() != expected):
            raise self.value_error(
                StaticString("an array") if expected
                == `[` else StaticString("an object")
            )
        self.advance()

    # The error calls pass the cursor's address as an `Int`, a value every
    # reader already holds: passed as a pointer, LLVM expands the cursor
    # into by-value arguments, and passed as the input's bounds they stay
    # live across the hot loops -- both for calls that almost never run.
    @always_inline
    def token_error(self, expected: Byte, close: Byte) -> DeserializationError:
        return _token_error[Self.origin, Self.options](
            Int(Pointer(to=self)), expected, close
        )

    @always_inline
    def value_error(self, what: StaticString) -> DeserializationError:
        return _value_error[Self.origin, Self.options](
            Int(Pointer(to=self)), what
        )

    @always_inline
    def string_error(self, open: Int) -> DeserializationError:
        return _string_error[Self.origin, Self.options](
            Int(Pointer(to=self)), open
        )

    @always_inline
    def field_key_error(self, first: Bool) -> DeserializationError:
        return _field_key_error[Self.origin, Self.options](
            Int(Pointer(to=self)), first
        )

    @always_inline
    def tuple_error(self, count: Int) -> DeserializationError:
        return _tuple_error[Self.origin, Self.options](
            Int(Pointer(to=self)), count
        )

    @always_inline
    def tuple_element_error(
        self, at: Int, count: Int, var e: DeserializationError
    ) -> DeserializationError:
        return _tuple_element_error[Self.origin, Self.options](
            Int(Pointer(to=self)), at, count, e^
        )

    @always_inline
    def trailing_error(self) -> DeserializationError:
        return _trailing_error[Self.origin, Self.options](Int(Pointer(to=self)))

    @always_inline
    def seek(mut self, off: Int):
        self.p.data.p = self.p.data.start.unsafe_offset(off)

    @always_inline
    def seek_next(mut self):
        """Positions the `Parser` on the next token (not consumed), or at
        the end of the input past the last one, where its reads raise the
        end-of-input error."""
        if likely(self.i < self.n):
            self.seek(self.peek_off())
        else:
            self.p.data.p = self.p.data.end

    @always_inline
    def check_token_end(self) raises DeserializationError:
        """After a number or literal: the index only marks where a scalar
        STARTS, so `12x` is one token -- the byte after it must end it."""
        if self.p.data.dist() <= 0:
            return
        var b = self.p.data.p[unsafe_offset=0]
        if unlikely(not lut[_TOKEN_END_OK](Int(b))):
            raise after_value(b)

    @always_inline
    def take_scalar(mut self):
        """Consumes the next token and leaves the `Parser` on it, or at the
        end of the input past the last token (see `seek_next`)."""
        self.seek_next()
        if likely(self.i < self.n):
            self.advance()

    @always_inline
    def next_scalar_unchecked(self) -> Bool:
        """Whether the token next in the index, if a scalar, can be scanned
        with `unchecked=True`: its run ends before the entry after it, and
        16 readable bytes past that entry cover every wide read. Implies
        `i < n`, so `next_ptr()` is on a real token."""
        return (
            self.i + 1 < self.n
            and self.entry_off(self.i + 1) + 16 <= self.p.size
        )

    @always_inline
    def next_ptr(self) -> CheckedPointer[Self.origin]:
        """A pointer to the next token."""
        return CheckedPointer(
            self.p.data.start.unsafe_offset(self.peek_off()),
            self.p.data.start,
            self.p.data.end,
        )

    @always_inline
    def read_int[DT: DType](mut self) raises DeserializationError -> Scalar[DT]:
        """Reads the integer token next in the index with `Parser.expect_int`'s
        own `try_parse_int`, inline and unchecked away from the end of the
        input. Everything else goes through `expect_int` itself."""
        if likely(self.next_scalar_unchecked()):
            var p = self.next_ptr()
            var v = Scalar[DT]()
            if likely(try_parse_int[DT, unchecked=True, nul_ends=False](p, v)):
                self.advance()
                return v
        return self._read_int_checked[DT]()

    @no_inline
    def _read_int_checked[
        DT: DType
    ](mut self) raises DeserializationError -> Scalar[DT]:
        """`read_int` near the end of the input, on a fraction or exponent,
        or on a token that is not a number: `Parser.expect_int` itself,
        which raises the error for the last two."""
        self.take_scalar()
        var v = self.p.expect_int[DT]()
        self.check_token_end()
        return v

    @always_inline
    def read_float64(mut self) raises DeserializationError -> Float64:
        """Reads the Float64 token next in the index with
        `Parser.expect_float`'s own `try_parse_float64`, inline and
        unchecked away from the end of the input. Everything else goes
        through `expect_float` itself."""
        if likely(self.next_scalar_unchecked()):
            var p = self.next_ptr()
            var v = Float64()
            if likely(try_parse_float64[unchecked=True, nul_ends=False](p, v)):
                self.advance()
                return v
        return self.read_float_checked[DType.float64]()

    @no_inline
    def read_float_checked[
        DT: DType
    ](mut self) raises DeserializationError -> Scalar[DT]:
        """`read_float64` near the end of the input, on an exponent or a
        long mantissa, or on a token that is not a number:
        `Parser.expect_float` itself."""
        self.take_scalar()
        var v = self.p.expect_float[DT]()
        self.check_token_end()
        return v

    def skip_past(mut self, end_off: Int) raises DeserializationError:
        """Drops the index entries of a span a `Parser` just consumed (the
        `Parser` rests at `end_off`), then checks its end as the cursor's
        scalar readers do: the index marks only where a scalar STARTS, so a
        tail glued to one (`12x`) has no entry and nothing else sees it. An
        entry right at `end_off` is a structural the next read validates,
        so the bytes are loaded only when none is there. (A byte after a
        string or container is left to the next read: it is only glued to
        a scalar.)"""
        while self.i < self.n and self.peek_off() < end_off:
            self.advance()
        if self.peek_off() != end_off and self.p.data.dist() > 0:
            var b = self.p.data.p[unsafe_offset=0]
            if unlikely(glued(self.p.data.p[unsafe_offset=-1], b)):
                raise after_value(b)

    @always_inline
    def has_control(self, start: Int, end: Int) -> Bool:
        """Whether `[start, end)` holds a raw control byte (< 0x20), which no
        JSON string may contain. Checked on the strings taken verbatim --
        the `Parser`'s scanner checks the rest -- instead of in stage 1.
        Whole 16-byte loads while they stay inside the input (lanes past
        `end` masked off), bytewise only at the very end of the input."""
        var base = self.p.data.start
        var i = start
        while i < end and i + SIMD8_WIDTH <= self.p.size:
            var ctrl = pack_into_integer(
                base.unsafe_offset(i).unsafe_load[width=SIMD8_WIDTH]().lt(0x20)
            )
            var valid = end - i
            if valid < SIMD8_WIDTH:
                ctrl &= (Bits_T(1) << Bits_T(valid)) - 1
            if ctrl != 0:
                return True
            i += SIMD8_WIDTH
        while i < end:
            if base[unsafe_offset=i] < 0x20:
                return True
            i += 1
        return False

    @always_inline
    def plain(mut self, start: Int, end: Int) -> Bool:
        """True when the string content `[start, end)` holds no backslash,
        so it decodes to its own bytes. Strings are read in document order,
        so every backslash below `next_bs` lies before this string: one
        compare settles the common case."""
        if likely(self.next_bs >= end):
            return True
        while self.next_bs < start:
            self.bs_i += 1
            self.next_bs = (
                Int(
                    self.backslashes.unsafe_ptr()[unsafe_offset=self.bs_i]
                ) if self.bs_i
                < len(self.backslashes) else Int.MAX
            )
        return self.next_bs >= end

    @always_inline
    def take_string_span(
        mut self,
    ) raises DeserializationError -> Tuple[Int, Int]:
        """Consumes a string token, returning its opening and closing quote
        offsets (the closing quote is the next index entry)."""
        if unlikely(self.peek() != `"`):
            raise self.value_error("a string")
        var open = self.peek_off()
        self.advance()
        # Stage 1 emits no entry inside a string, so the entry after an
        # opening quote is its closing quote -- unless the string never
        # closes, in which case no entry follows at all.
        if unlikely(self.i >= self.n):
            raise self.string_error(open)
        var close = self.peek_off()
        self.advance()
        return (open, close)

    @always_inline
    def decode_string(
        mut self, open: Int, close: Int
    ) raises DeserializationError -> String:
        if self.plain(open + 1, close):
            if unlikely(self.has_control(open + 1, close)):
                raise self.string_error(open)
            return copy_to_string[Self.options.ignore_unicode](
                self.p.data.start.unsafe_offset(open + 1),
                self.p.data.start.unsafe_offset(close),
                False,
            )
        # Escapes possible: the `Parser`'s scanner validates and decodes.
        self.seek(open)
        var s = self.p.read_string()
        if unlikely(ptr_dist(self.p.data.start, self.p.data.p) != close + 1):
            raise malformed_string()
        return s^

    @always_inline
    def check_string(
        mut self, open: Int, close: Int
    ) raises DeserializationError:
        """Validates the string spanning `(open, close)` as `decode_string`
        reads it, without materializing it."""
        if self.plain(open + 1, close):
            if unlikely(self.has_control(open + 1, close)):
                raise self.string_error(open)
            return
        self.seek(open)
        _ = self.p.expect_string_bytes()
        if unlikely(ptr_dist(self.p.data.start, self.p.data.p) != close + 1):
            raise malformed_string()

    def skip_container(
        mut self,
    ) raises DeserializationError -> Span[Byte, Self.origin]:
        """Consumes the array or object opening at the next token and
        returns its bytes, found by counting brackets along the index as
        simdjson On Demand's `skip_child` does. Nothing inside is validated
        -- not even that the brackets match -- beyond `options.max_depth`:
        `Lazy.get()` validates the span when it reads it."""
        var start = self.peek_off()
        var depth = 0
        while self.i < self.n:
            # `[` and `]` are `{` and `}` with bit 5 clear, and no other
            # byte maps onto either.
            var b = self.byte(self.peek_off()) | 0x20
            self.advance()
            depth += Int(b == `{`) - Int(b == `}`)
            if depth == 0:
                return Span(
                    unsafe_ptr=self.p.data.start.unsafe_offset(start),
                    length=self.entry_off(self.i - 1) + 1 - start,
                )
            if unlikely(self.p.depth + depth > Self.options.max_depth):
                raise too_deep()
        raise unexpected_eof()

    def skip_value(mut self) raises DeserializationError:
        """Consumes one value, validated as the readers validate what they
        read -- grammar, strings, number and literal syntax, depth -- but
        token to token along the index, never over the bytes between.

        Iterative, with one bit per open level (set for an object), held
        to `options.max_depth` counted from the `Parser`'s `depth`."""
        comptime WORDS = max(1, (Self.options.max_depth + 63) // 64)
        var objects = StackArray[UInt64, WORDS](fill=0)
        var open = 0
        while True:
            # --- one value ---
            var b = self.peek()
            if b == `"`:
                var span = self.take_string_span()
                self.check_string(span[0], span[1])
            elif b == `{` or b == `[`:
                if unlikely(self.p.depth + open >= Self.options.max_depth):
                    raise too_deep()
                self.advance()
                var first = True
                if b == `{`:
                    var key = self.next_field_key(first)
                    if key[0] >= 0:
                        self.check_string(key[0], key[1])
                        objects.unsafe_get(open >> 6) |= UInt64(1) << UInt64(
                            open & 63
                        )
                        open += 1
                        continue
                elif self.list_next(first, `]`):
                    objects.unsafe_get(open >> 6) &= ~(
                        UInt64(1) << UInt64(open & 63)
                    )
                    open += 1
                    continue
                # Empty: `list_next`/`next_field_key` left the close.
                self.advance()
            elif b == `-` or isdigit(b) or b == `+`:
                self.take_scalar()
                self.p._validate_number()
                self.check_token_end()
            elif b == `t` or b == `f` or b == `n`:
                self.take_scalar()
                self.p._expect_literal()
                self.check_token_end()
            elif self.i >= self.n:
                raise unexpected_eof()
            else:
                raise invalid_value(b)

            # --- a value completed: close every container it finished ---
            while True:
                if open == 0:
                    return
                var top = open - 1
                var first = False
                if (objects.unsafe_get(top >> 6) >> UInt64(top & 63)) & 1:
                    var key = self.next_field_key(first)
                    if key[0] >= 0:
                        self.check_string(key[0], key[1])
                        break
                elif self.list_next(first, `]`):
                    break
                self.advance()
                open -= 1

    @always_inline
    def read_string(mut self) raises DeserializationError -> String:
        """Reads the string token next in the index."""
        var span = self.take_string_span()
        return self.decode_string(span[0], span[1])

    @always_inline
    def next_field_key(
        mut self, mut first: Bool
    ) raises DeserializationError -> Tuple[Int, Int]:
        """An object's `has_next` and `"key":` in one step.

        Returns the key's opening and closing quote offsets, or `(-1, -1)`
        at the closing brace (left unconsumed). The separator, key and
        colon are consecutive index entries, so they are read with one
        bounds check and one cursor update; the closing quote needs no
        test (the entry after an opening quote is always its closing
        quote, see `take_string_span`).
        """
        var b = self.peek()
        if b == `}`:
            return (-1, -1)
        var i = self.i
        var skip = 0
        var was_first = first
        if not first:
            if unlikely(b != `,`):
                raise self.field_key_error(was_first)
            skip = 1
            comptime if (
                StrictOptions.ALLOW_TRAILING_COMMA in Self.options.strict_mode
            ):
                if i + 1 < self.n and self.byte(self.entry_off(i + 1)) == `}`:
                    self.i = i + 1
                    return (-1, -1)
        first = False
        if unlikely(i + skip + 3 > self.n):
            raise self.field_key_error(was_first)
        var open = self.entry_off(i + skip)
        var close = self.entry_off(i + skip + 1)
        if unlikely(
            self.byte(open) != `"`
            or self.byte(self.entry_off(i + skip + 2)) != `:`
        ):
            raise self.field_key_error(was_first)
        self.i = i + skip + 3
        return (open, close)

    @always_inline
    def resolve_key[
        T: AnyType
    ](mut self, open: Int, close: Int) raises DeserializationError -> Int:
        """Resolves the key spanning `(open, close)` against `T`'s fields.

        A key that matched a field equals one of `T`'s names, so it can only
        hold a raw control byte if a name does; any other key is checked.
        """
        if self.plain(open + 1, close):
            var idx = field_index[T](
                StringSlice(
                    unsafe_from_utf8=Span(
                        unsafe_ptr=self.p.data.start.unsafe_offset(open + 1),
                        length=close - open - 1,
                    )
                )
            )
            comptime if _names_have_control[T]():
                if unlikely(self.has_control(open + 1, close)):
                    raise self.string_error(open)
            else:
                if unlikely(idx < 0 and self.has_control(open + 1, close)):
                    raise self.string_error(open)
            return idx
        return field_index[T](self.decode_string(open, close))

    @always_inline
    def list_next(
        mut self, mut first: Bool, close: Byte
    ) raises DeserializationError -> Bool:
        """`has_next` for arrays and objects: separator and trailing-comma
        rules are the `Parser`'s."""
        var b = self.peek()
        if b == close:
            return False
        if not first:
            if unlikely(b != `,`):
                raise self.token_error(`,`, close)
            self.advance()
            b = self.peek()
            if b == close:
                comptime if (
                    StrictOptions.ALLOW_TRAILING_COMMA
                    in Self.options.strict_mode
                ):
                    return False
                else:
                    raise trailing_comma()
        first = False
        return True

    def _entry_after_value(self, j: Int) -> Int:
        """The index entry after the (well-formed) value whose first entry
        is `j`. A string is two entries, its quotes; a container runs to
        its matching close, and the quotes inside it come in pairs."""
        var b = self.byte(self.entry_off(j))
        if b == `"`:
            return j + 2
        if b != `{` and b != `[`:
            return j + 1
        var depth = 0
        var k = j
        while True:
            var c = self.byte(self.entry_off(k))
            if c == `"`:
                k += 2
                continue
            if c == `{` or c == `[`:
                depth += 1
            elif c == `}` or c == `]`:
                depth -= 1
                if depth == 0:
                    return k + 1
            k += 1

    @no_inline
    def check_duplicate_key(
        mut self, members: Int, name: String
    ) raises DeserializationError:
        """Raises `DuplicateField` when an earlier key of the object whose
        members start at index entry `members` decodes to `name`, the key
        just read (its two entries end at `i`). Called only when `name`'s
        hash repeats, which a collision can also cause."""
        var j = members
        while j < self.i - 2:
            self.seek(self.entry_off(j))
            if self.p.read_string() == name:
                raise duplicate_key(name)
            # Past the key, its `:`, the value and the `,` after it.
            j = self._entry_after_value(j + 3) + 1


comptime _Cursor[
    origin: ImmOrigin, options: ParseOptions, ptr_origin: MutOrigin
] = Pointer[EmberJsonCursor[origin, options], ptr_origin]


@fieldwise_init
struct EmberJsonSeqDe[
    origin: ImmOrigin, options: ParseOptions, ptr_origin: MutOrigin
](SeqDerState):
    var c: _Cursor[Self.origin, Self.options, Self.ptr_origin]
    var first: Bool

    @always_inline
    def has_next(mut self) raises DeserializationError -> Bool:
        return self.c[].list_next(self.first, `]`)

    def expect_element[T: AnyType](mut self) raises DeserializationError -> T:
        var sub = EmberJsonDeserializer(c=self.c)
        return _de[T](sub)

    @always_inline
    def end(mut self) raises DeserializationError:
        self.c[].expect(`]`, `]`)
        self.c[].p.depth -= 1


@fieldwise_init
struct EmberJsonMapDe[
    origin: ImmOrigin, options: ParseOptions, ptr_origin: MutOrigin
](MapDerState):
    var c: _Cursor[Self.origin, Self.options, Self.ptr_origin]
    var first: Bool
    # Strict mode only: hashes of the decoded keys seen so far (`"a"` and
    # `"\u0061"` are duplicates). A repeated hash re-reads the earlier keys
    # from the input to tell a duplicate from a collision, so each key
    # costs one hash instead of a copied, hashed and inserted `String`.
    var seen: Set[UInt64]
    # Index entry of the first member, for that re-read.
    var members: Int

    def has_next(mut self) raises DeserializationError -> Bool:
        return self.c[].list_next(self.first, `}`)

    def expect_key[T: AnyType](mut self) raises DeserializationError -> T:
        # A key is a string whatever `T` reads it as, so anything else is
        # malformed JSON, not a mismatch.
        if unlikely(self.c[].peek() != `"`):
            raise self.c[].field_key_error(True)
        var sub = EmberJsonDeserializer(c=self.c)
        comptime if T == String and not (
            StrictOptions.ALLOW_DUPLICATE_KEYS in Self.options.strict_mode
        ):
            comptime assert conforms_to(T, Base), "unreachable: T == String"
            var key = _de[T](sub)
            ref name = rebind[String](key)
            var h = _key_hash(name.as_bytes().unsafe_ptr(), name.byte_length())
            if unlikely(h in self.seen):
                self.c[].check_duplicate_key(self.members, name)
            self.seen.add(h)
            return key^
        else:
            return _de[T](sub)

    def expect_value[T: AnyType](mut self) raises DeserializationError -> T:
        self.c[].expect(`:`, `}`)
        var sub = EmberJsonDeserializer(c=self.c)
        return _de[T](sub)

    @always_inline
    def end(mut self) raises DeserializationError:
        self.c[].expect(`}`, `}`)
        self.c[].p.depth -= 1


@fieldwise_init
struct EmberJsonStructDe[
    origin: ImmOrigin, options: ParseOptions, ptr_origin: MutOrigin
](StructDerState):
    var c: _Cursor[Self.origin, Self.options, Self.ptr_origin]
    var first: Bool

    def expect_field_index[
        T: AnyType
    ](mut self) raises DeserializationError -> Optional[Int]:
        var span = self.c[].next_field_key(self.first)
        if span[0] < 0:
            return None
        return self.c[].resolve_key[T](span[0], span[1])

    @always_inline
    def expect_field_value[
        T: AnyType
    ](mut self) raises DeserializationError -> T:
        var sub = EmberJsonDeserializer(c=self.c)
        return _de[T](sub)

    def skip_value(mut self) raises DeserializationError:
        self.c[].skip_value()

    @always_inline
    def end(mut self) raises DeserializationError:
        self.c[].expect(`}`, `}`)
        self.c[].p.depth -= 1


@fieldwise_init
struct EmberJsonTupleDe[
    origin: ImmOrigin, options: ParseOptions, ptr_origin: MutOrigin
](TupleDerState):
    var c: _Cursor[Self.origin, Self.options, Self.ptr_origin]
    var first: Bool
    # The tuple's arity.
    var count: Int

    # The array ending early or running on is well-formed JSON of the wrong
    # length. An element is read without testing for the `]` first (tuples
    # of scalars are hot: canada's coordinates): a `]` fails the read, and
    # the handler tells that from a malformed element.

    @always_inline
    def expect_element[T: AnyType](mut self) raises DeserializationError -> T:
        if not self.first:
            if unlikely(self.c[].peek() != `,`):
                raise self.c[].tuple_error(self.count)
            self.c[].advance()
        self.first = False
        var at = self.c[].i
        var sub = EmberJsonDeserializer(c=self.c)
        try:
            return _de[T](sub)
        except e:
            raise self.c[].tuple_element_error(at, self.count, e^)

    @always_inline
    def end(mut self) raises DeserializationError:
        if unlikely(self.c[].list_next(self.first, `]`)):
            raise expected_length(self.count)
        self.c[].advance()
        self.c[].p.depth -= 1


@fieldwise_init
struct EmberJsonEnumDe[
    origin: ImmOrigin, options: ParseOptions, ptr_origin: MutOrigin
](EnumDerState):
    var c: _Cursor[Self.origin, Self.options, Self.ptr_origin]
    var idx: Int

    def variant_index(mut self) raises DeserializationError -> Int:
        return self.idx

    def expect_payload[T: AnyType](mut self) raises DeserializationError -> T:
        var sub = EmberJsonDeserializer(c=self.c)
        return _de[T](sub)

    @always_inline
    def end(mut self) raises DeserializationError:
        # After the payload, as after an object member: a second member
        # is well-formed, but no enum.
        var first = False
        if unlikely(self.c[].list_next(first, `}`)):
            raise expected_single_key()
        self.c[].advance()
        self.c[].p.depth -= 1


@fieldwise_init
struct EmberJsonDeserializer[
    origin: ImmOrigin, options: ParseOptions, ptr_origin: MutOrigin
](BorrowingDeserializer, SelfDescribingDeserializer):
    var c: _Cursor[Self.origin, Self.options, Self.ptr_origin]

    comptime SeqType = EmberJsonSeqDe[
        Self.origin, Self.options, Self.ptr_origin
    ]
    comptime MapType = EmberJsonMapDe[
        Self.origin, Self.options, Self.ptr_origin
    ]
    comptime StructType = EmberJsonStructDe[
        Self.origin, Self.options, Self.ptr_origin
    ]
    comptime TupleType = EmberJsonTupleDe[
        Self.origin, Self.options, Self.ptr_origin
    ]
    comptime EnumType = EmberJsonEnumDe[
        Self.origin, Self.options, Self.ptr_origin
    ]
    comptime Value = Value

    def expect_bool(mut self) raises DeserializationError -> Bool:
        self.c[].take_scalar()
        var b = self.c[].p.expect_bool()
        self.c[].check_token_end()
        return b

    @always_inline
    def expect_number[
        DT: DType
    ](mut self) raises DeserializationError -> Scalar[DT]:
        # Float64 and integer reads inline into the reader of the field or
        # element (a call per scalar costs more than the code); narrower
        # floats, rare in practice, stay one out-of-line copy.
        comptime if DT == DType.float64:
            return rebind[Scalar[DT]](self.c[].read_float64())
        elif DT.is_integral():
            return self.c[].read_int[DT]()
        else:
            return self._expect_narrow_float[DT]()

    def _expect_narrow_float[
        DT: DType
    ](mut self) raises DeserializationError -> Scalar[DT]:
        ref c = self.c[]
        var b = c.peek()
        if unlikely(
            not ((isdigit(b) or b == `-`) and c.next_scalar_unchecked())
        ):
            return c.read_float_checked[DT]()
        c.take_scalar()
        var v = c.p.expect_float[DT, unchecked=True]()
        c.check_token_end()
        return v

    def expect_string(mut self) raises DeserializationError -> String:
        return self.c[].read_string()

    def expect_optional[
        T: Base
    ](mut self) raises DeserializationError -> Optional[T]:
        if self.c[].peek() == `n`:
            self.c[].take_scalar()
            self.c[].p.expect_null()
            self.c[].check_token_end()
            return Optional[T]()
        return Optional[T](_de[T](self))

    @always_inline
    def begin_seq(mut self) raises DeserializationError -> Self.SeqType:
        self.c[].expect_open(`[`)
        self.c[].p.enter_container()
        return {c = self.c, first = True}

    def begin_map(mut self) raises DeserializationError -> Self.MapType:
        self.c[].expect_open(`{`)
        self.c[].p.enter_container()
        return {
            c = self.c,
            first = True,
            seen = Set[UInt64](),
            members = self.c[].i,
        }

    def begin_struct[
        T: AnyType
    ](mut self) raises DeserializationError -> Self.StructType:
        self.c[].expect_open(`{`)
        self.c[].p.enter_container()
        return {c = self.c, first = True}

    def begin_tuple[
        field_count: Int
    ](mut self) raises DeserializationError -> Self.TupleType:
        self.c[].expect_open(`[`)
        self.c[].p.enter_container()
        return {c = self.c, first = True, count = field_count}

    def begin_enum[
        T: AnyType, arm_names: List[String]
    ](mut self) raises DeserializationError -> Self.EnumType:
        self.c[].expect_open(`{`)
        self.c[].p.enter_container()
        # A tag that is no object key is malformed JSON, as `Value` reports
        # it; an empty object is well-formed but holds no tag.
        ref c = self.c[]
        if c.peek() != `"`:
            if c.i >= c.n:
                raise unexpected_eof()
            if c.peek() == `}`:
                raise expected_enum_tag(c.peek())
            raise expected_key(c.peek())
        var name = c.read_string()
        c.expect(`:`, `}`)
        var idx = -1
        comptime for i in range(len(arm_names)):
            comptime an = get_static_string[arm_names[i]]()
            if idx == -1 and name == an:
                idx = i
        return {c = self.c, idx = idx}

    def raw_bytes[
        kind: RawKind
    ](mut self) raises DeserializationError -> Span[Byte, ImmUntrackedOrigin]:
        # A container is captured by its brackets alone (`skip_container`);
        # a scalar, one token, by the `Parser`'s extractors, which validate
        # it, and its index entry is then dropped.
        ref c = self.c[]
        comptime if (
            kind == RawKind.Any or kind == RawKind.Map or kind == RawKind.Seq
        ):
            var b = c.peek()
            comptime if kind == RawKind.Map:
                if unlikely(b != `{`):
                    raise c.value_error("an object")
            elif kind == RawKind.Seq:
                if unlikely(b != `[`):
                    raise c.value_error("an array")
            if b == `{` or b == `[`:
                return rebind[Span[Byte, ImmUntrackedOrigin]](
                    c.skip_container()
                )
        c.seek_next()
        var span: Span[Byte, ImmUntrackedOrigin]
        comptime if kind == RawKind.Integer:
            span = rebind[Span[Byte, ImmUntrackedOrigin]](
                c.p.expect_int_bytes()
            )
        elif kind == RawKind.Float:
            span = rebind[Span[Byte, ImmUntrackedOrigin]](
                c.p.expect_float_bytes()
            )
        elif kind == RawKind.Str:
            # Anything but a quote where a string was requested is a kind
            # mismatch.
            if c.p.peek() != `"`:
                raise c.p.shape_error("a string")
            span = rebind[Span[Byte, ImmUntrackedOrigin]](
                c.p.expect_string_bytes()
            )
        else:
            # `Any` on a scalar (every `Map`/`Seq` returned above).
            span = rebind[Span[Byte, ImmUntrackedOrigin]](
                c.p.expect_value_bytes()
            )
        c.skip_past(ptr_dist(c.p.data.start, c.p.data.p))
        return span

    def deserialize_any(mut self) raises DeserializationError -> Value:
        ref c = self.c[]
        c.seek_next()
        var v = c.p.parse_value()
        c.skip_past(ptr_dist(c.p.data.start, c.p.data.p))
        return v^


def from_json[
    o: ImmOrigin,
    //,
    T: Movable & Deinitable,
    options: ParseOptions = ParseOptions(),
](s: StringSlice[o], out result: T) raises DeserializationError:
    """Deserializes `s` into `T` through emberserde's framework, driven by
    `EmberJsonDeserializer`.

    Parameters:
        T: The type to deserialize into.
        options: The parsing options handed to the underlying `Parser`.
            This is reflection's `ParseOptions` channel -- the deserializer
            is already parameterized on them, so `ignore_unicode`,
            `strict_mode` and friends reach the parser from here.

    Args:
        s: The input JSON text.

    Returns:
        The deserialized value.

    Raises:
        `DeserializationError` if `s` is not valid JSON, does not match
        the shape of `T`, or carries non-whitespace content after the
        root value.
    """
    # `validate_utf8` is the caller's to apply: `emberjson.from_json` does,
    # this private entry point does not.
    result = from_json_bytes[T, options](s.as_bytes())


def from_json_bytes[
    o: ImmOrigin,
    //,
    T: Movable & Deinitable,
    options: ParseOptions = ParseOptions(),
](b: Span[Byte, o], out result: T) raises DeserializationError:
    """`from_json` over bytes, such as a span `Lazy` captured."""
    var c = EmberJsonCursor[o, options](b)
    var d = EmberJsonDeserializer(c=Pointer(to=c))
    result = deserialize[T](d)
    # Every structural consumed: nothing but whitespace after the root.
    if unlikely(c.i != c.n):
        raise c.trailing_error()
