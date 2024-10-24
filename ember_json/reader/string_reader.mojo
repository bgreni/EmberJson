from utils import Span, StringSlice
from ..constants import *
from sys.intrinsics import likely
from ..utils import *


struct Reader[origin: ImmutableOrigin,//]:
    var _data: Span[Byte, origin]
    var _index: Int

    fn __init__(inout self, data: StringSlice[origin]):
        self._data = data.as_bytes()
        self._index = 0

    @always_inline
    fn peek(self) -> Byte:
        return self._data[self._index]

    @always_inline
    fn next(inout self, chars: Int = 1) -> Span[Byte, origin]:
        var start = self._index
        self.inc(chars)
        return self._data[start : self._index]

    @always_inline
    fn read_until(inout self, char: Byte) -> Span[Byte, origin]:
        @parameter
        fn not_char(c: Byte) -> Bool:
            return c != char

        return self.read_while[not_char]()

    @always_inline
    fn read_string(inout self) -> Span[Byte, origin]:
        var start = self._index
        while likely(self._index < len(self._data)):
            if self.peek() == QUOTE:
                break
            if self.peek() == RSOL:
                self.inc()
            self.inc()
        return self._data[start : self._index]

    @always_inline
    fn read_word(inout self) -> Span[Byte, origin]:
        var end_chars = ByteVec[4](COMMA, RCURLY, RBRACKET)

        @always_inline
        @parameter
        fn func(c: Byte) -> Bool:
            return not is_space(c) and not c in end_chars

        return self.read_while[func]()

    @always_inline
    fn read_while[func: fn (char: Byte) capturing -> Bool](inout self) -> Span[Byte, origin]:
        var start = self._index
        while likely(self._index < len(self._data)) and func(self.peek()):
            self.inc()
        return self._data[start : self._index]

    @always_inline
    fn skip_whitespace(inout self):
        while likely(self._index < len(self._data)) and is_space(self.peek()):
            self.inc()

    @always_inline
    fn inc(inout self, amount: Int = 1):
        self._index += amount

    @always_inline
    fn skip_if(inout self, char: Byte):
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
