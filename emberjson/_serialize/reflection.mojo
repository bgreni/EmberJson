from std.reflection import (
    reflect,
)
from std.collections import Set
from std.sys.intrinsics import _type_is_eq
from std.memory import ArcPointer, OwnedPointer
from std.format._utils import _WriteBufferStack
from emberjson.teju import write_float
from emberjson.traits import PrettyPrintable
from emberjson.utils import write_escaped_string


# TODO: When we have parametric traits, we can make this generic over some Writer type
# Then the serializer dictates _what_ is written, and the Writer dictates _where_ it is written
trait Serializer(Writer):
    def begin_object(mut self):
        self.write("{")

    def end_object(mut self):
        self.write("}")

    def begin_array(mut self):
        self.write("[")

    def end_array(mut self):
        self.write("]")

    def write_key(mut self, key: String):
        self.write('"', key, '":')

    def write_item(mut self, value: Some[AnyType], add_comma: Bool):
        serialize(value, self)
        if add_comma:
            self.write(",")

    def write_item[add_comma: Bool](mut self, value: Some[AnyType]):
        serialize(value, self)

        comptime if add_comma:
            self.write(",")


__extension String(Serializer):
    def begin_object(mut self):
        self.write("{")

    def end_object(mut self):
        self.write("}")

    def begin_array(mut self):
        self.write("[")

    def end_array(mut self):
        self.write("]")

    def write_key(mut self, key: String):
        self.write('"', key, '":')

    def write_item(mut self, value: Some[AnyType], add_comma: Bool):
        serialize(value, self)
        if add_comma:
            self.write(",")

    def write_item[add_comma: Bool](mut self, value: Some[AnyType]):
        serialize(value, self)

        comptime if add_comma:
            self.write(",")


__extension _WriteBufferStack(Serializer):
    def begin_object(mut self):
        self.write("{")

    def end_object(mut self):
        self.write("}")

    def begin_array(mut self):
        self.write("[")

    def end_array(mut self):
        self.write("]")

    def write_key(mut self, key: String):
        self.write('"', key, '":')

    def write_item(mut self, value: Some[AnyType], add_comma: Bool):
        serialize(value, self)
        if add_comma:
            self.write(",")

    def write_item[add_comma: Bool](mut self, value: Some[AnyType]):
        serialize(value, self)

        comptime if add_comma:
            self.write(",")


struct PrettySerializer[
    T: Writer & Defaultable & Movable, indent: String = "    "
](Defaultable, Serializer):
    var _data: Self.T
    var _skip_indent: Bool
    var _depth: Int

    def __init__(out self):
        self._data = Self.T()
        self._skip_indent = False
        self._depth = 0

    def finish(deinit self) -> Self.T:
        return self._data^

    def write_string(mut self, string: StringSlice):
        self._data.write(string)

    def _write_indent(mut self):
        for _ in range(self._depth):
            self.write(Self.indent)

    def begin_object(mut self):
        self.write("{\n")
        self._depth += 1

    def end_object(mut self):
        self._depth -= 1
        self._write_indent()
        self.write("}")

    def begin_array(mut self):
        self.write("[\n")
        self._depth += 1

    def end_array(mut self):
        self._depth -= 1
        self._write_indent()
        self.write("]")

    def write_key(mut self, key: String):
        self._write_indent()
        self.write('"', key, '": ')
        self._skip_indent = True

    def write_item(mut self, value: Some[AnyType], add_comma: Bool):
        if not self._skip_indent:
            self._write_indent()

        self._skip_indent = False
        serialize(value, self)

        if add_comma:
            self.write(",")
        self.write("\n")

    def write_item[add_comma: Bool](mut self, value: Some[AnyType]):
        if not self._skip_indent:
            self._write_indent()

        self._skip_indent = False
        serialize(value, self)

        comptime if add_comma:
            self.write(",")
        self.write("\n")


trait JsonSerializable:
    def write_json(self, mut writer: Some[Serializer]):
        _default_serialize[Self.serialize_as_array()](self, writer)

    @staticmethod
    def serialize_as_array() -> Bool:
        return False


def serialize[
    T: AnyType, //, *, pretty: Bool = False
](value: T, out output: String):
    output = String()
    comptime if pretty:
        # fallback to write_pretty impl for JSON types to make use of stack writer speedup
        comptime if conforms_to(T, PrettyPrintable):
            output = write_pretty(value)
        else:
            var writer = PrettySerializer[String]()
            serialize(value, writer)
            output = writer^.finish()
    else:
        var writer = _WriteBufferStack(output)
        serialize(value, writer)
        writer.flush()


