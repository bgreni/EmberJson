from .utils import *
from .json import JSON
from .simd import *
from .array import Array
from .object import Object
from .value import Value
from memory import UnsafePointer
from sys.intrinsics import unlikely, likely
from collections import InlineArray
from .parser_helper import *
from memory.unsafe import bitcast
from bit import count_leading_zeros

#######################################################
# Certain parts inspired/taken from SonicCPP and simdjon
# https://github.com/bytedance/sonic-cpp
# https://github.com/simdjson/simdjson
#######################################################


@value
struct ParseOptions:
    var fast_float_parsing: Bool

    fn __init__(out self, *, fast_float_parsing: Bool = False):
        self.fast_float_parsing = fast_float_parsing


struct Parser[options: ParseOptions = ParseOptions()]:
    var data: BytePtr
    var end: BytePtr
    var size: Int

    fn __init__(out self, s: String):
        self.data = s.unsafe_ptr()
        self.size = len(s)
        self.end = self.data + self.size

    fn __init__(out self, b: BytePtr, size: Int):
        self.data = b
        self.size = size
        self.end = self.data + self.size

    @always_inline
    fn bytes_remaining(self) -> Int:
        return ptr_dist(self.data, self.end)

    @always_inline
    fn has_more(self) -> Bool:
        return self.bytes_remaining() > 0

    @always_inline
    fn remaining(self) -> String:
        return copy_to_string(self.data, ptr_dist(self.data, self.end))

    @always_inline
    fn pos(self) -> Int:
        return self.size - (self.size - ptr_dist(self.data, self.end))

    fn parse(mut self, out json: JSON) raises:
        self.skip_whitespace()
        var n = self.data[]
        if n == LBRACKET:
            json = self.parse_array()
        elif n == LCURLY:
            json = self.parse_object()
        else:
            raise Error("Invalid json")

        self.skip_whitespace()
        if unlikely(self.has_more()):
            raise Error("Invalid json, expected end of input, recieved: " + self.remaining())

    fn parse_array(mut self, out arr: Array) raises:
        self.data += 1
        self.skip_whitespace()
        arr = Array()
        arr.reserve(8)

        if unlikely(self.data[] != RBRACKET):
            while True:
                arr.append(self.parse_value())
                self.skip_whitespace()
                var has_comma = False
                if self.data[] == COMMA:
                    self.data += 1
                    has_comma = True
                    self.skip_whitespace()
                if self.data[] == RBRACKET:
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

        if unlikely(self.data[] != RCURLY):
            while True:
                if unlikely(self.data[] != QUOTE):
                    raise Error("Invalid identifier")
                var ident = self.read_string()
                self.skip_whitespace()
                if unlikely(self.data[] != COLON):
                    raise Error("Invalid identifier : " + self.remaining())
                self.data += 1
                var v = self.parse_value()
                self.skip_whitespace()
                var has_comma = False
                if self.data[] == COMMA:
                    self.data += 1
                    self.skip_whitespace()
                    has_comma = True
                obj[ident^] = v^
                if self.data[] == RCURLY:
                    if has_comma:
                        raise Error("Illegal trailing comma")
                    break
                if unlikely(self.bytes_remaining() == 0):
                    raise Error("Expected '}'")

        self.data += 1
        self.skip_whitespace()

    fn parse_value(mut self, out v: Value) raises:
        self.skip_whitespace()
        var n = self.data[]
        if n == QUOTE:
            v = self.read_string()
        elif n == T:
            var w = self.data.load[width=4]()
            if any(w != TRUE):
                raise Error("Expected 'true', received: " + to_string(w))
            v = True
            self.data += 4
        elif n == F:
            self.data += 1
            var w = self.data.load[width=4]()
            if any(w != ALSE):
                raise Error("Expected 'false', received: " + to_string(w))
            v = False
            self.data += 4
        elif n == N:
            var w = self.data.load[width=4]()
            if any(w != NULL):
                raise Error("Expected 'null', received: " + to_string(w))
            v = Null()
            self.data += 4
        elif n == LCURLY:
            v = self.parse_object()
        elif n == LBRACKET:
            v = self.parse_array()
        elif is_numerical_component(n):
            v = self.parse_number()
        else:
            raise Error("Invalid json value")

    fn handle_unicode_codepoint(mut self) -> Bool:
        var c1 = hex_to_u32(self.data.load[width=4]())
        self.data += 4
        if c1 >= 0xD800 and c1 < 0xDC00:
            var v = self.data.load[width=2]()
            if all(v != ByteVec[2](RSOL, U)):
                return False

            self.data += 2

            var c2 = hex_to_u32(self.data.load[width=4]())

            if ((c1 | c2) >> 16) != 0:
                return False

            c1 = (((c1 - 0xD800) << 10) | (c2 - 0xDC00)) + 0x10000
            self.data += 4

        return c1 <= 0x10FFFF

    # @always_inline
    fn find_and_move(mut self, start: BytePtr, out s: String) raises:
        var block = StringBlock.find(self.data)
        if block.has_quote_first():
            self.data += block.quote_index()
            return copy_to_string(start, ptr_dist(start, self.data))
        if unlikely(block.has_unescaped()):
            raise Error(
                "Control characters must be escaped: "
                + to_string(self.data.load[width=SIMD8_WIDTH]())
                + " : "
                + str(block.unescaped_index())
            )
        if not block.has_backslash():
            self.data += SIMD8_WIDTH
            return self.find_and_move(start)
        self.data += block.bs_index()
        return self.cont(start)

    fn cont(mut self, start: BytePtr, out s: String) raises:
        self.data += 1
        if self.data[] == U:
            self.data += 1
            return self.find_and_move(start)
            # TODO: Fix this
            # if not self.handle_unicode_codepoint():
            #     raise Error("Invalid unicode")
        else:
            if unlikely(self.data[] not in acceptable_escapes):
                raise Error("Invalid escape sequence: " + byte_to_string(self.data[-1]) + byte_to_string(self.data[]))
        self.data += 1
        if self.data[] == RSOL:
            return self.cont(start)
        return self.find_and_move(start)

    fn find(mut self, start: BytePtr, out s: String) raises:
        var block = StringBlock.find(self.data)
        if block.has_quote_first():
            self.data += block.quote_index()
            return copy_to_string(start, ptr_dist(start, self.data))
        if unlikely(block.has_unescaped()):
            raise Error(
                "Control characters must be escaped: "
                + to_string(self.data.load[width=SIMD8_WIDTH]())
                + " : "
                + str(block.unescaped_index())
            )
        if not block.has_backslash():
            self.data += SIMD8_WIDTH
            return self.find(start)

        self.data += block.bs_index()

        return self.cont(start)

    fn read_string(mut self, out s: String) raises:
        self.data += 1
        var start = self.data
        while likely(self.has_more()):
            if self.bytes_remaining() >= SIMD8_WIDTH:
                s = self.find(start)
                self.data += 1
                return
            else:
                if self.data[] == QUOTE:
                    s = copy_to_string(start, ptr_dist(start, self.data))
                    self.data += 1
                    return
                if self.data[] == RSOL:
                    self.data += 1
                    if unlikely(self.data[] not in acceptable_escapes):
                        raise Error(
                            "Invalid escape sequence: " + byte_to_string(self.data[-1]) + byte_to_string(self.data[])
                        )
                alias control_chars = ByteVec[4](NEWLINE, TAB, LINE_FEED, LINE_FEED)
                if unlikely(self.data[] in control_chars):
                    raise Error("Control characters must be escaped: " + str(self.data[]))
                self.data += 1
        raise Error("Invalid String")

    @always_inline
    fn skip_whitespace(mut self):
        if not is_space(self.data[]):
            return
        self.data += 1
        if not is_space(self.data[]):
            return
        self.data += 1

        while self.bytes_remaining() >= SIMD8_WIDTH:
            var chunk = self.data.load[width=SIMD8_WIDTH]()
            var nonspace = get_non_space_bits(chunk)
            var ind = first_true(nonspace)
            if ind != Int.MAX:
                self.data += ind
                return
            else:
                self.data += SIMD8_WIDTH + 1

        while self.has_more() and is_space(self.data[]):
            self.data += 1

    #####################################################################################################################
    # BASED ON SIMDJSON https://github.com/simdjson/simdjson/blob/master/include/simdjson/generic/numberparsing.h
    #####################################################################################################################

    @always_inline
    fn compute_float_fast[*, use_lot: Bool](self, out d: Float64, power: Int64, i: UInt64, negative: Bool):
        d = float(i)
        var pow: Float64
        var neg_power = power < 0

        @parameter
        if use_lot:
            if neg_power:
                pow = power_of_ten[-int(power)]
            else:
                pow = power_of_ten[int(power)]
        else:
            pow = 10 ** float(abs(power))

        if power < 0:
            d = d / pow
        else:
            d = d * pow
        if negative:
            d = -d

    @always_inline
    fn compute_float64(self, out d: Float64, power: Int64, owned i: UInt64, negative: Bool) raises:
        @parameter
        if options.fast_float_parsing:
            return self.compute_float_fast[use_lot=False](power, i, negative)

        alias min_fast_power = Int64(-22)
        alias max_fast_power = Int64(22)
        if min_fast_power <= power <= max_fast_power and i <= 9007199254740991:
            return self.compute_float_fast[use_lot=True](power, i, negative)

        if unlikely(i == 0 or power < -342):
            return -0.0 if negative else 0.0

        var lz = count_leading_zeros(i)
        i <<= lz

        var index = int(2 * (power - smallest_power))

        var first_product = full_multiplication(i, power_of_five_128[index])

        if unlikely(first_product[1] & 0x1FF == 0x1FF):
            second_product = full_multiplication(i, power_of_five_128[index + 1])
            first_product[0] += second_product[1]
            if second_product[1] > first_product[0]:
                first_product[1] += 1

        var lower = first_product[0]
        var upper = first_product[1]

        var upperbit: UInt64 = upper >> 63
        var mantissa: UInt64 = upper >> (upperbit + 9)
        lz += int(1 ^ upperbit)

        alias `152170 + 65536` = 152170 + 65536
        alias `1024 + 63` = 1024 + 63

        var real_exponent: Int64 = (((`152170 + 65536`) * power) >> 16) + `1024 + 63` - lz.cast[DType.int64]()

        alias `1 << 52` = 1 << 52

        if unlikely(real_exponent <= 0):
            if -real_exponent + 1 >= 64:
                d = -0.0 if negative else 0.0
                return
            mantissa >>= (-real_exponent + 1).cast[DType.uint64]() + 1

            real_exponent = 0 if (mantissa < (`1 << 52`)) else 1
            return to_double(mantissa, real_exponent.cast[DType.uint64](), negative)

        if unlikely(lower <= 1 and power >= -4 and power <= 23 and (mantissa & 3 == 1)):
            alias `64 - 53 - 2` = 64 - 53 - 2
            if (mantissa << (upperbit + `64 - 53 - 2`)) == upper:
                mantissa &= ~1

        mantissa += mantissa & 1
        mantissa >>= 1

        alias `1 << 53` = 1 << 53
        if mantissa >= (`1 << 53`):
            mantissa = `1 << 52`
            real_exponent += 1
        mantissa &= ~(`1 << 52`)

        if unlikely(real_exponent > 2046):
            raise Error("infinite value")

        d = to_double(mantissa, real_exponent.cast[DType.uint64](), negative)

    @always_inline
    fn write_float(
        self, out v: Value, negative: Bool, i: UInt64, start_digits: BytePtr, digit_count: Int, exponent: Int64
    ) raises:
        # TODO: check for long strings

        if unlikely(exponent < smallest_power or exponent > largest_power):
            if exponent < smallest_power or i == 0:
                return -0.0 if negative else 0.0
            raise Error("Invalid number: inf")

        return self.compute_float64(exponent, i, negative)

    @always_inline
    fn parse_number(mut self, out v: Value) raises:
        var neg = self.data[] == NEG
        var p = self.data + int(neg or self.data[] == PLUS)

        var start_digits = p
        var i: UInt64 = 0

        while parse_digit(p, i):
            p += 1

        var digit_count = ptr_dist(start_digits, p)

        if unlikely(digit_count == 0 or (start_digits[] == ZERO_CHAR and digit_count > 1)):
            raise Error("Invalid number")

        var exponent: Int64 = 0
        var is_float = False

        if p[] == DOT:
            is_float = True
            p += 1

            var first_after_period = p

            if self.bytes_remaining() >= 8 and is_made_of_eight_digits_fast(p):
                i = i * 100000000 + parse_eight_digits(p)
                p += 8

            while parse_digit(p, i):
                p += 1
            exponent = ptr_dist(p, first_after_period)
            if exponent == 0:
                raise Error("Invalid number")
            digit_count = ptr_dist(start_digits, p)

        if is_exp_char(p[]):
            is_float = True
            p += 1

            var neg_exp = p[] == NEG
            p += int(neg_exp or p[] == PLUS)

            if unlikely(is_exp_char(p[])):
                raise Error("Invalid float: Double sign for exponent")

            var start_exp = p
            var exp_number: Int64 = 0
            while parse_digit(p, exp_number):
                p += 1

            if unlikely(p == start_exp):
                raise Error("Invalid number")

            if unlikely(p > start_exp + 18):
                while start_exp[] == ZERO_CHAR:
                    start_exp += 1
                if p > start_exp + 18:
                    exp_number = 999999999999999999

            exponent += -exp_number if neg_exp else exp_number

        if is_float:
            v = self.write_float(neg, i, start_digits, digit_count, exponent)
            self.data = p
            return

        var longest_digit_count = 20
        if digit_count > longest_digit_count:
            raise Error("integer overflow")
        if digit_count == longest_digit_count:
            if i > Int64.MAX.cast[DType.uint64]():
                raise Error("integer overflow")
            if neg:
                self.data = p
                return int(~i + 1)
            elif self.data[0] != to_byte("1") or i <= Int64.MAX.cast[DType.uint64]():
                raise Error("integer overflow")

        self.data = p
        return int(~i + 1) if neg else int(i)
