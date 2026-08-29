"""Schema wrappers driven through the emberserde path.

`test/emberjson/test_schema.mojo` keeps the same coverage on EmberJson's
legacy `deserialize`/`serialize` entry points; this file exercises the
emberserde `Deserializable`/`Serializable` conformances the wrappers
gained in the port, via `from_json_string`/`to_json_string`.
"""

from emberjson import Value
from emberjson.schema import (
    AllOf,
    AnyOf,
    Clamp,
    Coerce,
    CoerceFloat,
    CoerceInt,
    CoerceString,
    CoerceUInt,
    CrossFieldValidator,
    Default,
    EndsWith,
    Enum,
    Eq,
    ExclusiveRange,
    MultipleOf,
    Ne,
    NoneOf,
    NonEmpty,
    Not,
    OneOf,
    Range,
    Secret,
    Size,
    StartsWith,
    Transform,
    Unique,
)
from emberjson._serde import from_json_string, to_json_string
from emberserde import Defaulted, Field
from emberserde.error import DerErrorKind
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)


@fieldwise_init
struct Rec(Movable):
    var a: Int
    var b: Default[Int, 42]


@fieldwise_init
struct OptRec(Movable):
    var a: Int
    var b: Defaulted[Optional[Int], Optional[Int](5)]


@fieldwise_init
struct Renamed(Movable):
    var a: Int
    var b: Field[Int, rename=String("bee"), default=7]


@fieldwise_init
struct Skipped(Movable):
    var a: Int
    var b: Field[Int, skip=True, default=3]


@fieldwise_init
struct Aliased(Movable):
    var a: Field[Int, extra_names=List[String]([String("a_alt")])]


# `Field` carries wire metadata, the validators carry value semantics, so
# they compose by nesting rather than competing for the same slot.
@fieldwise_init
struct RenamedBounded(Movable):
    var n: Field[Range[Int, 0, 10], rename=String("num")]


@fieldwise_init
struct Bounded(Movable):
    var n: Range[Int, 0, 10]


@fieldwise_init
struct Pair(Movable):
    var a: Int
    var b: Int


# `Defaultable` because the payloads have non-trivial destructors: the
# framework will only claim an unwritten struct in place when every field
# is trivially destructible, otherwise it wants a real default to fill in.
@fieldwise_init
struct Creds(Defaultable, Movable):
    var user: String
    var password: Secret[String]

    def __init__(out self):
        self.user = String()
        self.password = Secret[String](String())


# A failure raised by a wrapper has to surface as a typed
# `DeserializationError` (not the untyped `Error` the legacy validators
# raise) so the framework's `kind`/`path` machinery still works. The
# sentinel idiom is emberserde's: `assert_true(False)` inside the `try`
# won't compile, because one `try` block can't mix the typed and untyped
# raise flavours.
def _kind_of[T: Movable & Deinitable](s: String) raises -> String:
    var kind = DerErrorKind.Custom
    try:
        _ = from_json_string[T](s)
    except e:
        kind = e.kind
    return String(kind)


def _path_of[T: Movable & Deinitable](s: String) raises -> String:
    var path = String("<did not raise>")
    try:
        _ = from_json_string[T](s)
    except e:
        path = e.path
    return path^


##########################################################
# Default (emberserde `Field[T, default=...]`)
##########################################################


def test_default_fills_when_key_missing() raises:
    var r = from_json_string[Rec]('{"a":1}')
    assert_equal(r.a, 1)
    assert_equal(r.b.value, 42)
    assert_equal(r.b[], 42)


def test_default_present_key_wins() raises:
    var r = from_json_string[Rec]('{"a":1,"b":7}')
    assert_equal(r.b[], 7)


def test_default_explicit_null_raises() raises:
    # BEHAVIOR CHANGE (see task-6 report): emberserde's `Field` fills only
    # when the key is absent from the wire. An explicit `null` is a present
    # value of the wrong type for `Int`, so it is an error rather than a
    # silent fall back to the default.
    with assert_raises():
        _ = from_json_string[Rec]('{"a":1,"b":null}')


def test_optional_default_null_binds_none() raises:
    # The escape hatch for the old null-tolerant behaviour: make the payload
    # itself `Optional`. A missing key still takes the default; an explicit
    # `null` binds `None` instead of raising.
    var missing = from_json_string[OptRec]('{"a":1}')
    assert_true(missing.b[])
    assert_equal(missing.b[].value(), 5)

    var explicit = from_json_string[OptRec]('{"a":1,"b":null}')
    assert_false(explicit.b[])

    var present = from_json_string[OptRec]('{"a":1,"b":9}')
    assert_equal(present.b[].value(), 9)


