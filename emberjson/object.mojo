from .value import Value, Null
from collections import Dict
from .constants import *
from .utils import *
from sys.intrinsics import unlikely, likely
from .traits import JsonValue, PrettyPrintable
from .parser import Parser
from .tree import _TreeKeyIter, _TreeIter, _TreeValueIter, Tree


struct Object(Sized, JsonValue):
    alias Type = Tree
    var _data: Self.Type

    alias ObjectIter = _TreeIter
    alias ObjectKeyIter = _TreeKeyIter
    alias ObjectValueIter = _TreeValueIter

    @always_inline
    fn __init__(out self):
        self._data = Self.Type()

    @always_inline
    @implicit
    fn __init__(out self, owned d: Self.Type):
        self._data = d^

    @always_inline
    @implicit
    fn __init__(out self, d: Dict[String, Value]):
        self._data = Self.Type()
        for item in d.items():
            self._data.insert(item[].key, item[].value)

    @always_inline
    fn __copyinit__(out self, other: Self):
        self._data = other._data

    @always_inline
    fn __moveinit__(out self, owned other: Self):
        self._data = other._data^

    @always_inline
    fn copy(self) -> Self:
        return self

    fn min_size_for_string(self) -> Int:
        var n = 2 + len(self)  # include ':' for each pairing
        for item in self._data:
            n += 3 + len(item[].key) + item[].data.min_size_for_string()
        n -= 1
        return n

    @always_inline
    fn __setitem__(mut self, owned key: String, owned item: Value):
        self._data[key^] = item^

    @always_inline
    fn __getitem__(ref self, key: String) raises -> ref [self._data] Value:
        return self._data.__getitem__(key)

    @always_inline
    fn __contains__(self, key: String) -> Bool:
        return key in self._data

    @always_inline
    fn __len__(self) -> Int:
        return len(self._data)

    fn __eq__(self, other: Self) -> Bool:
        if len(self) != len(other):
            return False

        for k in self._data.keys():
            if k[] not in other:
                return False
            try:
                if self[k[]] != other[k[]]:
                    return False
            except:
                return False
        return True

    @always_inline
    fn __ne__(self, other: Self) -> Bool:
        return not self == other

    @always_inline
    fn __bool__(self) -> Bool:
        return len(self) == 0

    @always_inline
    fn __as_bool__(self) -> Bool:
        return Bool(self)

    @always_inline
    fn keys(ref self) -> Self.ObjectKeyIter:
        return self._data.keys()

    @always_inline
    fn values(ref self) -> Self.ObjectValueIter:
        return self._data.values()

    @always_inline
    fn __iter__(ref self) -> Self.ObjectKeyIter:
        return self.keys()

    @always_inline
    fn items(ref self) -> Self.ObjectIter:
        return self._data.items()

    fn write_to[W: Writer](self, mut writer: W):
        writer.write(self._data)

    fn pretty_to[W: Writer](self, mut writer: W, indent: String, *, curr_depth: Int = 0):
        writer.write("{\n")
        self._pretty_write_items(writer, indent, curr_depth + 1)
        writer.write("}")

    fn _pretty_write_items[W: Writer](self, mut writer: W, indent: String, curr_depth: Int):
        var done = 0
        for item in self._data:
            writer.write(indent * curr_depth, '"', item[].key, '"', ": ")
            item[].data._pretty_to_as_element(writer, indent, curr_depth)
            if done < len(self._data) - 1:
                writer.write(",")
            writer.write("\n")
            done += 1

    @always_inline
    fn __str__(self) -> String:
        return write(self)

    @always_inline
    fn __repr__(self) -> String:
        return self.__str__()

    @staticmethod
    @always_inline
    fn from_string(out o: Object, s: String) raises:
        var p = Parser(s)
        o = p.parse_object()

    @always_inline
    fn to_dict(owned self, out d: Dict[String, Value]):
        # TODO: Avoid copies here
        d = Dict[String, Value]()
        for item in self.items():
            d[item[].key] = item[].data
