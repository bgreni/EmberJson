from emberjson import (
    JsonDeserializable,
    JsonSerializable,
    Parser,
    ParseOptions,
    Serializer,
    serialize,
    deserialize,
    Value,
)
from emberjson._deserialize.reflection import _Base


@fieldwise_init
struct Validated[
    T: _Base,
    validator: fn(T) -> Bool,
    err_msg: String = "Value is not valid",
](JsonDeserializable, JsonSerializable):
    var value: Self.T

    @staticmethod
    fn from_json[
        origin: ImmutOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        s = {deserialize[Self.T](p)}

        if not Self.validator(s.value):
            raise Error(Self.err_msg)

    fn write_json(self, mut writer: Some[Serializer]):
        serialize(self.value, writer)

    fn __getitem__(self) -> ref[self.value] Self.T:
        return self.value


@always_inline
fn __is_in_range[
    T: Comparable & _Base, min: T, max: T
](value: T,) -> Bool:
    return value >= materialize[min]() and value <= materialize[max]()


comptime Range[T: Comparable & _Base, min: T, max: T] = Validated[
    T, __is_in_range[T, min, max], "Value out of range"
]


@always_inline
fn __is_in_size_range[
    T: Sized & _Base, min: Int, max: Int
](value: T,) -> Bool:
    return len(value) >= min and len(value) <= max


comptime Size[T: Sized & _Base, min: Int, max: Int] = Validated[
    T, __is_in_size_range[T, min, max], "Value out of size range"
]


@fieldwise_init
struct OneOf[T: _Base & Equatable, *accepted: T](
    JsonDeserializable, JsonSerializable
):
    var value: Self.T

    @staticmethod
    fn from_json[
        origin: ImmutOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        s = {deserialize[Self.T](p)}

        comptime for i in range(Variadic.size(Self.accepted)):
            if s.value == materialize[Self.accepted[i]]():
                return

        raise Error("Value not in options")

    fn write_json(self, mut writer: Some[Serializer]):
        serialize(self.value, writer)

    fn __getitem__(self) -> ref[self.value] Self.T:
        return self.value


@fieldwise_init
struct Secret[T: _Base](JsonDeserializable, JsonSerializable):
    var value: Self.T

    @staticmethod
    fn from_json[
        origin: ImmutOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        s = {deserialize[Self.T](p)}

    fn write_json(self, mut writer: Some[Serializer]):
        writer.write('"********"')

    fn __getitem__(self) -> ref[self.value] Self.T:
        return self.value


@fieldwise_init
struct Clamp[T: _Base & Comparable, min: T, max: T](
    JsonDeserializable, JsonSerializable
):
    var value: Self.T

    @staticmethod
    fn from_json[
        origin: ImmutOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        s = {deserialize[Self.T](p)}

        var min_val = materialize[Self.min]()
        var max_val = materialize[Self.max]()

        if s.value < min_val:
            s.value = min_val^
        elif s.value > max_val:
            s.value = max_val^

    fn write_json(self, mut writer: Some[Serializer]):
        serialize(self.value, writer)

    fn __getitem__(self) -> ref[self.value] Self.T:
        return self.value


@fieldwise_init
struct Coerce[Target: _Base, func: fn(Value) raises -> Target](
    JsonDeserializable, JsonSerializable
):
    var value: Self.Target

    @staticmethod
    fn from_json[
        origin: ImmutOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        s = {Self.func(deserialize[Value](p))}

    fn write_json(self, mut writer: Some[Serializer]):
        serialize(self.value, writer)

    fn __getitem__(self) -> ref[self.value] Self.Target:
        return self.value


@fieldwise_init
struct Default[T: _Base, default: T](
    Defaultable, JsonDeserializable, JsonSerializable
):
    var value: Self.T

    fn __init__(out self):
        self.value = materialize[Self.default]()

    @staticmethod
    fn from_json[
        origin: ImmutOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        var op = deserialize[Optional[Self.T]](p)
        if op:
            s = {op.take()}
        else:
            s = {materialize[Self.default]()}

    fn write_json(self, mut writer: Some[Serializer]):
        serialize(self.value, writer)

    fn __getitem__(self) -> ref[self.value] Self.T:
        return self.value


@fieldwise_init
struct Transform[InT: _Base, OutT: _Base, func: fn(InT) -> OutT](
    JsonDeserializable, JsonSerializable
):
    var value: Self.OutT

    @staticmethod
    fn from_json[
        origin: ImmutOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        s = {Self.func(deserialize[Self.InT](p))}

    fn write_json(self, mut writer: Some[Serializer]):
        serialize(self.value, writer)

    fn __getitem__(self) -> ref[self.value] Self.OutT:
        return self.value
