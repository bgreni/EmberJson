from .object import Object
from .array import Array
from .utils import will_overflow, constrain_json_type
from utils import Variant
from .traits import JsonValue, PrettyPrintable
from collections import InlineArray
from memory import UnsafePointer
from sys.intrinsics import unlikely, likely
from .parser import Parser
from .format_int import write_int
from sys.info import bitwidthof
from .teju import write_f64
from os import abort


@value
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
    fn __as_bool__(self) -> Bool:
        return False

    @always_inline
    fn write_to[W: Writer](self, mut writer: W):
        writer.write(self.__str__())

    @always_inline
    fn pretty_to[
        W: Writer
    ](self, mut writer: W, indent: String, *, curr_depth: UInt = 0):
        writer.write(self)


@value
struct Value(JsonValue):
    alias Type = Variant[
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
    fn __init__(out self, owned v: Self.Type):
        self._data = v^

    @implicit
    fn __init__(out self, owned j: JSON):
        if j.is_object():
            self._data = j.object()
        else:
            self._data = j.array()

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
            bitwidthof[DType.index]() <= bitwidthof[DType.int64](),
            "Cannot fit index width into 64 bits for signed integer",
        ]()
        self._data = Int64(v)

    @implicit
    @always_inline
    fn __init__(out self, v: UInt):
        constrained[
            bitwidthof[DType.index]() <= bitwidthof[DType.uint64](),
            "Cannot fit index width into 64 bits for unsigned integer",
        ]()
        self._data = UInt64(v)

    @implicit
    @always_inline
    fn __init__(out self, v: Float64):
        self._data = v

    @implicit
    @always_inline
    fn __init__(out self, owned v: Object):
        self._data = v^

    @implicit
    @always_inline
    fn __init__(out self, owned v: Array):
        self._data = v^

    @implicit
    @always_inline
    fn __init__(out self, owned v: String):
        self._data = v^

    @always_inline
    fn __init__(out self: Value, *, parse_string: String) raises:
        var p = Parser(parse_string)
        self = p.parse_value()

    @implicit
    @always_inline
    fn __init__(out self, owned v: StringLiteral):
        self._data = String(v)

    @implicit
    @always_inline
    fn __init__(out self, v: Null):
        self._data = v

    @implicit
    @always_inline
    fn __init__(out self, v: Bool):
        self._data = v

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
        return False

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
        return False

    @always_inline
    fn __as_bool__(self) -> Bool:
        return Bool(self)

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

    fn write_to[W: Writer](self, mut writer: W):
        if self.isa[Int64]():
            write_int(self.int(), writer)
        elif self.isa[UInt64]():
            write_int(self.uint(), writer)
        elif self.isa[Float64]():
            write_f64(self.float(), writer)
        elif self.isa[String]():
            writer.write('"')
            writer.write(self.string())
            writer.write('"')
        elif self.isa[Bool]():
            writer.write("true") if self.bool() else writer.write("false")
        elif self.isa[Null]():
            writer.write("null")
        elif self.isa[Object]():
            writer.write(self.object())
        elif self.isa[Array]():
            writer.write(self.array())
        else:
            abort("Unreachable: write_to")

    fn _pretty_to_as_element[
        W: Writer
    ](self, mut writer: W, indent: String, curr_depth: UInt):
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

    fn pretty_to[
        W: Writer
    ](self, mut writer: W, indent: String, *, curr_depth: UInt = 0):
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
