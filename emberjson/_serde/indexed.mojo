"""Index-driven reflection deserializer: simdjson On Demand's shape.

`EmberJsonDeserializer` (deserializer.mojo) walks the input byte by byte,
skipping whitespace around every token. This format runs the SIMD stage-1
indexer first and then hops token to token through the structural index,
the way simdjson's On Demand API feeds its C++26 reflection deserializer:
whitespace is never touched, the next token is one index load away, and a
string's closing quote is the next index entry, so its span is known before
it is read.

It is an OPTIMISTIC fast path. Every failure -- malformed JSON, a shape
mismatch, a missing field, an input feature it does not handle inline --
raises, and `from_json` then re-runs the byte-walk deserializer, which
produces the error the caller sees. So this path never has to reproduce
error kinds, messages or paths; its one obligation is to never ACCEPT an
input the byte-walk rejects, and to build the identical value when both
accept. Scalars are parsed by the same `Parser` primitives the byte-walk
uses, repositioned at the token's offset, so number and string semantics
are shared rather than re-implemented. Nesting depth is counted on that
`Parser` too, container for container as the byte-walk counts it, so this
path never recurses past `options.max_depth` either.
"""

from std.sys.intrinsics import unlikely, likely
from std.collections import Set

from emberjson._deserialize import Parser, ParseOptions, StrictOptions
from emberjson._deserialize._parser_helper import (
    copy_to_string,
    ptr_dist,
    unsafe_is_made_of_eight_digits_fast,
    unsafe_parse_eight_digits,
    unsafe_is_made_of_four_digits_fast,
    unsafe_parse_four_digits,
    isdigit,
    pack_into_integer,
    Bits_T,
)
from std.sys.info import bit_width_of
from emberjson._deserialize.tape_indexed import _TOKEN_END_OK
from emberjson._index import structural_index_with_flags
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
    `0`,
    `.`,
)
from emberjson.utils import BytePtr, lut
from emberjson.value import Value
from .deserializer import from_json_bytewalk

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
    deserialize_struct,
)
from emberserde.error import DeserializationError, DerErrorKind
from emberserde.field_meta import (
    field_index,
    wire_field_names,
    FieldMeta,
    static_wire_name,
    _eq_static,
)
from std.reflection import reflect
from std.builtin.rebind import downcast
from emberjson.simd import SIMD8_WIDTH
from emberserde.utils import Base
from std.collections.string.string_span import get_static_string


trait RawCapture:
    """A type whose deserialization is one `raw_bytes` capture (`Lazy`).
    As the root it would have the whole input indexed only to skip it,
    so `from_json` hands it straight to the byte walk."""

    pass


@no_inline
def _declined() -> DeserializationError:
    # Never surfaces: the byte-walk re-run raises the real error.
    return DeserializationError(
        "indexed deserializer declined", DerErrorKind.InvalidValue
    )


@always_inline
def _raw_key_hash(p: BytePtr, n: Int) -> UInt64:
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
    comptime r = reflect[T]
    comptime for i in range(r.field_count()):
        comptime FT = r.field_types()[i]
        comptime if conforms_to(FT, FieldMeta):
            comptime FM = downcast[FT, FieldMeta]
            comptime if FM.serde_extra:
                comptime extra = FM.serde_extra.value()
                comptime for j in range(len(extra)):
                    names.append(String(get_static_string[extra[j]]()))
    for name in names:
        for b in name.as_bytes():
            if b < 0x20:
                return True
    return False


@always_inline
def _de[
    T: AnyType
](mut sub: IndexedDeserializer) raises DeserializationError -> T:
    """`deserialize[T]` without the dispatcher's call: a type's own
    `deserialize` inlines as far as it is marked to (a scalar's read, an
    empty list's check) into the state that reads it."""
    comptime if conforms_to(T, Deserializable):
        return T.deserialize(sub)
    else:
        return deserialize[T](sub)


def _ordered_ok[T: AnyType]() -> Bool:
    """Whether `IndexedDeserializer.expect_struct` may read `T` in
    declaration order: no field is skipped or aliased and no name holds a
    control byte, so a plain key equal to field `i`'s wire name is exactly
    a key `field_index` resolves to `i` and `resolve_key` lets through."""
    comptime r = reflect[T]
    comptime for i in range(r.field_count()):
        comptime FT = r.field_types()[i]
        comptime if conforms_to(FT, FieldMeta):
            comptime FM = downcast[FT, FieldMeta]
            comptime if FM.serde_skip or FM.serde_extra:
                return False
    return not _names_have_control[T]()


