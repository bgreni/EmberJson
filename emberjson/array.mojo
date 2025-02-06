from .object import Object
from .value import Value
from .utils import *
from .constants import *
from sys.intrinsics import unlikely, likely
from .traits import JsonValue, PrettyPrintable
from .parser import Parser


@value
struct _ArrayIter[mut: Bool, //, origin: Origin[mut], forward: Bool = True]:
    var index: Int
    var src: Pointer[Array, origin]

    fn __iter__(self) -> Self:
        return self

    fn __next__(mut self, out p: Pointer[Value, __origin_of(self.src[]._data)]):
        @parameter
        if forward:
            p = Pointer.address_of(self.src[].__getitem__(self.index))
            self.index += 1
        else:
            self.index -= 1
            p = Pointer.address_of(self.src[].__getitem__(self.index))

    fn __has_next__(self) -> Bool:
        return len(self) > 0

    fn __len__(self) -> Int:
        @parameter
        if forward:
            return len(self.src[]) - self.index
        else:
            return self.index

    fn collect(owned self, out arr: Array):
        arr = Array(capacity=len(self))
        for _ in range(len(self)):
            arr.append(self.__next__()[])


struct Array(Sized, JsonValue):
    """Represents a heterogeneous array of json types.

    This is accomplished by using `Value` for the collection type, which
    is essentially a variant type of the possible valid json types.
    """

    alias Type = List[Value]
    var _data: Self.Type

    @always_inline
    fn __init__(out self):
        # TODO: Maybe a good candidate for autotuning in the future?
        self._data = Self.Type(capacity=8)

    @always_inline
    fn __init__(out self, *, capacity: Int):
        self._data = Self.Type(capacity=capacity)

    @always_inline
    @implicit
    fn __init__(out self, owned d: Self.Type):
        self._data = d^

    @always_inline
    fn __init__(out self, owned *values: Value):
        self._data = Self.Type(elements=values^)

    @always_inline
    fn __copyinit__(out self, other: Self):
        self._data = other._data

    @always_inline
    fn copy(self) -> Self:
        return self

    @always_inline
    fn __moveinit__(out self, owned other: Self):
        self._data = other._data^

    @always_inline
    fn __getitem__[T: Indexer](ref self, ind: T) -> ref [self._data] Value:
        return self._data[ind]

    @always_inline
    fn __setitem__[T: Indexer](mut self, ind: T, owned item: Value):
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
        return _ArrayIter(0, Pointer.address_of(self))

    @always_inline
    fn reversed(ref self) -> _ArrayIter[__origin_of(self), False]:
        return _ArrayIter[forward=False](len(self), Pointer.address_of(self))

    @always_inline
    fn iter(ref self) -> _ArrayIter[__origin_of(self)]:
        return self.__iter__()

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

    fn pretty_to[W: Writer](self, mut writer: W, indent: String, *, curr_depth: Int = 0):
        writer.write("[\n")
        self._pretty_write_items(writer, indent, curr_depth + 1)
        writer.write("]")

    fn _pretty_write_items[W: Writer](self, mut writer: W, indent: String, curr_depth: Int):
        for i in range(len(self._data)):
            writer.write(indent * curr_depth)
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
    fn append(mut self, owned item: Value):
        self._data.append(item^)

    @staticmethod
    @always_inline
    fn from_string(out arr: Array, input: String) raises:
        var p = Parser(input)
        arr = p.parse_array()

    fn to_list(owned self, out l: List[Value]):
        l = self._data^
        self._data = Self.Type()
