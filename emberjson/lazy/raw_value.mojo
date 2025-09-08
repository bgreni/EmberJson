from python import PythonObject
from memory import UnsafePointer, memcmp
from os import abort
from utils import Variant


from .raw_object import RawObject
from .raw_array import RawArray
from emberjson.format_int import write_int
from emberjson.teju import write_f64
from emberjson.parser import Parser
from emberjson._parser_helper import copy_to_string, TRUE
from emberjson.traits import JsonValue


struct RawJsonType(ImplicitlyCopyable, Movable):
    alias OBJECT = RawJsonType.__init__[0]()
    alias ARRAY = RawJsonType.__init__[1]()
    alias INT = RawJsonType.__init__[2]()
    alias FLOAT = RawJsonType.__init__[3]()
    alias FLOAT_DOT = RawJsonType.__init__[4]()
    alias FLOAT_EXP = RawJsonType.__init__[5]()
    alias STRING = RawJsonType.__init__[6]()
    alias BOOL = RawJsonType.__init__[7]()
    alias TRUE = RawJsonType.__init__[8]()
    alias FALSE = RawJsonType.__init__[9]()
    alias NULL = RawJsonType.__init__[10]()
    var _type: UInt8

    @always_inline
    fn __init__[json_type: UInt8](out self):
        constrained[UInt8(0) <= json_type <= UInt8(10), "Invalid type"]()
        self._type = json_type

    @always_inline
    fn __is__(self, other: Self) -> Bool:
        return self._type == other._type

    @always_inline
    fn __is_not__(self, other: Self) -> Bool:
        return self._type != other._type

    @always_inline
    fn __eq__(self, other: Self) -> Bool:
        return self._type == other._type

    @always_inline
    fn __ne__(self, other: Self) -> Bool:
        return self._type != other._type


