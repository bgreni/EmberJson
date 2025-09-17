from .value import Value, Null
from collections import Dict
from sys.intrinsics import unlikely, likely
from .traits import JsonValue, PrettyPrintable
from .parser import Parser
from .tree import _TreeKeyIter, _TreeIter, _TreeValueIter, Tree
from python import PythonObject, Python
from os import abort


struct Object(JsonValue, Sized):
    """Represents a key-value pair object.
    All keys are String and all values are of type `Value` which is
    a variant type of any valid JSON type.
    """

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
    fn __init__(out self, var d: Self.Type):
        self._data = d^

    @always_inline
    @implicit
    fn __init__(out self, var d: Dict[String, Value]):
        self._data = Self.Type()
        for item in d.take_items():
            self._data.insert(item.key^, item.value^)

    fn __init__(
        out self,
        var keys: List[String],
        var values: List[Value],
        __dict_literal__: (),
    ):
        debug_assert(len(keys) == len(values))
        self._data = Self.Type()
        for i in range(len(keys)):
            # TODO: Avoid copies
            self._data.insert(keys[i], values[i].copy())

    @always_inline
    fn __init__(out self, *, parse_string: String) raises:
        var p = Parser(parse_string)
        self = p.parse_object()

    @always_inline
    fn __setitem__(mut self, var key: String, var item: Value):
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
            if k not in other:
                return False
            try:
                if self[k] != other[k]:
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

    fn write_to(self, mut writer: Some[Writer]):
        writer.write(self._data)

    fn pretty_to(
        self, mut writer: Some[Writer], indent: String, *, curr_depth: UInt = 0
    ):
        writer.write("{\n")
        self._pretty_write_items(writer, indent, curr_depth + 1)
        writer.write("}")

    fn _pretty_write_items(
        self, mut writer: Some[Writer], indent: String, curr_depth: UInt
    ):
        var done = 0
        for item in self._data:
            for _ in range(curr_depth):
                writer.write(indent)
            writer.write('"', item.key, '"', ": ")
            item.data._pretty_to_as_element(writer, indent, curr_depth)
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
    fn to_dict(self, out d: Dict[String, Value]):
        d = Dict[String, Value]()
        for item in self.items():
            # TODO: avoid copies
            d[item.key] = item.data.copy()

    fn to_python_object(self) raises -> PythonObject:
        var d = Python.dict()
        for item in self.items():
            d[item.key] = item.data.to_python_object()
        return d
