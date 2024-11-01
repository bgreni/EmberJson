from .object import Object
from .array import Array
from .reader import Reader
from .utils import *
from utils import Variant
from .constants import *
from sys.intrinsics import unlikely
from .traits import JsonValue, PrettyPrintable
from collections.string import _calc_initial_buffer_size, _atol, _atof
from collections import InlineArray
from utils import StringSlice
from sys.ffi import external_call
from memory import UnsafePointer


@value
@register_passable("trivial")
struct Null(JsonValue):
    fn __eq__(self, n: Null) -> Bool:
        return True

    fn __ne__(self, n: Null) -> Bool:
        return False

    fn __str__(self) -> String:
        return "null"

    fn __repr__(self) -> String:
        return self.__str__()

    fn min_size_for_string(self) -> Int:
        return 4

    fn write_to[W: Writer](self, inout writer: W):
        writer.write(self.__str__())


@always_inline
fn validate_string(b: ByteView[_]) raises:
    alias SOL = to_byte("/")
    alias B = to_byte("b")
    alias F = to_byte("f")
    alias N = to_byte("n")
    alias R = to_byte("r")
    alias T = to_byte("t")
    alias U = to_byte("u")

    # can't be alias for some reason
    var acceptable_escapes = ByteVec[16](QUOTE, RSOL, SOL, B, F, N, R, T, U)
    var control_chars = ByteVec[4](NEWLINE, TAB, LINE_FEED)
    i = 0
    while i < len(b):
        var char = b[i]
        if char == RSOL:
            var next = b[i + 1]
            if unlikely(not next in acceptable_escapes):
                raise Error("Invalid escape sequence: " + byte_to_string(char) + byte_to_string(next))
            i += 1
        if unlikely(char in control_chars):
            raise Error("Control characters must be escaped")
        i += 1


fn _read_string(inout reader: Reader) raises -> String:
    reader.inc()
    var res = reader.read_string()
    validate_string(res)
    reader.inc()
    return bytes_to_string(res)


alias DOT = to_byte(".")
alias LOW_E = to_byte("e")
alias UPPER_E = to_byte("E")
alias PLUS = to_byte("+")
alias NEG = to_byte("-")
alias ZERO_CHAR = to_byte("0")

alias TRUE = ByteVec[4](to_byte("t"), to_byte("r"), to_byte("u"), to_byte("e"))
alias FALSE = InlineArray[UInt8, 5](to_byte("f"), to_byte("a"), to_byte("l"), to_byte("s"), to_byte("e"))
alias NULL = ByteVec[4](to_byte("n"), to_byte("u"), to_byte("l"), to_byte("l"))


@always_inline
@parameter
fn is_numerical_component(char: Byte) -> Bool:
    var componenents = ByteVec[8](DOT, LOW_E, UPPER_E, PLUS, NEG)
    return isdigit(char) or char in componenents


@always_inline
fn _read_number(inout reader: Reader) raises -> Variant[Int, Float64]:
    var num = reader.read_while[is_numerical_component]()
    var is_float = False
    var first_digit_found = False
    var leading_zero = False
    var float_parts = ByteVec[4](DOT, LOW_E, UPPER_E)
    var sign_parts = ByteVec[2](PLUS, NEG)
    for i in range(len(num)):
        var b = num[i]
        if b in float_parts:
            is_float = True
        if b in sign_parts:
            var j = i + 1
            if j < len(num):
                # atof doesn't reject numbers like 0e+-1
                var after = num[j]
                if after in sign_parts:
                    raise Error("Invalid number: " + bytes_to_string(num))
        if isdigit(b):
            if not first_digit_found and b == ZERO_CHAR:
                leading_zero = True
            else:
                first_digit_found = True

    var is_negative = num[0] == NEG

    if is_float:
        return _atof(StringSlice(unsafe_from_utf8=num))

    # _atol has to look for a bunch of extra stuff that slows it down that isn't valid for JSON anyways
    # var parsed = _atol(StringSlice(unsafe_from_utf8=num))

    var parsed = 0
    var has_pos = num[0] == PLUS

    var i = 0
    if is_negative or has_pos:
        if len(num) == 1:
            raise Error("Invalid number")
        i += 1

    while i < len(num):
        if not isdigit(num[i]):
            raise Error("unexpected token in number")
        parsed = parsed * 10 + int(num[i] - 48)
        i += 1

    if is_negative:
        parsed = -parsed

    if leading_zero and parsed != 0:
        raise Error("Integer cannot have leading zero")
    return parsed


