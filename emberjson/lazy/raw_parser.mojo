from bit import count_trailing_zeros
from memory import UnsafePointer, memset
from sys.intrinsics import unlikely, likely
from collections import InlineArray
from memory.unsafe import bitcast
from bit import count_leading_zeros
from sys.compile import is_compile_time


from .raw_array import RawArray
from .raw_object import RawObject
from .raw_json import RawJSON
from .raw_value import RawValue, RawJsonType

from emberjson.utils import to_string, is_space
from emberjson.simd import SIMD8_WIDTH, SIMD8xT
from emberjson._parser_helper import (
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
from emberjson.tables import (
    power_of_ten,
    full_multiplication,
    power_of_five_128,
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
)

#######################################################
# Certain parts inspired/taken from SonicCPP and simdjon
# https://github.com/bytedance/sonic-cpp
# https://github.com/simdjson/simdjson
#######################################################


struct RawParseOptions(Copyable, Movable):
    """JSON parsing options.

    Fields:
        ignore_unicode: Do not decode escaped unicode characters for a slight
            increase in performance.
    """

    var ignore_unicode: Bool

    fn __init__(out self, *, ignore_unicode: Bool = False):
        self.ignore_unicode = ignore_unicode


struct RawParser[
    origin: ImmutableOrigin, options: RawParseOptions = RawParseOptions()
](Sized):
    var data: Span[Byte, origin]
    """The raw data that the parser parses."""
    var idx: UInt
    """The index at which the parser points to."""

    fn __init__(out self, ref [origin]s: String):
        self = __type_of(self)(ptr=s.unsafe_ptr(), length=s.byte_length())

    fn __init__(out self, s: StringSlice[origin], idx: UInt = 0):
        self = Self(ptr=s.unsafe_ptr(), length=s.byte_length(), idx=idx)

    fn __init__(out self, s: Span[Byte, origin], idx: UInt = 0):
        self = Self(ptr=s.unsafe_ptr(), length=len(s), idx=idx)

    fn __init__(
        out self,
        *,
        ptr: UnsafePointer[Byte, mut=False, origin=origin, **_],
        length: UInt,
        idx: UInt = 0,
    ):
        # FIXME: temporary rebind
        self.data = Span[Byte, ptr.origin](
            ptr=rebind[UnsafePointer[Byte]](ptr), length=length
        )
        self.idx = idx

    @always_inline
    fn __len__(self) -> Int:
        return len(self.data) - 1 - self.idx

    @always_inline
    fn has_more(self) -> Bool:
        return len(self.data) - 1 > self.idx

    @always_inline
    fn remaining(self) -> String:
        """Used for debug purposes.

        Returns:
            A string containing the remaining unprocessed data from parser
            input.
        """
        try:
            var span = self.data[Int(self.idx) :]
            var ptr = span.unsafe_ptr()
            return copy_to_string[True](ptr, ptr + len(span))
        except:
            return ""

    @always_inline
    fn load_chunk(self) -> SIMD8xT:
        var ptr = self.data.unsafe_ptr()
        if len(self) < SIMD8_WIDTH:
            v = SIMD8xT(0)
            for i in range(len(self)):
                v[i] = ptr[i]
            return v
        return ptr.load[width=SIMD8_WIDTH]()

    @always_inline
    fn can_load_chunk(self) -> Bool:
        return len(self) >= SIMD8_WIDTH

    fn parse(mut self, out json: RawJSON[origin]) raises:
        self.skip_whitespace()
        if likely(self.has_more()):
            var b = self.data.unsafe_ptr()[self.idx]
            if b == `[`:
                json = self.parse_array()
                return
            elif b == `{`:
                json = self.parse_object()
                return
        raise Error("Invalid json")

    fn parse_array(mut self, out arr: RawArray[origin]) raises:
        self.idx += 1
        self.skip_whitespace()
        arr = RawArray[origin]()
        var ptr = self.data.unsafe_ptr()
        var has_comma = False

        while ptr[self.idx] != `]` and likely(self.has_more()):
            arr.append(self.parse_value())
            self.skip_whitespace()
            has_comma = ptr[self.idx] == `,`
            self.idx += Int(has_comma and likely(self.has_more()))

        if unlikely(has_comma):
            raise Error("Illegal trailing comma")
        if unlikely(ptr[self.idx] != `]`):
            raise Error("Expected ']'")

        self.idx += 1

    fn parse_object(mut self, out obj: RawObject[origin]) raises:
        obj = RawObject[origin]()
        self.idx += 1
        self.skip_whitespace()
        var ptr = self.data.unsafe_ptr()

        if unlikely(ptr[self.idx] != `}`):
            while True:
                if unlikely(ptr[self.idx] != `"`):
                    raise Error("Invalid identifier")
                var ident = RawValue(self._read_string()).string()
                self.skip_whitespace()
                if unlikely(ptr[self.idx] != `:`):
                    raise Error("Invalid identifier : ", self.remaining())
                self.idx += 1
                var value = self.parse_value()
                self.skip_whitespace()
                var has_comma = False
                if ptr[self.idx] == `,`:
                    self.idx += 1
                    self.skip_whitespace()
                    has_comma = True
                obj[ident] = value^
                if ptr[self.idx] == `}`:
                    if has_comma:
                        raise Error("Illegal trailing comma")
                    break
                if unlikely(len(self) == 0):
                    raise Error("Expected '}'")

        self.idx += 1

    fn parse_value(mut self, out v: RawValue[origin]) raises:
        self.skip_whitespace()
        var ptr = self.data.unsafe_ptr()
        var b = ptr[self.idx]
        # Handle string
        if b == `"`:
            v = self._read_string()

        # Handle "true" atom
        elif b == `t`:
            if unlikely(len(self) < 3):
                raise Error('Encountered EOF when expecting "true"')
            # Safety: Safe because we checked the amount of bytes remaining
            var w = (ptr + self.idx).bitcast[UInt32]()[0]
            if w != TRUE:
                raise Error("Expected 'true', received: ", to_string(w))
            v = RawValue(
                json_type=RawJsonType.TRUE,
                span=self.data[Int(self.idx) : Int(self.idx) + 4],
            )
            self.idx += 4

        # handle "false" atom
        elif b == `f`:
            self.idx += 1
            if unlikely(len(self) < 3):
                raise Error('Encountered EOF when expecting "false"')
            # Safety: Safe because we checked the amount of bytes remaining
            var w = (ptr + self.idx).bitcast[UInt32]()[0]
            if w != ALSE:
                raise Error("Expected 'false', received: f", to_string(w))
            v = RawValue(
                json_type=RawJsonType.FALSE,
                span=self.data[Int(self.idx) - 1 : Int(self.idx) + 4],
            )
            self.idx += 4

        # handle "null" atom
        elif b == `n`:
            if unlikely(len(self) < 3):
                raise Error('Encountered EOF when expecting "null"')
            # Safety: Safe because we checked the amount of bytes remaining
            var w = (ptr + self.idx).bitcast[UInt32]()[0]
            if w != NULL:
                raise Error("Expected 'null', received: ", to_string(w))
            v = RawValue(
                json_type=RawJsonType.NULL,
                span=self.data[Int(self.idx) : Int(self.idx) + 4],
            )
            self.idx += 4

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
            raise Error("Invalid json value: ", self.remaining())

    fn _skip_escaped_chars(
        mut self, start: UInt, out s: StringSlice[origin]
    ) raises:
        debug_assert(self.has_more(), "Should have values to iterate")
        self.idx += 1
        var ptr = self.data.unsafe_ptr()
        if ptr[self.idx] == `\\`:
            debug_assert(self.has_more(), "unescaped value")
            debug_assert(
                ptr[self.idx + 1] in acceptable_escapes,
                "Value cannot be escaped: ",
                StringSlice[origin](ptr=ptr + self.idx, length=1),
            )
            return self._skip_escaped_chars(start)
        return self._find_quote(start)

    fn _find_quote(mut self, start: UInt, out s: StringSlice[origin]) raises:
        var ptr = self.data.unsafe_ptr()
        var block = StringBlock.find(ptr + self.idx)
        if block.has_quote_first():
            self.idx += UInt(block.quote_index())
            return StringSlice[ptr.origin](
                ptr=ptr + start, length=self.idx - start
            )
        elif unlikely(not self.has_more()):
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
            self.idx += SIMD8_WIDTH
            return self._find_quote(start)
        self.idx += UInt(block.bs_index())
        return self._skip_escaped_chars(start)

    fn _read_string(mut self, out s: StringSlice[origin]) raises:
        self.idx += 1
        var ptr = self.data.unsafe_ptr()
        if ptr[self.idx] == `"`:  # ""
            s = StringSlice[origin](ptr=ptr + self.idx, length=0)
            self.idx += 1
            return
        var start = self.idx
        var escaped = False
        while likely(self.has_more()):
            self.idx += 1
            # compile time interpreter is incompatible with the SIMD accelerated
            # path, so fallback to the serial implementation
            if self.can_load_chunk() and not is_compile_time():
                s = self._find_quote(start)
                self.idx += 1
                return
            elif likely(not escaped) and ptr[self.idx] == `"`:
                s = StringSlice[origin](
                    ptr=ptr + start, length=self.idx - start
                )
                self.idx += 1
                return
            escaped = ptr[self.idx] == `\\`
        raise Error("Invalid String")

    @always_inline
    fn skip_whitespace(mut self) raises:
        var ptr = self.data.unsafe_ptr()
        if not self.has_more() or not is_space(ptr[self.idx]):
            return
        self.idx += 1

        # compile time interpreter is incompatible with the SIMD accelerated
        # path, so fallback to the serial implementation
        while self.can_load_chunk() and not is_compile_time():
            var chunk = self.load_chunk()
            var nonspace = get_non_space_bits(chunk)
            if nonspace != 0:
                self.idx += UInt(count_trailing_zeros(nonspace))
                return
            else:
                self.idx += SIMD8_WIDTH

        while self.has_more() and is_space(ptr[self.idx]):
            self.idx += 1

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

        # TODO: Remove this branch after `power_of_ten` is also ctime computed again
        if is_compile_time():
            pow = 10.0 ** Float64(abs(power))
        else:
            pow = power_of_ten.unsafe_get(Int(abs(power)))

        d = d / pow if neg_power else d * pow
        if negative:
            d = -d

    @always_inline
    fn parse_number(mut self, out v: RawValue[origin]) raises:
        var ptr = self.data.unsafe_ptr()
        var start = self.idx
        var neg = ptr[self.idx] == `-`
        self.idx += Int(neg or ptr[self.idx] == `+`)
        if unlikely(not self.has_more() and start != self.idx):
            raise Error("Invalid number: sign only")
        var starts_with_zero = ptr[self.idx] == `0`

        while `0` <= ptr[self.idx] <= `9` and likely(self.has_more()):
            self.idx += 1

        if unlikely(starts_with_zero and self.idx > start + 1):
            raise Error("Invalid number: starts with zero")

        var has_dot = ptr[self.idx] == `.`

        if has_dot and self.has_more():
            self.idx += 1

            if len(self) >= 8:
                self.idx += (7 + Int(self.has_more())) & -Int(
                    unsafe_is_made_of_eight_digits_fast(ptr + self.idx)
                )

            while `0` <= ptr[self.idx] <= `9` and likely(self.has_more()):
                self.idx += 1

        if is_exp_char(ptr[self.idx]):
            if unlikely(not self.has_more()):
                raise Error("Invalid float: Exponent followed by no number")
            self.idx += 1

            var neg_exp = ptr[self.idx] == `-`
            var has_sign = neg_exp or ptr[self.idx] == `+`
            self.idx += Int(has_sign and likely(self.has_more()))

            if unlikely(not (`0` <= ptr[self.idx] <= `9`)):
                raise Error("Invalid float: Sign followed by no number")

            while `0` <= ptr[self.idx] <= `9` and likely(self.has_more()):
                self.idx += 1

            self.idx += 1
            v = RawValue(
                json_type=RawJsonType.FLOAT_EXP,
                span=Span[Byte, origin](
                    ptr=ptr + start, length=self.idx - start
                ),
            )
            return

        self.idx += Int(`0` <= ptr[self.idx] <= `9`)
        if has_dot:
            v = RawValue(
                json_type=RawJsonType.FLOAT_DOT,
                span=Span[Byte, origin](
                    ptr=ptr + start, length=self.idx - start
                ),
            )
        else:
            v = RawValue(
                json_type=RawJsonType.INT,
                span=Span[Byte, origin](
                    ptr=ptr + start, length=self.idx - start
                ),
            )
