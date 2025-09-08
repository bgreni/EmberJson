from utils import Variant
from sys.intrinsics import unlikely
from os import abort
from python import PythonObject

from .raw_array import RawArray
from .raw_object import RawObject
from .raw_parser import RawParser
from .raw_value import RawValue
from emberjson.traits import JsonValue
from emberjson.utils import write, ByteView


struct RawJSON[origin: ImmutableOrigin](JsonValue, Sized):
    """Top level JSON object, can either be a RawArray, or a RawObject."""

    alias Type = Variant[RawObject[origin], RawArray[origin]]
    var _data: Self.Type

    @always_inline
    fn __init__(out self):
        self._data = RawObject[origin]()

    @implicit
    @always_inline
    fn __init__(out self, var ob: RawObject[origin]):
        self._data = ob^

    @implicit
    @always_inline
    fn __init__(out self, var arr: RawArray[origin]):
        self._data = arr^

    @implicit
    @always_inline
    fn __init__(out self, var l: RawArray[origin].Type):
        self._data = l^

    @implicit
    @always_inline
    fn __init__(out self, var o: RawObject[origin].Type):
        self._data = o^

    @always_inline
    fn __init__(out self, *, parse_bytes: Span[Byte, origin]) raises:
        """Parse JSON document from bytes.

        Args:
            parse_bytes: The bytes to parse.

        Raises:
            If the bytes represent an invalid JSON document.
        """
        var parser = RawParser[origin](parse_bytes)
        self = parser.parse()

    @always_inline
    fn __init__(out self, *, ref [origin]parse_string: String) raises:
        """Parse JSON document from a string.

        Args:
            parse_string: The string to parse.

        Raises:
            If the string represents an invalid JSON document.
        """
        self = Self(parse_bytes=parse_string.as_bytes())

    @always_inline
    fn __copyinit__(out self, other: Self):
        self._data = other._data

    @always_inline
    fn __moveinit__(out self, deinit other: Self):
        self._data = other._data^

    @always_inline
    fn object(ref self) -> ref [self._data] RawObject[origin]:
        """Fetch the inner object of this json document.

        Returns:
            A reference to a JSON object.
        """
        return self._data[RawObject[origin]]

    @always_inline
    fn array(ref self) -> ref [self._data] RawArray[origin]:
        """Fetch the inner array of this json document.

        Returns:
            A reference to a JSON array.
        """
        return self._data[RawArray[origin]]

    fn __contains__(self, v: RawValue[origin]) raises -> Bool:
        """Check if the given value exists in the document.

        Raises:
            If a non-string value is used on an object.

        Returns:
            True if the value is a value within the array or is a key in the object.
        """
        if self.is_array():
            return v in self.array()
        if not v.is_string():
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

    fn pretty_to[
        W: Writer
    ](self, mut writer: W, indent: String, *, curr_depth: UInt = 0):
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
    fn isa[T: Movable & Copyable](self) -> Bool:
        return self._data.isa[T]()

    @always_inline
    fn is_object(self) -> Bool:
        """Check if the inner value is an object.

        Returns:
            True if the inner value is an object else False.
        """
        return self.isa[RawObject[origin]]()

    @always_inline
    fn is_array(self) -> Bool:
        """Check if the inner value is an array.

        Returns:
            True if the inner value is an array else False.
        """
        return self.isa[RawArray[origin]]()

    fn to_python_object(self) raises -> PythonObject:
        return (
            self.array()
            .to_python_object() if self.is_array() else self.object()
            .to_python_object()
        )