def test_default_serializes_payload() raises:
    assert_equal(to_json_string(Rec(1, 42)), '{"a":1,"b":42}')


def test_default_missing_required_field_still_raises() raises:
    with assert_raises():
        _ = from_json_string[Rec]('{"b":7}')


##########################################################
# The rest of what `Field` brings with it
##########################################################


def test_field_rename_skip_and_aliases() raises:
    # `Default` sits on `Field`, so the sibling wire-field knobs are
    # available on the same wrapper and compose with the default. These
    # have no equivalent among the old EmberJson schema types.
    var renamed = from_json_string[Renamed]('{"a":1,"bee":2}')
    assert_equal(renamed.b[], 2)
    # The default fills against the *wire* name, not the declared one.
    assert_equal(from_json_string[Renamed]('{"a":1}').b[], 7)
    assert_equal(to_json_string(Renamed(1, 2)), '{"a":1,"bee":2}')

    # A skipped field never appears on the wire in either direction.
    var skipped = from_json_string[Skipped]('{"a":1}')
    assert_equal(skipped.b[], 3)
    assert_equal(to_json_string(Skipped(1, 3)), '{"a":1}')

    # An alias binds the same field under a second accepted name.
    assert_equal(from_json_string[Aliased]('{"a":5}').a[], 5)
    assert_equal(from_json_string[Aliased]('{"a_alt":5}').a[], 5)


def test_field_composes_with_a_validator() raises:
    # Two different axes, so they stack: the rename decides which key the
    # value is read from, the `Range` decides whether the value is
    # acceptable once read.
    var ok = from_json_string[RenamedBounded]('{"num":5}')
    assert_equal(ok.n[][], 5)
    assert_equal(to_json_string(ok), '{"num":5}')

    with assert_raises(contains="Value out of range"):
        _ = from_json_string[RenamedBounded]('{"num":11}')

    # The rename is still in force on the failing path: the old key is
    # simply an unknown field, so the required one reads as missing.
    assert_equal(_kind_of[RenamedBounded]('{"n":5}'), String("MissingField"))


##########################################################
# Validated and its comptime aliases
##########################################################


def test_range() raises:
    assert_equal(from_json_string[Range[Int, 0, 10]]("5")[], 5)
    assert_equal(from_json_string[Range[Int, 0, 10]]("0")[], 0)
    assert_equal(from_json_string[Range[Int, 0, 10]]("10")[], 10)

    with assert_raises(contains="Value out of range"):
        _ = from_json_string[Range[Int, 0, 10]]("-1")
    with assert_raises(contains="Value out of range"):
        _ = from_json_string[Range[Int, 0, 10]]("11")

    assert_equal(from_json_string[Range[Float64, 0.0, 1.0]]("0.5")[], 0.5)
    with assert_raises(contains="Value out of range"):
        _ = from_json_string[Range[Float64, 0.0, 1.0]]("1.1")


def test_validation_failure_reports_kind_and_path() raises:
    # A validator rejection is a bad *value*, not a bad shape.
    assert_equal(_kind_of[Range[Int, 0, 10]]("11"), String("InvalidValue"))
    # ...and it still rides the framework's error-path tracking when the
    # wrapper sits inside a struct field.
    assert_equal(_path_of[Bounded]('{"n":11}'), String(".n"))


def test_exclusive_range() raises:
    assert_equal(from_json_string[ExclusiveRange[Int, 0, 10]]("5")[], 5)
    with assert_raises(contains="Value out of range (exclusive)"):
        _ = from_json_string[ExclusiveRange[Int, 0, 10]]("0")
    with assert_raises(contains="Value out of range (exclusive)"):
        _ = from_json_string[ExclusiveRange[Int, 0, 10]]("10")


def test_size() raises:
    assert_equal(from_json_string[Size[String, 3, 5]]('"abc"')[], "abc")
    with assert_raises(contains="Value out of size range"):
        _ = from_json_string[Size[String, 3, 5]]('"ab"')
    with assert_raises(contains="Value out of size range"):
        _ = from_json_string[Size[String, 3, 5]]('"abcdef"')

    assert_equal(len(from_json_string[Size[List[Int], 1, 3]]("[1,2]")[]), 2)
    with assert_raises(contains="Value out of size range"):
        _ = from_json_string[Size[List[Int], 1, 3]]("[]")