@fieldwise_init
struct RawValue[origin: ImmutableOrigin](JsonValue):
    var _type: RawJsonType
    var _data: Variant[Span[Byte, origin], RawObject[origin], RawArray[origin]]

    @always_inline
    fn __init__(out self):
        self._type = RawJsonType.NULL
        self._data = Span[Byte, origin]()

    @implicit
    @always_inline
    fn __init__(
        out self: RawValue[StaticConstantOrigin], n: NoneType._mlir_type
    ):
        self = __type_of(self)()

    @implicit
    @always_inline
    fn __init__(out self, val: Bool):
        if val:
            self._type = RawJsonType.TRUE
            self._data = "true".as_bytes()
        else:
            self._type = RawJsonType.FALSE
            self._data = "false".as_bytes()

    @implicit
    @always_inline
    fn __init__(out self: RawValue[StaticConstantOrigin], val: StringLiteral):
        self._type = RawJsonType.STRING
        self._data = val.as_bytes()

    @implicit
    @always_inline
    fn __init__(out self, val: StringSlice[origin]):
        self._type = RawJsonType.STRING
        self._data = val.as_bytes()

    @implicit
    @always_inline
    fn __init__(out self, ref [origin]val: String):
        self._type = RawJsonType.STRING
        self._data = val.as_bytes()

    @implicit
    @always_inline
    fn __init__(out self, var val: RawObject[origin]):
        self._type = RawJsonType.OBJECT
        self._data = val^

    @implicit
    @always_inline
    fn __init__(out self, var val: RawArray[origin]):
        self._type = RawJsonType.ARRAY
        self._data = val^

    @always_inline
    fn __init__(out self, *, json_type: RawJsonType, span: Span[Byte, origin]):
        self._type = json_type
        self._data = span

    @always_inline
    fn __init__(out self, *, parse_string: StringSlice[origin]) raises:
        var p = RawParser(parse_string)
        self = p.parse_value()

    fn __eq__(self, other: Self) -> Bool:
        if self._type != other._type:
            return False
        if self.is_object():
            debug_assert(
                other._data.isa[RawObject[origin]](), "should be equal"
            )
            return (
                self._data[RawObject[origin]] == other._data[RawObject[origin]]
            )
        elif self.is_array():
            debug_assert(other._data.isa[RawArray[origin]](), "should be equal")
            return self._data[RawArray[origin]] == other._data[RawArray[origin]]
        var s_span = self._data[Span[Byte, origin]]
        var o_span = other._data[Span[Byte, origin]]
        if not s_span and not o_span:  # both empty
            return True
        if len(s_span) != len(o_span):
            return False
        return (
            memcmp(s_span.unsafe_ptr(), o_span.unsafe_ptr(), len(s_span)) == 0
        )

    @always_inline
    fn __ne__(self, other: Self) -> Bool:
        return not self == other

    fn __bool__(self) -> Bool:
        try:
            if self.is_int():
                return Bool(self.int())
            elif self.is_float():
                return Bool(self.float())
            elif self.is_string():
                return Bool(self.as_string_slice())
            elif self.is_true():
                return True
            elif self.is_false():
                return False
            elif self.is_bool():
                return self.bool()
            elif self.is_null():
                return False
            elif self.is_object():
                return Bool(self.object())
            elif self.is_array():
                return Bool(self.array())
            else:
                return abort[Bool]("Unreachable: __bool__")
        except:
            return False

    @always_inline
    fn __as_bool__(self) -> Bool:
        return Bool(self)

    @always_inline
    fn is_int(self) -> Bool:
        return (
            self._data.isa[Span[Byte, origin]]()
            and self._type is RawJsonType.INT
        )

    @always_inline
    fn is_string(self) -> Bool:
        return (
            self._data.isa[Span[Byte, origin]]()
            and self._type is RawJsonType.STRING
        )

    @always_inline
    fn is_true(self) -> Bool:
        return (
            self._data.isa[Span[Byte, origin]]()
            and self._type is RawJsonType.TRUE
        )

    @always_inline
    fn is_false(self) -> Bool:
        return (
            self._data.isa[Span[Byte, origin]]()
            and self._type is RawJsonType.FALSE
        )

    @always_inline
    fn is_bool(self) -> Bool:
        return self._data.isa[Span[Byte, origin]]() and (
            self._type is RawJsonType.BOOL
            or self._type is RawJsonType.TRUE
            or self._type is RawJsonType.FALSE
        )

    @always_inline
    fn is_float(self) -> Bool:
        return self._data.isa[Span[Byte, origin]]() and (
            self._type is RawJsonType.FLOAT
            or self._type is RawJsonType.FLOAT_DOT
            or self._type is RawJsonType.FLOAT_EXP
        )

    @always_inline
    fn is_object(self) -> Bool:
        debug_assert(
            self._data.isa[RawObject[origin]]()
            == (self._type is RawJsonType.OBJECT),
            "Both the variant and the RawJsonType should be equal",
        )
        return (
            self._data.isa[RawObject[origin]]()
            and self._type is RawJsonType.OBJECT
        )

    @always_inline
    fn is_array(self) -> Bool:
        debug_assert(
            self._data.isa[RawArray[origin]]()
            == (self._type is RawJsonType.ARRAY),
            "Both the variant and the RawJsonType should be equal",
        )
        return (
            self._data.isa[RawArray[origin]]()
            and self._type is RawJsonType.ARRAY
        )

    @always_inline
    fn is_null(self) -> Bool:
        return (
            self._data.isa[Span[Byte, origin]]()
            and self._type is RawJsonType.NULL
        )

    @always_inline
    fn null(self) raises -> None:
        if not self.is_null():
            raise Error("RawValue should be an null")
        return None

    @always_inline
    fn string(ref self) raises -> String:
        if not self.is_string():
            raise Error("RawValue should be a string")
        var span = self._data[Span[Byte, origin]]
        var ptr = span.unsafe_ptr()
        return copy_to_string(ptr, ptr + len(span))

    @always_inline
    fn as_string_slice(ref self) -> StringSlice[origin]:
        """Returns a stringslice with the unparsed unicode escape sequences and
        potentially invalid UTF-16 surrogate pairs."""
        debug_assert(self.is_string(), "RawValue should be a string")
        return StringSlice(unsafe_from_utf8=self._data[Span[Byte, origin]])

    @always_inline
    fn int(self) raises -> Int:
        if not self.is_int():
            raise Error("RawValue should be an int")
        var p = Parser(self._data[Span[Byte, origin]])
        return Int(p.parse_number().int())  # TODO: specialize for each

    @always_inline
    fn float(self) raises -> Float64:
        if not self.is_float():
            raise Error("RawValue should be a float")
        var p = Parser(self._data[Span[Byte, origin]])
        if self._type is RawJsonType.FLOAT_DOT:
            return p.parse_number().float()  # TODO: specialize for each
        elif self._type is RawJsonType.FLOAT_EXP:
            return p.parse_number().float()  # TODO: specialize for each
        else:
            return p.parse_number().float()  # TODO: specialize for each

    @always_inline
    fn bool(self) raises -> Bool:
        if not self.is_bool():
            raise Error("RawValue should be a bool")
        var span = self._data[Span[Byte, origin]]
        if not (4 <= len(span) <= 5):
            raise Error("Data is not the correct length")
        return True if self._type is RawJsonType.TRUE else (
            False if (self._type is RawJsonType.FALSE) else Bool(
                span.unsafe_ptr().bitcast[UInt32]()[0] == TRUE
            )
        )

    @always_inline
    fn object(ref self) raises -> ref [self._data] RawObject[origin]:
        if not self.is_object():
            raise Error("RawValue should be an object")
        return self._data[RawObject[origin]]

    @always_inline
    fn array(ref self) raises -> ref [self._data] RawArray[origin]:
        if not self.is_array():
            raise Error("RawValue should be an array")
        return self._data[RawArray[origin]]

    fn write_to[W: Writer](self, mut writer: W):
        if self.is_object():
            try:
                writer.write(self.object())
            except:
                writer.write("{}")
        elif self.is_array():
            try:
                writer.write(self.array())
            except:
                writer.write("[]")
        else:
            debug_assert(
                self._data.isa[Span[Byte, origin]](),
                "data should be a Span:",
                self._type._type,
            )
            if self.is_string():
                writer.write('"', self.as_string_slice(), '"')
                return

            var span = self._data[Span[Byte, origin]]
            if span:
                writer.write(StringSlice(unsafe_from_utf8=span))
            else:
                writer.write("null")

    fn _pretty_to_as_element[
        W: Writer
    ](self, mut writer: W, indent: String, curr_depth: UInt):
        if self.is_object():
            writer.write("{\n")
            try:
                self.object()._pretty_write_items(
                    writer, indent, curr_depth + 1
                )
            except:
                pass
            for _ in range(curr_depth):
                writer.write(indent)
            writer.write("}")
        elif self.is_array():
            writer.write("[\n")
            try:
                self.array()._pretty_write_items(writer, indent, curr_depth + 1)
            except:
                pass
            for _ in range(curr_depth):
                writer.write(indent)
            writer.write("]")
        else:
            self.write_to(writer)

    fn pretty_to[
        W: Writer
    ](self, mut writer: W, indent: String, *, curr_depth: UInt = 0):
        if self.is_object():
            # ref obj: RawObject[origin]
            try:
                ref obj = self.object()
                obj.pretty_to(writer, indent, curr_depth=curr_depth)
            except:
                obj = RawObject[origin]()
                obj.pretty_to(writer, indent, curr_depth=curr_depth)

        elif self.is_array():
            # ref arr: RawArray[origin]
            try:
                ref arr = self.array()
                arr.pretty_to(writer, indent, curr_depth=curr_depth)
            except:
                arr = RawArray[origin]()
                arr.pretty_to(writer, indent, curr_depth=curr_depth)

        else:
            self.write_to(writer)

    @always_inline
    fn __str__(self) -> String:
        return write(self)

    @always_inline
    fn __repr__(self) -> String:
        return self.__str__()

    fn to_python_object(self) raises -> PythonObject:
        if self.is_int():
            return self.int()
        elif self.is_float():
            return self.float()
        elif self.is_string():
            return self.string()
        elif self.is_bool():
            return self.bool()
        elif self.is_null():
            return None
        elif self.is_object():
            return self.object().to_python_object()
        elif self.is_array():
            return self.array().to_python_object()
        else:
            return abort[NoneType]("Unreachable: to_python_object")
