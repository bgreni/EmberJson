from emberjson.utils import (
    CheckedPointer,
    BytePtr,
    ByteView,
    PaddedBuffer,
    PAD_INPUT_THRESHOLD,
    to_string,
    is_space,
    StackArray,
)
from std.math import isinf
from emberjson.simd import SIMD8_WIDTH, SIMD8xT
from emberjson.array import Array
from emberjson.object import Object, _ObjectParseIndex
from emberjson.value import Value, Null
from std.bit import count_trailing_zeros
from std.sys.intrinsics import unlikely, likely
from ._parser_helper import (
    copy_to_string,
    TRUE,
    ALSE,
    NULL,
    StringBlock,
    is_numerical_component,
    get_non_space_bits,
    ptr_dist,
    is_exp_char,
    pack_into_integer,
    isdigit,
    check_escapes,
    glued,
    value_error,
)
from ._errors import (
    unexpected_eof,
    invalid_value,
    after_value,
    expected_separator,
    expected_token,
    trailing_comma,
    expected_key,
    expected_colon,
    trailing_content,
    too_deep,
    literal_eof,
    bad_literal,
    control_character,
    invalid_escape,
    invalid_hex_escape,
    found_float,
    float_overflow,
)
from std.memory.unsafe import bitcast
from .slow_float_parse import from_chars_slow
from ._number import (
    RawNumber,
    parse_int,
    parse_float64,
    parse_raw_number,
    scan_number,
)
from emberjson.constants import (
    `[`,
    `]`,
    `{`,
    `}`,
    `,`,
    `"`,
    `:`,
    `t`,
    `f`,
    `n`,
    `u`,
    acceptable_escapes,
    `\\`,
    `-`,
    `+`,
    `0`,
    `9`,
    `.`,
    ` `,
)
from std.utils.numerics import FPUtils
from emberserde.error import DeserializationError


#######################################################
# Certain parts inspired/taken from SonicCPP and simdjon
# https://github.com/bytedance/sonic-cpp
# https://github.com/simdjson/simdjson
#######################################################


comptime _WS_PEEL = 1
"""Scalar whitespace bytes peeled before falling back to the SIMD scan.

Tuned on citm (M3): 0 -> 0.859ms, 1 -> 0.684ms, 2 -> 0.690ms, 4 -> 0.699ms,
8 -> 0.713ms. One byte catches the single space after ":" (34% of citm's
whitespace runs) while costing longer indent runs almost nothing."""


struct StrictOptions(Defaultable, Equatable, TrivialRegisterPassable):
    var _flags: Int

    @always_inline
    def __init__(out self, val: Int):
        self._flags = val

    comptime STRICT = StrictOptions(0)

    comptime ALLOW_TRAILING_COMMA = StrictOptions(1)
    comptime ALLOW_DUPLICATE_KEYS = StrictOptions(1 << 1)

    comptime LENIENT = Self.ALLOW_TRAILING_COMMA | Self.ALLOW_DUPLICATE_KEYS

    def __init__(out self):
        self = Self.STRICT

    def __or__(self, other: Self) -> Self:
        return Self(self._flags | other._flags)

    def __contains__(self, other: Self) -> Bool:
        return self._flags & other._flags == other._flags


struct ParseOptions(Equatable, TrivialRegisterPassable):
    """JSON parsing options.

    Fields:
        ignore_unicode: Keep `\\u` escapes as their raw six-character text
            instead of decoding them (a small speed-up for trusted input).
            Escapes are NOT validated under this flag (`\\u12G4` is stored
            as-is), and a value parsed this way does not round-trip:
            `to_json` re-escapes the backslash.
        strict_mode: Flags to control strictness of parsing.
        validate_utf8: Validate that the whole input is well-formed UTF-8
            (RFC 3629) before parsing, as the JSON spec requires. On by
            default; the check runs at 20-30 GB/s (with an ASCII fast
            path) and typically costs 2-4% of a parse. Set False to skip
            it for trusted input.
        max_depth: The deepest nesting of arrays and objects combined that
            any parser accepts (the root container is level 1). Deeper
            input raises `DeserializationError("Exceeded maximum nesting
            depth", InvalidValue)`. It exists to protect the stack: the
            `Value` and reflection parsers recurse once per level, and the
            `Document` builder reserves a 16-byte scope per level up front.
            Must be positive (a compile-time error otherwise).
    """

    var ignore_unicode: Bool
    var strict_mode: StrictOptions
    var validate_utf8: Bool
    var max_depth: Int
    # Internal: the input is backed by a `PaddedBuffer`, so hot loops may
    # read past end-of-input into NUL padding without bounds checks. Only
    # the public entry points that copy into a PaddedBuffer set this; user
    # code should never construct options with it enabled.
    var _assume_padded: Bool

    def __init__(
        out self,
        *,
        ignore_unicode: Bool = False,
        strict_mode: StrictOptions = StrictOptions.STRICT,
        validate_utf8: Bool = True,
        max_depth: Int = 1024,
    ):
        self.ignore_unicode = ignore_unicode
        self.strict_mode = strict_mode
        self.validate_utf8 = validate_utf8
        self.max_depth = max_depth
        self._assume_padded = False

    def _padded(self) -> Self:
        # A parser carrying these options can only be constructed from a
        # `PaddedBuffer` (see `Parser.__init__(padded=...)`); every other
        # constructor rejects `_assume_padded` at compile time, so the
        # unchecked hot-loop reads are safe by construction.
        var res = self
        res._assume_padded = True
        return res

    def _utf8_validated(self) -> Self:
        # Defence-in-depth, not the enforcing mechanism: `validate_utf8` is
        # only read by `from_json` (which sets this flag) and by
        # `parse_pointer` (an unrelated entry point `from_json` never
        # reaches), so clearing it here prevents no double-check today.
        # The real guarantee is structural: `from_json` is the sole caller
        # of the root helpers, and it runs the UTF-8 check exactly once,
        # before dispatching to them. Mirrors `_padded()`: a comptime-only
        # options transform, never something user code constructs directly.
        var res = self
        res.validate_utf8 = False
        return res


