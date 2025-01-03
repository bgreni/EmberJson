from .object import Object
from .value import Value
from .utils import *
from .constants import *
from sys.intrinsics import unlikely, likely
from .traits import JsonValue, PrettyPrintable
from .parser import Parser


@value
struct Array(Sized, JsonValue):
    """Represents a json array."""

    alias Type = List[Value]
    var _data: Self.Type

    fn __init__(out self):
        # TODO: Maybe a good candidate for autotuning in the future?
        self._data = Self.Type(capacity=8)

    fn __init__(out self, owned *values: Value):
        self._data = Self.Type(elements=values^)

    @always_inline
    fn __getitem__(ref [_]self, ind: Int) -> ref [self._data] Value:
        return self._data[ind]

    @always_inline
    fn __setitem(mut self, ind: Int, owned item: Value):
        self._data[ind] = item^

    @always_inline
    fn __len__(self) -> Int:
        return len(self._data)

    fn __contains__[T: EqualityComparableCollectionElement, //](self, item: T) -> Bool:
        for v in self._data:
            if v[].isa[T]() and v[][T] == item:
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

    @always_inline
    fn reserve(mut self, n: Int):
        self._data.reserve(n)

    fn write_to[W: Writer](self, mut writer: W):
        ("[").write_to(writer)
        for i in range(len(self._data)):
            self._data[i].write_to(writer)
            if i != len(self._data) - 1:
                (",").write_to(writer)
        ("]").write_to(writer)

    fn pretty_to[W: Writer](self, mut writer: W, indent: String):
        writer.write("[\n")
        self._pretty_write_items(writer, indent)
        writer.write("]")

    fn _pretty_write_items[W: Writer](self, mut writer: W, indent: String):
        for i in range(len(self._data)):
            writer.write(indent)
            self._data[i]._pretty_to_as_element(writer, indent)
            if i < len(self._data) - 1:
                writer.write(",")
            writer.write("\n")

    @always_inline
    fn __str__(self) -> String:
        return write(self)

    @always_inline
    fn __repr__(self) -> String:
        return self.__str__()

    @always_inline
    fn append(mut self, owned item: Value):
        self._data.append(item^)

    fn min_size_for_string(self) -> Int:
        var n = 2
        for item in self._data:
            n += item[].min_size_for_string() + 1
        n -= 1

        return n

    @staticmethod
    @always_inline
    fn from_string(out arr: Array, input: String) raises:
        var p = Parser(input)
        arr = p.parse_array()

    @staticmethod
    @always_inline
    fn from_list(out arr: Array, owned l: Self.Type):
        arr = Self(l^)