def test_non_empty() raises:
    assert_equal(from_json_string[NonEmpty[String]]('"hi"')[], "hi")
    with assert_raises(contains="Value must not be empty"):
        _ = from_json_string[NonEmpty[String]]('""')
    with assert_raises(contains="Value must not be empty"):
        _ = from_json_string[NonEmpty[List[Int]]]("[]")


def test_starts_ends_with() raises:
    assert_equal(from_json_string[StartsWith["a"]]('"abc"')[], "abc")
    with assert_raises(contains="does not start with expected prefix"):
        _ = from_json_string[StartsWith["a"]]('"bcd"')

    assert_equal(from_json_string[EndsWith[".json"]]('"a.json"')[], "a.json")
    with assert_raises(contains="does not end with expected suffix"):
        _ = from_json_string[EndsWith[".json"]]('"a.toml"')


def test_unique() raises:
    assert_equal(len(from_json_string[Unique[List[Int]]]("[1,2,3]")[]), 3)
    with assert_raises(contains="Values are not unique"):
        _ = from_json_string[Unique[List[Int]]]("[1,2,1]")


def test_eq_ne_not() raises:
    assert_equal(from_json_string[Eq["red"]]('"red"')[], "red")
    with assert_raises(contains="Value is not equal"):
        _ = from_json_string[Eq["red"]]('"blue"')

    assert_equal(from_json_string[Ne[10]]("5")[], 5)
    with assert_raises(contains="Expected validator to fail"):
        _ = from_json_string[Ne[10]]("10")

    assert_equal(from_json_string[Not[Int, Range[Int, 0, 10]]]("15")[], 15)
    with assert_raises(contains="Expected validator to fail"):
        _ = from_json_string[Not[Int, Range[Int, 0, 10]]]("5")


def test_multiple_of() raises:
    assert_equal(from_json_string[MultipleOf[Int64(10)]]("50")[], 50)
    with assert_raises(contains="Value is not a multiple of"):
        _ = from_json_string[MultipleOf[Int64(10)]]("55")


def test_validated_serializes_payload() raises:
    assert_equal(to_json_string(Range[Int, 0, 10](5)), "5")
    assert_equal(to_json_string(NonEmpty[String](String("hi"))), '"hi"')


##########################################################
# Combinators
##########################################################


def test_all_of() raises:
    comptime V = AllOf[
        String,
        Size[String, 3, 7],
        OneOf[String, Eq["astring"], Eq["bstring"]],
    ]
    assert_equal(from_json_string[V]('"astring"')[], "astring")
    with assert_raises(contains="Value out of size range"):
        _ = from_json_string[V]('"a"')
    with assert_raises(contains="Value didn't match any validators"):
        _ = from_json_string[V]('"cstring"')

    assert_equal(to_json_string(V(String("astring"))), '"astring"')


def test_one_of() raises:
    comptime V = OneOf[String, Eq["red"], Eq["green"], Eq["blue"]]
    assert_equal(from_json_string[V]('"red"')[], "red")
    with assert_raises(contains="Value didn't match any validators"):
        _ = from_json_string[V]('"yellow"')

    with assert_raises(contains="Multiple validators matched"):
        _ = from_json_string[
            OneOf[Int64, Eq[Int64(1)], Eq[Int64(4)], MultipleOf[Int64(2)]]
        ]("4")

    assert_equal(to_json_string(V(String("red"))), '"red"')


def test_any_of() raises:
    comptime V = AnyOf[Int64, Eq[Int64(1)], Eq[Int64(4)], MultipleOf[Int64(2)]]
    assert_equal(from_json_string[V]("4")[], 4)
    with assert_raises(contains="Value not in options"):
        _ = from_json_string[AnyOf[Int, Eq[1], Eq[2]]]("5")

    assert_equal(to_json_string(V(Int64(4))), "4")


def test_none_of() raises:
    comptime V = NoneOf[Int, Eq[1], Eq[2]]
    assert_equal(from_json_string[V]("5")[], 5)
    with assert_raises(contains="Value matched a rejected validator"):
        _ = from_json_string[NoneOf[Int, Eq[1], Range[Int, 0, 10]]]("5")

    assert_equal(to_json_string(V(5)), "5")


def test_enum() raises:
    comptime Color = Enum["red", "green", "blue"]
    assert_equal(from_json_string[Color]('"blue"')[], "blue")
    with assert_raises(contains="Value not in options"):
        _ = from_json_string[Color]('"yellow"')
    assert_equal(to_json_string(Color(String("red"))), '"red"')

    comptime Priority = Enum[1, 2, 3]
    assert_equal(from_json_string[Priority]("2")[], 2)
    with assert_raises(contains="Value not in options"):
        _ = from_json_string[Priority]("5")


