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
from collections.string import _atof

#######################################################
# Certain parts inspired/taken from SonicCPP https://github.com/bytedance/sonic-cpp
#######################################################


struct Parser:
    var data: BytePtr
    var end: BytePtr
    var size: Int

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
            v = self.read_number()
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

    fn count_before(self, to_count: Byte, until: Byte) -> Int:
        var count = 0
        var offset = 0
        while self.bytes_remaining() - offset >= SIMD8_WIDTH:
            var block = self.data.offset(offset).load[width=SIMD8_WIDTH]()
            var end = block == until
            if not end.reduce_or():
                count += int((block == to_count).cast[DType.index]().reduce_add())
                offset += SIMD8_WIDTH
            else:
                var ind = first_true(end)
                for i in range(offset, offset + ind):
                    count += int(self.data[i] == to_count)
                break
        return count

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

    # @always_inline
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

    # @always_inline
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
        var control_chars = ByteVec[4](NEWLINE, TAB, LINE_FEED, LINE_FEED)
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
                if unlikely(self.data[] in control_chars):
                    raise Error("Control characters must be escaped: " + str(self.data[]))
                self.data += 1
        raise Error("Invalid String")

    fn read_number(mut self, out number: Value) raises:
        var num = self.data
        var is_float = False
        var float_parts = ByteVec[4](DOT, LOW_E, UPPER_E, LOW_E)
        while is_numerical_component(self.data[]):
            if self.data[] in float_parts:
                is_float = True
            self.data += 1

        var l = ptr_dist(num, self.data)
        var sign_parts = ByteVec[2](PLUS, NEG)

        for i in range(l):
            var b = num[i]
            if b in sign_parts:
                var j = i + 1
                if j < l:
                    # atof doesn't reject numbers like 0e+-1
                    var after = num[j]
                    if after in sign_parts:
                        raise Error("Invalid number: ")

        var is_negative = num[0] == NEG

        if is_float:
            # I think I'm scamming the type system here but its fine for now
            number = _atof(StringSlice[__origin_of(num)](ptr=num, length=l))
            return

        var parsed = 0
        var has_pos = num[0] == PLUS

        var i = 0
        if is_negative or has_pos:
            if l == 1:
                raise Error("Invalid number")
            i += 1

        if num[i] == ZERO_CHAR and l - 1 - i != 0:
            raise Error("Integer cannot have leading zero")

        while i < l:
            if unlikely(not isdigit(num[i])):
                raise Error("unexpected token in number: " + '"' + copy_to_string(num, l) + '"')
            parsed = parsed * 10 + int(num[i] - ZERO_CHAR)
            i += 1

        if is_negative:
            parsed = -parsed
        number = parsed

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
            if ind != -1:
                self.data += ind
                return
            else:
                self.data += SIMD8_WIDTH + 1

        while self.has_more() and is_space(self.data[]):
            self.data += 1
