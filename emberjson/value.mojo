from .object import Object
from .array import Array
from .utils import (
    will_overflow,
    constrain_json_type,
    write_escaped_string,
    ByteView,
)
from utils import Variant
from .traits import JsonValue, PrettyPrintable, JsonSerializable
from collections import InlineArray
from memory import UnsafePointer
from sys.intrinsics import unlikely, likely
from ._deserialize import Parser
from .format_int import write_int
from sys.info import bit_width_of
from .teju import write_f64
from os import abort
from python import PythonObject
from ._pointer import resolve_pointer, PointerIndex


@fieldwise_init
@register_passable("trivial")
struct Null(JsonValue):
    """Represents "null" json value.
    Can be implicitly converted from `None`.
    """

    @always_inline
    fn __eq__(self, n: Null) -> Bool:
        return True

    @always_inline
    fn __ne__(self, n: Null) -> Bool:
        return False

    @always_inline
    fn __str__(self) -> String:
        return "null"

    @always_inline
    fn __repr__(self) -> String:
        return self.__str__()

    @always_inline
    fn __bool__(self) -> Bool:
        return False

    @always_inline
    fn write_to(self, mut writer: Some[Writer]):
        writer.write(self.__str__())

    @always_inline
    fn pretty_to(
        self, mut writer: Some[Writer], indent: String, *, curr_depth: UInt = 0
    ):
        writer.write(self)

    fn to_python_object(self) raises -> PythonObject:
        return {}

    @always_inline
    fn write_json(self, mut writer: Some[Writer]):
        writer.write(self)

    @staticmethod
    fn from_json(mut json: Parser, out s: Self) raises:
        s = json.parse_null()


