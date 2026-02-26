from std.reflection import (
    struct_field_count,
    struct_field_names,
    struct_field_types,
    is_struct_type,
)
from std.collections import Set
from sys.intrinsics import _type_is_eq
from std.memory import ArcPointer, OwnedPointer
from std.format._utils import _WriteBufferStack
from emberjson.teju import write_f64


# TODO: When we have parametric traits, we can make this generic over some Writer type
# Then the serializer dictates _what_ is written, and the Writer dictates _where_ it is written
trait Serializer(Writer):
    fn begin_object(mut self):
        self.write("{")

    fn end_object(mut self):
        self.write("}")

    fn begin_array(mut self):
        self.write("[")

    fn end_array(mut self):
        self.write("]")

    fn write_key(mut self, key: String):
        self.write('"', key, '":')

    fn write_item(mut self, value: Some[AnyType], add_comma: Bool):
        serialize(value, self)
        if add_comma:
            self.write(",")

    fn write_item[add_comma: Bool](mut self, value: Some[AnyType]):
        serialize(value, self)

        comptime if add_comma:
            self.write(",")


__extension String(Serializer):
    fn begin_object(mut self):
        self.write("{")

    fn end_object(mut self):
        self.write("}")

    fn begin_array(mut self):
        self.write("[")

    fn end_array(mut self):
        self.write("]")

    fn write_key(mut self, key: String):
        self.write('"', key, '":')

    fn write_item(mut self, value: Some[AnyType], add_comma: Bool):
        serialize(value, self)
        if add_comma:
            self.write(",")

    fn write_item[add_comma: Bool](mut self, value: Some[AnyType]):
        serialize(value, self)

        comptime if add_comma:
            self.write(",")


__extension _WriteBufferStack(Serializer):
    fn begin_object(mut self):
        self.write("{")

    fn end_object(mut self):
        self.write("}")

    fn begin_array(mut self):
        self.write("[")

    fn end_array(mut self):
        self.write("]")

    fn write_key(mut self, key: String):
        self.write('"', key, '":')

    fn write_item(mut self, value: Some[AnyType], add_comma: Bool):
        serialize(value, self)
        if add_comma:
            self.write(",")

    fn write_item[add_comma: Bool](mut self, value: Some[AnyType]):
        serialize(value, self)

        comptime if add_comma:
            self.write(",")


@fieldwise_init
struct PrettySerializer[indent: String = "    "](Defaultable, Serializer):
    var _data: String
    var _skip_indent: Bool
    var _depth: Int

    fn __init__(out self):
        self._data = ""
        self._skip_indent = False
        self._depth = 0

    fn write_string(mut self, string: StringSlice):
        self._data.write(string)

    fn _write_indent(mut self):
        for _ in range(self._depth):
            self.write(Self.indent)

    fn begin_object(mut self):
        self.write("{\n")
        self._depth += 1

    fn end_object(mut self):
        self._depth -= 1
        self._write_indent()
        self.write("}")

    fn begin_array(mut self):
        self.write("[\n")
        self._depth += 1

    fn end_array(mut self):
        self._depth -= 1
        self._write_indent()
        self.write("]")

    fn write_key(mut self, key: String):
        self._write_indent()
        self.write('"', key, '": ')
        self._skip_indent = True

    fn write_item(mut self, value: Some[AnyType], add_comma: Bool):
        if not self._skip_indent:
            self._write_indent()

        self._skip_indent = False
        serialize(value, self)

        if add_comma:
            self.write(",")
        self.write("\n")

    fn write_item[add_comma: Bool](mut self, value: Some[AnyType]):
        if not self._skip_indent:
            self._write_indent()

        self._skip_indent = False
        serialize(value, self)

        comptime if add_comma:
            self.write(",")
        self.write("\n")


trait JsonSerializable:
    fn write_json(self, mut writer: Some[Serializer]):
        _default_serialize[Self.serialize_as_array()](self, writer)

    @staticmethod
    fn serialize_as_array() -> Bool:
        return False


