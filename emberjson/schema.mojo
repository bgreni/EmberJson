# `deserialize` is the public (emberserde-backed) entry point, used by the
# `Coerce*` helpers below to read a number out of a JSON string payload.
from emberjson import Value, deserialize
from emberserde import Defaulted, Field
from emberserde.utils import Base as _Base

# Aliased for the same reason as in `value.mojo`/`object.mojo`.
from emberserde.serialize import (
    Serializable,
    Serializer as SerdeSerializer,
    serialize as serde_serialize,
)
from emberserde.deserialize import (
    Deserializable,
    Deserializer as SerdeDeserializer,
    SelfDescribingDeserializer,
    deserialize as serde_deserialize,
)
from emberserde.error import (
    DerErrorKind,
    DeserializationError,
    SerializationError,
)
from std.builtin.rebind import downcast
from std.reflection import reflect

##########################################################
# Value Validation
##########################################################


struct AllOf[T: _Base, *validators: Validator](
    Deserializable,
    Serializable,
    Validator,
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
    def deserialize(
        mut d: Some[SerdeDeserializer],
    ) raises DeserializationError -> Self:
        # See `_validation_failed` for why the constructor does the
        # validating and why a rejection is `InvalidValue`.
        var value = serde_deserialize[Self.T](d)
        try:
            return Self(value^)
        except e:
            raise _validation_failed(e)

    @staticmethod
    def validate(value: Self.Type) raises:
        comptime for i in range(len(Self.validators)):
            comptime VType = Self.validators[i]
            comptime assert VType.Type == Self.T
            VType.validate(rebind[VType.Type](value))

    def serialize(self, mut s: Some[SerdeSerializer]) raises SerializationError:
        serde_serialize(self.value, s)

    def __getitem__(self) -> ref[self.value] Self.T:
        return self.value


# Every wrapper here runs its check in the *constructor*, so a value built
# by hand (`Range[Int, 0, 10](15)`) is validated exactly like one read off
# the wire, and `deserialize` has one code path to guard. The check itself
# is defined in terms of the untyped `Error` the `Validator` trait raises,
# so the emberserde entry points funnel it through here into the typed
# `DeserializationError` that carries the framework's `kind`/`path`. The
# kind is `InvalidValue` rather than `TypeMismatch` on purpose: the wire
# shape was perfectly good JSON of the right type, the *value* was not
# acceptable.
@always_inline
def _validation_failed(e: Error) -> DeserializationError:
    return DeserializationError(String(e), DerErrorKind.InvalidValue)


trait Validator:
    comptime Type: _Base

    @staticmethod
    def validate(value: Self.Type) raises:
        ...


struct Validated[
    T: _Base,
    validator: def(T) thin -> Bool,
    err_msg: String = "Value is not valid",
](
    Deserializable,
    Serializable,
    Validator,
):
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
    def deserialize(
        mut d: Some[SerdeDeserializer],
    ) raises DeserializationError -> Self:
        # See `_validation_failed` for why the constructor does the
        # validating and why a rejection is `InvalidValue`.
        var value = serde_deserialize[Self.T](d)
        try:
            return Self(value^)
        except e:
            raise _validation_failed(e)

    @staticmethod
    def validate(value: Self.Type) raises:
        if not Self.validator(value):
            raise Error(Self.err_msg)

    def serialize(self, mut s: Some[SerdeSerializer]) raises SerializationError:
        serde_serialize(self.value, s)

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
def _sized_len[T: _Base](value: T) -> Int:
    comptime assert T == String or conforms_to(T, Sized)

    comptime if T == String:
        return rebind[String](value).byte_length()
    else:
        return rebind[downcast[T, Sized]](value).__len__()


@always_inline
def __is_in_size_range[
    T: _Base, min: Int, max: Int
](value: T,) -> Bool:
    var n = _sized_len(value)
    return n >= min and n <= max


comptime Size[T: _Base, min: Int, max: Int] = Validated[
    T, __is_in_size_range[T, min, max], "Value out of size range"
]
"""Validates a value to be within a given size range.

Parameters:
    T: The type of the value to validate.
    min: The minimum size.
    max: The maximum size.
"""


@always_inline
def __is_non_empty[T: _Base](value: T) -> Bool:
    return _sized_len(value) > 0


comptime NonEmpty[T: _Base] = Validated[
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
def __has_unique_elements[T: _Base & Iterable](value: T) -> Bool:
    # Driven off the raw iterators rather than `for ... in enumerate(value)`:
    # a generic `Iterator.Element` is only `Movable`, so both the loop binding
    # and `enumerate`'s `Tuple` would be values the compiler cannot drop.
    # Taking each element by hand lets us consume it through a `downcast` that
    # carries `Deinitable`.
    comptime Elem = downcast[
        T.IteratorType[origin_of(value)].Element,
        Equatable & Movable & Deinitable,
    ]
    var i = 0
    var outer = value.__iter__()
    while True:
        try:
            var a = rebind_var[Elem](outer.__next__())
            var j = 0
            var inner = value.__iter__()
            while True:
                try:
                    var b = rebind_var[Elem](inner.__next__())
                    var dup = i != j and a == b
                    _ = b^
                    if dup:
                        _ = a^
                        return False
                    j += 1
                except StopIteration:
                    break
            _ = a^
            i += 1
        except StopIteration:
            break
    return True


comptime Unique[T: _Base & Iterable] = Validated[
    T, __has_unique_elements[T], "Values are not unique"
]
"""Enforces a value to have unique elements.

Parameters:
    T: The type of the value to validate.
"""


@always_inline
def __is_eq[T: Equatable & Deinitable, //, value: T](a: T) -> Bool:
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
    comptime assert VType == T
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
    Deserializable,
    Serializable,
    Validator,
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
    def deserialize(
        mut d: Some[SerdeDeserializer],
    ) raises DeserializationError -> Self:
        # See `_validation_failed` for why the constructor does the
        # validating and why a rejection is `InvalidValue`.
        var value = serde_deserialize[Self.T](d)
        try:
            return Self(value^)
        except e:
            raise _validation_failed(e)

    @staticmethod
    def validate(value: Self.Type) raises:
        var matched = False
        comptime for i in range(len(Self.accepted)):
            var current_match = False
            try:
                comptime VType = Self.accepted[i]
                comptime assert VType.Type == Self.T
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

    def serialize(self, mut s: Some[SerdeSerializer]) raises SerializationError:
        serde_serialize(self.value, s)

    def __getitem__(self) -> ref[self.value] Self.T:
        return self.value


struct AnyOf[T: _Base & Equatable, *accepted: Validator](
    Deserializable,
    Serializable,
    Validator,
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
    def deserialize(
        mut d: Some[SerdeDeserializer],
    ) raises DeserializationError -> Self:
        # See `_validation_failed` for why the constructor does the
        # validating and why a rejection is `InvalidValue`.
        var value = serde_deserialize[Self.T](d)
        try:
            return Self(value^)
        except e:
            raise _validation_failed(e)

    @staticmethod
    def validate(value: Self.Type) raises:
        var matched = False
        comptime for i in range(len(Self.accepted)):
            try:
                comptime VType = Self.accepted[i]
                comptime assert VType.Type == Self.T
                VType.validate(rebind[VType.Type](value))
                matched = True
                break
            except:
                pass
        if not matched:
            raise Error("Value not in options")

    def serialize(self, mut s: Some[SerdeSerializer]) raises SerializationError:
        serde_serialize(self.value, s)

    def __getitem__(self) -> ref[self.value] Self.T:
        return self.value


struct NoneOf[T: _Base & Equatable, *rejected: Validator](
    Deserializable,
    Serializable,
    Validator,
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
    def deserialize(
        mut d: Some[SerdeDeserializer],
    ) raises DeserializationError -> Self:
        # See `_validation_failed` for why the constructor does the
        # validating and why a rejection is `InvalidValue`.
        var value = serde_deserialize[Self.T](d)
        try:
            return Self(value^)
        except e:
            raise _validation_failed(e)

    @staticmethod
    def validate(value: Self.Type) raises:
        comptime for i in range(len(Self.rejected)):
            var matched = False
            try:
                comptime VType = Self.rejected[i]
                comptime assert VType.Type == Self.T
                VType.validate(rebind[VType.Type](value))
                matched = True
            except:
                pass

            if matched:
                raise Error("Value matched a rejected validator")

    def serialize(self, mut s: Some[SerdeSerializer]) raises SerializationError:
        serde_serialize(self.value, s)

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


struct Enum[T: _Base & Equatable, //, *accepted: T](
    Deserializable,
    Serializable,
    Validator,
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
    def deserialize(
        mut d: Some[SerdeDeserializer],
    ) raises DeserializationError -> Self:
        # See `_validation_failed` for why the constructor does the
        # validating and why a rejection is `InvalidValue`.
        var value = serde_deserialize[Self.T](d)
        try:
            return Self(value^)
        except e:
            raise _validation_failed(e)

    @staticmethod
    def validate(value: Self.Type) raises:
        comptime for i in range(len(Self.accepted)):
            if value == materialize[Self.accepted[i]]():
                return
        raise Error("Value not in options")

    def serialize(self, mut s: Some[SerdeSerializer]) raises SerializationError:
        serde_serialize(self.value, s)

    def __getitem__(self) -> ref[self.value] Self.T:
        return self.value


##########################################################
# Secret
##########################################################


@fieldwise_init
struct Secret[T: _Base](Deserializable, Serializable):
    var value: Self.T
    """
    A secret value that will be hidden as an opaque string if serialized back to JSON.

    Parameters:
        T: The type of the value to hide.
    """

    @staticmethod
    def deserialize(
        mut d: Some[SerdeDeserializer],
    ) raises DeserializationError -> Self:
        return {serde_deserialize[Self.T](d)}

    # Asymmetric on purpose: the payload is read from the wire as itself
    # and written back redacted. `serialize_string` (not a raw write) so
    # the mask goes through the format's own string encoding.
    def serialize(self, mut s: Some[SerdeSerializer]) raises SerializationError:
        s.serialize_string("********")

    def __getitem__(self) -> ref[self.value] Self.T:
        return self.value


##########################################################
# Clamp
##########################################################


@fieldwise_init
struct Clamp[T: _Base & Comparable, minimum: T, maximum: T](
    Deserializable, Serializable
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
    def deserialize(
        mut d: Some[SerdeDeserializer],
    ) raises DeserializationError -> Self:
        var value = serde_deserialize[Self.T](d)

        var min_val = materialize[Self.minimum]()
        var max_val = materialize[Self.maximum]()

        if value < min_val:
            value = min_val^
        elif value > max_val:
            value = max_val^
        return {value^}

    def serialize(self, mut s: Some[SerdeSerializer]) raises SerializationError:
        serde_serialize(self.value, s)

    def __getitem__(self) -> ref[self.value] Self.T:
        return self.value


##########################################################
# Coerce
##########################################################


@fieldwise_init
struct Coerce[Target: _Base, func: def(Value) thin raises -> Target](
    Deserializable, Serializable
):
    """
    A value that will be coerced to a different type.

    Parameters:
        Target: The type of the value to coerce to.
        func: The function to coerce the value to the target type.
    """

    var value: Self.Target

    @staticmethod
    def deserialize(
        mut d: Some[SerdeDeserializer],
    ) raises DeserializationError -> Self:
        # `func` is typed on EmberJson's `Value`, so this only works over a
        # format that can hand back a whole dynamic value with no type
        # hint. `Value.deserialize` asserts that too, but assert it here
        # for a message that names `Coerce`.
        comptime assert conforms_to(
            type_of(d), SelfDescribingDeserializer
        ), "Coerce requires a self-describing deserializer"
        var v = serde_deserialize[Value](d)
        try:
            return {Self.func(v)}
        except e:
            raise _validation_failed(e)

    def serialize(self, mut s: Some[SerdeSerializer]) raises SerializationError:
        serde_serialize(self.value, s)

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


comptime Default[T: _Base, default: T] = Defaulted[T, default]
"""
Defaults the value to a given value if the key is absent from the wire.

`Default` is a spelling of `emberserde`'s `Field[T, default=...]`: it is
wire-field metadata (the same axis as `Rename`/`Skip`), which is exactly
what a default is, so it lives in the shared cross-format layer rather
than being reimplemented per format.

Note the presence rule that comes with it: the default fills a **missing
key** only. An explicit `null` on the wire is a present value, and is
parsed as `T` — so `{"b": null}` for a `Default[Int, 42]` is an error,
not a fall back to `42`. Wrap the payload in `Optional` when `null`
should be tolerated: `Defaulted[Optional[Int], Optional[Int](42)]` takes
the default when the key is missing and binds `None` when it is `null`.

Parameters:
    T: The type of the value to default.
    default: The value to default to.
"""


##########################################################
# Transform
##########################################################


@fieldwise_init
struct Transform[InT: _Base, OutT: _Base, func: def(InT) thin -> OutT](
    Deserializable, Serializable
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
    def deserialize(
        mut d: Some[SerdeDeserializer],
    ) raises DeserializationError -> Self:
        return {Self.func(serde_deserialize[Self.InT](d))}

    def serialize(self, mut s: Some[SerdeSerializer]) raises SerializationError:
        serde_serialize(self.value, s)

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
    F1: StringLiteral,
    F2: StringLiteral,
    V: def(
        reflect[Parent].field[F1].T,
        reflect[Parent].field[F2].T,
    ) thin raises,
](
    Deserializable,
    Serializable,
    Validator,
):
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
        comptime assert __field_in_parent[Self.Parent, Self.F1]()
        comptime assert __field_in_parent[Self.Parent, Self.F2]()
        self.value = value^
        Self.validate(self.value)

    @staticmethod
    def deserialize(
        mut d: Some[SerdeDeserializer],
    ) raises DeserializationError -> Self:
        # Same shape as the value validators, but the thing being checked
        # is the whole parent struct rather than one field's payload.
        var value = serde_deserialize[Self.Type](d)
        try:
            return Self(value^)
        except e:
            raise _validation_failed(e)

    @staticmethod
    def validate(value: Self.Type) raises:
        comptime r = reflect[Self.Type]
        comptime f1 = r.field_index[Self.F1]()
        comptime f2 = r.field_index[Self.F2]()
        Self.V(
            rebind[r.field[Self.F1].T](r.field_ref[f1](value)),
            rebind[r.field[Self.F2].T](r.field_ref[f2](value)),
        )

    def serialize(self, mut s: Some[SerdeSerializer]) raises SerializationError:
        serde_serialize(self.value, s)

    def __getitem__(self) -> ref[self.value] Self.Type:
        return self.value
