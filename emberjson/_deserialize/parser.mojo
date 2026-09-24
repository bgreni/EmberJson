from emberjson.utils import (
    CheckedPointer,
    BytePtr,
    ByteView,
    PaddedBuffer,
    PAD_INPUT_THRESHOLD,
    to_string,
    is_space,
    select,
    lut,
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
    smallest_power,
    to_double,
    parse_digit,
    at_or_nul,
    ptr_dist,
    significant_digits,
    unsafe_is_made_of_eight_digits_fast,
    unsafe_parse_eight_digits,
    largest_power,
    is_exp_char,
    pack_into_integer,
    isdigit,
    is_hex_digits,
)
from std.memory.unsafe import bitcast
from std.bit import count_leading_zeros
from std.builtin.dtype import _uint_type_of_width
from std.sys.info import bit_width_of
from .slow_float_parse import from_chars_slow
from .tables import (
    POWER_OF_TEN,
    full_multiplication,
    POWER_OF_FIVE_128,
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
    `1`,
    MAX_NESTING_DEPTH,
)
from std.utils.numerics import FPUtils
from emberserde.error import DeserializationError, DerErrorKind


#######################################################
# Certain parts inspired/taken from SonicCPP and simdjon
# https://github.com/bytedance/sonic-cpp
# https://github.com/simdjson/simdjson
#######################################################


