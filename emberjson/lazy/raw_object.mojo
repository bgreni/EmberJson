from collections import Dict
from sys.intrinsics import unlikely, likely
from python import PythonObject, Python
from os import abort

from .raw_value import RawValue
from .raw_tree import _RawTreeKeyIter, _RawTreeIter, _RawTreeValueIter, RawTree
from .raw_parser import RawParser
from emberjson.traits import JsonValue


struct RawObject[origin: ImmutableOrigin](JsonValue, Sized):
    """Represents a key-value pair object.
    All keys are String and all values are of type `RawValue` which is
    a variant type of any valid JSON type.
    """

    alias Type = RawTree[origin]
    var _data: Self.Type

    alias ObjectIter = _RawTreeIter[origin]
    alias ObjectKeyIter = _RawTreeKeyIter[origin]
    alias ObjectValueIter = _RawTreeValueIter[origin]

    @always_inline
    fn __init__(out self):
        self._data = Self.Type()

    @always_inline
    @implicit
    fn __init__(out self, var d: Self.Type):
        self._data = d^

    @always_inline
    @implicit
    fn __init__(out self, d: Dict[String, RawValue[origin]]):
        self._data = Self.Type()
        for item in d.items():
            self._data.insert(item.key, item.value.copy())

    fn __init__(
        out self,
        var keys: List[String],
        var values: List[RawValue[origin]],
        __dict_literal__: (),
    ):
        debug_assert(len(keys) == len(values))
        self._data = Self.Type()
        for i in range(len(keys)):
            # NOTE: Call `pop` to move the value out of the list instead of copying it.
            # We keep index 0, since each pop moves the remaining values to the left.
            self._data.insert(keys.pop(0), values.pop(0))

    @always_inline
    fn __init__(out self, *, parse_string: StringSlice[origin]) raises:
        var p = RawParser(parse_string)
        self = p.parse_object()

    @always_inline
    fn __copyinit__(out self, other: Self):
        self._data = other._data

    @always_inline
    fn __moveinit__(out self, deinit other: Self):
        self._data = other._data^

    @always_inline
    fn __setitem__(mut self, var key: String, var item: RawValue[origin]):
        self._data[key^] = item^

    @always_inline
    fn __getitem__(ref self, key: String) raises -> RawValue[origin]:
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

    fn pretty_to[
        W: Writer
    ](self, mut writer: W, indent: String, *, curr_depth: UInt = 0):
        writer.write("{\n")
        self._pretty_write_items(writer, indent, curr_depth + 1)
        writer.write("}")

    fn _pretty_write_items[
        W: Writer
    ](self, mut writer: W, indent: String, curr_depth: UInt):
        var done = 0
        for item in self._data:
            for _ in range(curr_depth):
                writer.write(indent)
            writer.write('"', item[].key, '"', ": ")
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

    @always_inline
    fn to_dict(var self, out d: Dict[String, RawValue[origin]]):
        d = Dict[String, RawValue[origin]]()
        for item in self.items():
            d[item[].key] = item[].data

    fn to_python_object(self) raises -> PythonObject:
        var d = Python.dict()
        for item in self.items():
            d[item[].key] = item[].data.to_python_object()
        return d