@fieldwise_init
struct StringScan[origin: ImmOrigin](TrivialRegisterPassable):
    """A scanned string's content, `[start, end)`, and what decoding it needs.

    `first_escape` is the offset of the first backslash (0 when unknown), so
    the decoder can bulk-copy the clean prefix instead of re-scanning it."""

    var start: BytePtr[Self.origin]
    var end: BytePtr[Self.origin]
    var found_escaped: Bool
    var first_escape: Int


struct Parser[origin: ImmOrigin, options: ParseOptions = ParseOptions()]:
    var data: CheckedPointer[Self.origin]
    var size: Int
    # Open containers, bounded by `options.max_depth`. The reflection
    # deserializers share one `Parser` and count their containers here too,
    # so a `Value` or skipped field nests from its enclosing struct's depth.
    var depth: Int

    @implicit
    def __init__(
        out self: Parser[Self.origin, Self.options], ref[Self.origin] s: String
    ):
        self = {StringSlice(s)}

    @implicit
    def __init__(
        out self: Parser[ImmStaticOrigin, Self.options], s: StringLiteral
    ):
        self = {StaticString(s)}

    @implicit
    def __init__(out self, s: StringSlice[Self.origin]):
        self = {ptr = s.unsafe_ptr(), length = s.byte_length()}

    @implicit
    def __init__(out self, s: ByteView[Self.origin]):
        self = {ptr = s.unsafe_ptr(), length = len(s)}

    def __init__(
        out self,
        *,
        ptr: Pointer[Byte, origin=Self.origin],
        length: Int,
    ):
        # `_assume_padded` removes bounds checks from every hot loop, which
        # is only sound over a `PaddedBuffer`'s NUL tail. Enforce the
        # pairing at compile time: padded options are unconstructible from
        # arbitrary memory.
        comptime assert not Self.options._assume_padded, (
            "options with `_assume_padded` require a `PaddedBuffer`:"
            " construct with `Parser(padded=...)`"
        )
        comptime assert (
            Self.options.max_depth > 0
        ), "ParseOptions.max_depth must be positive"
        self.data = CheckedPointer(ptr, ptr, ptr.unsafe_offset(length))
        self.size = length
        self.depth = 0

    def __init__(
        out self: Parser[Self.origin, Self.options],
        *,
        ref[Self.origin] padded: PaddedBuffer,
    ):
        """The only constructor for `_assume_padded` options: the buffer's
        NUL tail is what makes the unchecked hot-loop reads safe."""
        comptime assert Self.options._assume_padded, (
            "`Parser(padded=...)` is reserved for `_padded()` options; use"
            " the span/string constructors otherwise"
        )
        comptime assert (
            Self.options.max_depth > 0
        ), "ParseOptions.max_depth must be positive"
        # Safety: the buffer is borrowed for `Self.origin`, so viewing its
        # heap data through that origin is exactly the borrow contract.
        var p: BytePtr[
            Self.origin
        ] = padded._data.unsafe_ptr().unsafe_origin_cast[Self.origin]()
        self.data = CheckedPointer(p, p, p.unsafe_offset(padded._len))
        self.size = padded._len
        self.depth = 0

    @always_inline
    def bytes_remaining(self) -> Int:
        return self.data.dist()

    @always_inline
    def has_more(self) -> Bool:
        return self.bytes_remaining() > 0

    @always_inline
    def remaining(self) -> String:
        """Used for debug purposes.

        Returns:
            A string containing the remaining unprocessed data from parser input.
        """
        try:
            return copy_to_string[True](self.data.p, self.data.end)
        except:
            return ""

    @always_inline
    def load_chunk(self) -> SIMD8xT:
        comptime if Self.options._assume_padded:
            return self.data.unsafe_load_chunk()
        else:
            return self.data.load_chunk()

    @always_inline
    def can_load_chunk(self) -> Bool:
        comptime if Self.options._assume_padded:
            # PaddedBuffer.PAD >= SIMD8_WIDTH: a full chunk is always
            # readable while any input remains.
            return self.has_more()
        else:
            return self.bytes_remaining() >= SIMD8_WIDTH

    @always_inline
    def pos(self) -> Int:
        return self.size - (self.size - self.data.dist())

    @always_inline
    def peek(self) raises DeserializationError -> Byte:
        return self.data[]

    @always_inline
    def cur(self) raises DeserializationError -> Byte:
        """The byte at the current position. In padded mode reads at or past
        end-of-input return the NUL padding (which no token accepts, so every
        caller falls into its existing error/terminate branch); otherwise a
        bounds-checked read that raises on EOF.
        """
        comptime if Self.options._assume_padded:
            return self.data.unsafe_get()
        else:
            return self.data[]

    def parse(mut self, out json: Value) raises DeserializationError:
        self.skip_whitespace()
        json = self.parse_value()

        self.skip_whitespace()
        if unlikely(self.has_more()):
            raise self.trailing_error()

    # The errors below are for failure branches the byte walk shares with
    # the `Document` builder; each decides between the end of input and the
    # byte at the cursor, then raises the shared `_errors` constructor.

    @no_inline
    def trailing_error(self) -> DeserializationError:
        """After the root value, at a byte that is not whitespace."""
        var b = self.data.unsafe_get()
        if glued(self.data.p[unsafe_offset=-1], b):
            return after_value(b)
        return trailing_content(self.data.p, self.bytes_remaining())

    @no_inline
    def separator_error(self, close: Byte) -> DeserializationError:
        """After a container's value, at a byte that is neither `,` nor
        `close`."""
        if not self.has_more():
            return unexpected_eof()
        var b = self.data.unsafe_get()
        if glued(self.data.p[unsafe_offset=-1], b):
            return after_value(b)
        return expected_separator(close, b)

    @no_inline
    def key_error(self) -> DeserializationError:
        """Where an object key must start, at a byte that is not `"`."""
        if not self.has_more():
            return unexpected_eof()
        return expected_key(self.data.unsafe_get())

    @no_inline
    def colon_error(self) -> DeserializationError:
        """After an object key, at a byte that is not `:`."""
        if not self.has_more():
            return unexpected_eof()
        return expected_colon(self.data.unsafe_get())

    @no_inline
    def value_start_error(self) -> DeserializationError:
        """Where any value may start, at a byte that starts none."""
        if not self.has_more():
            return unexpected_eof()
        return invalid_value(self.data.unsafe_get())

    @no_inline
    def shape_error(self, what: StaticString) -> DeserializationError:
        """Where a `what` must start, at bytes that do not start one: see
        `value_error`."""
        return value_error(self.data.p, self.bytes_remaining(), what)

    @always_inline
    def enter_container(mut self) raises DeserializationError:
        """Counts one more open container against `options.max_depth`; the
        caller decrements `depth` when the container closes."""
        self.depth += 1
        if unlikely(self.depth > Self.options.max_depth):
            raise too_deep()

    def parse_array(mut self, out arr: Array) raises DeserializationError:
        self.data += 1
        self.enter_container()
        self.skip_whitespace()

        if unlikely(self.cur() == `]`):
            arr = Array()
        else:
            # Reserve a few slots up front: most JSON arrays are small, and
            # growing a List from zero costs several reallocations that each
            # move the 32-byte Values. Empty arrays stay allocation-free.
            arr = Array(capacity=4)
            while True:
                arr.append(self.parse_value())
                self.skip_whitespace()
                var has_comma = False
                if self.cur() == `,`:
                    self.data += 1
                    has_comma = True
                    self.skip_whitespace()
                if self.cur() == `]`:
                    comptime if (
                        StrictOptions.ALLOW_TRAILING_COMMA
                        not in Self.options.strict_mode
                    ):
                        if has_comma:
                            raise trailing_comma()
                    break
                elif unlikely(not has_comma):
                    raise self.separator_error(`]`)
                if unlikely(not self.has_more()):
                    raise unexpected_eof()

        self.data += 1
        self.depth -= 1
        self.skip_whitespace()

    def parse_object(mut self, out obj: Object) raises DeserializationError:
        self.data += 1
        self.enter_container()
        self.skip_whitespace()

        if unlikely(self.cur() == `}`):
            obj = Object()
        else:
            # Reserve a few slots up front (see parse_array); KeyValuePair
            # entries are ~64 bytes, so realloc-from-zero growth is costly.
            obj = Object(capacity=4)
            # Transient hash index over this object's keys; stays empty
            # (allocation-free) until the object crosses _INDEX_THRESHOLD,
            # then keeps duplicate detection O(1) instead of O(n) per key.
            var index = _ObjectParseIndex()
            while True:
                if unlikely(self.cur() != `"`):
                    raise self.key_error()
                var ident = self.read_string()
                self.skip_whitespace()
                if unlikely(self.cur() != `:`):
                    raise self.colon_error()
                self.data += 1
                var v = self.parse_value()
                self.skip_whitespace()
                var has_comma = False
                if self.cur() == `,`:
                    self.data += 1
                    self.skip_whitespace()
                    has_comma = True

                # Strict mode rejects duplicate keys outright. In lenient mode
                # (`ALLOW_DUPLICATE_KEYS`), duplicates collapse with
                # last-write-wins semantics — matching how dict literals and
                # `__setitem__` behave, and what RFC 8259 recommends.
                obj._append_for_parse[
                    StrictOptions.ALLOW_DUPLICATE_KEYS
                    in Self.options.strict_mode
                ](ident^, v^, index)

                if self.cur() == `}`:
                    comptime if (
                        not StrictOptions.ALLOW_TRAILING_COMMA
                        in Self.options.strict_mode
                    ):
                        if has_comma:
                            raise trailing_comma()
                    break
                elif not has_comma:
                    raise self.separator_error(`}`)
                if unlikely(self.bytes_remaining() == 0):
                    raise unexpected_eof()

        self.data += 1
        self.depth -= 1
        self.skip_whitespace()

    @always_inline
    def parse_true(mut self) raises DeserializationError -> Bool:
        if unlikely(self.bytes_remaining() < 4):
            raise literal_eof("true")
        # Safety: Safe because we checked the amount of bytes remaining
        var w = self.data.p.unsafe_bitcast[UInt32]()[]
        if w != TRUE:
            raise bad_literal("true", String(to_string(w)))
        self.data += 4
        return True

    @always_inline
    def parse_false(mut self) raises DeserializationError -> Bool:
        self.data += 1
        if unlikely(self.bytes_remaining() < 4):
            raise literal_eof("false")
        # Safety: Safe because we checked the amount of bytes remaining
        var w = self.data.p.unsafe_bitcast[UInt32]()[]
        if w != ALSE:
            raise bad_literal("false", String("f") + String(to_string(w)))
        self.data += 4
        return False

    @always_inline
    def parse_null(mut self) raises DeserializationError -> Null:
        self.expect_null()
        return Null()

    def parse_value(mut self, out v: Value) raises DeserializationError:
        self.skip_whitespace()
        var b = self.cur()
        # Handle string
        if b == `"`:
            v = self.read_string()

        # Handle "true" atom
        elif b == `t`:
            v = self.parse_true()

        # handle "false" atom
        elif b == `f`:
            v = self.parse_false()

        # handle "null" atom
        elif b == `n`:
            v = self.parse_null()

        # handle object
        elif b == `{`:
            v = self.parse_object()

        # handle array
        elif b == `[`:
            v = self.parse_array()

        # handle number
        elif is_numerical_component(b):
            v = self.parse_number()
        else:
            raise self.value_start_error()

    @always_inline
    def scan_string(
        mut self,
    ) raises DeserializationError -> StringScan[Self.origin]:
        """Validates the string at the cursor (which sits on its opening
        quote) and leaves the cursor past the closing quote.

        Decoding is the caller's: `read_string` materializes a `String`,
        the tape builders write straight into their arena.
        """
        self.data += 1
        var start = self.data.p
        var found_escaped = False
        var first_escape = 0

        # compile time interpreter is incompatible with the SIMD accelerated
        # path, so fallback to the serial implementation
        if not self.can_load_chunk():
            while likely(self.has_more()):
                if self.data[] == `"`:
                    var end = self.data.p
                    self.data += 1
                    return {start, end, found_escaped, 0}
                if self.data[] == `\\`:
                    self.data += 1
                    if unlikely(self.data[] not in acceptable_escapes):
                        raise invalid_escape(self.data[])
                    # We found a backslash, so we need to unescape
                    found_escaped = True
                elif unlikely(self.data[] < 0x20):
                    raise control_character(self.data[])
                self.data += 1
            raise unexpected_eof()

        while True:
            var block: StringBlock
            comptime if Self.options._assume_padded:
                # Unconditional full-chunk load; an overread lands in NUL
                # padding, which registers as an unescaped control character
                # and is caught by the EOF check below before it can be
                # reported as such.
                block = StringBlock.find(self.data.p)
            else:
                block = StringBlock.find(self.data)
            if block.has_quote_first():
                self.data += block.quote_index()
                var end = self.data.p
                self.data += 1
                return {start, end, found_escaped, first_escape}
            elif unlikely(self.data.p >= self.data.end):
                # We got EOF before finding the end quote, so obviously this
                # input is malformed
                raise unexpected_eof()

            if unlikely(block.unescaped_first()):
                # A chunk that straddles the end of input reads NULs past
                # it (padding or the partial load's fill), which are not
                # the input's.
                var at = self.data.p.unsafe_offset(Int(block.unescaped_index()))
                if at >= self.data.end:
                    raise unexpected_eof()
                raise control_character(at[])
            if not block.has_backslash():
                self.data += SIMD8_WIDTH
                continue
            self.data += block.bs_index()

            # We found a backslash, so we need to unescape. Record where the
            # first one is so the decoder can bulk-copy the clean prefix
            # instead of re-scanning it.
            if not found_escaped:
                first_escape = ptr_dist(start, self.data.p)
            found_escaped = True
            while True:
                self.data += 1
                if self.cur() == `u`:
                    self.data += 1
                    break
                else:
                    if unlikely(self.cur() not in acceptable_escapes):
                        # Padded input reads NUL past the end.
                        if not self.has_more():
                            raise unexpected_eof()
                        raise invalid_escape(self.cur())
                self.data += 1
                if self.cur() != `\\`:
                    break

    def read_string(mut self, out s: String) raises DeserializationError:
        var scan = self.scan_string()
        s = copy_to_string[Self.options.ignore_unicode](
            scan.start, scan.end, scan.found_escaped, scan.first_escape
        )

    @always_inline
    def skip_whitespace(mut self) raises DeserializationError:
        comptime if Self.options._assume_padded:
            # NUL padding is not whitespace, so the EOF check is free.
            if not is_space(self.cur()):
                return
        else:
            if not self.has_more() or not is_space(self.data[]):
                return
        self.data += 1

        # compile time interpreter is incompatible with the SIMD accelerated
        # path, so fallback to the serial implementation
        while self.can_load_chunk():
            var chunk = self.load_chunk()
            var nonspace = get_non_space_bits(chunk)
            if nonspace != 0:
                self.data += count_trailing_zeros(nonspace)
                return
            else:
                self.data += SIMD8_WIDTH

        while self.has_more() and is_space(self.data[]):
            self.data += 1

    @always_inline
    def parse_number(mut self, out v: Value) raises DeserializationError:
        var r = self._parse_number_raw()
        if r.kind == RawNumber.FLOAT64:
            v = bitcast[DType.float64](r.bits)
        elif r.kind == RawNumber.UINT64:
            v = r.bits
        else:
            v = bitcast[DType.int64](r.bits)

    @always_inline
    def _parse_number_raw(
        mut self, out r: RawNumber
    ) raises DeserializationError:
        var p = self.data
        r = parse_raw_number[Self.options._assume_padded](p)
        self.data = p

    def expect(mut self, expected: Byte) raises DeserializationError:
        """Grammar-only token check (`:`, `,`, and the closing brackets).

        A byte that is not the one the grammar requires here is always
        malformed JSON -- there is no "value of the wrong type" reading of
        a missing separator -- so this never consults the shape test. Use
        `expect_open` for the `[`/`{` that stand at a value position.
        """
        self.skip_whitespace()
        if unlikely(not self.has_more() or self.cur() != expected):
            if not self.has_more():
                raise unexpected_eof()
            if expected == `:`:
                raise expected_colon(self.cur())
            raise expected_token(expected, self.cur())
        self.data += 1
        self.skip_whitespace()

    def expect_open(mut self, expected: Byte) raises DeserializationError:
        """`expect` for the `[` or `{` that opens a value.

        Unlike a separator, a container opener sits where a whole JSON
        value is expected, so a different *complete* value opener at the
        cursor is a shape disagreement (`TypeMismatch`), not a grammar
        one. Anything else -- EOF, a truncated keyword, a stray byte --
        stays `InvalidValue`. The test only runs on the failure path.
        """
        self.skip_whitespace()
        if unlikely(not self.has_more() or self.cur() != expected):
            raise self.shape_error(
                StaticString("an array") if expected
                == `[` else StaticString("an object")
            )
        self.data += 1
        self.skip_whitespace()

    @always_inline
    def _expect_number_opener(self) raises DeserializationError:
        """Raises unless the cursor is on `-` or a digit."""
        var c = self.cur()
        if unlikely(not (isdigit(c) or c == `-`)):
            raise self._not_a_number(c)

    @no_inline
    def _not_a_number(self, c: Byte) -> DeserializationError:
        return self.shape_error("a number")

    def expect_int[
        type: DType = DType.int64, unchecked: Bool = False
    ](mut self) raises DeserializationError -> Scalar[type]:
        """Parses the integer at the cursor.

        Parameters:
            type: The integer type to produce.
            unchecked: See `expect_float`.
        """
        self.skip_whitespace()
        self._expect_number_opener()
        var p = self.data
        var v = parse_int[type, unchecked or Self.options._assume_padded](p)
        self.data = p
        return v

    def expect_float[
        type: DType = DType.float64, unchecked: Bool = False
    ](mut self) raises DeserializationError -> Scalar[type]:
        """Parses the float at the cursor.

        Parameters:
            type: The floating-point type to produce.
            unchecked: The caller guarantees the number's scalar run ends
                inside the buffer (a non-number byte follows it) and that
                16 bytes past any byte of the run are readable -- the
                indexed deserializer knows both from the structural index.
                The digit loops then read without bounds checks, exactly
                as they do over a `PaddedBuffer`.
        """
        comptime assert (
            type.is_floating_point()
        ), "Expected float, found non-float type: " + String(type)

        self.skip_whitespace()
        self._expect_number_opener()
        var start = self.data
        var p = start
        var f = parse_float64[unchecked or Self.options._assume_padded](p)
        self.data = p

        comptime if type != DType.float64:
            var r = f.cast[type]()
            # Below the target's smallest normal the midpoint bit moves up
            # with the exponent, so the fixed-position test below misses it
            # (2^-150 has no low bits set yet is the 0 / 2^-149 midpoint).
            # Nonzero values that small are rare: take the exact path.
            comptime min_normal_bits = UInt64(
                1023 + 1 - FPUtils[type].exponent_bias()
            ) << 52
            var magnitude = bitcast[DType.uint64](f) & ~(UInt64(1) << 63)
            var subnormal_boundary = (
                magnitude != 0 and magnitude < min_normal_bits
            )
            # Guard against double-rounding: if the float64 result lands exactly
            # on a float32/float16 midpoint, the cast may choose the wrong
            # neighbour. Re-parse with correctly-rounded big-decimal arithmetic.
            # This also covers the FLT_MAX/infinity midpoint at the top of the
            # range, so the overflow check below must run on the re-parsed
            # result, not the plain cast -- otherwise a value that
            # double-rounds up to infinity but correctly rounds down to
            # FLT_MAX would raise incorrectly.
            comptime half_ulp_pos = 52 - FPUtils[type].mantissa_width() - 1
            comptime midpoint_bit = UInt64(1) << UInt64(half_ulp_pos)
            comptime midpoint_mask = (UInt64(1) << UInt64(half_ulp_pos + 1)) - 1
            var on_midpoint = (
                bitcast[DType.uint64](f) & midpoint_mask
            ) == midpoint_bit
            if unlikely(subnormal_boundary or on_midpoint):
                r = from_chars_slow[type](start)
            # Check if the final (possibly re-parsed) result is infinite
            # where the original float64 wasn't.
            if unlikely(not isinf(f) and isinf(r)):
                raise float_overflow()
            return r

        return f.cast[type]()

    def expect_bool(mut self) raises DeserializationError -> Bool:
        self.skip_whitespace()
        if self.data[] == `t`:
            return self.parse_true()
        elif self.data[] == `f`:
            return self.parse_false()
        # Neither `t` nor `f`: another complete value (a mismatch) or
        # malformed JSON.
        raise self.shape_error("a bool")

    def expect_null(mut self) raises DeserializationError:
        # No `skip_whitespace` here: every caller (`parse_null` via
        # `parse_value`, `_expect_literal`, the deserializer's
        # `expect_optional`) has already positioned the cursor on the
        # literal, and this sits on the `Value` path.
        #
        # Both kinds are hardcoded `InvalidValue`: the shape test is
        # structurally dead here. Every caller has already seen an `n` at
        # the cursor, so reaching a failure branch means the keyword does
        # not spell out -- which the shape test rejects as an opener too.
        if unlikely(self.bytes_remaining() < 4):
            raise literal_eof("null")
        # Safety: Safe because we checked the amount of bytes remaining
        var w = self.data.p.unsafe_bitcast[UInt32]()[]
        if w != NULL:
            raise bad_literal("null", String(to_string(w)))
        self.data += 4

    def expect_string(mut self, out s: String) raises DeserializationError:
        """The string entry point the reflection deserializer calls.

        Positions the cursor itself (unlike `read_string`, whose other
        callers have already validated the opening quote) and applies the
        shape rule on failure.
        """
        self.skip_whitespace()
        if unlikely(not self.has_more() or self.cur() != `"`):
            raise self.shape_error("a string")
        s = self.read_string()

    def expect_value_bytes(
        mut self,
    ) raises DeserializationError -> Span[Byte, Self.origin]:
        return self._expect_validated_bytes()

    def skip_value(mut self) raises DeserializationError:
        _ = self.expect_value_bytes()

    @always_inline
    def _skip_ws(mut self) raises DeserializationError:
        """Whitespace skip tuned for the token-dense validating walk.

        Three measured facts drive the shape of this (M3, citm):

        1. Every byte that can legally start a JSON token is > 0x20, so a
           single compare rejects whitespace. `is_space`'s four-way
           short-circuit chain is paid on every call, and most calls (~3 of the
           4 per token) sit on a non-space byte. Bytes <= 0x20 that are not
           whitespace are control characters, which are illegal here anyway --
           we return and let the dispatcher raise.
        2. The SIMD scan costs a flat ~6.6ns per *call* regardless of run
           length -- it is a serial load -> compare -> pack_bits -> ctz ->
           dependent-load chain with nothing to overlap it. Scalar runs
           ~0.33ns/byte. So scalar wins outright below ~16 bytes, and 34% of
           citm's whitespace runs are the single space after ':'.
        3. Long runs (pretty-printed indentation) still favour SIMD, so peel
           scalar first and fall through only when the run keeps going.
        """
        if not self.has_more() or self.data[] > ` `:
            return
        if not is_space(self.data[]):
            return
        self.data += 1

        comptime for _ in range(_WS_PEEL):
            if not self.has_more() or not is_space(self.data[]):
                return
            self.data += 1

        while self.can_load_chunk():
            var nonspace = get_non_space_bits(self.data.unsafe_load_chunk())
            if nonspace != 0:
                self.data += count_trailing_zeros(nonspace)
                return
            self.data += SIMD8_WIDTH

        while self.has_more() and is_space(self.data[]):
            self.data += 1

    @always_inline
    def _expect_literal(mut self) raises DeserializationError:
        """Bounds-checked `true`/`false`/`null`. Unlike a fixed 4/5 byte bump
        this can neither over-read the input nor accept a misspelling.
        """
        var b = self.data[]
        if b == `t`:
            _ = self.parse_true()
        elif b == `f`:
            _ = self.parse_false()
        else:
            self.expect_null()

    def _validate_number[
        integer_only: Bool = False
    ](mut self) raises DeserializationError:
        """Consumes one number with `scan_number`, the scanner every number
        reader uses, so a skipped or captured number is held to exactly the
        grammar (and errors) of a parsed one."""
        self._expect_number_opener()
        var p = self.data
        var n = scan_number[Self.options._assume_padded, validate_only=True](p)
        comptime if integer_only:
            if unlikely(n.is_float):
                raise found_float()
        self.data = p

    @always_inline
    def _expect_key_and_colon(mut self) raises DeserializationError:
        """Consume `"key" :` at the head of an object member."""
        self._skip_ws()
        if unlikely(not self.has_more() or self.data[] != `"`):
            raise self.key_error()
        _ = self.expect_string_bytes()
        self._skip_ws()
        if unlikely(not self.has_more() or self.data[] != `:`):
            raise self.colon_error()
        self.data += 1

    def _expect_validated_bytes(
        mut self,
    ) raises DeserializationError -> Span[Byte, Self.origin]:
        """Consume exactly one JSON value and return the bytes spanning it.

        This is a full grammar check that stops short of materializing
        anything: no allocation, no unescaping, no float conversion. It is the
        `serde_json` `ignore_value` contract, and it is what makes `Lazy` safe
        to re-emit verbatim in `write_json`. A cheaper bracket-counting skip
        would accept mismatched brackets, missing commas, bare `nope` and
        `1.2.3`, and hand those straight back out.

        Iterative rather than recursive, with one bit per open level: set
        for an object, so the closing byte each level expects is known,
        which is what makes `{"a": [1,2}` an error rather than a shrug. It
        is held to `options.max_depth`, counted from `depth`, so a value is
        equally deep whether it is skipped, captured or materialized, and
        that bound sizes the bit stack (128 bytes at the default depth).
        """
        self._skip_ws()
        var start = self.data
        comptime WORDS = max(1, (Self.options.max_depth + 63) // 64)
        var objects = StackArray[UInt64, WORDS](fill=0)
        var open = 0

        @always_inline
        def push(is_object: Bool) {mut objects, mut open}:
            var bit = UInt64(1) << UInt64(open & 63)
            if is_object:
                objects.unsafe_get(open >> 6) |= bit
            else:
                objects.unsafe_get(open >> 6) &= ~bit
            open += 1

        @always_inline
        def closer() {imm objects, imm open} -> Byte:
            var top = open - 1
            if (objects.unsafe_get(top >> 6) >> UInt64(top & 63)) & 1:
                return `}`
            return `]`

        while True:
            self._skip_ws()
            if unlikely(not self.has_more()):
                raise unexpected_eof()

            # --- consume one value ------------------------------------------
            var b = self.data[]
            if b == `"`:
                _ = self.expect_string_bytes()
            elif b == `-` or isdigit(b) or b == `+`:
                self._validate_number()
            elif b == `t` or b == `f` or b == `n`:
                self._expect_literal()
            elif b == `{`:
                if unlikely(self.depth + open >= Self.options.max_depth):
                    raise too_deep()
                self.data += 1
                self._skip_ws()
                if unlikely(not self.has_more()):
                    raise unexpected_eof()
                if self.data[] == `}`:
                    self.data += 1
                else:
                    push(True)
                    self._expect_key_and_colon()
                    continue
            elif b == `[`:
                if unlikely(self.depth + open >= Self.options.max_depth):
                    raise too_deep()
                self.data += 1
                self._skip_ws()
                if unlikely(not self.has_more()):
                    raise unexpected_eof()
                if self.data[] == `]`:
                    self.data += 1
                else:
                    push(False)
                    continue
            else:
                raise invalid_value(b)

            # --- a value completed: close out every container it finished ----
            while True:
                if open == 0:
                    return Span(
                        unsafe_ptr=start.p,
                        length=ptr_dist(start.p, self.data.p),
                    )

                self._skip_ws()
                if unlikely(not self.has_more()):
                    raise unexpected_eof()

                var close = closer()
                var c = self.data[]
                if c == close:
                    self.data += 1
                    open -= 1
                    continue

                if unlikely(c != `,`):
                    raise self.separator_error(close)

                self.data += 1
                self._skip_ws()
                if self.has_more() and self.data[] == close:
                    comptime if (
                        StrictOptions.ALLOW_TRAILING_COMMA
                        in Self.options.strict_mode
                    ):
                        self.data += 1
                        open -= 1
                        continue
                    else:
                        raise trailing_comma()

                if close == `}`:
                    self._expect_key_and_colon()
                break

    def expect_string_bytes(
        mut self,
    ) raises DeserializationError -> Span[Byte, Self.origin]:
        """Validates the string at the cursor as `read_string` reads it --
        `scan_string`'s checks, then decoding its escapes -- without
        materializing it, and returns its bytes, quotes included."""
        var start = self.data.p
        var scan = self.scan_string()
        comptime if not Self.options.ignore_unicode:
            if unlikely(scan.found_escaped):
                check_escapes(
                    scan.start.unsafe_offset(scan.first_escape), scan.end
                )
        return Span(unsafe_ptr=start, length=ptr_dist(start, self.data.p))

    def expect_int_bytes(
        mut self,
    ) raises DeserializationError -> Span[Byte, Self.origin]:
        self.skip_whitespace()
        var start = self.data
        self._validate_number[integer_only=True]()
        return Span(unsafe_ptr=start.p, length=ptr_dist(start.p, self.data.p))

    def expect_float_bytes(
        mut self,
    ) raises DeserializationError -> Span[Byte, Self.origin]:
        self.skip_whitespace()
        var start = self.data
        self._validate_number()
        return Span(unsafe_ptr=start.p, length=ptr_dist(start.p, self.data.p))

    def expect_object_bytes(
        mut self,
    ) raises DeserializationError -> Span[Byte, Self.origin]:
        self.skip_whitespace()
        if unlikely(not self.has_more() or self.data[] != `{`):
            raise self.shape_error("an object")
        return self._expect_validated_bytes()

    def expect_array_bytes(
        mut self,
    ) raises DeserializationError -> Span[Byte, Self.origin]:
        self.skip_whitespace()
        if unlikely(not self.has_more() or self.data[] != `[`):
            raise self.shape_error("an array")
        return self._expect_validated_bytes()


def parse_root[
    options: ParseOptions = ParseOptions()
](s: ByteView[mut=False, ...], out j: Value) raises DeserializationError:
    """Parses a whole document into a `Value`; UTF-8 is the caller's job.

    Copies the input into a NUL-padded buffer (one memcpy, cheap relative
    to parsing) so the parser's hot loops can skip per-byte bounds checks.
    Safe because the returned `Value` owns all of its data. Tiny inputs
    skip the copy: the allocation would cost more than the parse.

    `Parser.parse()` raises `DeserializationError` itself, with the kind
    chosen at the failure site (F16), so nothing is translated here: a
    duplicate key arrives as `DuplicateField`, not flattened into
    `InvalidValue` by a blanket re-wrap.
    """
    if len(s) < PAD_INPUT_THRESHOLD:
        var p = Parser[options=options](s)
        j = p.parse()
    else:
        var buf = PaddedBuffer(s)
        var p = Parser[options=options._padded()](padded=buf)
        j = p.parse()


def minify(s: String, out out_str: String) raises:
    """Removes whitespace characters from JSON string.

    `minify` is a lexical transform: it strips whitespace outside strings
    and rejects unescaped control characters inside them, but does not
    validate the grammar, numbers or UTF-8. Call `from_json` first on
    untrusted input.

    Returns:
        A copy of the input string with all whitespace characters removed.
    """
    var s_len = s.byte_length()
    out_str = String(capacity_bytes=s_len)

    var ptr = BytePtr[origin_of(s)](s.unsafe_ptr())
    var end = ptr.unsafe_offset(s_len)

    @always_inline
    @__parameter
    def _load_chunk(
        p: type_of(ptr), cond: Bool
    ) -> SIMD[DType.uint8, SIMD8_WIDTH]:
        if cond:
            return ptr.unsafe_load[width=SIMD8_WIDTH]()
        else:
            var chunk = SIMD[DType.uint8, SIMD8_WIDTH](` `)

            for i in range(Int(end) - Int(ptr)):
                chunk[i] = ptr[unsafe_offset=i]
            return chunk

    while ptr < end:
        var is_block_iter = likely(ptr.unsafe_offset(SIMD8_WIDTH) < end)
        var chunk = _load_chunk(ptr, is_block_iter)

        var bits = get_non_space_bits(chunk)
        while bits == 0 and ptr < end:
            ptr = ptr.unsafe_offset(SIMD8_WIDTH)
            chunk = _load_chunk(ptr, ptr.unsafe_offset(SIMD8_WIDTH) < end)
            bits = get_non_space_bits(chunk)

        var trailing = count_trailing_zeros(bits)
        ptr = ptr.unsafe_offset(trailing)
        if ptr >= end:
            break
        is_block_iter = likely(ptr.unsafe_offset(SIMD8_WIDTH) < end)

        if ptr[] == `"`:
            var p = ptr
            p = p.unsafe_offset(1)
            var block = StringBlock.find(p)
            var length = 1

            while not block.has_quote_first() and p < end:
                if unlikely(block.has_unescaped()):
                    raise "Invalid JSON, unescaped control character"
                elif block.has_backslash():
                    var ind = Int(block.bs_index()) + 2
                    length += ind
                    p = p.unsafe_offset(ind)
                else:
                    var ind = SIMD8_WIDTH if is_block_iter else (
                        Int(end) - Int(ptr)
                    )
                    length += ind
                    p = p.unsafe_offset(ind)
                if unlikely(p >= end):
                    # The escape (or the chunk) ran off the end of the
                    # input: the string was never closed. Never load a
                    # block at `end`.
                    raise "Invalid JSON, unterminated string"
                block = StringBlock.find(p)

            if unlikely(not block.has_quote_first()):
                raise "Invalid JSON, unterminated string"
            length += Int(block.quote_index() + 1)
            if unlikely(Int(ptr) + length > Int(end)):
                raise "Invalid JSON, unterminated string"
            out_str += StringSlice(
                unsafe_from_utf8=Span[Byte, ptr.origin](
                    unsafe_ptr=ptr, length=length
                )
            )
            ptr = ptr.unsafe_offset(length)

        else:
            var chunk = _load_chunk(ptr, is_block_iter)

            var quotes = pack_into_integer(chunk.eq(`"`))
            var valid_bits = count_trailing_zeros(~get_non_space_bits(chunk))
            if quotes != 0:
                valid_bits = min(valid_bits, count_trailing_zeros(quotes))
            out_str += StringSlice(
                unsafe_from_utf8=Span[Byte, ptr.origin](
                    unsafe_ptr=ptr, length=Int(valid_bits)
                )
            )
            ptr = ptr.unsafe_offset(valid_bits)
