from emberjson.utils import (
    CheckedPointer,
    BytePtr,
    ByteView,
    to_string,
    ByteVec,
    is_space,
    select,
    lut,
)
from std.math import isinf
from emberjson.json import JSON
from emberjson.simd import SIMD8_WIDTH, SIMD8xT
from emberjson.array import Array
from emberjson.object import Object
from emberjson.value import Value
from std.bit import count_trailing_zeros
from std.memory import UnsafePointer, memset
from std.sys.intrinsics import unlikely, likely
from std.collections import InlineArray
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
    ptr_dist,
    significant_digits,
    unsafe_is_made_of_eight_digits_fast,
    unsafe_parse_eight_digits,
    largest_power,
    is_exp_char,
    pack_into_integer,
    isdigit,
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
    `\n`,
    `\r`,
    `\t`,
    `-`,
    `+`,
    `0`,
    `9`,
    `.`,
    ` `,
    `1`,
    `E`,
    `e`,
)
from std.utils.numerics import FPUtils


#######################################################
# Certain parts inspired/taken from SonicCPP and simdjon
# https://github.com/bytedance/sonic-cpp
# https://github.com/simdjson/simdjson
#######################################################


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
        ignore_unicode: Do not decode escaped unicode characters for a slight increase in performance.
        strict_mode: Flags to control strictness of parsing.
    """

    var ignore_unicode: Bool
    var strict_mode: StrictOptions

    def __init__(
        out self,
        *,
        ignore_unicode: Bool = False,
        strict_mode: StrictOptions = StrictOptions.STRICT,
    ):
        self.ignore_unicode = ignore_unicode
        self.strict_mode = strict_mode


comptime IntegerParseResult[origin: ImmutOrigin, acc_type: DType] = Tuple[
    Scalar[acc_type], Bool, CheckedPointer[origin], Int, CheckedPointer[origin]
]


struct Parser[origin: ImmutOrigin, options: ParseOptions = ParseOptions()]:
    var data: CheckedPointer[Self.origin]
    var size: Int

    @implicit
    def __init__(out self: Parser[Self.origin, Self.options],ref[Self.origin] s: String):
        self = {StringSlice(s)}

    @implicit
    def __init__(
        out self: Parser[StaticConstantOrigin, Self.options], s: StringLiteral
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
        ptr: UnsafePointer[Byte, origin=Self.origin],
        length: Int,
    ):
        self.data = CheckedPointer(ptr, ptr, ptr + length)
        self.size = length

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
        return self.data.load_chunk()

    @always_inline
    def can_load_chunk(self) -> Bool:
        return self.bytes_remaining() >= SIMD8_WIDTH

    @always_inline
    def pos(self) -> Int:
        return self.size - (self.size - self.data.dist())

    @always_inline
    def peek(self) raises -> Byte:
        return self.data[]

    def parse(mut self, out json: Value) raises:
        self.skip_whitespace()
        json = self.parse_value()

        self.skip_whitespace()
        if unlikely(self.has_more()):
            raise Error(
                "Invalid json, expected end of input, recieved: ",
                self.remaining(),
            )

    def parse_array(mut self, out arr: Array) raises:
        self.data += 1
        self.skip_whitespace()
        arr = Array()

        if unlikely(self.data[] != `]`):
            while True:
                arr.append(self.parse_value())
                self.skip_whitespace()
                var has_comma = False
                if self.data[] == `,`:
                    self.data += 1
                    has_comma = True
                    self.skip_whitespace()
                if self.data[] == `]`:
                    comptime if (
                        StrictOptions.ALLOW_TRAILING_COMMA
                        not in Self.options.strict_mode
                    ):
                        if has_comma:
                            raise Error("Illegal trailing comma")
                    break
                elif unlikely(not has_comma):
                    raise Error("Expected ',' or ']'")
                if unlikely(not self.has_more()):
                    raise Error("Expected ']'")

        self.data += 1
        self.skip_whitespace()

    def parse_object(mut self, out obj: Object) raises:
        obj = Object()
        self.data += 1
        self.skip_whitespace()

        if unlikely(self.data[] != `}`):
            while True:
                if unlikely(self.data[] != `"`):
                    raise Error("Invalid identifier")
                var ident = self.read_string()
                self.skip_whitespace()
                if unlikely(self.data[] != `:`):
                    raise Error("Invalid identifier : ", self.remaining())
                self.data += 1
                var v = self.parse_value()
                self.skip_whitespace()
                var has_comma = False
                if self.data[] == `,`:
                    self.data += 1
                    self.skip_whitespace()
                    has_comma = True

                # In case of duplicate keys, first one wins
                comptime if (
                    not StrictOptions.ALLOW_DUPLICATE_KEYS
                    in Self.options.strict_mode
                ):
                    if ident in obj:
                        raise Error("Duplicate key: ", ident)

                obj._add_unchecked(ident^, v^)

                if self.data[] == `}`:
                    comptime if (
                        not StrictOptions.ALLOW_TRAILING_COMMA
                        in Self.options.strict_mode
                    ):
                        if has_comma:
                            raise Error("Illegal trailing comma")
                    break
                elif not has_comma:
                    raise Error("Expected ',' or '}'")
                if unlikely(self.bytes_remaining() == 0):
                    raise Error("Expected '}'")

        self.data += 1
        self.skip_whitespace()

    @always_inline
    def parse_true(mut self) raises -> Bool:
        if unlikely(self.bytes_remaining() < 4):
            raise Error('Encountered EOF when expecting "true"')
        # Safety: Safe because we checked the amount of bytes remaining
        var w = self.data.p.bitcast[UInt32]()[]
        if w != TRUE:
            raise Error("Expected 'true', received: ", to_string(w))
        self.data += 4
        return True

    @always_inline
    def parse_false(mut self) raises -> Bool:
        self.data += 1
        if unlikely(self.bytes_remaining() < 4):
            raise Error('Encountered EOF when expecting "false"')
        # Safety: Safe because we checked the amount of bytes remaining
        var w = self.data.p.bitcast[UInt32]()[0]
        if w != ALSE:
            raise Error("Expected 'false', received: f", to_string(w))
        self.data += 4
        return False

    @always_inline
    def parse_null(mut self) raises -> Null:
        self.expect_null()
        return Null()

    def parse_value(mut self, out v: Value) raises:
        self.skip_whitespace()
        var b = self.data[]
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
            raise Error("Invalid json value")

    def find(mut self, start: CheckedPointer, out s: String) raises:
        var found_escaped = False
        while True:
            var block = StringBlock.find(self.data)
            if block.has_quote_first():
                self.data += block.quote_index()
                return copy_to_string[Self.options.ignore_unicode](
                    start.p, self.data.p, found_escaped
                )
            elif unlikely(self.data.p >= self.data.end):
                # We got EOF before finding the end quote, so obviously this
                # input is malformed
                raise Error("Unexpected EOF")

            if unlikely(block.has_unescaped()):
                raise Error(
                    "Control characters must be escaped: ",
                    to_string(self.load_chunk()),
                    " : ",
                    String(block.unescaped_index()),
                )
            if not block.has_backslash():
                self.data += SIMD8_WIDTH
                continue
            self.data += block.bs_index()

            # We found a backslash, so we need to unescape
            found_escaped = True
            while True:
                self.data += 1
                if self.data[] == `u`:
                    self.data += 1
                    break
                else:
                    if unlikely(self.data[] not in acceptable_escapes):
                        raise Error(
                            "Invalid escape sequence: ",
                            to_string(self.data[-1]),
                            to_string(self.data[]),
                        )
                self.data += 1
                if self.data[] != `\\`:
                    break

    def read_serial(mut self, start: CheckedPointer, out s: String) raises:
        var found_escaped = False
        while likely(self.has_more()):
            if self.data[] == `"`:
                s = copy_to_string[Self.options.ignore_unicode](
                    start.p, self.data.p, found_escaped
                )
                self.data += 1
                return
            if self.data[] == `\\`:
                self.data += 1
                if unlikely(self.data[] not in acceptable_escapes):
                    raise Error(
                        "Invalid escape sequence: ",
                        to_string(self.data[-1]),
                        to_string(self.data[]),
                    )
                # We found a backslash, so we need to unescape
                found_escaped = True
            comptime control_chars = ByteVec[4](`\n`, `\t`, `\r`, `\r`)
            if unlikely(self.data[] in control_chars):
                raise Error(
                    "Control characters must be escaped: ",
                    String(self.data[]),
                )
            self.data += 1

        raise Error("Invalid String")

    def read_string(mut self, out s: String) raises:
        self.data += 1
        var start = self.data
        # compile time interpreter is incompatible with the SIMD accelerated
        # path, so fallback to the serial implementation
        if self.can_load_chunk():
            s = self.find(start)
            self.data += 1
        else:
            s = self.read_serial(start)

    @always_inline
    def skip_whitespace(mut self) raises:
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
    ) raises:
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
            second_product = full_multiplication(
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
            raise Error("infinite value")

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
    ) raises:
        if unlikely(
            digit_count > 19
            and significant_digits(start_digits.p, digit_count) > 19
        ):
            return from_chars_slow[DType.float64](self.data)

        if unlikely(exponent < smallest_power or exponent > largest_power):
            if likely(exponent < smallest_power or i == 0):
                return select(negative, -0.0, 0.0)
            raise Error("Invalid number: inf")

        return self.compute_float64(exponent, i, negative)

    @always_inline
    def parse_number(mut self, out v: Value) raises:
        if self.data[] == `+`:
            raise Error('Expected digit of "-", found "+"')

        var neg = self.data[] == `-`
        var p = self.data + Int(neg)

        var start_digits = p
        var i: UInt64 = 0

        while parse_digit(p, i):
            p += 1

        var digit_count = ptr_dist(start_digits.p, p.p)

        if unlikely(
            digit_count == 0 or (start_digits[] == `0` and digit_count > 1)
        ):
            raise Error("Invalid number")

        var exponent: Int64 = 0
        var is_float = False

        if p.dist() > 0 and p[] == `.`:
            is_float = True
            p += 1

            var first_after_period = p
            if p.dist() >= 8 and unsafe_is_made_of_eight_digits_fast(p.p):
                i = i * 100_000_000 + unsafe_parse_eight_digits(p.p)
                p += 8
            while parse_digit(p, i):
                p += 1
            exponent = Int64(ptr_dist(p.p, first_after_period.p))
            if exponent == 0:
                raise Error("Invalid number")
            digit_count = ptr_dist(start_digits.p, p.p)

        if p.dist() > 0 and is_exp_char(p[]):
            is_float = True
            p += 1

            var neg_exp = p[] == `-`
            p += Int(neg_exp or p[] == `+`)

            if unlikely(is_exp_char(p[])):
                raise Error("Invalid float: Double sign for exponent")

            var start_exp = p
            var exp_number: Int64 = 0
            while parse_digit(p, exp_number):
                p += 1

            if unlikely(p == start_exp):
                raise Error("Invalid number")

            if unlikely(p > start_exp + 18):
                while start_exp.dist() > 0 and start_exp[] == `0`:
                    start_exp += 1
                if p > start_exp + 18:
                    exp_number = 999999999999999999

            exponent += select(neg_exp, -exp_number, exp_number)

        if is_float:
            v = self.write_float(neg, i, start_digits, digit_count, exponent)
            self.data = p
            return

        var longest_digit_count = select(neg, 19, 20)
        comptime SIGNED_OVERFLOW = UInt64(Int64.MAX)
        if digit_count > longest_digit_count:
            raise Error("integer overflow")
        if digit_count == longest_digit_count:
            if neg:
                if unlikely(i > SIGNED_OVERFLOW + 1):
                    raise Error("integer overflow")
                self.data = p
                return Int64(~i + 1)
            elif unlikely(self.data[0] != `1` or i <= SIGNED_OVERFLOW):
                raise Error("integer overflow")

        self.data = p
        if i > SIGNED_OVERFLOW:
            return i
        return select(neg, Int64(~i + 1), Int64(i))

    def expect(mut self, expected: Byte) raises:
        self.skip_whitespace()
        if unlikely(self.data[] != expected):
            raise Error(
                "Invalid JSON, Expected: ",
                to_string(expected),
                ", Received: ",
                to_string(self.data[]),
            )
        self.data += 1
        self.skip_whitespace()

    @always_inline
    def _parse_integer_common[
        acc_type: DType
    ](mut self,) raises -> IntegerParseResult[Self.origin, acc_type]:
        if unlikely(self.data[] == `+`):
            raise Error('Expected digit of "-", found "+"')

        var neg = self.data[] == `-`
        var p = self.data + Int(neg)

        var start_digits = p
        var i = Scalar[acc_type](0)

        comptime MAX_VAL = Scalar[acc_type].MAX // 10
        comptime MAX_REM = Scalar[acc_type].MAX % 10

        while p.dist() > 0 and isdigit(p[]):
            var dig = (p[] - `0`).cast[acc_type]()
            if unlikely(i > MAX_VAL or (i == MAX_VAL and dig > MAX_REM)):
                raise Error("integer overflow")
            else:
                i = i * 10 + dig
            p += 1

        var digit_count = ptr_dist(start_digits.p, p.p)

        if unlikely(
            digit_count == 0 or (start_digits[] == `0` and digit_count > 1)
        ):
            raise Error("Invalid number")

        if unlikely(p.dist() > 0 and (p[] == `.` or is_exp_char(p[]))):
            raise Error("Expected integer, found float")

        return i, neg, p, digit_count, start_digits

    def expect_int[type: DType = DType.int64](mut self) raises -> Scalar[type]:
        comptime acc_type = _uint_type_of_width[bit_width_of[type]()]()

        var i, neg, p, _, _ = self._parse_integer_common[acc_type]()

        comptime if type.is_signed():
            self.data = p

            if neg:
                comptime MIN_ABS = (~Scalar[type].MIN.cast[acc_type]()) + 1
                if unlikely(i > MIN_ABS):
                    raise Error("integer overflow")
                return (~i + 1).cast[type]()
            else:
                comptime MAX_ABS = Scalar[type].MAX.cast[acc_type]()
                if unlikely(i > MAX_ABS):
                    raise Error("integer overflow")
                return i.cast[type]()
        else:
            if unlikely(neg):
                raise Error("Expected unsigned integer, found negative")

            self.data = p
            return i.cast[type]()

    def expect_float[
        type: DType = DType.float64
    ](mut self) raises -> Scalar[type]:
        comptime assert (
            type.is_floating_point()
        ), "Expected float, found non-float type: " + String(type)

        var neg = self.data[] == `-`
        var p = self.data + Int(neg or self.data[] == `+`)

        var start_digits = p
        var i: UInt64 = 0

        while parse_digit(p, i):
            p += 1

        var digit_count = ptr_dist(start_digits.p, p.p)

        if unlikely(
            digit_count == 0 or (start_digits[] == `0` and digit_count > 1)
        ):
            raise Error("Invalid number")

        var exponent: Int64 = 0

        if p.dist() > 0 and p[] == `.`:
            p += 1

            var first_after_period = p
            if p.dist() >= 8 and unsafe_is_made_of_eight_digits_fast(p.p):
                i = i * 100_000_000 + unsafe_parse_eight_digits(p.p)
                p += 8
            while parse_digit(p, i):
                p += 1
            exponent = Int64(ptr_dist(p.p, first_after_period.p))
            if exponent == 0:
                raise Error("Invalid number")
            digit_count = ptr_dist(start_digits.p, p.p)

        if p.dist() > 0 and is_exp_char(p[]):
            p += 1

            var neg_exp = p[] == `-`
            p += Int(neg_exp or p[] == `+`)

            if unlikely(is_exp_char(p[])):
                raise Error("Invalid float: Double sign for exponent")

            var start_exp = p
            var exp_number: Int64 = 0
            while parse_digit(p, exp_number):
                p += 1

            if unlikely(p == start_exp):
                raise Error("Invalid number")

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
            var casted = f.cast[type]()
            # Check if casting caused infinity where original wasn't
            if unlikely(not isinf(f) and isinf(casted)):
                raise Error("float overflow")
            # Guard against double-rounding: if the float64 result lands exactly
            # on a float32/float16 midpoint, the cast may choose the wrong
            # neighbour. Re-parse with correctly-rounded big-decimal arithmetic.
            comptime half_ulp_pos = 52 - FPUtils[type].mantissa_width() - 1
            comptime midpoint_bit = UInt64(1) << UInt64(half_ulp_pos)
            comptime midpoint_mask = (UInt64(1) << UInt64(half_ulp_pos + 1)) - 1
            if unlikely(
                (bitcast[DType.uint64](f) & midpoint_mask) == midpoint_bit
            ):
                return from_chars_slow[type](number_start)
            return casted

        return f.cast[type]()

    def expect_bool(mut self) raises -> Bool:
        if self.data[] == `t`:
            return self.parse_true()
        elif self.data[] == `f`:
            return self.parse_false()
        raise Error("Expected Bool")

    def expect_null(mut self) raises:
        if unlikely(self.bytes_remaining() < 4):
            raise Error("Encountered EOF when expecting 'null'")
        # Safety: Safe because we checked the amount of bytes remaining
        var w = self.data.p.bitcast[UInt32]()[0]
        if w != NULL:
            raise Error("Expected 'null', received: ", to_string(w))
        self.data += 4

    def expect_value_bytes(mut self) raises -> Span[Byte, Self.origin]:
        self.skip_whitespace()
        var b = self.data[]
        if b == `"`:
            return self.expect_string_bytes()
        elif b == `{`:
            return self.expect_object_bytes()
        elif b == `[`:
            return self.expect_array_bytes()
        elif b == `t` or b == `n`:
            var s = Span(ptr=self.data.p, length=4)
            self.data += 4
            return s
        elif b == `f`:
            var s = Span(ptr=self.data.p, length=5)
            self.data += 5
            return s
        elif is_numerical_component(b):
            return self.expect_float_bytes()
        else:
            raise Error("Invalid json value to skip")

    def skip_value(mut self) raises:
        _ = self.expect_value_bytes()

    def expect_string_bytes(mut self) raises -> Span[Byte, Self.origin]:
        var start = self.data
        self.data += 1

        while self.can_load_chunk():
            var block = StringBlock.find(self.data)
            if block.has_quote_first():
                self.data += block.quote_index()
                self.data += 1
                var res = Span(
                    ptr=start.p, length=ptr_dist(start.p, self.data.p)
                )
                return res

            if unlikely(block.has_unescaped()):
                raise Error("Control characters must be escaped")

            if not block.has_backslash():
                self.data += SIMD8_WIDTH
                continue

            self.data += block.bs_index()
            # Found backslash
            self.data += 1
            if self.data[] == `u`:
                self.data += 5
            else:
                self.data += 1

        while self.has_more():
            var c = self.data[]
            if c == `"`:
                self.data += 1
                var res = Span(
                    ptr=start.p, length=ptr_dist(start.p, self.data.p)
                )
                return res
            elif c == `\\`:
                self.data += 1
                if unlikely(not self.has_more()):
                    raise Error("Unexpected EOF")

                var esc = self.data[]
                if esc == `u`:
                    self.data += 5
                else:
                    self.data += 1
            elif c < 0x20:
                raise Error("Control characters must be escaped")
            else:
                self.data += 1

        raise Error("Unexpected EOF")

    def _expect_structural_bytes[
        open: Byte, close: Byte
    ](mut self) raises -> Span[Byte, Self.origin]:
        var start = self.data
        if unlikely(self.data[] != open):
            raise Error(
                "Invalid JSON, Expected: ",
                to_string(open),
                ", Received: ",
                to_string(self.data[]),
            )
        self.data += 1
        var depth = 1

        while self.has_more():
            while (
                self.can_load_chunk()
            ):
                var chunk = self.load_chunk()
                var relevant = chunk.eq(`"`) | chunk.eq(open) | chunk.eq(close)
                var mask = pack_into_integer(relevant)

                if mask == 0:
                    self.data += SIMD8_WIDTH
                else:
                    var broke = False
                    while mask != 0:
                        var offset = count_trailing_zeros(mask)
                        var c = self.data[Int(offset)]
                        if c == `"`:
                            self.data += Int(offset)
                            _ = self.expect_string_bytes()
                            broke = True
                            break
                        elif c == open:
                            depth += 1
                        elif c == close:
                            depth -= 1
                            if depth == 0:
                                self.data += Int(offset) + 1
                                return Span(
                                    ptr=start.p,
                                    length=ptr_dist(start.p, self.data.p),
                                )
                        mask &= mask - 1

                    if not broke:
                        self.data += SIMD8_WIDTH
                    else:
                        break

            if unlikely(not self.has_more()):
                break

            var c = self.data[]
            if c == `"`:
                _ = self.expect_string_bytes()
            elif c == open:
                depth += 1
                self.data += 1
            elif c == close:
                depth -= 1
                self.data += 1
                if depth == 0:
                    return Span(
                        ptr=start.p, length=ptr_dist(start.p, self.data.p)
                    )
            else:
                self.data += 1

        raise Error("Unexpected EOF while parsing structure")

    def expect_int_bytes(mut self) raises -> Span[Byte, Self.origin]:
        var start = self.data
        if self.data[] == `-`:  # '-'
            self.data += 1

        while self.can_load_chunk():
            var chunk = self.load_chunk()
            var is_digit = chunk.ge(`0`) & chunk.le(`9`)  # '0' to '9'
            var invalid = ~is_digit
            var mask = pack_into_integer(invalid)
            if mask == 0:
                self.data += SIMD8_WIDTH
            else:
                var offset = count_trailing_zeros(mask)
                self.data += offset
                return Span(ptr=start.p, length=ptr_dist(start.p, self.data.p))

        while self.has_more():
            var c = self.data[]
            if not isdigit(c):
                break
            self.data += 1

        return Span(ptr=start.p, length=ptr_dist(start.p, self.data.p))

    def expect_float_bytes(mut self) raises -> Span[Byte, Self.origin]:
        var start = self.data
        if self.data[] == `-`:  # '-'
            self.data += 1

        while self.can_load_chunk():
            var chunk = self.load_chunk()
            var is_digit = chunk.ge(`0`) & chunk.le(`9`)
            var is_dot = chunk.eq(`.`)  # '.'
            var is_e = chunk.eq(`e`) | chunk.eq(`E`)  # 'e', 'E'
            var is_sign = chunk.eq(`+`) | chunk.eq(`-`)  # '+', '-'
            var valid = is_digit | is_dot | is_e | is_sign
            var invalid = ~valid
            var mask = pack_into_integer(invalid)
            if mask == 0:
                self.data += SIMD8_WIDTH
            else:
                var offset = count_trailing_zeros(mask)
                self.data += offset
                return Span(ptr=start.p, length=ptr_dist(start.p, self.data.p))

        while self.has_more():
            var c = self.data[]
            var valid_char = (
                isdigit(c)
                or c == `.`
                or c == `e`
                or c == `E`
                or c == `+`
                or c == `-`
            )
            if not valid_char:
                break
            self.data += 1

        return Span(ptr=start.p, length=ptr_dist(start.p, self.data.p))

    def expect_object_bytes(mut self) raises -> Span[Byte, Self.origin]:
        return self._expect_structural_bytes[`{`, `}`]()

    def expect_array_bytes(mut self) raises -> Span[Byte, Self.origin]:
        return self._expect_structural_bytes[`[`, `]`]()


def minify(s: String, out out_str: String) raises:
    """Removes whitespace characters from JSON string.

    Returns:
        A copy of the input string with all whitespace characters removed.
    """
    var s_len = s.byte_length()
    out_str = String(capacity=s_len)

    var ptr = BytePtr[origin_of(s)](s.unsafe_ptr())
    var end = ptr + s_len

    @always_inline
    @parameter
    def _load_chunk(
        p: type_of(ptr), cond: Bool
    ) -> SIMD[DType.uint8, SIMD8_WIDTH]:
        if cond:
            return ptr.load[width=SIMD8_WIDTH]()
        else:
            var chunk = SIMD[DType.uint8, SIMD8_WIDTH](` `)

            for i in range(Int(end) - Int(ptr)):
                chunk[i] = ptr[i]
            return chunk

    while ptr < end:
        var is_block_iter = likely(ptr + SIMD8_WIDTH < end)
        var chunk = _load_chunk(ptr, is_block_iter)

        var bits = get_non_space_bits(chunk)
        while bits == 0 and ptr < end:
            ptr += SIMD8_WIDTH
            chunk = ptr.load[width=SIMD8_WIDTH]()
            bits = get_non_space_bits(chunk)

        var trailing = count_trailing_zeros(bits)
        ptr += trailing

        if ptr[] == `"`:
            var p = ptr
            p += 1
            var block = StringBlock.find(p)
            var length = 1

            while not block.has_quote_first() and p < end:
                if unlikely(block.has_unescaped()):
                    raise "Invalid JSON, unescaped control character"
                elif block.has_backslash():
                    var ind = Int(block.bs_index()) + 2
                    length += ind
                    p += ind
                else:
                    var ind = SIMD8_WIDTH if is_block_iter else (
                        Int(end) - Int(ptr)
                    )
                    length += ind
                    p += ind
                block = StringBlock.find(p)

            length += Int(block.quote_index() + 1)
            out_str += StringSlice[ptr.origin](ptr=ptr, length=length)
            ptr += length

        else:
            var chunk = _load_chunk(ptr, is_block_iter)

            var quotes = pack_into_integer(chunk.eq(`"`))
            var valid_bits = count_trailing_zeros(~get_non_space_bits(chunk))
            if quotes != 0:
                valid_bits = min(valid_bits, count_trailing_zeros(quotes))
            out_str += StringSlice[ptr.origin](ptr=ptr, length=Int(valid_bits))
            ptr += valid_bits
