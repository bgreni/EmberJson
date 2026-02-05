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

        @parameter
        if add_comma:
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

        @parameter
        if add_comma:
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

        @parameter
        if add_comma:
            self.write(",")


@fieldwise_init
struct PrettySerializer[indent: String = "    "](Serializer):
    var _data: String

    fn write_string(mut self, string: StringSlice):
        self._data.write(string)

    fn begin_object(mut self):
        self.write("{\n")

    fn end_object(mut self):
        self.write("\n}")

    fn begin_array(mut self):
        self.write("[\n")

    fn end_array(mut self):
        self.write("\n]")

    fn write_key(mut self, key: String):
        self.write(Self.indent, '"', key, '": ')

    fn write_item(mut self, value: Some[AnyType], add_comma: Bool):
        self.write(Self.indent)
        serialize(value, self)
        if add_comma:
            self.write(",")
        self.write("\n")

    fn write_item[add_comma: Bool](mut self, value: Some[AnyType]):
        self.write(Self.indent)
        serialize(value, self)

        @parameter
        if add_comma:
            self.write(",")
        self.write("\n")


trait JsonSerializable:
    fn write_json(self, mut writer: Some[Serializer]):
        comptime field_count = struct_field_count[Self]()
        comptime field_names = struct_field_names[Self]()
        comptime types = struct_field_types[Self]()
        comptime is_array = Self.serialize_as_array()
        comptime open = "[" if is_array else "{"
        comptime end = "]" if is_array else "}"
        writer.write(open)

        @parameter
        for i in range(field_count):

            @parameter
            if not is_array:
                comptime name = field_names[i]
                writer.write_key(name)

            comptime add_comma = i != field_count - 1
            writer.write_item[add_comma](__struct_field_ref(i, self))
        writer.write(end)

    @staticmethod
    fn serialize_as_array() -> Bool:
        return False


fn serialize[
    T: AnyType, //, Out: Writer & Defaultable = String
](value: T, out writer: Out):
    writer = Out()
    var stack_writer = _WriteBufferStack(writer)
    serialize(value, stack_writer)
    stack_writer.flush()


fn serialize[T: AnyType, //](value: T, mut writer: Some[Serializer]):
    comptime assert is_struct_type[T](), "Cannot serialize MLIR type"

    @parameter
    if conforms_to(T, JsonSerializable):
        trait_downcast[JsonSerializable](value).write_json(writer)
    else:
        comptime field_count = struct_field_count[T]()
        comptime field_names = struct_field_names[T]()
        comptime types = struct_field_types[T]()

        writer.begin_object()

        @parameter
        for i in range(field_count):
            comptime name = field_names[i]
            writer.write_key(name)
            comptime add_comma = i != field_count - 1
            writer.write_item[add_comma](__struct_field_ref(i, value))

        writer.end_object()


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
        @parameter
        if size > 1:
            writer.begin_array()

        @parameter
        for i in range(size):
            writer.write(self[i])

            @parameter
            if i != size - 1:
                writer.write(",")

        @parameter
        if size > 1:
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

        @parameter
        for i in range(Self.__len__()):
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
