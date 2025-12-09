from .utils import (
    CheckedPointer,
    BytePtr,
    ByteView,
    to_string,
    ByteVec,
    is_space,
    select,
    lut,
)
from .json import JSON
from .simd import SIMD8_WIDTH, SIMD8xT
from .array import Array
from .object import Object
from .value import Value
from bit import count_trailing_zeros
from memory import UnsafePointer, memset
from sys.intrinsics import unlikely, likely
from collections import InlineArray
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
)
from memory.unsafe import bitcast
from bit import count_leading_zeros
from .slow_float_parse import from_chars_slow
from sys.compile import is_compile_time
from .tables import POWER_OF_TEN, full_multiplication, POWER_OF_FIVE_128
from .constants import (
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
    `.`,
    ` `,
    `1`,
)

#######################################################
# Certain parts inspired/taken from SonicCPP and simdjon
# https://github.com/bytedance/sonic-cpp
# https://github.com/simdjson/simdjson
#######################################################


struct ParseOptions(Copyable, Movable):
    """JSON parsing options.

    Fields:
        ignore_unicode: Do not decode escaped unicode characters for a slight increase in performance.
    """

    var ignore_unicode: Bool

    fn __init__(out self, *, ignore_unicode: Bool = False):
        self.ignore_unicode = ignore_unicode


