from ._deserialize.reflection import (
    _Base,
    deserialize,
    JsonDeserializable,
    _deserialize_impl,
)
from ._deserialize.parser import Parser
from ._serialize import JsonSerializable, serialize, Serializer
from std.hashlib import Hasher
from std.sys.intrinsics import _type_is_eq
from std.builtin.rebind import downcast


fn _get_object_bytes[
    origin: ImmutOrigin
](mut p: Parser[origin]) raises -> Span[Byte, origin]:
    return p.expect_object_bytes()


fn _get_array_bytes[
    origin: ImmutOrigin
](mut p: Parser[origin]) raises -> Span[Byte, origin]:
    return p.expect_array_bytes()


fn _get_int_bytes[
    origin: ImmutOrigin
](mut p: Parser[origin]) raises -> Span[Byte, origin]:
    return p.expect_integer_bytes()


fn _get_float_bytes[
    origin: ImmutOrigin
](mut p: Parser[origin]) raises -> Span[Byte, origin]:
    return p.expect_float_bytes()


fn _get_string_bytes[
    origin: ImmutOrigin
](mut p: Parser[origin]) raises -> Span[Byte, origin]:
    return p.expect_string_bytes()


fn _get_value_bytes[
    origin: ImmutOrigin
](mut p: Parser[origin]) raises -> Span[Byte, origin]:
    return p.expect_value_bytes()


fn _deserialize_bytes[
    T: _Base, origin: Origin
](b: Span[Byte, origin]) raises -> T:
    var p = Parser(b)
    return _deserialize_impl[T](p)


comptime ReadBytesFn[origin: ImmutOrigin] = fn(
    mut Parser[origin]
) raises -> Span[Byte, origin]
comptime ParseFn[T: _Base, origin: ImmutOrigin] = fn(
    Span[Byte, origin]
) raises -> T


fn __pick_byte_expect[T: _Base, origin: ImmutOrigin]() -> ReadBytesFn[origin]:
    comptime if conforms_to(T, JsonDeserializable) and downcast[
        T, JsonDeserializable
    ].deserialize_as_array():
        return _get_array_bytes[origin]
    else:
        return _get_object_bytes[origin]


@fieldwise_init
struct Lazy[
    T: _Base,
    origin: ImmutOrigin,
    parse_value: ReadBytesFn[origin] = __pick_byte_expect[T, origin](),
    extract_value: ParseFn[T, origin] = _deserialize_bytes[T, origin],
](Hashable, JsonDeserializable, JsonSerializable, TrivialRegisterPassable):
    var _data: Span[Byte, Self.origin]

    @staticmethod
    fn from_json[
        o: ImmutOrigin, options: ParseOptions, //
    ](mut p: Parser[o, options], out s: Self) raises:
        # TODO: Remove this restriction when compiler allows
        comptime assert (
            options == ParseOptions()
        ), "Lazy deserialization only works with default parse options"
        s = {Self.parse_value(rebind[Parser[Self.origin]](p))}

    fn write_json(self, mut writer: Some[Serializer]):
        writer.write(StringSlice(unsafe_from_utf8=self._data))

    fn get(self) raises -> Self.T:
        return Self.extract_value(self._data)

    fn __getitem__(self) raises -> Self.T:
        return self.get()

    fn __eq__(self, other: Self) -> Bool:
        return self._data == other._data

    fn __hash__(self, mut h: Some[Hasher]):
        comptime assert conforms_to(Self.T, Hashable)
        h.update(StringSlice(unsafe_from_utf8=self._data))

    fn unsafe_as_string_slice(
        self,
    ) -> StringSlice[Self.origin]:
        # TODO: Use where clause when that actually works
        comptime assert _type_is_eq[Self.T, String]()
        return StringSlice(unsafe_from_utf8=self._data[1:-1])


comptime LazyString[origin: ImmutOrigin] = Lazy[
    String, origin, _get_string_bytes[origin]
]

comptime LazyInt[origin: ImmutOrigin] = Lazy[
    Int64, origin, _get_int_bytes[origin]
]

comptime LazyUInt[origin: ImmutOrigin] = Lazy[
    UInt64, origin, _get_int_bytes[origin]
]

comptime LazyFloat[origin: ImmutOrigin] = Lazy[
    Float64, origin, _get_float_bytes[origin]
]

comptime LazyValue[origin: ImmutOrigin] = Lazy[
    Value, origin, _get_value_bytes[origin]
]
