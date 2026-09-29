# EmberJson's JSON coercions for emberserde's `Transform`. Field validation,
# clamping and redaction are emberserde annotations
# (`@__annotation(Range(0, 10))`, `Transform(clamp[0, 100])`,
# `SerializeWith(f)`); these stay here because they read EmberJson's `Value`.
from emberjson import Value, from_json


##########################################################
# Coerce
##########################################################

# JSON coercions for emberserde's `Transform`:
# `@__annotation(Transform(coerce_int)) var n: Int64` binds `5`, `5.0` and
# `"5"` alike. Each takes the parsed `Value`, so a custom
# `def(Value) raises -> T` works the same way.


def coerce_int(v: Value) raises -> Int64:
    """Coerces an integer, float or numeric string to `Int64`."""
    if v.is_int():
        return v.int()
    elif v.is_uint():
        if v.uint() <= UInt64(Int64.MAX):
            return v.int()
    elif v.is_float():
        # 2^63 is exact in `Float64`; NaN fails both comparisons.
        var f = v.float()
        if f >= -9223372036854775808.0 and f < 9223372036854775808.0:
            return Int64(f)
    elif v.is_string():
        return from_json[Int64](v.string())
    raise Error("Value cannot be converted to an integer")


def coerce_uint(v: Value) raises -> UInt64:
    """Coerces a non-negative number or numeric string to `UInt64`."""
    if v.is_uint():
        return v.uint()
    elif v.is_int():
        if v.int() >= 0:
            return v.uint()
    elif v.is_float():
        # 2^64 is exact in `Float64`; NaN fails both comparisons.
        var f = v.float()
        if f >= 0.0 and f < 18446744073709551616.0:
            return UInt64(f)
    elif v.is_string():
        return from_json[UInt64](v.string())
    raise Error("Value cannot be converted to an unsigned integer")


def coerce_float(v: Value) raises -> Float64:
    """Coerces an integer, float or numeric string to `Float64`."""
    if v.is_int():
        return Float64(v.int())
    elif v.is_uint():
        return Float64(v.uint())
    elif v.is_float():
        return v.float()
    elif v.is_string():
        return from_json[Float64](v.string())
    else:
        raise Error("Value cannot be converted to a float")


def coerce_string(v: Value) raises -> String:
    """Coerces a string, number, bool or null to its `String` text."""
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
