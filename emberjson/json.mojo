from collections import Dict, Optional
from utils import Variant
from .object import Object
from .array import Array
from .constants import *
from .traits import JsonValue, PrettyPrintable
from .utils import write, ByteView
from sys.intrinsics import unlikely
from .parser import Parser
from os import abort


struct JSON(JsonValue, Sized, PrettyPrintable):
    """Top level JSON object, can either be an Array, or an Object."""

    alias Type = Variant[Object, Array]
    var _data: Self.Type

    @always_inline
    fn __init__(out self):
        self._data = Object()

    @implicit
    @always_inline
    fn __init__(out self, owned ob: Object):
        self._data = ob^

    @implicit
    @always_inline
    fn __init__(out self, owned arr: Array):
        self._data = arr^

    @implicit
    @always_inline
    fn __init__(out self, owned l: Array.Type):
        self._data = l^

    @implicit
    @always_inline
    fn __init__(out self, owned o: Object.Type):
        self._data = o^

    @always_inline
    fn __copyinit__(out self, other: Self):
        self._data = other._data

    @always_inline
    fn __moveinit__(out self, owned other: Self):
        self._data = other._data^

    @always_inline
    fn copy(self) -> Self:
        return self

    @always_inline
    fn object(ref self) -> ref [self._data] Object:
        """Fetch the inner object of this json document.

        Returns:
            A reference to a JSON object.
        """
        return self._data[Object]

    @always_inline
    fn array(ref self) -> ref [self._data] Array:
        """Fetch the inner array of this json document.

        Returns:
            A reference to a JSON array.
        """
        return self._data[Array]

    @always_inline
    fn __getitem__(self, key: String) raises -> ref [self.object()._data._entries[0].value().value] Value:
        """Access inner object value by key.

        Raises:
            If this document does not contain an object.

        Returns:
            A reference to the value associated with the given key.
        """
        if not self.is_object():
            raise Error("Array index must be an int")
        return self.object().__getitem__(key)

    @always_inline
    fn __getitem__(self, ind: Int) raises -> ref [self.array()._data] Value:
        """Access the inner array by index.

        Raises:
            If this document does not contain an array.

        Returns:
            A reference to the value at the given index.
        """
        if not self.is_array():
            raise Error("Object key expected to be string")
        return self.array().__getitem__(ind)

    @always_inline
    fn __setitem__(mut self, owned key: String, owned item: Value) raises:
        """Mutate the inner object.

        Raises:
            If this document does not contain an object.
        """
        if not self.is_object():
            raise Error("Object key expected to be string")
        self.object()[key^] = item^

    @always_inline
    fn __setitem__(mut self, ind: Int, owned item: Value) raises:
        """Mutate the inner array.

        Raises:
            If this document does not contain an array.
        """
        if not self.is_array():
            raise Error("Array index must be an int")
        self.array()[ind] = item^

    fn __contains__(self, v: Value) raises -> Bool:
        """Check if the given value exists in the document.

        Raises:
            If a non-string value is used on an object.

        Returns:
            True if the value is a value within the array or is a key in the object.
        """
        if self.is_array():
            return v in self.array()
        if not v.isa[String]():
            raise Error("expected string key")
        return v.string() in self.object()

    fn _type_equal(self, other: Self) -> Bool:
        return self._data._get_discr() == other._data._get_discr()

    fn __eq__(self, other: Self) -> Bool:
        """Checks if this document is equal to another.

        Returns:
            True if the document is of same type and value as other else False.
        """
        if not self._type_equal(other):
            return False
        elif self.is_object():
            return self.object() == other.object()
        elif self.is_array():
            return self.array() == other.array()
        abort("unreachable")
        return False

    @always_inline
    fn __ne__(self, other: Self) -> Bool:
        """Checks if this document is not equal to another.

        Returns:
            True if the document is not of same type and value as other else False.
        """
        return not self == other

    @always_inline
    fn __len__(self) -> Int:
        """Returns the length of the inner value. This will be the number of items
        in an array, or the number of keys in an object.

        Returns:
            The length of the inner container.
        """
        return len(self.array()) if self.is_array() else len(self.object())

    @always_inline
    fn __bool__(self) -> Bool:
        """Returns True if the size of the inner collection is non-empty.

        Return:
            True if the inner container is non-empty else False
        """
        return len(self) == 0

    @always_inline
    fn __as_bool__(self) -> Bool:
        """Returns True if the size of the inner collection is non-empty.

        Return:
            True if the inner container is non-empty else False
        """
        return Bool(self)

    @always_inline
    fn write_to[W: Writer](self, mut writer: W):
        """Writes the string representation of the document to the given writer.

        Args:
            writer: A writer to write to.
        """
        if self.is_object():
            writer.write(self.object())
        else:
            writer.write(self.array())

    fn pretty_to[W: Writer](self, mut writer: W, indent: String, *, curr_depth: Int = 0):
        """Write the pretty representation to a writer.

        Args:
            writer: The writer to write to.
            indent: If an int denotes the number of space characters to use,
                    if a string then use the given string to indent.
            curr_depth: The current depth into the json document, controls the
                    current level of indendation.
        """
        if self.is_object():
            self.object().pretty_to(writer, indent, curr_depth=curr_depth)
        else:
            self.array().pretty_to(writer, indent, curr_depth=curr_depth)

    @always_inline
    fn __str__(self) -> String:
        """Returns the json string repr of the document.

        Returns:
            A json string.
        """
        return write(self)

    @always_inline
    fn __repr__(self) -> String:
        """Returns the json string repr of the document.

        Returns:
            A json string.
        """
        return self.__str__()

    @always_inline
    fn isa[T: CollectionElement](self) -> Bool:
        return self._data.isa[T]()

    @always_inline
    fn is_object(self) -> Bool:
        """Check if the inner value is an object.

        Returns:
            True if the inner value is an object else False.
        """
        return self.isa[Object]()

    @always_inline
    fn is_array(self) -> Bool:
        """Check if the inner value is an array.

        Returns:
            True if the inner value is an array else False.
        """
        return self.isa[Array]()

    @always_inline
    @staticmethod
    fn from_string(out json: JSON, input: String) raises:
        """Parse JSON document from a string.

        Raises:
            If the string represent an invalid JSON document.

        Returns:
            A parsed JSON document.
        """
        json = Self.from_bytes(input.as_bytes())

    @staticmethod
    @always_inline
    fn from_bytes[origin: ImmutableOrigin, //](out data: JSON, input: ByteView[origin]) raises:
        """Parse JSON document from bytes.

        Raises:
            If the bytes represent an invalid JSON document.

        Returns:
            A parsed JSON document.
        """
        var parser = Parser(input.unsafe_ptr(), len(input))
        data = parser.parse()

    fn min_size_for_string(self) -> Int:
        """Should only be used as an estimatation. Sizes of float values are
        unreliable.
        """
        if self.is_array():
            return self.array().min_size_for_string()
        return self.object().min_size_for_string()

    @staticmethod
    fn try_from_string(input: String) -> Optional[JSON]:
        """Parse JSON document from a string.

        Returns:
            An optional parsed JSON document, returns None if the input is invalid.
        """
        try:
            return JSON.from_string(input)
        except:
            return None
