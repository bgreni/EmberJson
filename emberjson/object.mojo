from .value import Value, Null
from collections import Dict, List
from sys.intrinsics import unlikely, likely
from .traits import JsonValue, PrettyPrintable
from ._deserialize import Parser
from .utils import write_escaped_string
from python import PythonObject, Python
from os import abort
from memory import UnsafePointer


@fieldwise_init
struct KeyValuePair(Copyable, Movable):
    var key: String
    var value: Value


struct _ObjectIter[origin: Origin](Sized, TrivialRegisterType):
    var src: Pointer[Object, Self.origin]
    var idx: Int

    @always_inline
    fn __init__(out self, src: Pointer[Object, Self.origin]):
        self.src = src
        self.idx = 0

    @always_inline
    fn __iter__(self) -> Self:
        return self

    @always_inline
    fn __next__(
        mut self,
    ) raises StopIteration -> ref[self.src[]._data] KeyValuePair:
        if self.idx >= len(self.src[]):
            raise StopIteration()
        self.idx += 1
        return self.src[]._data[self.idx - 1]

    @always_inline
    fn __len__(self) -> Int:
        return len(self.src[]) - self.idx


struct _ObjectKeyIter[origin: Origin](Sized, TrivialRegisterType):
    var src: Pointer[Object, Self.origin]
    var idx: Int

    @always_inline
    fn __init__(out self, src: Pointer[Object, Self.origin]):
        self.src = src
        self.idx = 0

    @always_inline
    fn __iter__(self) -> Self:
        return self

    @always_inline
    fn __next__(
        mut self,
    ) raises StopIteration -> ref[self.src[]._data[0].key] String:
        if self.idx >= len(self.src[]):
            raise StopIteration()
        self.idx += 1
        return self.src[]._data[self.idx - 1].key

    @always_inline
    fn __len__(self) -> Int:
        return len(self.src[]) - self.idx


struct _ObjectValueIter[origin: Origin](Sized, TrivialRegisterType):
    var src: Pointer[Object, Self.origin]
    var idx: Int

    @always_inline
    fn __init__(out self, src: Pointer[Object, Self.origin]):
        self.src = src
        self.idx = 0

    @always_inline
    fn __iter__(self) -> Self:
        return self

    @always_inline
    fn __next__(
        mut self,
    ) raises StopIteration -> ref[self.src[]._data[0].value] Value:
        if self.idx >= len(self.src[]):
            raise StopIteration()
        self.idx += 1
        return self.src[]._data[self.idx - 1].value

    @always_inline
    fn __len__(self) -> Int:
        return len(self.src[]) - self.idx


struct Object(JsonValue, Sized):
    """Represents a key-value pair object.
    All keys are String and all values are of type `Value` which is
    a variant type of any valid JSON type.
    """

    comptime Type = List[KeyValuePair]
    var _data: Self.Type

    @always_inline
    fn __init__(out self):
        self._data = Self.Type()

    @always_inline
    fn __init__(out self, *, capacity: Int):
        self._data = Self.Type(capacity=capacity)

    @always_inline
    @implicit
    fn __init__(out self, var d: Self.Type):
        self._data = d^

    @always_inline
    @implicit
    fn __init__(out self, var d: Dict[String, Value]):
        self._data = Self.Type()
        for item in d.items():
            self._data.append(KeyValuePair(item.key, item.value.copy()))

    fn __init__(
        out self,
        var keys: List[String],
        var values: List[Value],
        __dict_literal__: (),
    ):
        debug_assert(len(keys) == len(values))
        self._data = Self.Type(capacity=len(keys))
        for i in range(len(keys)):
            self._data.append(KeyValuePair(keys[i], values[i].copy()))

    @always_inline
    fn __init__(out self, *, parse_string: String) raises:
        var p = Parser(parse_string)
        self = p.parse_object()

    fn __setitem__(mut self, var key: String, var item: Value):
        """Sets a key-value pair.
        If the key already exists, its value is updated.
        """
        for i in range(len(self._data)):
            if self._data[i].key == key:
                self._data[i].value = item^
                return
        self._data.append(KeyValuePair(key^, item^))

    fn pop(mut self, key: String) raises:
        for i in range(len(self._data)):
            if self._data[i].key == key:
                _ = self._data.pop(i)
                return
        raise Error("KeyError: " + key)

    fn __getitem__(
        ref self, key: String
    ) raises -> ref[self._data[0].value] Value:
        for i in range(len(self._data)):
            if self._data[i].key == key:
                return self._data[i].value
        raise Error("KeyError: " + key)

    @always_inline
    fn __contains__(self, key: String) -> Bool:
        for i in range(len(self._data)):
            if self._data[i].key == key:
                return True
        return False

    @always_inline
    fn __len__(self) -> Int:
        return len(self._data)

    fn __eq__(self, other: Self) -> Bool:
        if len(self) != len(other):
            return False

        # Iterate over keys because self.__iter__ returns keys
        for key in self:
            if key not in other:
                return False
            try:
                if self[key] != other[key]:
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
    fn keys(ref self) -> _ObjectKeyIter[origin_of(self)]:
        return _ObjectKeyIter(Pointer(to=self))

    @always_inline
    fn values(ref self) -> _ObjectValueIter[origin_of(self)]:
        return _ObjectValueIter(Pointer(to=self))

    @always_inline
    fn __iter__(ref self) -> _ObjectKeyIter[origin_of(self)]:
        return self.keys()

    @always_inline
    fn items(ref self) -> _ObjectIter[origin_of(self)]:
        return _ObjectIter(Pointer(to=self))

    @always_inline
    fn write_json(self, mut writer: Some[Writer]):
        writer.write(self)

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
            write_escaped_string(item.key, writer)
            writer.write(": ")
            item.value._pretty_to_as_element(writer, indent, curr_depth)
            if done < len(self._data) - 1:
                writer.write(",")
            writer.write("\n")
            done += 1

    @always_inline
    fn write_to(self, mut writer: Some[Writer]):
        writer.write("{")
        for i in range(len(self._data)):
            write_escaped_string(self._data[i].key, writer)
            writer.write(":")
            writer.write(self._data[i].value)
            if i < len(self._data) - 1:
                writer.write(",")
        writer.write("}")

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
            d[item.key] = item.value.copy()

    fn to_python_object(self) raises -> PythonObject:
        var d = Python.dict()
        for item in self.items():
            d[PythonObject(item.key)] = item.value.to_python_object()
        return d

    @staticmethod
    fn from_json(mut json: Parser, out s: Self) raises:
        s = json.parse_object()
