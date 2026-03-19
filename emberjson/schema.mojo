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
from std.reflection import (
    get_base_type_name,
    struct_field_type_by_name,
    struct_field_index_by_name,
)

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


comptime MergeAnyOf[
    T: _Base & Equatable,
    *Validators: Variadic.TypesOfTrait[Validator],
] = AnyOf[
    T,
    *Variadic.concat_types[*Validators],
]

comptime MergeOneOf[
    T: _Base & Equatable,
    *Validators: Variadic.TypesOfTrait[Validator],
] = OneOf[
    T,
    *Variadic.concat_types[*Validators],
]

comptime MergeNoneOf[
    T: _Base & Equatable,
    *Validators: Variadic.TypesOfTrait[Validator],
] = NoneOf[
    T,
    *Variadic.concat_types[*Validators],
]


struct AllOf[T: _Base, *validators: Validator](
    JsonDeserializable, JsonSerializable, Validator
):
    """A validator that requires a value to pass all of the given validators.

    Parameters:
        T: The type of the value to validate.
        validators: The validators to apply.
    """

    comptime Type = Self.T
    var value: Self.T

    def __init__(out self, var value: Self.T) raises:
        self.value = value^
        Self.validate(self.value)

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


struct Validated[
    T: _Base,
    validator: def(T) -> Bool,
    err_msg: String = "Value is not valid",
](JsonDeserializable, JsonSerializable, Validator):
    """Validates a value by applying the given function.

    Parameters:
        T: The type of the value to validate.
        validator: The validator to apply.
        err_msg: The error message to raise if the validator fails.
    """

    comptime Type = Self.T
    var value: Self.T

    def __init__(out self, var value: Self.T) raises:
        self.value = value^
        Self.validate(self.value)

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
    T: Comparable & _Base, min: T, max: T, exclusive: Bool
](value: T,) -> Bool:
    comptime if exclusive:
        return value > materialize[min]() and value < materialize[max]()
    else:
        return value >= materialize[min]() and value <= materialize[max]()


comptime Range[T: Comparable & _Base, min: T, max: T] = Validated[
    T, __is_in_range[T, min, max, False], "Value out of range"
]
"""Validates a value to be within a given value range.

Parameters:
    T: The type of the value to validate.
    min: The minimum value.
    max: The maximum value.
"""

comptime ExclusiveRange[T: Comparable & _Base, min: T, max: T] = Validated[
    T, __is_in_range[T, min, max, True], "Value out of range (exclusive)"
]
"""Validates a value to be strictly within a given range (exclusive bounds).

Parameters:
    T: The type of the value to validate.
    min: The exclusive lower bound.
    max: The exclusive upper bound.
"""


@always_inline
def __is_in_size_range[
    T: Sized & _Base, min: Int, max: Int
](value: T,) -> Bool:
    return len(value) >= min and len(value) <= max


comptime Size[T: Sized & _Base, min: Int, max: Int] = Validated[
    T, __is_in_size_range[T, min, max], "Value out of size range"
]
"""Validates a value to be within a given size range.

Parameters:
    T: The type of the value to validate.
    min: The minimum size.
    max: The maximum size.
"""


@always_inline
def __is_non_empty[T: Sized & _Base](value: T) -> Bool:
    return len(value) > 0


comptime NonEmpty[T: Sized & _Base] = Validated[
    T, __is_non_empty[T], "Value must not be empty"
]
"""Validates that a sized value is non-empty.

Parameters:
    T: The type of the value to validate.
"""


@always_inline
def __starts_with[prefix: String](s: String) -> Bool:
    return s.startswith(prefix)


comptime StartsWith[prefix: String] = Validated[
    String,
    __starts_with[prefix],
    "Value does not start with expected prefix",
]
"""Validates that a string starts with a given prefix.

Parameters:
    prefix: The required prefix.
"""


@always_inline
def __ends_with[suffix: String](s: String) -> Bool:
    return s.endswith(suffix)


