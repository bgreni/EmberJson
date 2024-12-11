from .constants import *
from sys.intrinsics import likely, unlikely
from .utils import *
from .simd import *
from .constants import *
from math import iota
from os import abort
from memory import UnsafePointer
from bit import count_leading_zeros
from sys.intrinsics import llvm_intrinsic
from .tables import digit_to_val32

fn index(simd: SIMD, item: Scalar[simd.type]) -> Int:
    var seq = iota[simd.type, simd.size]()
    var result = (simd == item).select(seq, simd.MAX).reduce_min()
    var found = bool(result != item.MAX)
    return (-1 * ~found) | (int(result) * found)

fn ind(simd: SIMD, item: Scalar[simd.type]) -> Int:
    var seq = iota[simd.type, simd.size]()
    var result = (simd == item).select(seq, simd.MAX).reduce_min()
    var found = bool(result != item.MAX)
    if found:
        return int(result)
    return Int.MAX

fn ind(simd: SIMDBool) -> Int:
    return ind(simd.cast[DType.uint8](), UInt8(1))

fn first_true(simd: SIMD[DType.bool, _]) -> Int:
    return index(simd.cast[DType.uint8](), UInt8(1))


@value
struct StringBlock:
    alias BitMask = SIMD8xT._Mask

    var bs_bits: Self.BitMask
    var quote_bits: Self.BitMask
    var unescaped_bits: Self.BitMask

    fn quote_index(self) -> Int:
        return first_true(self.quote_bits)
    
    fn bs_index(self) -> Int:
        return first_true(self.bs_bits)

    fn unescaped_index(self) -> Int:
        return first_true(self.unescaped_bits)

    fn has_quote_first(self) -> Bool:
        # return count_leading_zeros(u64_from_bits(self.quote_bits)) < count_leading_zeros(u64_from_bits(self.bs_bits)) and not self.has_unescaped()
        return ind(self.quote_bits) < ind(self.bs_bits) and not self.has_unescaped()
        # return (((u64_from_bits(self.bs_bits) - 1) & u64_from_bits(self.quote_bits)) != 0) and not self.has_unescaped()

    fn has_backslash(self) -> Bool:
        # return count_leading_zeros(u64_from_bits(self.bs_bits)) < count_leading_zeros(u64_from_bits(self.quote_bits))
        return ind(self.bs_bits) < ind(self.quote_bits)
        # return ((u64_from_bits(self.quote_bits) - 1) & u64_from_bits(self.bs_bits)) != 0

    fn has_unescaped(self) -> Bool:
        # return count_leading_zeros(u64_from_bits(self.unescaped_bits)) < count_leading_zeros(u64_from_bits(self.quote_bits))
        return ind(self.unescaped_bits) < ind(self.quote_bits)
        # TODO: Not guaranteed portable?
        # return ((u64_from_bits(self.quote_bits) - 1) & u64_from_bits(self.unescaped_bits)) != 0


    @staticmethod
    fn find(src: UnsafePointer[UInt8]) -> StringBlock:
        var v = src.load[width=SIMD8_WIDTH]()
        alias I_DONT_KNOW_WHAT_THIS_IS: UInt8 = 31
        return StringBlock(
            v == RSOL,
            v == QUOTE,
            v <= I_DONT_KNOW_WHAT_THIS_IS
        )


alias SOL = to_byte("/")
alias B = to_byte("b")
alias F = to_byte("f")
alias N = to_byte("n")
alias R = to_byte("r")
alias T = to_byte("t")
alias U = to_byte("u")
var acceptable_escapes = ByteVec[16](QUOTE, RSOL, SOL, B, F, N, R, T, U)


fn hex_to_u32(v: ByteVec[4]) -> UInt32:
    var other = ByteVec[4](630, 420, 210, 0)
    var out = UInt32(0)
    @parameter
    for i in range(4):
        out |= digit_to_val32[int(v[i] + other[i])]
    return out

struct Reader[origin: ImmutableOrigin]:
    var _data: ByteView[origin]
    var _index: Int

    fn __init__(out self, data: ByteView[origin]):
        self._data = data
        self._index = 0

    @always_inline
    fn peek(self) -> Byte:
        return self._data[self._index]

    @always_inline
    fn next(mut self, chars: Int = 1) -> ByteView[origin]:
        var start = self._index
        self.inc(chars)
        return self._data[start : self._index]

    @always_inline
    fn read_until(mut self, char: Byte) -> ByteView[origin]:
        @parameter
        @always_inline
        fn not_char(c: Byte) -> Bool:
            return c != char

        return self.read_while[not_char]()

    @always_inline
    fn ptr(self) -> UnsafePointer[UInt8]:
        return self._data.unsafe_ptr().offset(self._index)