fn serialize[T: AnyType, //](value: T, out writer: String):
    writer = String()
    var stack_writer = _WriteBufferStack(writer)
    serialize(value, stack_writer)
    stack_writer.flush()


fn _default_serialize[
    T: AnyType, //, is_array: Bool = False
](value: T, mut writer: Some[Serializer]):
    comptime assert is_struct_type[T](), "Cannot serialize MLIR type"

    comptime field_count = struct_field_count[T]()
    comptime field_names = struct_field_names[T]()
    comptime types = struct_field_types[T]()

    comptime if is_array:
        writer.begin_array()
    else:
        writer.begin_object()

    comptime for i in range(field_count):
        comptime if not is_array:
            comptime name = field_names[i]
            writer.write_key(name)

        comptime add_comma = i != field_count - 1
        writer.write_item[add_comma](__struct_field_ref(i, value))

    comptime if is_array:
        writer.end_array()
    else:
        writer.end_object()


fn serialize[T: AnyType, //](value: T, mut writer: Some[Serializer]):
    comptime assert is_struct_type[T](), "Cannot serialize MLIR type"

    comptime if conforms_to(T, JsonSerializable):
        trait_downcast[JsonSerializable](value).write_json(writer)
    else:
        _default_serialize(value, writer)


# ===============================================
# Primitives
# ===============================================


__extension String(JsonSerializable):
    fn write_json(self, mut writer: Some[Serializer]):
        writer.write('"', self, '"')

    @staticmethod
    fn serialize_as_array() -> Bool:
        return False


__extension Int(JsonSerializable):
    fn write_json(self, mut writer: Some[Serializer]):
        writer.write(self)

    @staticmethod
    fn serialize_as_array() -> Bool:
        return False


__extension SIMD(JsonSerializable):
    fn write_json(self, mut writer: Some[Serializer]):
        comptime if size == 1:
            comptime if Self.dtype == DType.float64:
                write_f64(rebind[Float64](self), writer)
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
    fn serialize_as_array() -> Bool:
        return False


__extension Bool(JsonSerializable):
    fn write_json(self, mut writer: Some[Serializer]):
        writer.write("true" if self else "false")

    @staticmethod
    fn serialize_as_array() -> Bool:
        return False


__extension IntLiteral(JsonSerializable):
    fn write_json(self, mut writer: Some[Serializer]):
        writer.write(self)

    @staticmethod
    fn serialize_as_array() -> Bool:
        return False


__extension FloatLiteral(JsonSerializable):
    fn write_json(self, mut writer: Some[Serializer]):
        writer.write(self)

    @staticmethod
    fn serialize_as_array() -> Bool:
        return False


# ===============================================
# Pointers
# ===============================================


__extension ArcPointer(JsonSerializable):
    fn write_json(self, mut writer: Some[Serializer]):
        serialize(self[], writer)

    @staticmethod
    fn serialize_as_array() -> Bool:
        return False


__extension OwnedPointer(JsonSerializable):
    fn write_json(self, mut writer: Some[Serializer]):
        serialize(self[], writer)

    @staticmethod
    fn serialize_as_array() -> Bool:
        return False


# ===============================================
# Collections
# ===============================================


__extension Optional(JsonSerializable):
    fn write_json(self, mut writer: Some[Serializer]):
        if self:
            serialize(self.value(), writer)
        else:
            writer.write("null")

    @staticmethod
    fn serialize_as_array() -> Bool:
        return False


__extension List(JsonSerializable):
    fn write_json(self, mut writer: Some[Serializer]):
        writer.begin_array()

        for i in range(len(self)):
            var add_comma = i != len(self) - 1
            writer.write_item(self[i], add_comma)

        writer.end_array()

    @staticmethod
    fn serialize_as_array() -> Bool:
        return False


__extension InlineArray(JsonSerializable):
    fn write_json(self, mut writer: Some[Serializer]):
        writer.begin_array()

        for i in range(Self.size):
            var add_comma = i != Self.size - 1
            writer.write_item(self[i], add_comma)

        writer.end_array()

    @staticmethod
    fn serialize_as_array() -> Bool:
        return False


__extension Dict(JsonSerializable):
    fn write_json(self, mut writer: Some[Serializer]):
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
    fn serialize_as_array() -> Bool:
        return False


__extension Tuple(JsonSerializable):
    fn write_json(self, mut writer: Some[Serializer]):
        writer.begin_array()

        comptime for i in range(Self.__len__()):
            comptime add_comma = i != Self.__len__() - 1
            writer.write_item[add_comma](self[i])

        writer.end_array()

    @staticmethod
    fn serialize_as_array() -> Bool:
        return True


__extension Set(JsonSerializable):
    fn write_json(self, mut writer: Some[Serializer]):
        writer.begin_array()

        for i, item in enumerate(self):
            var add_comma = i != len(self) - 1
            writer.write_item(item, add_comma)

        writer.end_array()

    @staticmethod
    fn serialize_as_array() -> Bool:
        return False