comptime EndsWith[suffix: String] = Validated[
    String, __ends_with[suffix], "Value does not end with expected suffix"
]
"""Validates that a string ends with a given suffix.

Parameters:
    suffix: The required suffix.
"""


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


comptime Unique[T: _Base & Iterable] = Validated[
    T, __has_unique_elements[T], "Values are not unique"
]
"""Enforces a value to have unique elements.

Parameters:
    T: The type of the value to validate.
"""


@always_inline
def __is_eq[T: Equatable, //, value: T](a: T) -> Bool:
    return a == materialize[value]()


comptime Eq[T: _Base & Equatable, //, value: T] = Validated[
    T, __is_eq[value], "Value is not equal"
]
"""
Validates a value to be equal to a given value.

Parameters:
    T: The type of the value to validate.
    value: The value to compare to.
"""


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
"""
Validates a value to not pass a given validator.

Parameters:
    T: The type of the value to validate.
    validator: The validator to apply.
"""

comptime Ne[T: _Base & Equatable, //, value: T] = Not[T, Eq[value]]
"""
Validates a value to not be equal to a given value.

Parameters:
    T: The type of the value to validate.
    value: The value to compare to.
"""


struct OneOf[T: _Base & Equatable, *accepted: Validator](
    JsonDeserializable, JsonSerializable, Validator
):
    """
    Validates a value to pass one and only one of the given validators.

    Parameters:
        T: The type of the value to validate.
        accepted: The validators to apply.
    """

    var value: Self.T
    comptime Type = Self.T

    def __init__(out self, var value: Self.T) raises:
        self.value = value^
        Self.validate(self.value)

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


struct AnyOf[T: _Base & Equatable, *accepted: Validator](
    JsonDeserializable, JsonSerializable, Validator
):
    """
    Validates a value to pass at least one of the given validators.

    Parameters:
        T: The type of the value to validate.
        accepted: The validators to apply.
    """

    var value: Self.T
    comptime Type = Self.T

    def __init__(out self, var value: Self.T) raises:
        self.value = value^
        Self.validate(self.value)

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


struct NoneOf[T: _Base & Equatable, *rejected: Validator](
    JsonDeserializable, JsonSerializable, Validator
):
    """
    Validates a value to not pass any of the given validators.

    Parameters:
        T: The type of the value to validate.
        rejected: The validators to apply.
    """

    var value: Self.T
    comptime Type = Self.T

    def __init__(out self, var value: Self.T) raises:
        self.value = value^
        Self.validate(self.value)

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
"""
Validates a value to be a multiple of a given value.

Parameters:
    base: The value to validate against.
"""


struct Enum[T: _Base & Equatable, *accepted: T](
    JsonDeserializable, JsonSerializable, Validator
):
    """Validates a value against an enumerated set of allowed values.
    A semantic alias for OneOf — use with Eq validators for enum-style validation.

    Example:
        comptime Color = Enum[String, "red", "green", "blue"]

    Parameters:
        T: The type of the value to validate.
        accepted: The validators representing allowed values.
    """

    var value: Self.T
    comptime Type = Self.T

    def __init__(out self, var value: Self.T) raises:
        self.value = value^
        Self.validate(self.value)

    @staticmethod
    def from_json[
        origin: ImmutOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        s = {deserialize[Self.T](p)}

        s.validate(s.value)

    @staticmethod
    def validate(value: Self.Type) raises:
        comptime for i in range(Variadic.size(Self.accepted)):
            if value == materialize[Self.accepted[i]]():
                return
        raise Error("Value not in options")

    def write_json(self, mut writer: Some[Serializer]):
        serialize(self.value, writer)

    def __getitem__(self) -> ref[self.value] Self.T:
        return self.value


##########################################################
# Secret
##########################################################


@fieldwise_init
struct Secret[T: _Base](JsonDeserializable, JsonSerializable):
    var value: Self.T
    """
    A secret value that will be hidden as an opaque string if serialized back to JSON.

    Parameters:
        T: The type of the value to hide.
    """

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
struct Clamp[T: _Base & Comparable, minimum: T, maximum: T](
    JsonDeserializable, JsonSerializable
):
    """
    A value that will be clamped to a given range.

    Parameters:
        T: The type of the value to clamp.
        minimum: The minimum value.
        maximum: The maximum value.
    """

    var value: Self.T

    @staticmethod
    def from_json[
        origin: ImmutOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        s = {deserialize[Self.T](p)}

        var min_val = materialize[Self.minimum]()
        var max_val = materialize[Self.maximum]()

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
    """
    A value that will be coerced to a different type.

    Parameters:
        Target: The type of the value to coerce to.
        func: The function to coerce the value to the target type.
    """

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
""" 
Coerces a value to an integer.

Parameters:
    T: The type of the value to coerce.
    func: The function to coerce the value to the target type.
"""

comptime CoerceUInt = Coerce[UInt64, __try_coerce_uint]
"""
Coerces a value to an unsigned integer.

Parameters:
    T: The type of the value to coerce.
    func: The function to coerce the value to the target type.
"""

comptime CoerceFloat = Coerce[Float64, __try_coerce_float]
"""
Coerces a value to a float.

Parameters:
    T: The type of the value to coerce.
    func: The function to coerce the value to the target type.
"""

comptime CoerceString = Coerce[String, __try_coerce_string]
"""
Coerces a value to a string.

Parameters:
    T: The type of the value to coerce.
    func: The function to coerce the value to the target type.
"""


##########################################################
# Default
##########################################################


@fieldwise_init
struct Default[T: _Base, default: T](
    Defaultable, JsonDeserializable, JsonSerializable
):
    """
    Defaults the value to a given value if not present.

    Parameters:
        T: The type of the value to default.
        default: The value to default to.
    """

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
    """
    Transforms the value to a different type.

    Parameters:
        InT: The type of the value to transform.
        OutT: The type of the value to transform to.
        func: The function to transform the value to the target type.
    """

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


##########################################################
# Cross-field validation
##########################################################
@always_inline("builtin")
def __field_in_parent[Parent: _Base, F: StringLiteral]() -> Bool:
    # Bit a hack until I have a better way to do this
    return (
        Int(
            mlir_value=__mlir_attr[
                `#kgen.struct_field_index_by_name<`,
                Parent,
                `, `,
                F.value,
                `> : index`,
            ]
        )
        >= 0
    )


struct CrossFieldValidator[
    Parent: _Base,
    F1: StringLiteral where __field_in_parent[Parent, F1](),
    F2: StringLiteral where __field_in_parent[Parent, F2](),
    V: def(
        struct_field_type_by_name[Parent, F1]().T,
        struct_field_type_by_name[Parent, F2]().T,
    ) raises,
](JsonDeserializable, JsonSerializable, Validator):
    """
    Validates a value to depend on another field.

    Parameters:
        Parent: Parent type of the fields we want to validate.
        F1: The name of the first field.
        F2: The name of the second field.
        V: The validator function to apply to the dependent field.
    """

    var value: Self.Parent
    comptime Type = Self.Parent

    def __init__(out self, var value: Self.Parent) raises:
        self.value = value^
        Self.validate(self.value)

    @staticmethod
    def from_json[
        origin: ImmutOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        s = {deserialize[Self.Type](p)}
        s.validate(s.value)

    @staticmethod
    def validate(value: Self.Type) raises:
        comptime f1 = struct_field_index_by_name[Self.Type, Self.F1]()
        comptime f2 = struct_field_index_by_name[Self.Type, Self.F2]()
        Self.V(
            rebind[struct_field_type_by_name[Self.Type, Self.F1]().T](
                __struct_field_ref(f1, value)
            ),
            rebind[struct_field_type_by_name[Self.Type, Self.F2]().T](
                __struct_field_ref(f2, value)
            ),
        )

    def write_json(self, mut writer: Some[Serializer]):
        serialize(self.value, writer)

    def __getitem__(self) -> ref[self.value] Self.Type:
        return self.value