comptime _DIGIT_PEEL = 16
"""Scalar digits peeled before `_skip_digits` falls back to its SIMD scan.

Same fixed-cost-vs-short-run story as `_WS_PEEL`: citm's numbers are 5-13
bytes, always inside one 16-byte chunk, so the SIMD scan's flat ~6.6ns/call
never amortised. Tuned on citm: 0 -> 0.668ms, 16 -> 0.623ms, pure scalar ->
0.638ms (the SIMD fallback still earns its keep on long digit runs)."""

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
    """

    var ignore_unicode: Bool
    var strict_mode: StrictOptions
    var validate_utf8: Bool
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
    ):
        self.ignore_unicode = ignore_unicode
        self.strict_mode = strict_mode
        self.validate_utf8 = validate_utf8
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


comptime IntegerParseResult[origin: ImmOrigin, acc_type: DType] = Tuple[
    Scalar[acc_type], Bool, CheckedPointer[origin], Int, CheckedPointer[origin]
]


@fieldwise_init
struct RawNumber(TrivialRegisterPassable):
    """A parsed JSON number as kind + raw 64-bit payload, decoupled from
    `Value` so non-DOM consumers (the tape builder) can share the number
    grammar without materializing a variant."""

    comptime INT64: Byte = 0
    comptime UINT64: Byte = 1
    comptime FLOAT64: Byte = 2

    var kind: Byte
    var bits: UInt64


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
    # Open containers on the recursion stack; bounded by MAX_NESTING_DEPTH.
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
            raise DeserializationError(
                String("Invalid json, expected end of input, received: ")
                + String(self.remaining()),
                DerErrorKind.InvalidValue,
            )

    def parse_array(mut self, out arr: Array) raises DeserializationError:
        self.data += 1
        self.depth += 1
        if unlikely(self.depth > MAX_NESTING_DEPTH):
            raise DeserializationError(
                "Exceeded maximum nesting depth", DerErrorKind.InvalidValue
            )
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
                            raise DeserializationError(
                                "Illegal trailing comma",
                                DerErrorKind.InvalidValue,
                            )
                    break
                elif unlikely(not has_comma):
                    raise DeserializationError(
                        "Expected ',' or ']'", DerErrorKind.InvalidValue
                    )
                if unlikely(not self.has_more()):
                    raise DeserializationError(
                        "Expected ']'", DerErrorKind.InvalidValue
                    )

        self.data += 1
        self.depth -= 1
        self.skip_whitespace()

    def parse_object(mut self, out obj: Object) raises DeserializationError:
        self.data += 1
        self.depth += 1
        if unlikely(self.depth > MAX_NESTING_DEPTH):
            raise DeserializationError(
                "Exceeded maximum nesting depth", DerErrorKind.InvalidValue
            )
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
                    raise DeserializationError(
                        "Invalid identifier", DerErrorKind.InvalidValue
                    )
                var ident = self.read_string()
                self.skip_whitespace()
                if unlikely(self.cur() != `:`):
                    raise DeserializationError(
                        String("Invalid identifier : ")
                        + String(self.remaining()),
                        DerErrorKind.InvalidValue,
                    )
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
                            raise DeserializationError(
                                "Illegal trailing comma",
                                DerErrorKind.InvalidValue,
                            )
                    break
                elif not has_comma:
                    raise DeserializationError(
                        "Expected ',' or '}'", DerErrorKind.InvalidValue
                    )
                if unlikely(self.bytes_remaining() == 0):
                    raise DeserializationError(
                        "Expected '}'", DerErrorKind.InvalidValue
                    )

        self.data += 1
        self.depth -= 1
        self.skip_whitespace()

    @always_inline
    def parse_true(mut self) raises DeserializationError -> Bool:
        if unlikely(self.bytes_remaining() < 4):
            raise DeserializationError(
                'Encountered EOF when expecting "true"',
                DerErrorKind.InvalidValue,
            )
        # Safety: Safe because we checked the amount of bytes remaining
        var w = self.data.p.unsafe_bitcast[UInt32]()[]
        if w != TRUE:
            raise DeserializationError(
                String("Expected 'true', received: ") + String(to_string(w)),
                DerErrorKind.InvalidValue,
            )
        self.data += 4
        return True

    @always_inline
    def parse_false(mut self) raises DeserializationError -> Bool:
        self.data += 1
        if unlikely(self.bytes_remaining() < 4):
            raise DeserializationError(
                'Encountered EOF when expecting "false"',
                DerErrorKind.InvalidValue,
            )
        # Safety: Safe because we checked the amount of bytes remaining
        var w = self.data.p.unsafe_bitcast[UInt32]()[]
        if w != ALSE:
            raise DeserializationError(
                String("Expected 'false', received: f") + String(to_string(w)),
                DerErrorKind.InvalidValue,
            )
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
            raise DeserializationError(
                "Invalid json value", DerErrorKind.InvalidValue
            )

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
                        raise DeserializationError(
                            String("Invalid escape sequence: ")
                            + String(to_string(self.data[-1]))
                            + String(to_string(self.data[])),
                            DerErrorKind.InvalidValue,
                        )
                    # We found a backslash, so we need to unescape
                    found_escaped = True
                if unlikely(self.data[] < 0x20):
                    raise DeserializationError(
                        String("Control characters must be escaped: ")
                        + String(String(self.data[])),
                        DerErrorKind.InvalidValue,
                    )
                self.data += 1
            raise DeserializationError(
                "Invalid String", DerErrorKind.InvalidValue
            )

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
                raise DeserializationError(
                    "Unexpected EOF", DerErrorKind.InvalidValue
                )

            if unlikely(block.has_unescaped()):
                raise DeserializationError(
                    String("Control characters must be escaped: ")
                    + String(to_string(self.load_chunk()))
                    + String(" : ")
                    + String(String(block.unescaped_index())),
                    DerErrorKind.InvalidValue,
                )
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
                        raise DeserializationError(
                            String("Invalid escape sequence: ")
                            + String(to_string(self.data[-1]))
                            + String(to_string(self.cur())),
                            DerErrorKind.InvalidValue,
                        )
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

    #####################################################################################################################
    # BASED ON SIMDJSON https://github.com/simdjson/simdjson/blob/master/include/simdjson/generic/numberparsing.h
    #####################################################################################################################

    @always_inline
    def compute_float_fast(
        self, out d: Float64, power: Int64, i: UInt64, negative: Bool
    ):
        d = Float64(i)
        var pow: Float64
        var neg_power = power < 0

        pow = lut[POWER_OF_TEN](Int(abs(power)))
        d = select(neg_power, d / pow, d * pow)
        d = select(negative, -d, d)

    @always_inline
    def compute_float64(
        self, out d: Float64, power: Int64, var i: UInt64, negative: Bool
    ) raises DeserializationError:
        comptime min_fast_power = Int64(-22)
        comptime max_fast_power = Int64(22)

        if min_fast_power <= power <= max_fast_power and i <= 9007199254740991:
            return self.compute_float_fast(power, i, negative)

        if unlikely(i == 0 or power < -342):
            return select(negative, -0.0, 0.0)

        var lz = count_leading_zeros(i)
        i <<= lz

        var index = Int(2 * (power - smallest_power))

        var first_product = full_multiplication(
            i, lut[POWER_OF_FIVE_128](index)
        )

        var upper = UInt64(first_product >> 64)
        var lower = UInt64(first_product)

        if unlikely(upper & 0x1FF == 0x1FF):
            var second_product = full_multiplication(
                i, lut[POWER_OF_FIVE_128](index + 1)
            )
            var upper_s = UInt64(second_product >> 64)
            lower += upper_s
            if upper_s > lower:
                upper += 1

        var upperbit: UInt64 = upper >> 63
        var mantissa: UInt64 = upper >> (upperbit + 9)
        lz += UInt64(1 ^ upperbit)

        comptime `152170 + 65536` = 152170 + 65536
        comptime `1024 + 63` = 1024 + 63

        var real_exponent: Int64 = (
            (((`152170 + 65536`) * power) >> 16)
            + `1024 + 63`
            - lz.cast[DType.int64]()
        )

        comptime `1 << 52` = 1 << 52

        if unlikely(real_exponent <= 0):
            if -real_exponent + 1 >= 64:
                d = select(negative, -0.0, 0.0)
                return
            mantissa >>= (-real_exponent + 1).cast[DType.uint64]()
            mantissa += mantissa & 1
            mantissa >>= 1

            real_exponent = select(mantissa < `1 << 52`, Int64(0), Int64(1))
            return to_double(
                mantissa, real_exponent.cast[DType.uint64](), negative
            )

        if unlikely(
            lower == 0 and (upper & 0x1FF) == 0 and (mantissa & 3 == 1)
        ):
            comptime `64 - 53 - 2` = 64 - 53 - 2
            if (mantissa << (upperbit + `64 - 53 - 2`)) == upper:
                mantissa &= ~1

        mantissa += mantissa & 1
        mantissa >>= 1

        comptime `1 << 53` = 1 << 53
        if mantissa >= `1 << 53`:
            mantissa = `1 << 52`
            real_exponent += 1
        mantissa &= ~(`1 << 52`)

        if unlikely(real_exponent > 2046):
            raise DeserializationError(
                "infinite value", DerErrorKind.InvalidValue
            )

        d = to_double(mantissa, real_exponent.cast[DType.uint64](), negative)

    @always_inline
    def write_float(
        self,
        out v: Float64,
        negative: Bool,
        i: UInt64,
        start_digits: CheckedPointer,
        digit_count: Int,
        exponent: Int64,
    ) raises DeserializationError:
        if unlikely(
            digit_count > 19
            and significant_digits(start_digits.p, digit_count) > 19
        ):
            return from_chars_slow[DType.float64](self.data)

        if unlikely(exponent < smallest_power or exponent > largest_power):
            if likely(exponent < smallest_power or i == 0):
                return select(negative, -0.0, 0.0)
            raise DeserializationError(
                "Invalid number: inf", DerErrorKind.InvalidValue
            )

        return self.compute_float64(exponent, i, negative)

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
        comptime padded = Self.options._assume_padded

        if self.cur() == `+`:
            raise DeserializationError(
                'Expected digit of "-", found "+"', DerErrorKind.InvalidValue
            )

        var neg = self.cur() == `-`
        var p = self.data + Int(neg)

        var start_digits = p
        var i: UInt64 = 0

        # Ingest digits 8 at a time (SWAR). `i` may wrap for very long
        # digit runs exactly as the scalar loop below would; correctness is
        # enforced afterwards via `digit_count` (integer overflow checks and
        # the >19-significant-digit float slow path). In padded mode the
        # remaining-bytes gate is unnecessary: the 8-byte read lands in the
        # NUL padding, which fails the all-digits test.
        while (padded or p.dist() >= 8) and unsafe_is_made_of_eight_digits_fast(
            p.p
        ):
            i = i * 100_000_000 + unsafe_parse_eight_digits(p.p)
            p += 8
        while parse_digit[padded](p, i):
            p += 1

        var digit_count = ptr_dist(start_digits.p, p.p)

        if unlikely(
            digit_count == 0
            or (at_or_nul[padded](start_digits) == `0` and digit_count > 1)
        ):
            raise DeserializationError(
                "Invalid number", DerErrorKind.InvalidValue
            )

        var exponent: Int64 = 0
        var is_float = False

        if at_or_nul[padded](p) == `.`:
            is_float = True
            p += 1

            var first_after_period = p
            while (
                padded or p.dist() >= 8
            ) and unsafe_is_made_of_eight_digits_fast(p.p):
                i = i * 100_000_000 + unsafe_parse_eight_digits(p.p)
                p += 8
            while parse_digit[padded](p, i):
                p += 1
            exponent = Int64(ptr_dist(p.p, first_after_period.p))
            if exponent == 0:
                raise DeserializationError(
                    "Invalid number", DerErrorKind.InvalidValue
                )
            digit_count = ptr_dist(start_digits.p, p.p)

        if is_exp_char(at_or_nul[padded](p)):
            is_float = True
            p += 1

            var neg_exp = at_or_nul[padded](p) == `-`
            p += Int(neg_exp or at_or_nul[padded](p) == `+`)

            if unlikely(is_exp_char(at_or_nul[padded](p))):
                raise DeserializationError(
                    "Invalid float: Double sign for exponent",
                    DerErrorKind.InvalidValue,
                )

            var start_exp = p
            var exp_number: Int64 = 0
            while parse_digit[padded](p, exp_number):
                p += 1

            if unlikely(p == start_exp):
                raise DeserializationError(
                    "Invalid number", DerErrorKind.InvalidValue
                )

            if unlikely(p > start_exp + 18):
                while at_or_nul[padded](start_exp) == `0`:
                    start_exp += 1
                if p > start_exp + 18:
                    exp_number = 999999999999999999

            exponent += select(neg_exp, -exp_number, exp_number)

        if is_float:
            var f = self.write_float(
                neg, i, start_digits, digit_count, exponent
            )
            self.data = p
            return RawNumber(RawNumber.FLOAT64, bitcast[DType.uint64](f))

        var longest_digit_count = select(neg, 19, 20)
        comptime SIGNED_OVERFLOW = UInt64(Int64.MAX)
        var overflow = digit_count > longest_digit_count
        if not overflow and digit_count == longest_digit_count:
            if neg:
                overflow = i > SIGNED_OVERFLOW + 1
            else:
                overflow = self.cur() != `1` or i <= SIGNED_OVERFLOW
        if unlikely(overflow):
            # R2: an integer literal outside Int64/UInt64 is a Float64, the
            # same result `List[Float64]` already produces; only ±Inf raises.
            var f = self.write_float(neg, i, start_digits, digit_count, 0)
            self.data = p
            return RawNumber(RawNumber.FLOAT64, bitcast[DType.uint64](f))

        self.data = p
        if not neg and i > SIGNED_OVERFLOW:
            return RawNumber(RawNumber.UINT64, i)
        return RawNumber(RawNumber.INT64, select(neg, ~i + 1, i))

    def expect(mut self, expected: Byte) raises DeserializationError:
        """Grammar-only token check (`:`, `,`, and the closing brackets).

        A byte that is not the one the grammar requires here is always
        malformed JSON -- there is no "value of the wrong type" reading of
        a missing separator -- so this never consults the shape test. Use
        `expect_open` for the `[`/`{` that stand at a value position.
        """
        self.skip_whitespace()
        if unlikely(self.cur() != expected):
            raise DeserializationError(
                String("Invalid JSON, Expected: ")
                + String(to_string(expected))
                + String(", Received: ")
                + String(to_string(self.cur())),
                DerErrorKind.InvalidValue,
            )
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
        if unlikely(self.cur() != expected):
            raise DeserializationError(
                String("Invalid JSON, Expected: ")
                + String(to_string(expected))
                + String(", Received: ")
                + String(to_string(self.cur())),
                self._value_shape_kind(),
            )
        self.data += 1
        self.skip_whitespace()

    @always_inline
    def _parse_integer_common[
        acc_type: DType
    ](
        mut self,
    ) raises DeserializationError -> IntegerParseResult[
        Self.origin, acc_type
    ]:
        if unlikely(self.data[] == `+`):
            raise DeserializationError(
                'Expected digit of "-", found "+"', DerErrorKind.InvalidValue
            )

        var neg = self.data[] == `-`
        var p = self.data + Int(neg)

        var start_digits = p
        var i = Scalar[acc_type](0)

        comptime MAX_VAL = Scalar[acc_type].MAX // 10
        comptime MAX_REM = Scalar[acc_type].MAX % 10

        while p.dist() > 0 and isdigit(p[]):
            var dig = (p[] - `0`).cast[acc_type]()
            if unlikely(i > MAX_VAL or (i == MAX_VAL and dig > MAX_REM)):
                # Well-formed JSON that does not fit the target width: a
                # shape problem, not a grammar one (there is no range kind).
                raise DeserializationError(
                    "integer overflow", DerErrorKind.TypeMismatch
                )
            else:
                i = i * 10 + dig
            p += 1

        var digit_count = ptr_dist(start_digits.p, p.p)

        if unlikely(digit_count == 0):
            # No digits at all: the cursor holds something that is not a
            # number. If it opens a complete value of another type this is a
            # shape mismatch; otherwise (`-a`, `+`, EOF, `tru`) it is
            # malformed JSON.
            raise DeserializationError(
                "Invalid number", self._number_shape_kind()
            )

        if unlikely(start_digits[] == `0` and digit_count > 1):
            raise DeserializationError(
                "Invalid number", DerErrorKind.InvalidValue
            )

        if unlikely(p.dist() > 0 and (p[] == `.` or is_exp_char(p[]))):
            # One class with `integer overflow`: a well-formed JSON number
            # the requested target cannot represent.
            raise DeserializationError(
                "Expected integer, found float", DerErrorKind.TypeMismatch
            )

        return i, neg, p, digit_count, start_digits

    def expect_int[
        type: DType = DType.int64
    ](mut self) raises DeserializationError -> Scalar[type]:
        self.skip_whitespace()
        comptime acc_type = _uint_type_of_width[bit_width_of[type]()]()

        var i, neg, p, _, _ = self._parse_integer_common[acc_type]()

        comptime if type.is_signed():
            self.data = p

            if neg:
                comptime MIN_ABS = (~Scalar[type].MIN.cast[acc_type]()) + 1
                if unlikely(i > MIN_ABS):
                    raise DeserializationError(
                        "integer overflow", DerErrorKind.TypeMismatch
                    )
                return (~i + 1).cast[type]()
            else:
                comptime MAX_ABS = Scalar[type].MAX.cast[acc_type]()
                if unlikely(i > MAX_ABS):
                    raise DeserializationError(
                        "integer overflow", DerErrorKind.TypeMismatch
                    )
                return i.cast[type]()
        else:
            if unlikely(neg):
                # See `integer overflow`: well-formed JSON, unrepresentable
                # in the requested target.
                raise DeserializationError(
                    "Expected unsigned integer, found negative",
                    DerErrorKind.TypeMismatch,
                )

            self.data = p
            return i.cast[type]()

    def expect_float[
        type: DType = DType.float64
    ](mut self) raises DeserializationError -> Scalar[type]:
        comptime assert (
            type.is_floating_point()
        ), "Expected float, found non-float type: " + String(type)

        self.skip_whitespace()
        var neg = self.data[] == `-`
        var p = self.data + Int(neg)

        var start_digits = p
        var i: UInt64 = 0

        # SWAR digit ingestion; see parse_number for the wrap rationale.
        while p.dist() >= 8 and unsafe_is_made_of_eight_digits_fast(p.p):
            i = i * 100_000_000 + unsafe_parse_eight_digits(p.p)
            p += 8
        while parse_digit(p, i):
            p += 1

        var digit_count = ptr_dist(start_digits.p, p.p)

        if unlikely(digit_count == 0):
            # See `_parse_integer_common`: no digits means the cursor is not
            # a number at all, so the shape test decides the kind.
            raise DeserializationError(
                "Invalid number", self._number_shape_kind()
            )

        if unlikely(start_digits[] == `0` and digit_count > 1):
            raise DeserializationError(
                "Invalid number", DerErrorKind.InvalidValue
            )

        var exponent: Int64 = 0

        if p.dist() > 0 and p[] == `.`:
            p += 1

            var first_after_period = p
            while p.dist() >= 8 and unsafe_is_made_of_eight_digits_fast(p.p):
                i = i * 100_000_000 + unsafe_parse_eight_digits(p.p)
                p += 8
            while parse_digit(p, i):
                p += 1
            exponent = Int64(ptr_dist(p.p, first_after_period.p))
            if exponent == 0:
                raise DeserializationError(
                    "Invalid number", DerErrorKind.InvalidValue
                )
            digit_count = ptr_dist(start_digits.p, p.p)

        if p.dist() > 0 and is_exp_char(p[]):
            p += 1

            var neg_exp = p[] == `-`
            p += Int(neg_exp or p[] == `+`)

            if unlikely(is_exp_char(p[])):
                raise DeserializationError(
                    "Invalid float: Double sign for exponent",
                    DerErrorKind.InvalidValue,
                )

            var start_exp = p
            var exp_number: Int64 = 0
            while parse_digit(p, exp_number):
                p += 1

            if unlikely(p == start_exp):
                raise DeserializationError(
                    "Invalid number", DerErrorKind.InvalidValue
                )

            if unlikely(p > start_exp + 18):
                while start_exp.dist() > 0 and start_exp[] == `0`:
                    start_exp += 1
                if p > start_exp + 18:
                    exp_number = 999999999999999999

            exponent += select(neg_exp, -exp_number, exp_number)

        var number_start = self.data
        var f = self.write_float(neg, i, start_digits, digit_count, exponent)

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
                r = from_chars_slow[type](number_start)
            # Check if the final (possibly re-parsed) result is infinite
            # where the original float64 wasn't.
            if unlikely(not isinf(f) and isinf(r)):
                raise DeserializationError(
                    "float overflow", DerErrorKind.InvalidValue
                )
            return r

        return f.cast[type]()

    def expect_bool(mut self) raises DeserializationError -> Bool:
        self.skip_whitespace()
        if self.data[] == `t`:
            return self.parse_true()
        elif self.data[] == `f`:
            return self.parse_false()
        # Neither `t` nor `f`: the shape test decides whether this is
        # another complete value (mismatch) or malformed JSON.
        raise DeserializationError("Expected Bool", self._value_shape_kind())

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
            raise DeserializationError(
                "Encountered EOF when expecting 'null'",
                DerErrorKind.InvalidValue,
            )
        # Safety: Safe because we checked the amount of bytes remaining
        var w = self.data.p.unsafe_bitcast[UInt32]()[]
        if w != NULL:
            raise DeserializationError(
                String("Expected 'null', received: ") + String(to_string(w)),
                DerErrorKind.InvalidValue,
            )
        self.data += 4

    @no_inline
    def _other_value_opens_here[wants_number: Bool = False](self) -> Bool:
        """True when the cursor holds a COMPLETE JSON value opener.

        The openers are `"`, `{`, `[`, `-` and the digits, plus `true`,
        `false` and `null` spelled out in full. A truncated keyword
        (`tru`, `nul`, a bare `n`) is NOT an opener: it is malformed JSON,
        not a well-formed value of the wrong type. Every read is bounded
        by `bytes_remaining()`, so this never over-reads -- and it never
        raises, so a failure branch can consult it freely.

        `wants_number=True` drops `-`/digit from the set, for the callers
        whose own type IS a number: a `-` with no digits after it (`-a`)
        is a malformed number, not "some other value".

        `@no_inline` and failure-branch-only: the success path of
        `expect_bool` on `t`, `expect_number` on a digit, `expect_string`
        on `"` and `expect_open` on its own bracket never reaches here.
        """
        var remaining = self.bytes_remaining()
        if remaining <= 0:
            return False
        var c = self.data.unsafe_get()
        if c == `"` or c == `{` or c == `[`:
            return True
        comptime if not wants_number:
            if c == `-` or (`0` <= c <= `9`):
                return True
        if c == `t`:
            return (
                remaining >= 4
                and self.data.p.unsafe_bitcast[UInt32]()[] == TRUE
            )
        if c == `f`:
            # `parse_false`'s own offset: the four bytes after the `f`.
            return (
                remaining >= 5
                and (self.data + 1).p.unsafe_bitcast[UInt32]()[] == ALSE
            )
        if c == `n`:
            return (
                remaining >= 4
                and self.data.p.unsafe_bitcast[UInt32]()[] == NULL
            )
        return False

    @no_inline
    def _value_shape_kind(self) -> DerErrorKind:
        """`TypeMismatch` when another complete value opens at the cursor,
        else `InvalidValue`. Failure branches only -- see
        `_other_value_opens_here`."""
        if self._other_value_opens_here():
            return DerErrorKind.TypeMismatch
        return DerErrorKind.InvalidValue

    @no_inline
    def _number_shape_kind(self) -> DerErrorKind:
        """`_value_shape_kind` for the number entry points, where `-` and a
        digit are the wanted opener rather than "some other type"."""
        if self._other_value_opens_here[wants_number=True]():
            return DerErrorKind.TypeMismatch
        return DerErrorKind.InvalidValue

    def expect_string(mut self, out s: String) raises DeserializationError:
        """The string entry point the reflection deserializer calls.

        Positions the cursor itself (unlike `read_string`, whose other
        callers have already validated the opening quote) and applies the
        shape rule on failure.
        """
        self.skip_whitespace()
        if unlikely(self.cur() != `"`):
            raise DeserializationError(
                "Expected a string", self._value_shape_kind()
            )
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

    @always_inline
    def _skip_digits(mut self) raises DeserializationError:
        comptime for _ in range(_DIGIT_PEEL):
            if not self.has_more() or not isdigit(self.data[]):
                return
            self.data += 1

        while self.can_load_chunk():
            var chunk = self.load_chunk()
            var is_digit = chunk.ge(`0`) & chunk.le(`9`)
            var mask = pack_into_integer(~is_digit)
            if mask == 0:
                self.data += SIMD8_WIDTH
            else:
                self.data += count_trailing_zeros(mask)
                return

        while self.has_more() and isdigit(self.data[]):
            self.data += 1

    def _validate_number[
        integer_only: Bool = False
    ](mut self) raises DeserializationError:
        """Consume one number, enforcing the JSON grammar:
        `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`.
        """
        # The shape test below reads the byte AT THE CURSOR, so it is only
        # meaningful while the cursor still sits where the value began. Once
        # a sign has been consumed we are unambiguously inside a malformed
        # number (`-true`, `-"x"`, `-{}`), never looking at another type's
        # opener -- and that is also the only way the untyped skip path
        # (`_expect_validated_bytes` -> `skip_value`, which has no requested
        # type at all) can reach here, since its dispatcher enters
        # `_validate_number` only on `-` or a digit.
        var consumed_sign = False
        if self.data[] == `-`:
            consumed_sign = True
            self.data += 1
            if unlikely(not self.has_more()):
                raise DeserializationError(
                    "Unexpected EOF in number", DerErrorKind.InvalidValue
                )

        var c = self.data[]
        if c == `0`:
            self.data += 1
            if unlikely(self.has_more() and isdigit(self.data[])):
                raise DeserializationError(
                    "Number may not have a leading zero",
                    DerErrorKind.InvalidValue,
                )
        elif likely(isdigit(c)):
            self._skip_digits()
        else:
            # Same split as `_parse_integer_common`: nothing numeric at the
            # cursor, so the shape test decides the kind -- but only while
            # the cursor is unmoved (see `consumed_sign` above). That keeps
            # `expect_float_bytes` on `"abc"` a `TypeMismatch` while `-true`
            # stays the malformed number it is.
            raise DeserializationError(
                "Invalid number, expected a digit",
                DerErrorKind.InvalidValue if consumed_sign else self._number_shape_kind(),
            )

        comptime if integer_only:
            if unlikely(
                self.has_more()
                and (self.data[] == `.` or is_exp_char(self.data[]))
            ):
                # See `_parse_integer_common`: a well-formed number the
                # requested (integer) target cannot represent.
                raise DeserializationError(
                    "Expected an integer, received a float",
                    DerErrorKind.TypeMismatch,
                )
            return

        if self.has_more() and self.data[] == `.`:
            self.data += 1
            if unlikely(not self.has_more() or not isdigit(self.data[])):
                raise DeserializationError(
                    "Expected a digit after the decimal point",
                    DerErrorKind.InvalidValue,
                )
            self._skip_digits()

        if self.has_more() and is_exp_char(self.data[]):
            self.data += 1
            if self.has_more() and (self.data[] == `+` or self.data[] == `-`):
                self.data += 1
            if unlikely(not self.has_more() or not isdigit(self.data[])):
                raise DeserializationError(
                    "Expected a digit in the exponent",
                    DerErrorKind.InvalidValue,
                )
            self._skip_digits()

    @always_inline
    def _expect_key_and_colon(mut self) raises DeserializationError:
        """Consume `"key" :` at the head of an object member."""
        self._skip_ws()
        if unlikely(not self.has_more() or self.data[] != `"`):
            raise DeserializationError(
                "Expected an object key string", DerErrorKind.InvalidValue
            )
        _ = self.expect_string_bytes()
        self._skip_ws()
        if unlikely(not self.has_more() or self.data[] != `:`):
            raise DeserializationError(
                "Expected ':' after an object key", DerErrorKind.InvalidValue
            )
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

        Iterative rather than recursive so that nesting depth costs heap, not
        stack. `_closers` holds the closing byte expected at each open level,
        which is what makes `{"a": [1,2}` an error rather than a shrug.
        """
        self._skip_ws()
        var start = self.data
        var closers = List[Byte](capacity=16)

        while True:
            self._skip_ws()
            if unlikely(not self.has_more()):
                raise DeserializationError(
                    "Unexpected EOF while parsing a value",
                    DerErrorKind.InvalidValue,
                )

            # --- consume one value ------------------------------------------
            var b = self.data[]
            if b == `"`:
                _ = self.expect_string_bytes()
            elif b == `-` or isdigit(b):
                self._validate_number()
            elif b == `t` or b == `f` or b == `n`:
                self._expect_literal()
            elif b == `{`:
                self.data += 1
                self._skip_ws()
                if unlikely(not self.has_more()):
                    raise DeserializationError(
                        "Unexpected EOF while parsing an object",
                        DerErrorKind.InvalidValue,
                    )
                if self.data[] == `}`:
                    self.data += 1
                else:
                    closers.append(`}`)
                    self._expect_key_and_colon()
                    continue
            elif b == `[`:
                self.data += 1
                self._skip_ws()
                if unlikely(not self.has_more()):
                    raise DeserializationError(
                        "Unexpected EOF while parsing an array",
                        DerErrorKind.InvalidValue,
                    )
                if self.data[] == `]`:
                    self.data += 1
                else:
                    closers.append(`]`)
                    continue
            else:
                raise DeserializationError(
                    String("Invalid JSON value: ") + String(to_string(b)),
                    DerErrorKind.InvalidValue,
                )

            # --- a value completed: close out every container it finished ----
            while True:
                if len(closers) == 0:
                    return Span(
                        unsafe_ptr=start.p,
                        length=ptr_dist(start.p, self.data.p),
                    )

                self._skip_ws()
                if unlikely(not self.has_more()):
                    raise DeserializationError(
                        "Unexpected EOF while parsing a structure",
                        DerErrorKind.InvalidValue,
                    )

                var closer = closers[len(closers) - 1]
                var c = self.data[]
                if c == closer:
                    self.data += 1
                    _ = closers.pop()
                    continue

                if unlikely(c != `,`):
                    raise DeserializationError(
                        String("Invalid JSON, Expected: ")
                        + String(to_string(closer))
                        + String(" or ',', Received: ")
                        + String(to_string(c)),
                        DerErrorKind.InvalidValue,
                    )

                self.data += 1
                comptime if (
                    StrictOptions.ALLOW_TRAILING_COMMA
                    in Self.options.strict_mode
                ):
                    self._skip_ws()
                    if self.has_more() and self.data[] == closer:
                        self.data += 1
                        _ = closers.pop()
                        continue

                if closer == `}`:
                    self._expect_key_and_colon()
                break

    @always_inline
    def _expect_escape_body(mut self) raises DeserializationError:
        """Positioned on the byte after a backslash: validate and consume the
        escape body. Escape-byte legality and the four `\\u` hex digits are
        checked here so captured spans carry the same guarantee as the eager
        path's `acceptable_escapes` contract; surrogate pairing stays deferred
        to materialization.
        """
        if unlikely(not self.has_more()):
            raise DeserializationError(
                "Unexpected EOF", DerErrorKind.InvalidValue
            )
        var esc = self.data[]
        if unlikely(esc not in acceptable_escapes):
            raise DeserializationError(
                String("Invalid escape sequence: ")
                + String(to_string(self.data[-1]))
                + String(to_string(esc)),
                DerErrorKind.InvalidValue,
            )
        self.data += 1
        if esc == `u`:
            if unlikely(
                ptr_dist(self.data.p, self.data.end) < 4
                or not is_hex_digits(self.data.p.unsafe_load[width=4]())
            ):
                raise DeserializationError(
                    "Invalid hex digit encountered", DerErrorKind.InvalidValue
                )
            self.data += 4

    def expect_string_bytes(
        mut self,
    ) raises DeserializationError -> Span[Byte, Self.origin]:
        var start = self.data
        self.data += 1

        while self.can_load_chunk():
            var block = StringBlock.find(self.data)
            if block.has_quote_first():
                self.data += block.quote_index()
                self.data += 1
                var res = Span(
                    unsafe_ptr=start.p, length=ptr_dist(start.p, self.data.p)
                )
                return res

            if unlikely(block.has_unescaped()):
                raise DeserializationError(
                    "Control characters must be escaped",
                    DerErrorKind.InvalidValue,
                )

            if not block.has_backslash():
                self.data += SIMD8_WIDTH
                continue

            self.data += block.bs_index()
            # Found backslash
            self.data += 1
            self._expect_escape_body()

        while self.has_more():
            var c = self.data[]
            if c == `"`:
                self.data += 1
                var res = Span(
                    unsafe_ptr=start.p, length=ptr_dist(start.p, self.data.p)
                )
                return res
            elif c == `\\`:
                self.data += 1
                self._expect_escape_body()
            elif c < 0x20:
                raise DeserializationError(
                    "Control characters must be escaped",
                    DerErrorKind.InvalidValue,
                )
            else:
                self.data += 1

        raise DeserializationError("Unexpected EOF", DerErrorKind.InvalidValue)

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
            raise DeserializationError(
                "Invalid JSON, Expected an object", self._value_shape_kind()
            )
        return self._expect_validated_bytes()

    def expect_array_bytes(
        mut self,
    ) raises DeserializationError -> Span[Byte, Self.origin]:
        self.skip_whitespace()
        if unlikely(not self.has_more() or self.data[] != `[`):
            raise DeserializationError(
                "Invalid JSON, Expected an array", self._value_shape_kind()
            )
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
