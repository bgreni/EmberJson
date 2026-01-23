from std.reflection import (
    struct_field_count,
    struct_field_names,
    struct_field_types,
    is_struct_type,
)
from sys.intrinsics import _type_is_eq


trait JsonSerializable:
    fn write_json(self, mut writer: Some[Writer]):
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
                writer.write('"', name, '":')

            serialize(__struct_field_ref(i, self), writer)

            @parameter
            if i != field_count - 1:
                writer.write(",")
        writer.write(end)

    @staticmethod
    fn serialize_as_array() -> Bool:
        return False


fn serialize[
    T: AnyType, //, Out: Writer & Defaultable = String
](value: T, out writer: Out):
    writer = Out()
    serialize(value, writer)


fn serialize[T: AnyType, //](value: T, mut writer: Some[Writer]):
    __comptime_assert is_struct_type[T](), "Cannot serialize MLIR type"

    @parameter
    if conforms_to(T, JsonSerializable):
        trait_downcast[JsonSerializable](value).write_json(writer)
    else:
        comptime field_count = struct_field_count[T]()
        comptime field_names = struct_field_names[T]()
        comptime types = struct_field_types[T]()

        writer.write("{")

        @parameter
        for i in range(field_count):
            comptime name = field_names[i]
            writer.write('"', name, '":')
            ref field = __struct_field_ref(i, value)
            serialize(field, writer)

            @parameter
            if i != field_count - 1:
                writer.write(",")

        writer.write("}")


__extension String(JsonSerializable):
    fn write_json(self, mut writer: Some[Writer]):
        writer.write('"', self, '"')

    @staticmethod
    fn serialize_as_array() -> Bool:
        return False


__extension Int(JsonSerializable):
    fn write_json(self, mut writer: Some[Writer]):
        writer.write(self)

    @staticmethod
    fn serialize_as_array() -> Bool:
        return False


__extension SIMD(JsonSerializable):
    fn write_json(self, mut writer: Some[Writer]):
        @parameter
        if size > 1:
            writer.write("[")

        @parameter
        for i in range(size):
            writer.write(self[i])

            @parameter
            if i != size - 1:
                writer.write(",")

        @parameter
        if size > 1:
            writer.write("]")

    @staticmethod
    fn serialize_as_array() -> Bool:
        return False


__extension Optional(JsonSerializable):
    fn write_json(self, mut writer: Some[Writer]):
        if self:
            serialize(self.value(), writer)
        else:
            writer.write("null")

    @staticmethod
    fn serialize_as_array() -> Bool:
        return False


__extension Bool(JsonSerializable):
    fn write_json(self, mut writer: Some[Writer]):
        writer.write("true" if self else "false")

    @staticmethod
    fn serialize_as_array() -> Bool:
        return False


__extension List(JsonSerializable):
    fn write_json(self, mut writer: Some[Writer]):
        writer.write("[")

        for i in range(len(self)):
            serialize(self[i], writer)

            if i != len(self) - 1:
                writer.write(",")
        writer.write("]")

    @staticmethod
    fn serialize_as_array() -> Bool:
        return False


__extension InlineArray(JsonSerializable):
    fn write_json(self, mut writer: Some[Writer]):
        writer.write("[")

        for i in range(Self.size):
            serialize(self[i], writer)

            if i != Self.size - 1:
                writer.write(",")
        writer.write("]")

    @staticmethod
    fn serialize_as_array() -> Bool:
        return False


__extension Dict(JsonSerializable):
    fn write_json(self, mut writer: Some[Writer]):
        __comptime_assert _type_is_eq[
            Self.K, String
        ](), "Dict must have string keys"
        writer.write("{")
        var i = 0
        for item in self.items():
            serialize(item.key, writer)
            writer.write(":")
            serialize(item.value, writer)

            if i != len(self) - 1:
                writer.write(",")
            i += 1
        writer.write("}")

    @staticmethod
    fn serialize_as_array() -> Bool:
        return False


__extension IntLiteral(JsonSerializable):
    fn write_json(self, mut writer: Some[Writer]):
        writer.write(self)

    @staticmethod
    fn serialize_as_array() -> Bool:
        return False


__extension FloatLiteral(JsonSerializable):
    fn write_json(self, mut writer: Some[Writer]):
        writer.write(self)

    @staticmethod
    fn serialize_as_array() -> Bool:
        return False