@value
struct Value(JsonValue):
    alias Type = Variant[Int, Float64, String, Bool, Object, Array, Null]
    var _data: Self.Type

    fn __init__(inout self, owned v: Self.Type):
        self._data = v^

    fn __init__(inout self, v: Int):
        self._data = v

    fn __init__(inout self, v: Float64):
        self._data = v

    fn __init__(inout self, owned v: Object):
        self._data = v^

    fn __init__(inout self, owned v: Array):
        self._data = v^

    fn __init__(inout self, owned v: String):
        self._data = v^

    fn __init__(inout self, v: StringLiteral):
        self._data = String(v)

    fn __init__(inout self, v: Null):
        self._data = v

    fn __init__(inout self, v: Bool):
        self._data = v

    fn __copyinit__(inout self, other: Self):
        self._data = other._data

    fn __moveinit__(inout self, owned other: Self):
        self._data = other._data^

    fn __eq__(self, other: Self) -> Bool:
        if self._data._get_discr() != other._data._get_discr():
            return False

        if self.isa[Int]() and other.isa[Int]():
            return self.int() == other.int()
        elif self.isa[Float64]() and other.isa[Float64]():
            return self.float() == other.float()
        elif self.isa[String]() and other.isa[String]():
            return self.string() == other.string()
        elif self.isa[Bool]() and other.isa[Bool]():
            return self.bool() == other.bool()
        elif self.isa[Object]() and other.isa[Object]():
            return self.object() == other.object()
        elif self.isa[Array]() and other.isa[Array]():
            return self.array() == other.array()
        return False

    fn __ne__(self, other: Self) -> Bool:
        return not self == other

    fn isa[T: CollectionElement](self) -> Bool:
        return self._data.isa[T]()

    fn get[T: CollectionElement](ref [_]self) -> ref [self._data] T:
        return self._data[T]

    fn int(ref [_]self) -> ref [self._data] Int:
        return self.get[Int]()

    fn null(ref [_]self) -> ref [self._data] Null:
        return self.get[Null]()

    fn string(ref [_]self) -> ref [self._data] String:
        return self.get[String]()

    fn float(ref [_]self) -> ref [self._data] Float64:
        return self.get[Float64]()

    fn bool(ref [_]self) -> ref [self._data] Bool:
        return self.get[Bool]()

    fn object(ref [_]self) -> ref [self._data] Object:
        return self.get[Object]()

    fn array(ref [_]self) -> ref [self._data] Array:
        return self.get[Array]()

    fn write_to[W: Writer](self, inout writer: W):
        if self.isa[Int]():
            self.int().write_to(writer)
        elif self.isa[Float64]():
            self.float().write_to(writer)
        elif self.isa[String]():
            ('"').write_to(writer)
            self.string().write_to(writer)
            ('"').write_to(writer)
        elif self.isa[Bool]():
            var b = self.bool()
            ("true").write_to(writer) if b else ("false").write_to(writer)
        elif self.isa[Null]():
            ("null").write_to(writer)
        elif self.isa[Object]():
            self.object().write_to(writer)
        elif self.isa[Array]():
            self.array().write_to(writer)

    fn _pretty_to_as_element[W: Writer](self, inout writer: W, indent: String):
        if self.isa[Object]():
            writer.write("{\n")
            self.object()._pretty_write_items(writer, indent * 2)
            writer.write(indent, "}")
        elif self.isa[Array]():
            writer.write("[\n")
            self.array()._pretty_write_items(writer, indent * 2)
            writer.write(indent, "]")
        else:
            self.write_to(writer)

    fn pretty_to[W: Writer](self, inout writer: W, indent: String):
        if self.isa[Object]():
            self.object().pretty_to(writer, indent)
        elif self.isa[Array]():
            self.array().pretty_to(writer, indent)
        else:
            self.write_to(writer)

    fn min_size_for_string(self) -> Int:
        if self.isa[Int]():
            return _calc_initial_buffer_size(self.int()) - 1
        elif self.isa[Float64]():
            return _calc_initial_buffer_size(self.float()) - 1
        elif self.isa[String]():
            return len(self.string()) + 2  # include the surrounding quotes
        elif self.isa[Bool]():
            return 4 if self.bool() else 5
        elif self.isa[Null]():
            return Null().min_size_for_string()
        elif self.isa[Object]():
            return self.object().min_size_for_string()
        elif self.isa[Array]():
            return self.array().min_size_for_string()

        return 0

    @always_inline
    fn __str__(self) -> String:
        return write(self)

    @always_inline
    fn __repr__(self) -> String:
        return self.__str__()

    @staticmethod
    fn _from_reader(inout reader: Reader) raises -> Value:
        reader.skip_whitespace()
        var v: Value
        var n = reader.peek()
        if n == QUOTE:
            v = _read_string(reader)
        elif n == T:
            var w = reader.read_word()
            if not compare_simd(w, TRUE):
                raise Error("Expected 'true', received: " + bytes_to_string(w))
            v = True
        elif n == F:
            var w = reader.read_word()
            if not compare_bytes(w, FALSE):
                raise Error("Expected 'false', received: " + bytes_to_string(w))
            v = False
        elif n == N:
            var w = reader.read_word()
            if not compare_simd(w, NULL):
                raise Error("Expected 'null', received: " + bytes_to_string(w))
            v = Null()
        elif n == LCURLY:
            v = Object._from_reader(reader)
        elif n == LBRACKET:
            v = Array._from_reader(reader)
        elif is_numerical_component(n):
            var num = _read_number(reader)
            if num.isa[Int]():
                v = num.unsafe_take[Int]()
            else:
                v = num.unsafe_take[Float64]()
        else:
            raise Error("Invalid json value")
        reader.skip_whitespace()
        return v^

    @staticmethod
    fn from_string(input: String) raises -> Value:
        var r = Reader(input.as_bytes())
        return Value._from_reader(r)