struct _IndexCursor[origin: ImmOrigin, options: ParseOptions](Movable):
    """Stage-1 index over the caller's (unpadded) input plus a `Parser`
    that scalar reads reposition onto a token's offset.

    `peek()` is the next token's first byte and `advance()` consumes it.
    Past the last token `peek()` is 0, which every consumer rejects before
    advancing, and the entry index then rests on a sentinel slot, so no
    read ever leaves the index or the input. (Holding the next token's
    byte pre-loaded in the cursor was measured slower: the extra stores
    sit on the same dependency chain the preload was meant to hide.)
    """

    var p: Parser[Self.origin, Self.options]
    var positions: List[UInt32]
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

    def __init__(out self, s: StringSlice[Self.origin]):
        self.p = Parser[Self.origin, Self.options](s)
        self.positions = List[UInt32]()
        self.backslashes = List[UInt32]()
        self.bs_i = 0
        _ = structural_index_with_flags[False](
            self.p.data.start, self.p.size, self.positions, self.backslashes
        )
        self.n = len(self.positions)
        self.next_bs = Int(self.backslashes.unsafe_ptr()[]) if len(
            self.backslashes
        ) else Int.MAX
        # The sentinel slot. Offset 0 is in bounds for any non-empty input
        # (`from_json_indexed` never builds a cursor over an empty one).
        self.positions.append(0)
        self.i = 0

    @always_inline
    def byte(self, off: Int) -> Byte:
        # Every index entry, the sentinel included, is `< size`.
        return self.p.data.start[unsafe_offset=off]

    @always_inline
    def peek_off(self) -> Int:
        """Offset of the next unread token (the sentinel's past the end)."""
        return Int(self.positions.unsafe_ptr()[unsafe_offset=self.i])

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
    def expect(mut self, expected: Byte) raises DeserializationError:
        """Consumes the next token, which must start with `expected`."""
        if unlikely(self.peek() != expected):
            raise _declined()
        self.advance()

    @always_inline
    def seek(mut self, off: Int):
        self.p.data.p = self.p.data.start.unsafe_offset(off)

    @always_inline
    def seek_lookahead(mut self) raises DeserializationError:
        """Positions the `Parser` on the next token (not consumed)."""
        if unlikely(self.i >= self.n):
            raise _declined()
        self.seek(self.peek_off())

    @always_inline
    def check_token_end(self) raises DeserializationError:
        """After a number or literal: the index only marks where a scalar
        STARTS, so `12x` is one token -- the byte after it must end it."""
        if self.p.data.dist() <= 0:
            return
        if unlikely(
            not lut[_TOKEN_END_OK](Int(self.p.data.p[unsafe_offset=0]))
        ):
            raise _declined()

    @always_inline
    def take_scalar(mut self) raises DeserializationError -> Int:
        """Consumes the next token, returning its offset; the `Parser` is
        left positioned on it."""
        self.seek_lookahead()
        var off = self.peek_off()
        self.advance()
        return off

    @always_inline
    def read_int[DT: DType](mut self) raises DeserializationError -> Scalar[DT]:
        """Reads the integer token next in the index.

        Accepts exactly what `Parser.expect_int` accepts: an optional `-`,
        no leading zeros, no fraction or exponent, in range for `DT`.
        Anything it cannot settle inline (20+ digits, a token near the end
        of the input) goes through `expect_int` itself.
        """
        var b = self.peek()
        if unlikely(not (isdigit(b) or b == `-`)):
            raise _declined()
        var off = self.peek_off()
        self.advance()
        comptime if bit_width_of[DT]() > 64:
            self.seek(off)
            var v = self.p.expect_int[DT]()
            self.check_token_end()
            return v
        else:
            # The inline path reads at most 22 bytes past `off` (sign, 20
            # digits, terminator); away from the end of input no read
            # needs a bounds check.
            if unlikely(off + 24 > self.p.size):
                self.seek(off)
                var v = self.p.expect_int[DT]()
                self.check_token_end()
                return v
            var neg = b == `-`
            var digits = self.p.data.start.unsafe_offset(off + Int(neg))
            var q = digits
            var u: UInt64 = 0
            if unsafe_is_made_of_eight_digits_fast(q):
                u = unsafe_parse_eight_digits(q)
                q = q.unsafe_offset(8)
            while isdigit(q[]) and ptr_dist(digits, q) < 20:
                u = u * 10 + UInt64(q[] - `0`)
                q = q.unsafe_offset(1)
            var nd = ptr_dist(digits, q)
            # 19 digits cannot overflow a UInt64 (10^19 - 1 < 2^64).
            if unlikely(
                nd == 0
                or nd > 19
                or (digits[] == `0` and nd > 1)
                or not lut[_TOKEN_END_OK](Int(q[]))
            ):
                raise _declined()
            comptime if DT.is_signed():
                comptime MIN_ABS = UInt64(1) << UInt64(bit_width_of[DT]() - 1)
                comptime MAX_ABS = Scalar[DT].MAX.cast[DType.uint64]()
                if neg:
                    if unlikely(u > MIN_ABS):
                        raise _declined()
                    return (~u + 1).cast[DT]()
                if unlikely(u > MAX_ABS):
                    raise _declined()
                return u.cast[DT]()
            else:
                if unlikely(neg or u > Scalar[DT].MAX.cast[DType.uint64]()):
                    raise _declined()
                return u.cast[DT]()

    @always_inline
    def read_float64(mut self) raises DeserializationError -> Float64:
        """Reads the Float64 token next in the index.

        The common shape -- `-?digits(.digits)?`, at most 19 digits, no
        exponent -- is scanned here with raw reads and handed to the same
        `compute_float64` `Parser.expect_float` uses, so the value is
        bit-identical. Everything else (exponents, long mantissas, a token
        near the end of the input) goes through `expect_float` itself.
        """
        var b = self.peek()
        if unlikely(not (isdigit(b) or b == `-`)):
            raise _declined()
        var off = self.peek_off()
        self.advance()
        if unlikely(
            not (self.i < self.n and self.peek_off() + 8 <= self.p.size)
        ):
            self.seek(off)
            var v = self.p.expect_float[DType.float64]()
            self.check_token_end()
            return v
        var start = self.p.data.start.unsafe_offset(off)
        var neg = b == `-`
        var digits = start.unsafe_offset(Int(neg))
        var q = digits
        var i: UInt64 = 0
        while isdigit(q[]):
            i = i * 10 + UInt64(q[] - `0`)
            q = q.unsafe_offset(1)
        var int_digits = ptr_dist(digits, q)
        var exponent: Int64 = 0
        if q[] == `.`:
            q = q.unsafe_offset(1)
            var first = q
            if unsafe_is_made_of_eight_digits_fast(q):
                i = i * 100_000_000 + unsafe_parse_eight_digits(q)
                q = q.unsafe_offset(8)
                if unsafe_is_made_of_eight_digits_fast(q):
                    i = i * 100_000_000 + unsafe_parse_eight_digits(q)
                    q = q.unsafe_offset(8)
            if unsafe_is_made_of_four_digits_fast(q):
                i = i * 10_000 + unsafe_parse_four_digits(q)
                q = q.unsafe_offset(4)
            while isdigit(q[]):
                i = i * 10 + UInt64(q[] - `0`)
                q = q.unsafe_offset(1)
            exponent = Int64(ptr_dist(q, first))
            if unlikely(exponent == 0):
                raise _declined()
        var digit_count = ptr_dist(digits, q)
        if unlikely(
            int_digits == 0
            or (digits[] == `0` and int_digits > 1)
            or digit_count > 19
            or not lut[_TOKEN_END_OK](Int(q[]))
        ):
            self.seek(off)
            var v = self.p.expect_float[DType.float64]()
            self.check_token_end()
            return v
        return self.p.compute_float64(exponent, i, neg)

    def skip_past(mut self, end_off: Int) raises DeserializationError:
        """Drops the index entries of a span a `Parser` just consumed (the
        `Parser` rests at `end_off`), then checks its end as the cursor's
        scalar readers do: the index marks only where a scalar STARTS, so a
        tail glued to one (`12x`) has no entry and nothing else sees it. An
        entry right at `end_off` is a structural the next read validates,
        so the byte is loaded only when none is there."""
        while self.i < self.n and self.peek_off() < end_off:
            self.advance()
        if self.peek_off() != end_off:
            self.check_token_end()

    @always_inline
    def has_control(self, start: Int, end: Int) -> Bool:
        """Whether `[start, end)` holds a raw control byte (< 0x20), which no
        JSON string may contain. Checked on the strings taken verbatim --
        the byte-walk scanner checks the rest -- instead of in stage 1.
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
            raise _declined()
        var open = self.peek_off()
        self.advance()
        # Stage 1 emits no entry inside a string, so the entry after an
        # opening quote is its closing quote -- unless the string never
        # closes, in which case no entry follows at all.
        if unlikely(self.i >= self.n):
            raise _declined()
        var close = self.peek_off()
        self.advance()
        return (open, close)

    @always_inline
    def decode_string(
        mut self, open: Int, close: Int
    ) raises DeserializationError -> String:
        if self.plain(open + 1, close):
            if unlikely(self.has_control(open + 1, close)):
                raise _declined()
            return copy_to_string[Self.options.ignore_unicode](
                self.p.data.start.unsafe_offset(open + 1),
                self.p.data.start.unsafe_offset(close),
                False,
            )
        # Escapes possible: the byte-walk scanner validates and decodes.
        self.seek(open)
        var s = self.p.read_string()
        if unlikely(ptr_dist(self.p.data.start, self.p.data.p) != close + 1):
            raise _declined()
        return s^

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
        var e = self.positions.unsafe_ptr().unsafe_offset(i)
        var skip = 0
        if not first:
            if unlikely(b != `,`):
                raise _declined()
            skip = 1
            comptime if (
                StrictOptions.ALLOW_TRAILING_COMMA in Self.options.strict_mode
            ):
                if i + 1 < self.n and self.byte(Int(e[unsafe_offset=1])) == `}`:
                    self.i = i + 1
                    return (-1, -1)
        first = False
        if unlikely(i + skip + 3 > self.n):
            raise _declined()
        var open = Int(e[unsafe_offset=skip])
        var close = Int(e[unsafe_offset=skip + 1])
        if unlikely(
            self.byte(open) != `"`
            or self.byte(Int(e[unsafe_offset=skip + 2])) != `:`
        ):
            raise _declined()
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
                    raise _declined()
            else:
                if unlikely(idx < 0 and self.has_control(open + 1, close)):
                    raise _declined()
            return idx
        return field_index[T](self.decode_string(open, close))

    @always_inline
    def list_next(
        mut self, mut first: Bool, close: Byte
    ) raises DeserializationError -> Bool:
        """`has_next` for arrays and objects: separator and trailing-comma
        rules are the byte-walk's."""
        var b = self.peek()
        if b == close:
            return False
        if not first:
            if unlikely(b != `,`):
                raise _declined()
            self.advance()
            if self.peek() == close:
                comptime if (
                    StrictOptions.ALLOW_TRAILING_COMMA
                    in Self.options.strict_mode
                ):
                    return False
                else:
                    raise _declined()
        first = False
        return True


