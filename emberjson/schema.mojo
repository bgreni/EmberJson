from emberjson import (
    JsonDeserializable,
    JsonSerializable,
    Parser,
    ParseOptions,
    Serializer,
    serialize,
)
from emberjson._deserialize.reflection import _deserialize_impl, _Base


@fieldwise_init
struct Range[T: Comparable & _Base & Defaultable, min: T, max: T](
    JsonDeserializable, JsonSerializable
):
    var value: Self.T

    @staticmethod
    fn from_json[
        origin: ImmutOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        s = Self(Self.T())
        s.value = _deserialize_impl[Self.T](p)

        if (
            s.value < materialize[Self.min]()
            or s.value > materialize[Self.max]()
        ):
            raise Error("Value out of range")

    fn write_json(self, mut writer: Some[Serializer]):
        serialize(self.value, writer)

    fn __getitem__(self) -> ref[self.value] Self.T:
        return self.value


@fieldwise_init
struct Size[T: Sized & _Base & Defaultable, min: Int, max: Int](
    JsonDeserializable, JsonSerializable
):
    var value: Self.T

    @staticmethod
    fn from_json[
        origin: ImmutOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        s = Self(Self.T())
        s.value = _deserialize_impl[Self.T](p)

        if len(s.value) < Self.min or len(s.value) > Self.max:
            raise Error("Value out of size range")

    fn write_json(self, mut writer: Some[Serializer]):
        serialize(self.value, writer)

    fn __getitem__(self) -> ref[self.value] Self.T:
        return self.value


@fieldwise_init
struct OneOf[T: _Base & Equatable & Defaultable, *accepted: T](
    JsonDeserializable, JsonSerializable
):
    var value: Self.T

    @staticmethod
    fn from_json[
        origin: ImmutOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        s = Self(Self.T())
        s.value = _deserialize_impl[Self.T](p)

        comptime for i in range(Variadic.size(Self.accepted)):
            if s.value == materialize[Self.accepted[i]]():
                return

        raise Error("Value not in options")

    fn write_json(self, mut writer: Some[Serializer]):
        serialize(self.value, writer)

    fn __getitem__(self) -> ref[self.value] Self.T:
        return self.value


@fieldwise_init
struct Secret[T: _Base & Defaultable](JsonDeserializable, JsonSerializable):
    var value: Self.T

    @staticmethod
    fn from_json[
        origin: ImmutOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        s = Self(Self.T())
        s.value = _deserialize_impl[Self.T](p)

    fn write_json(self, mut writer: Some[Serializer]):
        writer.write('"********"')

    fn __getitem__(self) -> ref[self.value] Self.T:
        return self.value