struct Parser[origin: ImmutOrigin, options: ParseOptions = ParseOptions()]:
    var data: CheckedPointer[Self.origin]
    var size: Int

    fn __init__(s: String, out self: Parser[origin_of(s), Self.options]):
        self = type_of(self)(ptr=s.unsafe_ptr(), length=s.byte_length())

    fn __init__(out self, s: StringSlice[Self.origin]):
        self = Self(ptr=s.unsafe_ptr(), length=s.byte_length())

    fn __init__(out self, s: ByteView[Self.origin]):
        self = Self(ptr=s.unsafe_ptr(), length=len(s))

    fn __init__(
        out self,
        *,
        ptr: UnsafePointer[Byte, origin = Self.origin],
        length: Int,
    ):
        self.data = CheckedPointer(ptr, ptr, ptr + length)
        self.size = length

    @always_inline
    fn bytes_remaining(self) -> Int:
        return self.data.dist()

    @always_inline
    fn has_more(self) -> Bool:
        return self.bytes_remaining() > 0

    @always_inline
    fn remaining(self) -> String:
        """Used for debug purposes.

        Returns:
            A string containing the remaining unprocessed data from parser input.
        """
        try:
            return copy_to_string[True](self.data.p, self.data.end)
        except:
            return ""

    @always_inline
    fn load_chunk(self) -> SIMD8xT:
        return self.data.load_chunk()

    @always_inline
    fn can_load_chunk(self) -> Bool:
        return self.bytes_remaining() >= SIMD8_WIDTH

    @always_inline
    fn pos(self) -> Int:
        return self.size - (self.size - self.data.dist())

    fn parse(mut self, out json: JSON) raises:
        self.skip_whitespace()
        var b = self.data[]
        if b == `[`:
            json = self.parse_array()
        elif b == `{`:
            json = self.parse_object()
        else:
            raise Error("Invalid json")

        self.skip_whitespace()
        if unlikely(self.has_more()):
            raise Error(
                "Invalid json, expected end of input, recieved: ",
                self.remaining(),
            )

    fn parse_array(mut self, out arr: Array) raises:
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
                    if has_comma:
                        raise Error("Illegal trailing comma")
                    break
                if unlikely(not self.has_more()):
                    raise Error("Expected ']'")

        self.data += 1
        self.skip_whitespace()

    fn parse_object(mut self, out obj: Object) raises:
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
                obj[ident^] = v^
                if self.data[] == `}`:
                    if has_comma:
                        raise Error("Illegal trailing comma")
                    break
                if unlikely(self.bytes_remaining() == 0):
                    raise Error("Expected '}'")

        self.data += 1
        self.skip_whitespace()

    fn parse_value(mut self, out v: Value) raises:
        self.skip_whitespace()
        var b = self.data[]
        # Handle string
        if b == `"`:
            v = self.read_string()

        # Handle "true" atom
        elif b == `t`:
            if unlikely(self.bytes_remaining() < 3):
                raise Error('Encountered EOF when expecting "true"')
            # Safety: Safe because we checked the amount of bytes remaining
            var w = self.data.p.bitcast[UInt32]()[0]
            if w != TRUE:
                raise Error("Expected 'true', received: ", to_string(w))
            v = True
            self.data += 4

        # handle "false" atom
        elif b == `f`:
            self.data += 1
            if unlikely(self.bytes_remaining() < 3):
                raise Error('Encountered EOF when expecting "false"')
            # Safety: Safe because we checked the amount of bytes remaining
            var w = self.data.p.bitcast[UInt32]()[0]
            if w != ALSE:
                raise Error("Expected 'false', received: f", to_string(w))
            v = False
            self.data += 4

        # handle "null" atom
        elif b == `n`:
            if unlikely(self.bytes_remaining() < 3):
                raise Error('Encountered EOF when expecting "null"')
            # Safety: Safe because we checked the amount of bytes remaining
            var w = self.data.p.bitcast[UInt32]()[0]
            if w != NULL:
                raise Error("Expected 'null', received: ", to_string(w))
            v = Null()
            self.data += 4

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

    fn find(mut self, start: CheckedPointer, out s: String) raises:
        var found_unicode = False
        while True:
            var block = StringBlock.find(self.data)
            if block.has_quote_first():
                self.data += block.quote_index()
                return copy_to_string[Self.options.ignore_unicode](
                    start.p, self.data.p, found_unicode
                )
            elif unlikely(self.data.p > self.data.end):
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

            while True:
                self.data += 1
                if self.data[] == `u`:
                    self.data += 1
                    found_unicode = True
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

    fn read_serial(mut self, start: CheckedPointer, out s: String) raises:
        var found_unicode = False
        while likely(self.has_more()):
            if self.data[] == `"`:
                s = copy_to_string[Self.options.ignore_unicode](
                    start.p, self.data.p, found_unicode
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
                if self.data[] == `u`:
                    found_unicode = True
            comptime control_chars = ByteVec[4](`\n`, `\t`, `\r`, `\r`)
            if unlikely(self.data[] in control_chars):
                raise Error(
                    "Control characters must be escaped: ",
                    String(self.data[]),
                )
            self.data += 1

        raise Error("Invalid String")

    fn read_string(mut self, out s: String) raises:
        self.data += 1
        var start = self.data
        # compile time interpreter is incompatible with the SIMD accelerated
        # path, so fallback to the serial implementation
        if self.can_load_chunk() and not is_compile_time():
            s = self.find(start)
            self.data += 1
        else:
            s = self.read_serial(start)

    @always_inline
    fn skip_whitespace(mut self) raises:
        if not self.has_more() or not is_space(self.data[]):
            return
        self.data += 1

        # compile time interpreter is incompatible with the SIMD accelerated
        # path, so fallback to the serial implementation
        while self.can_load_chunk() and not is_compile_time():
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
    fn compute_float_fast(
        self, out d: Float64, power: Int64, i: UInt64, negative: Bool
    ):
        d = Float64(i)
        var pow: Float64
        var neg_power = power < 0

        pow = lut[POWER_OF_TEN](Int(abs(power)))

        d = d / pow if neg_power else d * pow
        if negative:
            d = -d

    @always_inline
    fn compute_float64(
        self, out d: Float64, power: Int64, var i: UInt64, negative: Bool
    ) raises:
        comptime min_fast_power = Int64(-22)
        comptime max_fast_power = Int64(22)

        if min_fast_power <= power <= max_fast_power and i <= 9007199254740991:
            return self.compute_float_fast(power, i, negative)

        if unlikely(i == 0 or power < -342):
            return -0.0 if negative else 0.0

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
            var upper_s = UInt64(second_product)
            lower += upper_s
            if upper_s > lower:
                upper += 1

        var upperbit: UInt64 = upper >> 63
        var mantissa: UInt64 = upper >> (upperbit + 9)
        lz += Int(1 ^ upperbit)

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
                d = -0.0 if negative else 0.0
                return
            mantissa >>= (-real_exponent + 1).cast[DType.uint64]() + 1

            real_exponent = select(mantissa < (`1 << 52`), Int64(0), Int64(1))
            return to_double(
                mantissa, real_exponent.cast[DType.uint64](), negative
            )

        if unlikely(
            lower <= 1 and power >= -4 and power <= 23 and (mantissa & 3 == 1)
        ):
            comptime `64 - 53 - 2` = 64 - 53 - 2
            if (mantissa << (upperbit + `64 - 53 - 2`)) == upper:
                mantissa &= ~1

        mantissa += mantissa & 1
        mantissa >>= 1

        comptime `1 << 53` = 1 << 53
        if mantissa >= (`1 << 53`):
            mantissa = `1 << 52`
            real_exponent += 1
        mantissa &= ~(`1 << 52`)

        if unlikely(real_exponent > 2046):
            raise Error("infinite value")

        d = to_double(mantissa, real_exponent.cast[DType.uint64](), negative)

    @always_inline
    fn write_float(
        self,
        out v: Value,
        negative: Bool,
        i: UInt64,
        start_digits: CheckedPointer,
        digit_count: Int,
        exponent: Int64,
    ) raises:
        if unlikely(
            digit_count > 19
            and significant_digits(self.data.p, digit_count) > 19
        ):
            return from_chars_slow(self.data)

        if unlikely(exponent < smallest_power or exponent > largest_power):
            if likely(exponent < smallest_power or i == 0):
                return select(negative, -0.0, 0.0)
            raise Error("Invalid number: inf")

        return self.compute_float64(exponent, i, negative)

    @always_inline
    fn parse_number(mut self, out v: Value) raises:
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
            exponent = ptr_dist(p.p, first_after_period.p)
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


fn minify(s: String, out out_str: String) raises:
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
    fn _load_chunk(
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