comptime _Cursor[
    origin: ImmOrigin, options: ParseOptions, ptr_origin: MutOrigin
] = Pointer[_IndexCursor[origin, options], ptr_origin]


@fieldwise_init
struct _IdxSeqDe[
    origin: ImmOrigin, options: ParseOptions, ptr_origin: MutOrigin
](SeqDerState):
    var c: _Cursor[Self.origin, Self.options, Self.ptr_origin]
    var first: Bool

    @always_inline
    def has_next(mut self) raises DeserializationError -> Bool:
        return self.c[].list_next(self.first, `]`)

    def expect_element[T: AnyType](mut self) raises DeserializationError -> T:
        var sub = IndexedDeserializer(c=self.c)
        return _de[T](sub)

    def end(mut self) raises DeserializationError:
        self.c[].expect(`]`)
        self.c[].p.depth -= 1


@fieldwise_init
struct _IdxMapDe[
    origin: ImmOrigin, options: ParseOptions, ptr_origin: MutOrigin
](MapDerState):
    var c: _Cursor[Self.origin, Self.options, Self.ptr_origin]
    var first: Bool
    # Strict mode only: hashes of the raw keys seen so far. A repeated
    # hash declines, and the byte walk then settles it exactly (reporting
    # the duplicate, or accepting the collision); so hashing never lets a
    # duplicate through, and costs one hash per key instead of a copied,
    # hashed and inserted `String`.
    var seen: Set[UInt64]

    def has_next(mut self) raises DeserializationError -> Bool:
        return self.c[].list_next(self.first, `}`)

    def expect_key[T: AnyType](mut self) raises DeserializationError -> T:
        var sub = IndexedDeserializer(c=self.c)
        comptime if T == String and not (
            StrictOptions.ALLOW_DUPLICATE_KEYS in Self.options.strict_mode
        ):
            comptime assert conforms_to(T, Base), "unreachable: T == String"
            var key = _de[T](sub)
            ref c = self.c[]
            # The key string just consumed: its two quotes are the last two
            # index entries read.
            var open = Int(c.positions.unsafe_ptr()[unsafe_offset=c.i - 2])
            var close = Int(c.positions.unsafe_ptr()[unsafe_offset=c.i - 1])
            # An escaped key can equal another spelled differently; only the
            # byte walk compares decoded keys.
            if unlikely(not c.plain(open + 1, close)):
                raise _declined()
            var h = _raw_key_hash(
                c.p.data.start.unsafe_offset(open + 1), close - open - 1
            )
            if unlikely(h in self.seen):
                raise _declined()
            self.seen.add(h)
            return key^
        else:
            return _de[T](sub)

    def expect_value[T: AnyType](mut self) raises DeserializationError -> T:
        self.c[].expect(`:`)
        var sub = IndexedDeserializer(c=self.c)
        return _de[T](sub)

    def end(mut self) raises DeserializationError:
        self.c[].expect(`}`)
        self.c[].p.depth -= 1


