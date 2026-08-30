from .object import Object
from .value import Value
from .traits import JsonValue
from .utils import PaddedBuffer, PAD_INPUT_THRESHOLD
from ._utf8 import is_valid_utf8
from ._deserialize import Parser, ParseOptions
from std.python import PythonObject, Python

from emberserde.serialize import Serializer
from emberserde.deserialize import Deserializer
from emberserde.error import SerializationError, DeserializationError


struct _ArrayIter[mut: Bool, //, origin: Origin[mut=mut], forward: Bool = True](
    Copyable, Sized, TrivialRegisterPassable
):
    var index: Int
    var src: Pointer[Array, Self.origin]

    def __init__(out self, src: Pointer[Array, Self.origin]):
        self.src = src

        comptime if Self.forward:
            self.index = 0
        else:
            self.index = len(self.src[])

    def __iter__(self) -> Self:
        return self

    def __next__(
        mut self,
    ) raises StopIteration -> ref[self.src[]._data[self.index]] Value:
        if len(self) == 0:
            raise StopIteration()

        comptime if Self.forward:
            self.index += 1
            return self.src[][self.index - 1]
        else:
            self.index -= 1
            return self.src[][self.index]

    def __len__(self) -> Int:
        comptime if Self.forward:
            return len(self.src[]) - self.index
        else:
            return self.index


struct Array(JsonValue, Sized):
    """Represents a heterogeneous array of json types.

    This is accomplished by using `Value` for the collection type, which
    is essentially a variant type of the possible valid json types.
    """

    comptime Type = List[Value]
    var _data: Self.Type

    @always_inline
    def __init__(out self):
        self._data = Self.Type()

    @always_inline
    def __init__(out self, *, capacity: Int):
        self._data = Self.Type(capacity=capacity)

    @always_inline
    @implicit
    def __init__(out self, var d: Self.Type):
        self._data = d^

    @always_inline
    def __init__(
        out self, var *values: Value, __list_literal__: NoneType = None
    ):
        self._data = Self.Type(*values^, __list_literal__=None)

    @always_inline
    def __init__(out self: Array, *, parse_string: String) raises:
        # Default options: UTF-8 validation is on (see ParseOptions).
        if not is_valid_utf8(StringSlice(parse_string)):
            raise Error("Invalid UTF-8 in input")
        # See `emberjson.parse`: pad-and-copy enables unchecked hot loops;
        # tiny inputs skip the copy since it would cost more than the parse.
        if parse_string.byte_length() < PAD_INPUT_THRESHOLD:
            var p = Parser(parse_string)
            self = p.parse_array()
        else:
            var buf = PaddedBuffer(StringSlice(parse_string).as_bytes())
            var p = Parser[options=ParseOptions()._padded()](padded=buf)
            self = p.parse_array()

    @always_inline
    def __getitem__(ref self, ind: Some[Indexer]) -> ref[self._data[ind]] Value:
        return self._data[ind]

    @always_inline
    def __setitem__(mut self, ind: Some[Indexer], var item: Value):
        self._data[ind] = item^

    @always_inline
    def __len__(self) -> Int:
        return len(self._data)

    @always_inline
    def __bool__(self) -> Bool:
        return len(self) != 0

    @always_inline
    def __contains__(self, v: Value) -> Bool:
        return v in self._data

    @always_inline
    def __eq__(self, other: Self) -> Bool:
        return self._data == other._data

    @always_inline
    def __ne__(self, other: Self) -> Bool:
        return self._data != other._data

    @always_inline
    def __iter__(ref self) -> _ArrayIter[origin_of(self)]:
        return _ArrayIter(Pointer(to=self))

    @always_inline
    def reversed(ref self) -> _ArrayIter[origin_of(self), False]:
        return _ArrayIter[forward=False](Pointer(to=self))

    @always_inline
    def iter(ref self) -> _ArrayIter[origin_of(self)]:
        return self.__iter__()

    @always_inline
    def reserve(mut self, n: Int):
        self._data.reserve(n)

    def write_to(self, mut writer: Some[Writer]):
        writer.write("[")
        for i in range(len(self._data)):
            writer.write(self._data[i])
            if i != len(self._data) - 1:
                writer.write(",")
        writer.write("]")

    def write_repr_to(self, mut writer: Some[Writer]):
        writer.write("Array(")
        for i in range(len(self._data)):
            self._data[i].write_repr_to(writer)
            if i != len(self._data) - 1:
                writer.write(", ")
        writer.write(")")

    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        var st = s.begin_seq(len(self._data))
        for i in range(len(self._data)):
            st.serialize_element(self._data[i])
        st.end()

    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        var arr = Self()
        var st = d.begin_seq()
        while st.has_next():
            arr.append(st.expect_element[Value]())
        st.end()
        return arr^

    @always_inline
    def append(mut self, var item: Value):
        self._data.append(item^)

    @always_inline
    def insert(mut self, idx: Int, var item: Value):
        self._data.insert(idx, item^)

    @always_inline
    def pop(mut self, idx: Int) -> Value:
        return self._data.pop(idx)

    def to_list(self, out l: List[Value]):
        l = self._data.copy()

    def to_python_object(self) raises -> PythonObject:
        var l = Python.list()
        for ref item in self._data:
            l.append(item.to_python_object())
        return l