def serialize[T: AnyType, //](value: T, mut writer: Some[Serializer]):
    comptime assert reflect[T]().is_struct(), "Cannot serialize MLIR type"

    comptime if conforms_to(T, JsonSerializable):
        value.write_json(writer)
    else:
        _default_serialize(value, writer)


def _default_serialize[
    T: AnyType, //, is_array: Bool = False
](value: T, mut writer: Some[Serializer]):
    comptime r = reflect[T]()
    comptime assert r.is_struct(), "Cannot serialize MLIR type"
    comptime field_count = r.field_count()
    comptime field_names = r.field_names()
    comptime field_types = r.field_types()

    comptime if is_array:
        writer.begin_array()
    else:
        writer.begin_object()

    comptime for i in range(field_count):
        comptime if not is_array:
            comptime name = field_names[i]
            writer.write_key(name)

        comptime add_comma = i != field_count - 1
        writer.write_item[add_comma](r.field_ref[i](value))

    comptime if is_array:
        writer.end_array()
    else:
        writer.end_object()


def __serialize_iterable[
    T: Iterable & Sized
](value: T, mut writer: Some[Serializer]) where conforms_to(
    T.IteratorType[origin_of(value)], Copyable
):
    writer.begin_array()
    var len = len(value)
    for i, item in enumerate(value):
        var add_comma = i != len - 1
        writer.write_item(item, add_comma)

    writer.end_array()


# ===============================================
# Primitives
# ===============================================


__extension String(JsonSerializable):
    def write_json(self, mut writer: Some[Serializer]):
        # TODO: make this faster
        write_escaped_string(self, writer)

    @staticmethod
    def serialize_as_array() -> Bool:
        return False


__extension Int(JsonSerializable):
    def write_json(self, mut writer: Some[Serializer]):
        writer.write(self)

    @staticmethod
    def serialize_as_array() -> Bool:
        return False


__extension SIMD(JsonSerializable):
    def write_json(self, mut writer: Some[Serializer]):
        comptime if size == 1:
            comptime if Self.dtype.is_floating_point():
                write_float(rebind[Scalar[Self.dtype]](self), writer)
            else:
                writer.write(self)
        else:
            writer.begin_array()

            comptime for i in range(size):
                comptime if i != size - 1:
                    writer.write_item[True](self[i])
                else:
                    writer.write_item[False](self[i])

            writer.end_array()

    @staticmethod
    def serialize_as_array() -> Bool:
        return False


__extension Bool(JsonSerializable):
    def write_json(self, mut writer: Some[Serializer]):
        writer.write("true" if self else "false")

    @staticmethod
    def serialize_as_array() -> Bool:
        return False


__extension IntLiteral(JsonSerializable):
    def write_json(self, mut writer: Some[Serializer]):
        writer.write(self)

    @staticmethod
    def serialize_as_array() -> Bool:
        return False


__extension FloatLiteral(JsonSerializable):
    def write_json(self, mut writer: Some[Serializer]):
        writer.write(self)

    @staticmethod
    def serialize_as_array() -> Bool:
        return False


# ===============================================
# Pointers
# ===============================================


__extension ArcPointer(JsonSerializable):
    def write_json(self, mut writer: Some[Serializer]):
        serialize(self[], writer)

    @staticmethod
    def serialize_as_array() -> Bool:
        return False


__extension OwnedPointer(JsonSerializable):
    def write_json(self, mut writer: Some[Serializer]):
        serialize(self[], writer)

    @staticmethod
    def serialize_as_array() -> Bool:
        return False


# ===============================================
# Collections
# ===============================================


__extension Optional(JsonSerializable):
    def write_json(self, mut writer: Some[Serializer]):
        if self:
            serialize(self.value(), writer)
        else:
            writer.write("null")

    @staticmethod
    def serialize_as_array() -> Bool:
        return False


__extension List(JsonSerializable):
    def write_json(self, mut writer: Some[Serializer]):
        __serialize_iterable(self, writer)
        # writer.begin_array()

        # for i in range(len(self)):
        #     var add_comma = i != len(self) - 1
        #     writer.write_item(self[i], add_comma)

        # writer.end_array()

    @staticmethod
    def serialize_as_array() -> Bool:
        return False


__extension InlineArray(JsonSerializable):
    def write_json(self, mut writer: Some[Serializer]):
        __serialize_iterable(self, writer)

    @staticmethod
    def serialize_as_array() -> Bool:
        return False


__extension Dict(JsonSerializable):
    def write_json(self, mut writer: Some[Serializer]):
        comptime assert _type_is_eq[
            Self.K, String
        ](), "Dict must have string keys"
        writer.begin_object()
        var i = 0
        for item in self.items():
            writer.write_key(rebind[String](item.key))
            var add_comma = i != len(self) - 1
            writer.write_item(item.value, add_comma)
            i += 1
        writer.end_object()

    @staticmethod
    def serialize_as_array() -> Bool:
        return False


__extension Tuple(JsonSerializable):
    def write_json(self, mut writer: Some[Serializer]):
        writer.begin_array()

        comptime for i in range(Self.__len__()):
            comptime add_comma = i != Self.__len__() - 1
            writer.write_item[add_comma](self[i])

        writer.end_array()

    @staticmethod
    def serialize_as_array() -> Bool:
        return True


__extension Set(JsonSerializable):
    def write_json(self, mut writer: Some[Serializer]):
        __serialize_iterable(self, writer)

    @staticmethod
    def serialize_as_array() -> Bool:
        return False