@fieldwise_init
struct _IdxStructDe[
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

    def expect_field_value[
        T: AnyType
    ](mut self) raises DeserializationError -> T:
        var sub = IndexedDeserializer(c=self.c)
        return _de[T](sub)

    def skip_value(mut self) raises DeserializationError:
        _skip_value(self.c[])

    def end(mut self) raises DeserializationError:
        self.c[].expect(`}`)
        self.c[].p.depth -= 1


@fieldwise_init
struct _IdxTupleDe[
    origin: ImmOrigin, options: ParseOptions, ptr_origin: MutOrigin
](TupleDerState):
    var c: _Cursor[Self.origin, Self.options, Self.ptr_origin]
    var first: Bool

    @always_inline
    def expect_element[T: AnyType](mut self) raises DeserializationError -> T:
        if not self.first:
            self.c[].expect(`,`)
        self.first = False
        var sub = IndexedDeserializer(c=self.c)
        return _de[T](sub)

    def end(mut self) raises DeserializationError:
        self.c[].expect(`]`)
        self.c[].p.depth -= 1


@fieldwise_init
struct _IdxEnumDe[
    origin: ImmOrigin, options: ParseOptions, ptr_origin: MutOrigin
](EnumDerState):
    var c: _Cursor[Self.origin, Self.options, Self.ptr_origin]
    var idx: Int

    def variant_index(mut self) raises DeserializationError -> Int:
        return self.idx

    def expect_payload[T: AnyType](mut self) raises DeserializationError -> T:
        var sub = IndexedDeserializer(c=self.c)
        return _de[T](sub)

    def end(mut self) raises DeserializationError:
        self.c[].expect(`}`)
        self.c[].p.depth -= 1


def _skip_value[
    origin: ImmOrigin, options: ParseOptions
](mut c: _IndexCursor[origin, options]) raises DeserializationError:
    """Consumes one value with the byte-walk's validating skip."""
    c.seek_lookahead()
    c.p.skip_value()
    c.skip_past(ptr_dist(c.p.data.start, c.p.data.p))


@fieldwise_init
struct IndexedDeserializer[
    origin: ImmOrigin, options: ParseOptions, ptr_origin: MutOrigin
](BorrowingDeserializer, SelfDescribingDeserializer):
    var c: _Cursor[Self.origin, Self.options, Self.ptr_origin]

    comptime SeqType = _IdxSeqDe[Self.origin, Self.options, Self.ptr_origin]
    comptime MapType = _IdxMapDe[Self.origin, Self.options, Self.ptr_origin]
    comptime StructType = _IdxStructDe[
        Self.origin, Self.options, Self.ptr_origin
    ]
    comptime TupleType = _IdxTupleDe[Self.origin, Self.options, Self.ptr_origin]
    comptime EnumType = _IdxEnumDe[Self.origin, Self.options, Self.ptr_origin]
    comptime Value = Value

    def expect_struct[
        T: Deinitable
    ](mut self, out result: T) raises DeserializationError:
        """Reads `T` in one pass when its keys arrive in declaration order,
        as machine-written JSON's do: each key is one compare against its
        field's wire name, with no name lookup or duplicate tracking. Any
        other shape (reordered, missing, extra or escaped keys) rewinds to
        the `{` and runs the framework's driver, so its semantics hold."""
        comptime if conforms_to(T, Defaultable & Movable) and _ordered_ok[T]():
            ref c = self.c[]
            var i = c.i
            var bs_i = c.bs_i
            var next_bs = c.next_bs
            var depth = c.p.depth
            result = T()
            if self._read_ordered[T](result):
                return
            c.i = i
            c.bs_i = bs_i
            c.next_bs = next_bs
            c.p.depth = depth
            result = self._driver_struct[T]()
        else:
            result = deserialize_struct[T](self)

    @always_inline
    def _read_ordered[
        T: AnyType
    ](mut self, mut result: T) raises DeserializationError -> Bool:
        """Fills `result`'s fields from keys in declaration order; False
        (at a key) when they are not. A raise is one the driver would
        raise at the same value, having read the same keys before it."""
        comptime r = reflect[T]
        comptime names = r.field_names()
        self.c[].expect(`{`)
        self.c[].p.enter_container()
        var first = True
        comptime for i in range(r.field_count()):
            var span = self.c[].next_field_key(first)
            var start = span[0] + 1
            if unlikely(span[0] < 0 or not self.c[].plain(start, span[1])):
                return False
            comptime W = static_wire_name[T, r.field_types()[i], names[i]]()
            if unlikely(
                not _eq_static[W](
                    StringSlice(
                        unsafe_from_utf8=Span(
                            unsafe_ptr=self.c[].p.data.start.unsafe_offset(
                                start
                            ),
                            length=span[1] - start,
                        )
                    )
                )
            ):
                return False
            comptime assert conforms_to(
                r.field_types()[i], Base
            ), "field types must be Movable & Deinitable"
            var sub = IndexedDeserializer(c=self.c)
            r.field_ref[i](result) = _de[downcast[r.field_types()[i], Base]](
                sub
            )
        if unlikely(self.c[].next_field_key(first)[0] >= 0):
            return False
        self.c[].expect(`}`)
        self.c[].p.depth -= 1
        return True

    @no_inline
    def _driver_struct[
        T: Deinitable
    ](mut self) raises DeserializationError -> T:
        # Out of line: only structs whose keys are out of order get here.
        return deserialize_struct[T](self)

    def expect_bool(mut self) raises DeserializationError -> Bool:
        if unlikely(self.c[].peek() != `t` and self.c[].peek() != `f`):
            raise _declined()
        _ = self.c[].take_scalar()
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
        if unlikely(not (isdigit(b) or b == `-`)):
            raise _declined()
        _ = c.take_scalar()
        var v: Scalar[DT]
        # A structural follows the number's scalar run (the run ends at
        # whitespace or an operator, both before the next entry), so
        # the digit loops stop inside the input; with 8 bytes past that
        # entry in bounds, they need no checks at all.
        if likely(c.i < c.n and c.peek_off() + 8 <= c.p.size):
            v = c.p.expect_float[DT, unchecked=True]()
        else:
            v = c.p.expect_float[DT]()
        c.check_token_end()
        return v

    def expect_string(mut self) raises DeserializationError -> String:
        return self.c[].read_string()

    def expect_optional[
        T: Base
    ](mut self) raises DeserializationError -> Optional[T]:
        if self.c[].peek() == `n`:
            _ = self.c[].take_scalar()
            self.c[].p.expect_null()
            self.c[].check_token_end()
            return Optional[T]()
        return Optional[T](_de[T](self))

    @always_inline
    def begin_seq(mut self) raises DeserializationError -> Self.SeqType:
        self.c[].expect(`[`)
        self.c[].p.enter_container()
        return {c = self.c, first = True}

    def begin_map(mut self) raises DeserializationError -> Self.MapType:
        self.c[].expect(`{`)
        self.c[].p.enter_container()
        return {c = self.c, first = True, seen = Set[UInt64]()}

    def begin_struct[
        T: AnyType
    ](mut self) raises DeserializationError -> Self.StructType:
        self.c[].expect(`{`)
        self.c[].p.enter_container()
        return {c = self.c, first = True}

    def begin_tuple[
        field_count: Int
    ](mut self) raises DeserializationError -> Self.TupleType:
        self.c[].expect(`[`)
        self.c[].p.enter_container()
        return {c = self.c, first = True}

    def begin_enum[
        T: AnyType, arm_names: List[String]
    ](mut self) raises DeserializationError -> Self.EnumType:
        self.c[].expect(`{`)
        self.c[].p.enter_container()
        var name = self.c[].read_string()
        self.c[].expect(`:`)
        var idx = -1
        comptime for i in range(len(arm_names)):
            comptime an = get_static_string[arm_names[i]]()
            if idx == -1 and name == an:
                idx = i
        return {c = self.c, idx = idx}

    def raw_bytes[
        kind: RawKind
    ](mut self) raises DeserializationError -> Span[Byte, ImmUntrackedOrigin]:
        # The byte-walk extractors capture and validate the span; the
        # index entries inside it are then dropped.
        ref c = self.c[]
        c.seek_lookahead()
        var span: Span[Byte, ImmUntrackedOrigin]
        comptime if kind == RawKind.Any:
            span = rebind[Span[Byte, ImmUntrackedOrigin]](
                c.p.expect_value_bytes()
            )
        elif kind == RawKind.Integer:
            span = rebind[Span[Byte, ImmUntrackedOrigin]](
                c.p.expect_int_bytes()
            )
        elif kind == RawKind.Float:
            span = rebind[Span[Byte, ImmUntrackedOrigin]](
                c.p.expect_float_bytes()
            )
        elif kind == RawKind.Str:
            if c.p.peek() != `"`:
                raise _declined()
            span = rebind[Span[Byte, ImmUntrackedOrigin]](
                c.p.expect_string_bytes()
            )
        elif kind == RawKind.Seq:
            span = rebind[Span[Byte, ImmUntrackedOrigin]](
                c.p.expect_array_bytes()
            )
        else:
            span = rebind[Span[Byte, ImmUntrackedOrigin]](
                c.p.expect_object_bytes()
            )
        c.skip_past(ptr_dist(c.p.data.start, c.p.data.p))
        return span

    def deserialize_any(mut self) raises DeserializationError -> Value:
        ref c = self.c[]
        c.seek_lookahead()
        var v = c.p.parse_value()
        c.skip_past(ptr_dist(c.p.data.start, c.p.data.p))
        return v^


def from_json_indexed[
    o: ImmOrigin,
    //,
    T: Movable & Deinitable,
    options: ParseOptions = ParseOptions(),
](s: StringSlice[o], out result: T) raises DeserializationError:
    """Deserializes `s` into `T` over the structural index. Raises on ANY
    failure without a meaningful error; see the module docstring."""
    if unlikely(s.byte_length() == 0):
        raise _declined()
    var c = _IndexCursor[o, options](s)
    var d = IndexedDeserializer(c=Pointer(to=c))
    result = deserialize[T](d)
    # Every structural consumed: nothing but whitespace after the root.
    if unlikely(c.i != c.n):
        raise _declined()


def from_json[
    o: ImmOrigin,
    //,
    T: Movable & Deinitable,
    options: ParseOptions = ParseOptions(),
](s: StringSlice[o]) raises DeserializationError -> T:
    """Deserializes `s` into `T` through emberserde's framework.

    Runs the structural-index deserializer (`from_json_indexed`) and, if it
    declines, the byte-walk one (`from_json_bytewalk`), whose result or
    error is what the caller sees. The two accept exactly the same inputs
    and build the same values, so the fallback only ever costs time -- on
    input the fast path cannot settle inline, or that is invalid.

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
    comptime if conforms_to(T, RawCapture):
        return from_json_bytewalk[T, options](s)
    try:
        return from_json_indexed[T, options](s)
    except:
        return from_json_bytewalk[T, options](s)
