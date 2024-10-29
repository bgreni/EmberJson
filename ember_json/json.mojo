from collections import Dict, Optional
from utils import Variant
from .reader import Reader
from .object import Object
from .array import Array
from .constants import *
from .traits import JsonValue
from .utils import write, ByteView


@value
struct JSON(JsonValue, Sized):
    """Top level JSON object, can either be an Array, or an Object.

    ```mojo
    from ember_json import JSON
    var arr = JSON.from_string("[1, 2, 3]")
    var foo = arr[2] # index based access for arrays

    var object = JSON.from_string('{"key": true}')
    var bar = object["key"] # key based access for objects
    try:
        # using the wrong accessor type will raise an exception
        _ = arr["key"]
        _ = object[1]
    except:
        pass
    ```
    """

    alias Type = Variant[Object, Array]
    var _data: Self.Type

    fn __init__(inout self):
        self._data = Object()

    @always_inline
    fn _get[T: CollectionElement](ref [_]self: Self) -> ref [self._data] T:
        return self._data.__getitem__[T]()

    @always_inline
    fn object(ref [_]self) -> ref [self._data] Object:
        """Fetch the inner object of this json document.

        Returns:
            A reference to a JSON object.
        """
        return self._get[Object]()

    @always_inline
    fn array(ref [_]self) -> ref [self._data] Array:
        """Fetch the inner array of this json document.

        Returns:
            A reference to a JSON array.
        """
        return self._get[Array]()

    fn __getitem__(ref [_]self, key: String) raises -> ref [self.object()._data._entries[0].value().value] Value:
        """Access inner object value by key.

        Raises:
            If this document does not contain an object.

        Returns:
            A reference to the value associated with the given key.
        """
        if not self.is_object():
            raise Error("Array index must be an int")
        return self.object().__getitem__(key)

    fn __getitem__(ref [_]self, ind: Int) raises -> ref [self.array()._data] Value:
        """Access the inner array by index.

        Raises:
            If this document does not contain an array.

        Returns:
            A reference to the value at the given index.
        """
        if not self.is_array():
            raise Error("Object key expected to be string")
        return self.array()[ind]

    fn __setitem__(inout self, owned key: String, owned item: Value) raises:
        """Mutate the inner object.

        Raises:
            If this document does not contain an object.
        """
        if not self.is_object():
            raise Error("Object key expected to be string")
        self.object()[key^] = item^

    fn __setitem__(inout self, ind: Int, owned item: Value) raises:
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

    fn __eq__(self, other: Self) -> Bool:
        if self.is_object() and other.is_object():
            return self.object() == other.object()
        if self.is_array() and other.is_array():
            return self.array() == other.array()
        return False

    @always_inline
    fn __ne__(self, other: Self) -> Bool:
        return not self == other

    @always_inline
    fn __len__(self) -> Int:
        return len(self.array()) if self.is_array() else len(self.object())

    fn write_to[W: Writer](self, inout writer: W):
        if self.is_object():
            self.object().write_to(writer)
        elif self.is_array():
            self.array().write_to(writer)

    @always_inline
    fn __str__(self) -> String:
        return write(self)

    @always_inline
    fn __repr__(self) -> String:
        return self.__str__()

    @always_inline
    fn isa[T: CollectionElement](self) -> Bool:
        return self._data.isa[T]()

    @always_inline
    fn is_object(self) -> Bool:
        return self.isa[Object]()

    @always_inline
    fn is_array(self) -> Bool:
        return self.isa[Array]()

    @always_inline
    @staticmethod
    fn from_string(input: String) raises -> JSON:
        """Parse JSON document from a string.

        Raises:
            If the string represent an invalid JSON document.

        Returns:
            A parsed JSON document.
        """
        return Self.from_bytes(input.as_bytes())

    @staticmethod
    fn from_bytes[origin: ImmutableOrigin, //](input: ByteView[origin]) raises -> JSON:
        """Parse JSON document from bytes.

        Raises:
            If the bytes represent an invalid JSON document.

        Returns:
            A parsed JSON document.
        """
        var data = Self()
        var reader = Reader(input)
        reader.skip_whitespace()
        var next_char = reader.peek()
        if next_char == LCURLY:
            data = Object._from_reader(reader)
        elif next_char == LBRACKET:
            data = Array._from_reader(reader)
        else:
            raise Error("Invalid json")

        reader.skip_whitespace()
        if reader.has_more():
            raise Error("Invalid json, expected end of input, recieved: " + reader.remaining())

        return data

    fn bytes_for_string(self) -> Int:
        """Should only be used as an estimatation. Sizes of float values are
        unreliable.
        """
        if self.is_array():
            return self.array().bytes_for_string()
        return self.object().bytes_for_string()

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