##########################################################
# Secret / Clamp / Transform
##########################################################


def test_secret() raises:
    var s = from_json_string[Secret[String]]('"hunter2"')
    assert_equal(s[], "hunter2")
    assert_equal(to_json_string(s), '"********"')

    var n = from_json_string[Secret[Int]]("12345")
    assert_equal(n[], 12345)
    assert_equal(to_json_string(n), '"********"')


def test_secret_redaction_survives_nesting() raises:
    # The mask has to come from `Secret.serialize`, not from the field
    # walker, so it must survive being one field of a struct.
    var c = from_json_string[Creds]('{"user":"bg","password":"hunter2"}')
    assert_equal(c.password[], "hunter2")
    assert_equal(to_json_string(c), '{"user":"bg","password":"********"}')


def test_clamp() raises:
    assert_equal(from_json_string[Clamp[Int, 0, 10]]("5")[], 5)
    assert_equal(from_json_string[Clamp[Int, 0, 10]]("-5")[], 0)
    assert_equal(from_json_string[Clamp[Int, 0, 10]]("15")[], 10)
    assert_equal(to_json_string(Clamp[Int, 0, 10](7)), "7")

    # A payload that isn't a number at all is still a hard error — clamping
    # rewrites values, it does not rescue the wrong wire type.
    with assert_raises():
        _ = from_json_string[Clamp[Int, 0, 10]]('"nope"')


def date_to_int(s: String) -> Int:
    if s == "2024-01-01":
        return 1
    return 0


def test_transform() raises:
    var t = from_json_string[Transform[String, Int, date_to_int]](
        '"2024-01-01"'
    )
    assert_equal(t[], 1)
    assert_equal(to_json_string(t), "1")

    # The transform runs on the *input* type, so a wire value that isn't a
    # `String` fails before the function is ever called.
    with assert_raises():
        _ = from_json_string[Transform[String, Int, date_to_int]]("7")


##########################################################
# Coerce (needs a self-describing deserializer)
##########################################################


def coerce_int(v: Value) raises -> Int:
    if v.is_int():
        return Int(v.int())
    elif v.is_string():
        return Int(v.string())
    elif v.is_float():
        return Int(v.float())
    elif v.is_bool():
        return Int(v.bool())
    raise Error("Invalid value")


def test_coerce_custom_func() raises:
    assert_equal(from_json_string[Coerce[Int, coerce_int]]('"123"')[], 123)
    assert_equal(from_json_string[Coerce[Int, coerce_int]]("123.45")[], 123)
    assert_equal(from_json_string[Coerce[Int, coerce_int]]("true")[], 1)
    with assert_raises(contains="Invalid value"):
        _ = from_json_string[Coerce[Int, coerce_int]]("null")


def test_coerce_builtins() raises:
    assert_equal(from_json_string[CoerceInt]('"123"')[], 123)
    assert_equal(from_json_string[CoerceInt]("123.45")[], 123)
    with assert_raises(contains="cannot be converted to an integer"):
        _ = from_json_string[CoerceInt]("null")

    assert_equal(from_json_string[CoerceUInt]('"123"')[], 123)
    with assert_raises(contains="cannot be converted to an unsigned integer"):
        _ = from_json_string[CoerceUInt]("null")

    assert_equal(from_json_string[CoerceFloat]('"123.45"')[], 123.45)
    assert_equal(from_json_string[CoerceFloat]("123")[], 123.0)
    with assert_raises(contains="cannot be converted to a float"):
        _ = from_json_string[CoerceFloat]("null")

    assert_equal(from_json_string[CoerceString]("123.45")[], "123.45")
    assert_equal(from_json_string[CoerceString]("null")[], "null")
    assert_equal(to_json_string(from_json_string[CoerceInt]('"7"')), "7")


def test_coerce_failure_reports_kind() raises:
    assert_equal(_kind_of[CoerceInt]("null"), String("InvalidValue"))


##########################################################
# Cross-field validation (struct-level, not a `Field`)
##########################################################


def validate_greater(a: Int, b: Int) raises:
    if a <= b:
        raise Error("a must be greater than b")


def test_cross_field_validator() raises:
    comptime V = CrossFieldValidator[Pair, "a", "b", validate_greater]
    var ok = from_json_string[V]('{"a":5,"b":3}')
    assert_equal(ok[].a, 5)
    assert_equal(ok[].b, 3)

    with assert_raises(contains="a must be greater than b"):
        _ = from_json_string[V]('{"a":2,"b":3}')

    assert_equal(to_json_string(V(Pair(5, 3))), '{"a":5,"b":3}')


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