#######################################################
# Taken from https://github.com/bytedance/sonic-cpp
#######################################################
    fn handle_unicode_codepoint(mut self) -> Bool:
        var c1 = hex_to_u32(self.ptr().load[width=4]())
        self.inc(4)
        if c1 >= 0xd800 and c1 < 0xdc00:
            var v = self.ptr().load[width=2]()
            if all(v != ByteVec[2](RSOL, U)):
                return False

            self.inc(2)

            var c2 = hex_to_u32(self.ptr().load[width=4]())

            if ((c1 | c2) >> 16) != 0:
                return False

            c1 = (((c1 - 0xd800) << 10) | (c2 - 0xdc00)) + 0x10000
            self.inc(4)

        return c1 <= 0x10FFFF

    fn count_before(self, to_count: Byte, until: Byte) -> Int:
        var count = 0
        var offset = 0
        while self.bytes_remaining() - offset >= SIMD8_WIDTH:
            var block = self.ptr().offset(offset).load[width=SIMD8_WIDTH]()
            var end = block == until
            if not end.reduce_or():
                count += int((block == to_count).cast[DType.index]().reduce_add())
                offset += SIMD8_WIDTH
            else:
                var ind = first_true(end)
                for i in range(offset, offset + ind):
                    count += int(self.ptr()[i] == to_count)
                break
        return count

    # @always_inline
    fn find_and_move(mut self, start: Int) raises -> ByteView[origin]:
        var block = StringBlock.find(self.ptr())
        if block.has_quote_first():
            self.inc(block.quote_index())
            return self._data[start : self._index]
        if unlikely(block.has_unescaped()):
            raise Error("Control characters must be escaped: " + to_string(self.ptr().load[width=SIMD8_WIDTH]()) + " : " + str(block.unescaped_index()))
        if not block.has_backslash():
            self.inc(SIMD8_WIDTH)
            return self.find_and_move(start)
        self.inc(block.bs_index())
        return self.cont(start)

    # @always_inline
    fn cont(mut self, start: Int) raises -> ByteView[origin]:
        self.inc()
        if self.peek() == U:
            self.inc()
            return self.find_and_move(start)
            # if not self.handle_unicode_codepoint():
            #     raise Error("Invalid unicode")
        else:
            if unlikely(self.peek() not in acceptable_escapes):
                raise Error("Invalid escape sequence: " + byte_to_string(self.ptr().offset(-1)[]) + byte_to_string(self.peek()))
        self.inc()
        if self.peek() == RSOL:
            return self.cont(start)
        return self.find_and_move(start)

    # @always_inline
    fn find(mut self, start: Int) raises -> ByteView[origin]:
        var block = StringBlock.find(self.ptr())
        if block.has_quote_first():
            self.inc(block.quote_index())
            return self._data[start : self._index]
        if unlikely(block.has_unescaped()):
            raise Error("Control characters must be escaped: " + to_string(self.ptr().load[width=SIMD8_WIDTH]()) + " : " + str(block.unescaped_index()))
        if not block.has_backslash():
            self.inc(SIMD8_WIDTH)
            return self.find(start)

        self.inc(block.bs_index())

        return self.cont(start)

#######################################################

    @always_inline
    fn read_string(mut self) raises -> ByteView[origin]:
        var start = self._index
        var control_chars = ByteVec[4](NEWLINE, TAB, LINE_FEED, LINE_FEED)
        while likely(self.has_more()):

            if self.bytes_remaining() >= SIMD8_WIDTH:
                return self.find(start)
            else:
                if self.peek() == QUOTE:
                    return self._data[start : self._index]
                if self.peek() == RSOL:
                    self.inc()
                    if unlikely(self.peek() not in acceptable_escapes):
                        raise Error("Invalid escape sequence: " + byte_to_string(self.ptr().offset(-1)[]) + byte_to_string(self.peek()))
                if unlikely(self.peek() in control_chars):
                    raise Error("Control characters must be escaped: " + str(self.peek()))
                self.inc()
        raise Error("Invalid String")

    @always_inline
    fn read_word(mut self) -> ByteView[origin]:
        var end_chars = ByteVec[4](COMMA, RCURLY, RBRACKET, RBRACKET)

        @always_inline
        @parameter
        fn func(c: Byte) -> Bool:
            return not is_space(c) and not c in end_chars

        return self.read_while[func]()

    @always_inline
    fn read_while[func: fn (char: Byte) capturing -> Bool](mut self) -> ByteView[origin]:
        var start = self._index
        while likely(self._index < len(self._data)) and func(self.peek()):
            self.inc()
        return self._data[start : self._index]

    @always_inline
    fn skip_whitespace(mut self):
        if not is_space(self.peek()):
            return
        self.inc()
        if not is_space(self.peek()):
            return
        self.inc()

        while self.bytes_remaining() >= SIMD8_WIDTH:
            var chunk = self._data.unsafe_ptr().offset(self._index).load[width=SIMD8_WIDTH]()
            var nonspace = self.get_non_space_bits(chunk)
            var ind = first_true(nonspace)
            if ind != -1:
                self.inc(ind)
                return
            else:
                self.inc(SIMD8_WIDTH + 1)

        while self.has_more() and is_space(self.peek()):
            self.inc()

    @always_inline
    fn get_non_space_bits[Size: Int, //](self, s: ByteVec[Size]) -> ByteVec[Size]._Mask:
        var v = (s == SPACE) | (s == NEWLINE) | (s == TAB) | (s == LINE_FEED)
        return ~v

    @always_inline
    fn inc(mut self, amount: Int = 1):
        self._index += amount

    @always_inline
    fn skip_if(mut self, char: Byte):
        if self.peek() == char:
            self.inc()

    @always_inline
    fn remaining(self) -> String:
        return String(List(self._data[self._index :]) + Byte(0))

    @always_inline
    fn bytes_remaining(self) -> Int:
        return len(self._data) - self._index

    @always_inline
    fn has_more(self) -> Bool:
        return self.bytes_remaining() != 0
