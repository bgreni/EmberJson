from .object import Object
from .value import Value
from .traits import JsonValue, PrettyPrintable
from .parser import Parser
from python import PythonObject, Python


@register_passable("trivial")
struct _ArrayIter[mut: Bool, //, origin: Origin[mut], forward: Bool = True](
    Copyable, Movable, Sized
):
    var index: Int
    var src: Pointer[Array, origin]

    fn __init__(out self, src: Pointer[Array, origin]):
        self.src = src

        @parameter
        if forward:
            self.index = 0
        else:
            self.index = len(self.src[])

    fn __iter__(self) -> Self:
        return self

    fn __next__(mut self) -> ref [self.src[]._data] Value:
        @parameter
        if forward:
            self.index += 1
            return self.src[].__getitem__(self.index - 1)
        else:
            self.index -= 1
            return self.src[].__getitem__(self.index)

    fn __has_next__(self) -> Bool:
        return len(self) > 0

    fn __len__(self) -> Int:
        @parameter
        if forward:
            return len(self.src[]) - self.index
        else:
            return self.index


struct Array(JsonValue, Sized):
    """Represents a heterogeneous array of json types.

    This is accomplished by using `Value` for the collection type, which
    is essentially a variant type of the possible valid json types.
    """

    alias Type = List[Value]
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
    fn __init__(out self, var *values: Value, __list_literal__: () = ()):
        self._data = Self.Type(elements=values^)

    @always_inline
    fn __init__(out self: Array, *, parse_string: String) raises:
        var p = Parser(parse_string)
        self = p.parse_array()

    @always_inline
    fn __copyinit__(out self, other: Self):
        self._data = other._data

    @always_inline
    fn copy(self) -> Self:
        return self

    @always_inline
    fn __moveinit__(out self, deinit  other: Self):
        self._data = other._data^

    @always_inline
    fn __getitem__[T: Indexer](ref self, ind: T) -> ref [self._data] Value:
        return self._data[ind]

    @always_inline
    fn __setitem__[T: Indexer](mut self, ind: T, var item: Value):
        self._data[ind] = item^

    @always_inline
    fn __len__(self) -> Int:
        return len(self._data)

    @always_inline
    fn __bool__(self) -> Bool:
        return len(self) == 0

    @always_inline
    fn __as_bool__(self) -> Bool:
        return Bool(self)

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
    fn __iter__(ref self) -> _ArrayIter[__origin_of(self)]:
        return _ArrayIter(Pointer(to=self))

    @always_inline
    fn reversed(ref self) -> _ArrayIter[__origin_of(self), False]:
        return _ArrayIter[forward=False](Pointer(to=self))

    @always_inline
    fn iter(ref self) -> _ArrayIter[__origin_of(self)]:
        return self.__iter__()

    @always_inline
    fn reserve(mut self, n: Int):
        self._data.reserve(n)

    fn write_to[W: Writer](self, mut writer: W):
        writer.write("[")
        for i in range(len(self._data)):
            writer.write(self._data[i])
            if i != len(self._data) - 1:
                writer.write(",")
        writer.write("]")

    fn pretty_to[
        W: Writer
    ](self, mut writer: W, indent: String, *, curr_depth: UInt = 0):
        writer.write("[\n")
        self._pretty_write_items(writer, indent, curr_depth + 1)
        writer.write("]")

    fn _pretty_write_items[
        W: Writer
    ](self, mut writer: W, indent: String, curr_depth: UInt):
        for i in range(len(self._data)):
            for _ in range(curr_depth):
                writer.write(indent)
            self._data[i]._pretty_to_as_element(writer, indent, curr_depth)
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
    fn append(mut self, var  item: Value):
        self._data.append(item^)

    fn to_list(deinit self, out l: List[Value]):
        l = self._data^

    fn to_python_object(self) raises -> PythonObject:
        return Python.list(self._data)