struct Value(JsonValue, Sized):
    """Top level JSON object, representing any valid JSON value."""

    comptime Type = Variant[
        Int64, UInt64, Float64, String, Bool, Object, Array, Null
    ]
    var _data: Self.Type

    @always_inline
    fn __init__(out self):
        self._data = Null()

    @implicit
    @always_inline
    fn __init__(out self, n: NoneType._mlir_type):
        self._data = Null()

    @implicit
    @always_inline
    fn __init__(out self, var v: Self.Type):
        self._data = v^

    @implicit
    @always_inline
    fn __init__(out self, v: Int64):
        self._data = v

    @implicit
    @always_inline
    fn __init__(out self, v: UInt64):
        self._data = v

    @implicit
    @always_inline
    fn __init__(out self, v: IntLiteral):
        if UInt64(v) > Int64.MAX.cast[DType.uint64]():
            self._data = UInt64(v)
        else:
            self._data = Int64(v)

    @implicit
    @always_inline
    fn __init__(out self, v: Int):
        constrained[
            bit_width_of[DType.int]() <= bit_width_of[DType.int64](),
            "Cannot fit index width into 64 bits for signed integer",
        ]()
        self._data = Int64(v)

    @implicit
    @always_inline
    fn __init__(out self, v: UInt):
        constrained[
            bit_width_of[DType.int]() <= bit_width_of[DType.uint64](),
            "Cannot fit index width into 64 bits for unsigned integer",
        ]()
        self._data = UInt64(v)

    @implicit
    @always_inline
    fn __init__(out self, v: Float64):
        self._data = v

    @implicit
    @always_inline
    fn __init__(out self, var v: Object):
        self._data = v^

    @implicit
    @always_inline
    fn __init__(out self, var v: Array):
        self._data = v^

    @implicit
    @always_inline
    fn __init__(out self, var v: String):
        self._data = v^

    @always_inline
    fn __init__(out self, *, parse_string: String) raises:
        """Parse JSON document from a string.

        Args:
            parse_string: The string to parse.

        Raises:
            If the string represents an invalid JSON document.
        """
        var p = Parser(parse_string)
        self = p.parse()

    @always_inline
    fn __init__(out self, *, parse_bytes: ByteView[mut=False]) raises:
        """Parse JSON document from bytes.

        Args:
            parse_bytes: The bytes to parse.

        Raises:
            If the bytes represent an invalid JSON document.
        """
        var parser = Parser(parse_bytes)
        self = parser.parse()

    @implicit
    @always_inline
    fn __init__(out self, var v: StringLiteral):
        self._data = String(v)

    @implicit
    @always_inline
    fn __init__(out self, v: Null):
        self._data = v

    @implicit
    @always_inline
    fn __init__(out self, v: Bool):
        self._data = v

    fn __init__(
        out self,
        var keys: List[String],
        var values: List[Value],
        __dict_literal__: (),
    ):
        debug_assert(len(keys) == len(values))
        self = Object()
        for i in range(len(keys)):
            self.object()[keys[i]] = values[i].copy()

    fn __init__(out self, var *values: Value, __list_literal__: ()):
        self = Array()
        for val in values:
            self.array().append(val.copy())

    @always_inline
    fn _type_equal(self, other: Self) -> Bool:
        return self._data._get_discr() == other._data._get_discr()

    fn __eq__(self, other: Self) -> Bool:
        if (self.is_int() or self.is_uint()) and (
            other.is_int() or other.is_uint()
        ):
            if self.is_int():
                if other.is_int() or not will_overflow(other.uint()):
                    return self.int() == other.int()
                return False
            elif self.is_uint():
                if other.is_uint() or other.int() > 0:
                    return self.uint() == other.uint()
                return False

        if not self._type_equal(other):
            return False
        elif self.isa[Float64]():
            return self.float() == other.float()
        elif self.isa[String]():
            return self.string() == other.string()
        elif self.isa[Bool]():
            return self.bool() == other.bool()
        elif self.isa[Object]():
            return self.object() == other.object()
        elif self.isa[Array]():
            return self.array() == other.array()
        elif self.isa[Null]():
            return True
        abort("Unreachable: __eq__")

    fn __len__(self) -> Int:
        if self.is_array():
            return len(self.array())
        if self.is_object():
            return len(self.object())
        if self.is_string():
            return len(self.string())
        return -1

    fn __contains__(self, v: Value) raises -> Bool:
        if self.is_array():
            return v in self.array().copy()
        if not v.isa[String]():
            raise Error("expected string key")
        return v.string() in self.object().copy()

    fn __getitem__(ref self, ind: Some[Indexer]) raises -> ref [self] Value:
        if not self.is_array():
            raise Error("Expected numerical index for array")
        return UnsafePointer(to=self.array()[ind]).unsafe_origin_cast[
            origin_of(self)
        ]()[]

    fn __getitem__(ref self, key: String) raises -> ref [self] Value:
        if not self.is_object():
            raise Error("Expected string key for object")
        return UnsafePointer(to=self.object()[key]).unsafe_origin_cast[
            origin_of(self)
        ]()[]

    @always_inline
    fn __ne__(self, other: Self) -> Bool:
        return not self == other

    fn __bool__(self) -> Bool:
        if self.isa[Int64]():
            return Bool(self.int())
        elif self.isa[UInt64]():
            return Bool(self.uint())
        elif self.isa[Float64]():
            return Bool(self.float())
        elif self.isa[String]():
            return Bool(self.string())
        elif self.isa[Bool]():
            return self.bool()
        elif self.isa[Null]():
            return False
        elif self.isa[Object]():
            return Bool(self.object())
        elif self.isa[Array]():
            return Bool(self.array())
        abort("Unreachable: __bool__")

    @always_inline
    fn isa[T: Movable & Copyable](self) -> Bool:
        constrain_json_type[T]()
        return self._data.isa[T]()

    @always_inline
    fn is_int(self) -> Bool:
        return self.isa[Int64]()

    @always_inline
    fn is_uint(self) -> Bool:
        return self.isa[UInt64]()

    @always_inline
    fn is_string(self) -> Bool:
        return self.isa[String]()

    @always_inline
    fn is_bool(self) -> Bool:
        return self.isa[Bool]()

    @always_inline
    fn is_float(self) -> Bool:
        return self.isa[Float64]()

    @always_inline
    fn is_object(self) -> Bool:
        return self.isa[Object]()

    @always_inline
    fn is_array(self) -> Bool:
        return self.isa[Array]()

    @always_inline
    fn is_null(self) -> Bool:
        return self.isa[Null]()

    @always_inline
    fn get[T: Movable & Copyable](ref self) -> ref [self._data] T:
        constrain_json_type[T]()
        return self._data[T]

    @always_inline
    fn int(self) -> Int64:
        if self.is_int():
            return self.get[Int64]()
        else:
            return Int64(self.get[UInt64]())

    @always_inline
    fn uint(self) -> UInt64:
        if self.is_uint():
            return self.get[UInt64]()
        else:
            return UInt64(self.get[Int64]())

    @always_inline
    fn null(self) -> Null:
        return Null()

    @always_inline
    fn string(ref self) -> ref [self._data] String:
        return self.get[String]()

    @always_inline
    fn float(self) -> Float64:
        return self.get[Float64]()

    @always_inline
    fn bool(self) -> Bool:
        return self.get[Bool]()

    @always_inline
    fn object(ref self) -> ref [self._data] Object:
        return self.get[Object]()

    @always_inline
    fn array(ref self) -> ref [self._data] Array:
        return self.get[Array]()

    fn write_to(self, mut writer: Some[Writer]):
        if self.is_int():
            write_int(self.int(), writer)
        elif self.is_uint():
            write_int(self.uint(), writer)
        elif self.is_float():
            write_f64(self.float(), writer)
        elif self.is_string():
            write_escaped_string(self.string(), writer)
        elif self.is_bool():
            writer.write("true") if self.bool() else writer.write("false")
        elif self.is_null():
            writer.write("null")
        elif self.is_object():
            writer.write(self.object())
        elif self.is_array():
            writer.write(self.array())
        else:
            abort("Unreachable: write_to")

    fn _pretty_to_as_element(
        self, mut writer: Some[Writer], indent: String, curr_depth: UInt
    ):
        if self.isa[Object]():
            writer.write("{\n")
            self.object()._pretty_write_items(writer, indent, curr_depth + 1)
            for _ in range(curr_depth):
                writer.write(indent)
            writer.write("}")
        elif self.isa[Array]():
            writer.write("[\n")
            self.array()._pretty_write_items(writer, indent, curr_depth + 1)
            for _ in range(curr_depth):
                writer.write(indent)
            writer.write("]")
        else:
            self.write_to(writer)

    fn pretty_to(
        self, mut writer: Some[Writer], indent: String, *, curr_depth: UInt = 0
    ):
        if self.isa[Object]():
            self.object().pretty_to(writer, indent, curr_depth=curr_depth)
        elif self.isa[Array]():
            self.array().pretty_to(writer, indent, curr_depth=curr_depth)
        else:
            self.write_to(writer)

    @always_inline
    fn __str__(self) -> String:
        return write(self)

    @always_inline
    fn __repr__(self) -> String:
        return self.__str__()

    @always_inline
    fn write_json(self, mut writer: Some[Writer]):
        writer.write(self)

    fn to_python_object(self) raises -> PythonObject:
        if self.is_int():
            return PythonObject(self.int())
        elif self.is_uint():
            return PythonObject(self.uint())
        elif self.is_float():
            return PythonObject(self.float())
        elif self.is_string():
            return PythonObject(self.string())
        elif self.is_bool():
            return PythonObject(self.bool())
        elif self.is_null():
            return PythonObject()
        elif self.is_object():
            return self.object().to_python_object()
        elif self.is_array():
            return self.array().to_python_object()
        else:
            abort("Unreachable: to_python_object")

    fn get(ref self, path: PointerIndex) raises -> ref [self] Value:
        return resolve_pointer(self, path)

    fn __getattr__(ref self, var name: String) raises -> ref [self] Value:
        if name.startswith("/"):
            return self.get(name)
        else:
            if self.is_object():
                return UnsafePointer(to=self.object()[name]).unsafe_origin_cast[
                    origin_of(self)
                ]()[]
            else:
                raise Error("Cannot use getattr on JSON Array")

    fn __setattr__(mut self, var name: String, var value: Value) raises:
        if name.startswith("/"):
            self.get(name) = value^
        else:
            if self.is_object():
                self.object()[name] = value^
            else:
                raise Error("Cannot use setattr on JSON Array")
