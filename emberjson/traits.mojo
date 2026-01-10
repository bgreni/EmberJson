from python import ConvertibleToPython
from std.reflection import *
from .parser import Parser


trait PrettyPrintable:
    fn pretty_to(
        self, mut writer: Some[Writer], indent: String, *, curr_depth: UInt = 0
    ):
        ...


trait JsonValue(
    Boolable,
    ConvertibleToPython,
    Copyable,
    Defaultable,
    Equatable,
    Movable,
    PrettyPrintable,
    Representable,
    Stringable,
    Writable,
):
    pass


fn assert_all_fields_serializable[T: JsonSerializable]():
    comptime field_count = struct_field_count[T]()
    comptime types = struct_field_types[T]()
    comptime field_names = struct_field_names[T]()

    @parameter
    for i in range(field_count):
        __comptime_assert conforms_to(types[i], JsonSerializable), (
            "Non serializable field "
            + field_names[i]
            + " on type: "
            + get_type_name[T]()
        )


# fn assert_all_fields_deserializable[T: JsonSerializable]():
#     comptime field_count = struct_field_count[T]()
#     comptime types = struct_field_types[T]()
#     comptime field_names = struct_field_names[T]()

#     @parameter
#     for i in range(field_count):
#         __comptime_assert conforms_to(types[i], JsonDeserializable), (
#             "Non deserializable field "
#             + field_names[i]
#             + " on type: "
#             + get_type_name[T]()
#         )


# trait JsonDeserializable(Defaultable):
#     @staticmethod
#     fn from_json(json: Parser, out s: Self):
#         comptime field_count = struct_field_count[Self]()
#         comptime field_names = struct_field_names[Self]()
#         s = Self()

#         @parameter
#         for i in range(field_count):
#             ref field = trait_downcast[JsonDeserializable](
#                 __struct_field_ref(i, s)
#             )
#             field = type_of(field).from_json(json)


trait JsonSerializable:
    fn write_json(self, mut writer: Some[Writer]):
        # assert_all_fields_serializable[Self]()
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
                writer.write(field_names[i], ":")

            # var field = UnsafePointer(to=__struct_field_ref(i, self))

            ref field = __struct_field_ref(i, self)

            # Someday...
            trait_downcast[JsonSerializable](field).write_json(writer)

            # comptime T = get_type_name[types[i]]()

            # print(materialize[T]())

            # write_json[T](field, writer)

            @parameter
            if i != field_count - 1:
                writer.write(",")
        writer.write(end)

    @staticmethod
    fn serialize_as_array() -> Bool:
        return False


fn write_json[
    FT: AnyType, origin: Origin, //, T: String
](field: UnsafePointer[FT, origin], mut writer: Some[Writer]):
    @parameter
    if T == "String":
        write_json(field.bitcast[String]()[], writer)
    elif T == "Int":
        write_json(field.bitcast[Int]()[], writer)
    elif "SIMD" in T:
        # do something

        comptime start = T.find("[") + 1
        comptime end = T.find("]")
        comptime t = T[start:end]

        # write_json[String(t)](field, writer)


fn write_json(s: String, mut writer: Some[Writer]):
    writer.write('"', s, '"')


fn write_json(i: Int, mut writer: Some[Writer]):
    writer.write(i)


# __extension String(JsonSerializable):
#     fn write_json(self, mut writer: Some[Writer]):
#         writer.write('"', self, '"')


# __extension Int(JsonSerializable):
#     fn write_json(self, mut writer: Some[Writer]):
#         writer.write(self)
