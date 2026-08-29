from std.testing import assert_equal, assert_true, assert_false, TestSuite
from emberjson import Value, Object, Array, Null
from emberjson._serde import from_json_string
from emberserde.error import DerErrorKind


@fieldwise_init
struct Point(Copyable, Defaultable, Movable):
    var x: Int
    var y: Int

    def __init__(out self):
        self.x = 0
        self.y = 0


@fieldwise_init
struct Outer(Copyable, Defaultable, Movable):
    var label: String
    var inner: Point

    def __init__(out self):
        self.label = String()
        self.inner = Point()


# Regression coverage for the escaped-field-name-matching bug found in
# review: `expect_field_name` used to strip the wire key's surrounding
# quotes and build the `String` straight off the raw bytes, never decoding
# escapes — so a wire key written with an escape sequence could never equal
# any declared field name, and the field was reported (misleadingly) as
# missing. `AB` covers the reviewer's literal repro and the unescaped fast
# path; `WithEscapedField` covers the escaped path itself.
@fieldwise_init
struct AB(Copyable, Defaultable, Movable):
    var ab: Int

    def __init__(out self):
        self.ab = 0


# Mojo identifiers can't literally contain `"` or `\` (they're not valid
# bare-identifier characters), so this uses a backtick-quoted identifier —
# the same feature `emberjson/constants.mojo` uses to name byte constants
# after their punctuation (e.g. `` `"` ``, `` `{` ``) — to declare a field
# whose real name is the 3-byte string `a"b`. `reflect[T].field_names()`
# reports that literal name, so the wire key `"a\"b"` (JSON's `\"` escape
# for a literal quote) only binds to this field if `expect_field_name`
# actually decodes the escape before matching.
@fieldwise_init
struct WithEscapedField(Copyable, Defaultable, Movable):
    var `a"b`: Int

    def __init__(out self):
        self.`a"b` = 0


def test_ordinary_unescaped_key_still_binds() raises:
    var v = from_json_string[AB]('{"ab":42}')
    assert_equal(v.ab, 42)


# The escaped path: wire key `"a\"b"` (JSON's `\"` escape for a literal
# quote) must decode to `a"b` before matching, binding to `WithEscapedField`'s
# `a"b` field. Before the fix this raised `missing field: a"b` — the raw,
# undecoded key bytes (`a\"b`, 4 bytes) never equal the declared name's
# decoded bytes (`a"b`, 3 bytes), so the field was skipped as "unknown" and
# then reported missing.
def test_escaped_field_name_binds() raises:
    var v = from_json_string[WithEscapedField]('{"a\\"b":9}')
    assert_equal(v.`a"b`, 9)


def test_deserialize_any_returns_object_value() raises:
    var v = from_json_string[Value]('{"a":[1,2]}')
    assert_true(v.is_object())


# ===========================================================================
# Direct coverage of Null/Array/Object/Value's own `deserialize` (fix round
# 1, finding 3). `test_deserialize_any_returns_object_value` above only
# exercised the nested-object shape through `Value.deserialize`; these cover
# every scalar arm plus `Array`/`Object`/`Null` deserialized directly (not
# just as arms reached through `Value`).
# ===========================================================================


def test_value_deserialize_scalar_int() raises:
    var v = from_json_string[Value]("-42")
    assert_true(v.is_int())
    assert_equal(v.int(), Int64(-42))


def test_value_deserialize_scalar_uint() raises:
    var v = from_json_string[Value]("18446744073709551615")
    assert_true(v.is_uint())
    assert_equal(v.uint(), UInt64.MAX)


def test_value_deserialize_scalar_float() raises:
    var v = from_json_string[Value]("3.5")
    assert_true(v.is_float())
    assert_equal(v.float(), Float64(3.5))


def test_value_deserialize_scalar_string() raises:
    var v = from_json_string[Value]('"hi"')
    assert_true(v.is_string())
    assert_equal(v.string(), String("hi"))


def test_value_deserialize_scalar_bool() raises:
    var t = from_json_string[Value]("true")
    assert_true(t.is_bool())
    assert_true(t.bool())

    var f = from_json_string[Value]("false")
    assert_true(f.is_bool())
    assert_false(f.bool())


def test_value_deserialize_scalar_null() raises:
    var v = from_json_string[Value]("null")
    assert_true(v.is_null())


def test_array_deserialize_direct() raises:
    var a = from_json_string[Array]("[1,2,3]")
    assert_equal(len(a), 3)
    assert_equal(a[0].int(), Int64(1))
    assert_equal(a[2].int(), Int64(3))


def test_array_deserialize_empty() raises:
    var a = from_json_string[Array]("[]")
    assert_equal(len(a), 0)


def test_object_deserialize_direct() raises:
    var o = from_json_string[Object]('{"x":1,"y":2}')
    assert_equal(o["x"].int(), Int64(1))
    assert_equal(o["y"].int(), Int64(2))


def test_object_deserialize_empty() raises:
    var o = from_json_string[Object]("{}")
    assert_equal(len(o), 0)


def test_null_deserialize_round_trips() raises:
    var n = from_json_string[Null]("null")
    assert_equal(n, Null())


# `Null.deserialize` is new code (fix round 1 finding 3 flagged its raise
# path as never executed by any test): it delegates to `deserialize_any`
# and must reject a non-null wire value with `TypeMismatch` rather than
# silently accepting it.
def test_null_deserialize_rejects_non_null() raises:
    var kind = DerErrorKind.Custom
    try:
        _ = from_json_string[Null]("42")
    except e:
        kind = e.kind
    assert_equal(String(kind), String("TypeMismatch"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
