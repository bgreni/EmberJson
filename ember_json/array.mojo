from .object import Object
from .value import Value
from .reader import Reader
from .utils import *
from .constants import *
from sys.intrinsics import unlikely, likely
from .traits import JsonValue


@value
struct Array(Sized, JsonValue):
    alias Type = List[Value]
    var _data: Self.Type

    fn __init__(inout self):
        self._data = Self.Type()

    fn __init__(inout self, owned *values: Value):
        self._data = Self.Type(variadic_list=values^)

    @always_inline
    fn __getitem__(ref [_]self, ind: Int) -> ref [self._data] Value:
        return self._data[ind]

    @always_inline
    fn __setitem(inout self, ind: Int, owned item: Value):
        self._data[ind] = item^

    @always_inline
    fn __len__(self) -> Int:
        return len(self._data)

    fn __contains__[T: EqualityComparableCollectionElement, //](self, item: T) -> Bool:
        for v in self._data:
            if v[].isa[T]() and v[].get[T]() == item:
                return True
        return False

    @always_inline
    fn __contains__(self, v: Value) -> Bool:
        return v in self._data

    @always_inline
    fn __eq__(self, other: Self) -> Bool:
        return self._data == other._data

    @always_inline
    fn __ne__(self, other: Self) -> Bool:
        return self._data != other._data

    fn write_to[W: Writer](self, inout writer: W):
        ("[").write_to(writer)
        for i in range(len(self._data)):
            self._data[i].write_to(writer)
            if i != len(self._data) - 1:
                (",").write_to(writer)
        ("]").write_to(writer)

    @always_inline
    fn __str__(self) -> String:
        var s = StringBuilder(self.bytes_for_string())
        self.write_to(s)
        return s.build()

    @always_inline
    fn __repr__(self) -> String:
        return self.__str__()

    @always_inline
    fn append(inout self, owned item: Value):
        self._data.append(item^)

    fn bytes_for_string(self) -> Int:
        var n = 2
        for item in self._data:
            n += item[].bytes_for_string() + 1
        n -= 1

        return n

    @staticmethod
    fn _from_reader(inout reader: Reader) raises -> Array:
        var out = Self()
        reader.inc()
        reader.skip_whitespace()
        while likely(reader.peek() != RBRACKET):
            out.append(Value._from_reader(reader))
            var has_comma = False
            if reader.peek() == COMMA:
                has_comma = True
                reader.inc()
            reader.skip_whitespace()
            if unlikely(reader.peek() == RBRACKET and has_comma):
                raise Error("Illegal trailing comma")

            if reader.bytes_remaining() == 0:
                raise Error("Expected ']")
        reader.inc()
        return out^

    @staticmethod
    fn from_string_raises(owned input: String) raises -> Array:
        var r = Reader(input^)
        return Self._from_reader(r)
