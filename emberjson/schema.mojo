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
from std.sys.intrinsics import _type_is_eq
from emberjson._deserialize.reflection import _Base

##########################################################
# Value Validation
##########################################################


comptime MergeAllOf[
    T: _Base,
    *Validators: Variadic.TypesOfTrait[Validator],
] = AllOf[
    T,
    *Variadic.concat_types[*Validators],
]


@fieldwise_init
struct AllOf[T: _Base, *validators: Validator](
    JsonDeserializable, JsonSerializable, Validator
):
    comptime Type = Self.T
    var value: Self.T

    @staticmethod
    def from_json[
        origin: ImmutOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        s = {deserialize[Self.T](p)}

        s.validate(s.value)

    @staticmethod
    def validate(value: Self.Type) raises:
        comptime for i in range(Variadic.size(Self.validators)):
            comptime VType = Self.validators[i]
            comptime assert _type_is_eq[VType.Type, Self.T]()
            VType.validate(rebind[VType.Type](value))

    def write_json(self, mut writer: Some[Serializer]):
        serialize(self.value, writer)

    def __getitem__(self) -> ref[self.value] Self.T:
        return self.value


trait Validator:
    comptime Type: _Base

    @staticmethod
    def validate(value: Self.Type) raises:
        ...


@fieldwise_init
struct Validated[
    T: _Base,
    validator: def(T) -> Bool,
    err_msg: String = "Value is not valid",
](JsonDeserializable, JsonSerializable, Validator):
    var value: Self.T

    comptime Type = Self.T

    @staticmethod
    def from_json[
        origin: ImmutOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        s = {deserialize[Self.T](p)}

        s.validate(s.value)

    @staticmethod
    def validate(value: Self.Type) raises:
        if not Self.validator(value):
            raise Error(Self.err_msg)

    def write_json(self, mut writer: Some[Serializer]):
        serialize(self.value, writer)

    def __getitem__(self) -> ref[self.value] Self.T:
        return self.value


@always_inline
def __is_in_range[
    T: Comparable & _Base, min: T, max: T
](value: T,) -> Bool:
    return value >= materialize[min]() and value <= materialize[max]()


comptime Range[T: Comparable & _Base, min: T, max: T] = Validated[
    T, __is_in_range[T, min, max], "Value out of range"
]


@always_inline
def __is_in_size_range[
    T: Sized & _Base, min: Int, max: Int
](value: T,) -> Bool:
    return len(value) >= min and len(value) <= max


comptime Size[T: Sized & _Base, min: Int, max: Int] = Validated[
    T, __is_in_size_range[T, min, max], "Value out of size range"
]


@always_inline
def __has_unique_elements[
    T: _Base & Iterable
](value: T) -> Bool where conforms_to(
    T.IteratorType[origin_of(value)], Copyable
) and conforms_to(T.IteratorType[origin_of(value)].Element, Equatable):
    for i, a in enumerate(value):
        for j, b in enumerate(value):
            if i != j and trait_downcast[Equatable](a) == trait_downcast[
                Equatable
            ](b):
                return False
    return True


comptime Unique[
    T: _Base & Iterable, err_msg: String = "Value is not unique"
] = Validated[T, __has_unique_elements[T], err_msg]


@always_inline
def __is_eq[T: Equatable, //, value: T](a: T) -> Bool:
    return a == materialize[value]()


comptime Eq[T: _Base & Equatable, //, value: T] = Validated[
    T, __is_eq[value], "Value is not equal"
]


def __expect_raises[T: _Base, validator: Validator](value: T) -> Bool:
    comptime VType = validator.Type
    comptime assert _type_is_eq[VType, T]()
    try:
        validator.validate(rebind[VType](value))
        return False
    except:
        return True


comptime Not[T: _Base, validator: Validator] = Validated[
    T, __expect_raises[T, validator], "Expected validator to fail"
]

comptime Ne[T: _Base & Equatable, //, value: T] = Not[T, Eq[value]]


@fieldwise_init
struct OneOf[T: _Base & Equatable, *accepted: Validator](
    JsonDeserializable, JsonSerializable, Validator
):
    var value: Self.T
    comptime Type = Self.T

    @staticmethod
    def from_json[
        origin: ImmutOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        s = {deserialize[Self.T](p)}

        s.validate(s.value)

    @staticmethod
    def validate(value: Self.Type) raises:
        var matched = False
        comptime for i in range(Variadic.size(Self.accepted)):
            var current_match = False
            try:
                comptime VType = Self.accepted[i]
                comptime assert _type_is_eq[VType.Type, Self.T]()
                VType.validate(rebind[VType.Type](value))
                current_match = True
            except:
                pass

            if current_match:
                if matched:
                    raise Error("Multiple validators matched")
                matched = True

        if not matched:
            raise Error("Value didn't match any validators")

    def write_json(self, mut writer: Some[Serializer]):
        serialize(self.value, writer)

    def __getitem__(self) -> ref[self.value] Self.T:
        return self.value


@fieldwise_init
struct AnyOf[T: _Base & Equatable, *accepted: Validator](
    JsonDeserializable, JsonSerializable, Validator
):
    var value: Self.T
    comptime Type = Self.T

    @staticmethod
    def from_json[
        origin: ImmutOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        s = {deserialize[Self.T](p)}

        s.validate(s.value)

    @staticmethod
    def validate(value: Self.Type) raises:
        var matched = False
        comptime for i in range(Variadic.size(Self.accepted)):
            try:
                comptime VType = Self.accepted[i]
                comptime assert _type_is_eq[VType.Type, Self.T]()
                VType.validate(rebind[VType.Type](value))
                matched = True
                break
            except:
                pass
        if not matched:
            raise Error("Value not in options")

    def write_json(self, mut writer: Some[Serializer]):
        serialize(self.value, writer)

    def __getitem__(self) -> ref[self.value] Self.T:
        return self.value


@fieldwise_init
struct NoneOf[T: _Base & Equatable, *rejected: Validator](
    JsonDeserializable, JsonSerializable, Validator
):
    var value: Self.T
    comptime Type = Self.T

    @staticmethod
    def from_json[
        origin: ImmutOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        s = {deserialize[Self.T](p)}

        s.validate(s.value)

    @staticmethod
    def validate(value: Self.Type) raises:
        comptime for i in range(Variadic.size(Self.rejected)):
            var matched = False
            try:
                comptime VType = Self.rejected[i]
                comptime assert _type_is_eq[VType.Type, Self.T]()
                VType.validate(rebind[VType.Type](value))
                matched = True
            except:
                pass

            if matched:
                raise Error("Value matched a rejected validator")

    def write_json(self, mut writer: Some[Serializer]):
        serialize(self.value, writer)

    def __getitem__(self) -> ref[self.value] Self.T:
        return self.value


@always_inline
def __is_multiple_of[base: SIMD](v: type_of(base)) -> Bool:
    comptime zeroes = type_of(base)(0)
    return v % base == zeroes


# TODO: Use some trait for this
comptime MultipleOf[base: SIMD] = Validated[
    type_of(base),
    __is_multiple_of[base],
    "Value is not a multiple of " + String(base),
]

##########################################################
# Secret
##########################################################


@fieldwise_init
struct Secret[T: _Base](JsonDeserializable, JsonSerializable):
    var value: Self.T

    @staticmethod
    def from_json[
        origin: ImmutOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        s = {deserialize[Self.T](p)}

    def write_json(self, mut writer: Some[Serializer]):
        writer.write('"********"')

    def __getitem__(self) -> ref[self.value] Self.T:
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
    def from_json[
        origin: ImmutOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        s = {deserialize[Self.T](p)}

        var min_val = materialize[Self.min]()
        var max_val = materialize[Self.max]()

        if s.value < min_val:
            s.value = min_val^
        elif s.value > max_val:
            s.value = max_val^

    def write_json(self, mut writer: Some[Serializer]):
        serialize(self.value, writer)

    def __getitem__(self) -> ref[self.value] Self.T:
        return self.value


##########################################################
# Coerce
##########################################################


@fieldwise_init
struct Coerce[Target: _Base, func: def(Value) raises -> Target](
    JsonDeserializable, JsonSerializable
):
    var value: Self.Target

    @staticmethod
    def from_json[
        origin: ImmutOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        s = {Self.func(deserialize[Value](p))}

    def write_json(self, mut writer: Some[Serializer]):
        serialize(self.value, writer)

    def __getitem__(self) -> ref[self.value] Self.Target:
        return self.value


def __try_coerce_int(v: Value) raises -> Int64:
    if v.is_int() or v.is_uint():
        return v.int()
    elif v.is_float():
        return Int64(v.float())
    elif v.is_string():
        return deserialize[Int64](v.string())
    else:
        raise Error("Value cannot be converted to an integer")


def __try_coerce_uint(v: Value) raises -> UInt64:
    if v.is_int() or v.is_uint():
        return v.uint()
    elif v.is_float():
        return UInt64(v.float())
    elif v.is_string():
        return deserialize[UInt64](v.string())
    else:
        raise Error("Value cannot be converted to an unsigned integer")


def __try_coerce_float(v: Value) raises -> Float64:
    if v.is_int() or v.is_uint():
        return Float64(v.int())
    elif v.is_float():
        return v.float()
    elif v.is_string():
        return deserialize[Float64](v.string())
    else:
        raise Error("Value cannot be converted to a float")


def __try_coerce_string(v: Value) raises -> String:
    if v.is_string():
        return v.string()
    elif v.is_int():
        return String(v.int())
    elif v.is_uint():
        return String(v.uint())
    elif v.is_float():
        return String(v.float())
    elif v.is_bool():
        return String(v.bool())
    elif v.is_null():
        return "null"
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

    def __init__(out self):
        self.value = materialize[Self.default]()

    @staticmethod
    def from_json[
        origin: ImmutOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        var op = deserialize[Optional[Self.T]](p)
        if op:
            s = {op.take()}
        else:
            s = {materialize[Self.default]()}

    def write_json(self, mut writer: Some[Serializer]):
        serialize(self.value, writer)

    def __getitem__(self) -> ref[self.value] Self.T:
        return self.value


##########################################################
# Transform
##########################################################


@fieldwise_init
struct Transform[InT: _Base, OutT: _Base, func: def(InT) -> OutT](
    JsonDeserializable, JsonSerializable
):
    var value: Self.OutT

    @staticmethod
    def from_json[
        origin: ImmutOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        s = {Self.func(deserialize[Self.InT](p))}

    def write_json(self, mut writer: Some[Serializer]):
        serialize(self.value, writer)

    def __getitem__(self) -> ref[self.value] Self.OutT:
        return self.value
