from std.testing import (
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
    TestSuite,
)
from emberjson import Value, Object, Array, Null, ParseOptions, StrictOptions
from emberjson._serde import from_json
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
    var v = from_json[AB]('{"ab":42}')
    assert_equal(v.ab, 42)


# The escaped path: wire key `"a\"b"` (JSON's `\"` escape for a literal
# quote) must decode to `a"b` before matching, binding to `WithEscapedField`'s
# `a"b` field. Before the fix this raised `missing field: a"b` — the raw,
# undecoded key bytes (`a\"b`, 4 bytes) never equal the declared name's
# decoded bytes (`a"b`, 3 bytes), so the field was skipped as "unknown" and
# then reported missing.
def test_escaped_field_name_binds() raises:
    var v = from_json[WithEscapedField]('{"a\\"b":9}')
    assert_equal(v.`a"b`, 9)


def test_deserialize_any_returns_object_value() raises:
    var v = from_json[Value]('{"a":[1,2]}')
    assert_true(v.is_object())


# ===========================================================================
# Direct coverage of Null/Array/Object/Value's own `deserialize` (fix round
# 1, finding 3). `test_deserialize_any_returns_object_value` above only
# exercised the nested-object shape through `Value.deserialize`; these cover
# every scalar arm plus `Array`/`Object`/`Null` deserialized directly (not
# just as arms reached through `Value`).
# ===========================================================================


def test_value_deserialize_scalar_int() raises:
    var v = from_json[Value]("-42")
    assert_true(v.is_int())
    assert_equal(v.int(), Int64(-42))


def test_value_deserialize_scalar_uint() raises:
    var v = from_json[Value]("18446744073709551615")
    assert_true(v.is_uint())
    assert_equal(v.uint(), UInt64.MAX)


def test_value_deserialize_scalar_float() raises:
    var v = from_json[Value]("3.5")
    assert_true(v.is_float())
    assert_equal(v.float(), Float64(3.5))


def test_value_deserialize_scalar_string() raises:
    var v = from_json[Value]('"hi"')
    assert_true(v.is_string())
    assert_equal(v.string(), String("hi"))


def test_value_deserialize_scalar_bool() raises:
    var t = from_json[Value]("true")
    assert_true(t.is_bool())
    assert_true(t.bool())

    var f = from_json[Value]("false")
    assert_true(f.is_bool())
    assert_false(f.bool())


def test_value_deserialize_scalar_null() raises:
    var v = from_json[Value]("null")
    assert_true(v.is_null())


def test_array_deserialize_direct() raises:
    var a = from_json[Array]("[1,2,3]")
    assert_equal(len(a), 3)
    assert_equal(a[0].int(), Int64(1))
    assert_equal(a[2].int(), Int64(3))


def test_array_deserialize_empty() raises:
    var a = from_json[Array]("[]")
    assert_equal(len(a), 0)


def test_object_deserialize_direct() raises:
    var o = from_json[Object]('{"x":1,"y":2}')
    assert_equal(o["x"].int(), Int64(1))
    assert_equal(o["y"].int(), Int64(2))


def test_object_deserialize_empty() raises:
    var o = from_json[Object]("{}")
    assert_equal(len(o), 0)


def test_null_deserialize_round_trips() raises:
    var n = from_json[Null]("null")
    assert_equal(n, Null())


# `Null.deserialize` is new code (fix round 1 finding 3 flagged its raise
# path as never executed by any test): it delegates to `deserialize_any`
# and must reject a non-null wire value with `TypeMismatch` rather than
# silently accepting it.
def test_null_deserialize_rejects_non_null() raises:
    var kind = DerErrorKind.Custom
    try:
        _ = from_json[Null]("42")
    except e:
        kind = e.kind
    assert_equal(String(kind), String("TypeMismatch"))


# ===========================================================================
# Comma framing: the serde states must enforce JSON's separator grammar
# exactly like `parse()` does (strict by default, trailing commas only
# under `ALLOW_TRAILING_COMMA`) -- regression coverage for the review
# finding where commas were consume-if-present.
# ===========================================================================


def test_missing_comma_between_array_elements_rejected() raises:
    with assert_raises():
        _ = from_json[List[Int64]]("[1 2]")


def test_leading_comma_in_array_rejected() raises:
    with assert_raises():
        _ = from_json[List[Int64]]("[,1]")


def test_missing_comma_between_map_entries_rejected() raises:
    with assert_raises():
        _ = from_json[Dict[String, Int64]]('{"a":1 "b":2}')


def test_missing_comma_between_struct_fields_rejected() raises:
    with assert_raises():
        _ = from_json[Point]('{"x":1 "y":2}')


def test_leading_comma_in_struct_rejected() raises:
    with assert_raises():
        _ = from_json[Point]('{,"x":1,"y":2}')


def test_strict_mode_rejects_trailing_commas() raises:
    with assert_raises(contains="trailing comma"):
        _ = from_json[List[Int64]]("[1,2,]")
    with assert_raises(contains="trailing comma"):
        _ = from_json[Point]('{"x":1,"y":2,}')


def test_lenient_mode_allows_trailing_commas() raises:
    comptime lenient = ParseOptions(strict_mode=StrictOptions.LENIENT)
    var xs = from_json[List[Int64], lenient]("[1,2,]")
    assert_equal(len(xs), 2)
    assert_equal(xs[1], 2)
    var pt = from_json[Point, lenient]('{"x":1,"y":2,}')
    assert_equal(pt.x, 1)
    assert_equal(pt.y, 2)


def test_object_duplicate_keys_rejected_in_strict_mode() raises:
    with assert_raises(contains="Duplicate key"):
        _ = from_json[Object]('{"a":1,"a":2}')


def test_object_duplicate_keys_last_write_wins_in_lenient_mode() raises:
    comptime lenient = ParseOptions(strict_mode=StrictOptions.LENIENT)
    var o = from_json[Object, lenient]('{"a":1,"a":2}')
    assert_equal(len(o), 1)
    assert_equal(o["a"].int(), 2)


def test_field_names_honor_ignore_unicode() raises:
    # `parse()` stores keys raw under `ignore_unicode`; field-name matching
    # must agree, so an escaped key no longer binds.
    comptime opts = ParseOptions(ignore_unicode=True)
    with assert_raises(contains="missing field"):
        _ = from_json[AB, opts]('{"\\u0061b":1}')
    assert_equal(from_json[AB]('{"\\u0061b":1}').ab, 1)


def test_trailing_content_after_root_rejected() raises:
    with assert_raises(contains="trailing content"):
        _ = from_json[List[Int64]]("[1,2] xx")
    with assert_raises(contains="trailing content"):
        _ = from_json[Int64]("1 garbage")
    with assert_raises(contains="trailing content"):
        _ = from_json[Object]('{"x":1}{"x":2}')


def test_trailing_whitespace_after_root_accepted() raises:
    var xs = from_json[List[Int64]]("[1,2]  \n ")
    assert_equal(len(xs), 2)


def test_from_json_accepts_a_string_slice() raises:
    var owned = String('{"x":7,"y":9}')
    var slice = StringSlice(owned)
    var p = from_json[Point](slice)
    assert_equal(p.x, 7)
    assert_equal(p.y, 9)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
