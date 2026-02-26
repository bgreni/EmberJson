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

##########################################################
# Value Validation
##########################################################


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


##########################################################
# Secret
##########################################################


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


##########################################################
# Clamp
##########################################################


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


##########################################################
# Coerce
##########################################################


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


fn __try_coerce_int(v: Value) raises -> Int64:
    if v.is_int() or v.is_uint():
        return v.int()
    elif v.is_float():
        return Int64(v.float())
    elif v.is_string():
        return deserialize[Int64](v.string())
    else:
        raise Error("Value cannot be converted to an integer")


fn __try_coerce_uint(v: Value) raises -> UInt64:
    if v.is_int() or v.is_uint():
        return v.uint()
    elif v.is_float():
        return UInt64(v.float())
    elif v.is_string():
        return deserialize[UInt64](v.string())
    else:
        raise Error("Value cannot be converted to an unsigned integer")


fn __try_coerce_float(v: Value) raises -> Float64:
    if v.is_int() or v.is_uint():
        return Float64(v.int())
    elif v.is_float():
        return v.float()
    elif v.is_string():
        return deserialize[Float64](v.string())
    else:
        raise Error("Value cannot be converted to a float")


fn __try_coerce_string(v: Value) raises -> String:
    if v.is_string():
        return v.string()
    elif v.is_int():
        return String(v.int())
    elif v.is_uint():
        return String(v.uint())
    elif v.is_float():
        return String(v.float())
    else:
        raise Error("Value cannot be converted to a string")


comptime CoerceInt = Coerce[Int64, __try_coerce_int]
comptime CoerceUInt = Coerce[UInt64, __try_coerce_uint]
comptime CoerceFloat = Coerce[Float64, __try_coerce_float]
comptime CoerceString = Coerce[String, __try_coerce_string]


##########################################################
# Default
##########################################################


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


##########################################################
# Transform
##########################################################


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
