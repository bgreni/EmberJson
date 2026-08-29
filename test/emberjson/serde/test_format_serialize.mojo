from std.testing import assert_equal, TestSuite
from emberjson._serde import to_json_string
from emberjson import Value, Object, Array, Null, serialize as old_serialize


@fieldwise_init
struct Point(Copyable, Movable):
    var x: Int
    var y: Int


def test_struct_serializes_compact() raises:
    assert_equal(to_json_string(Point(1, 2)), String('{"x":1,"y":2}'))


def test_string_is_escaped() raises:
    assert_equal(to_json_string(String('a"b')), String('"a\\"b"'))


def test_float_uses_teju() raises:
    assert_equal(to_json_string(Float64(0.1)), String("0.1"))


def test_list_serializes_as_array() raises:
    var xs: List[Int] = [1, 2, 3]
    assert_equal(to_json_string(xs), String("[1,2,3]"))


def test_pretty_nests_with_indent() raises:
    assert_equal(
        to_json_string[pretty=True](Point(1, 2)),
        String('{\n    "x": 1,\n    "y": 2\n}'),
    )


# ===========================================================================
# Direct coverage of Null/Array/Object/Value's own `serialize` (fix round 1,
# finding 3): the type-level tests above only ever exercised the old
# `write_json`/`JsonSerializable` path (via `String(v)`/old `serialize()`),
# never the new emberserde-conforming `serialize` added by this task.
# ===========================================================================


def test_null_serializes_to_null_literal() raises:
    assert_equal(to_json_string(Null()), String("null"))


def test_array_serializes_compact() raises:
    var a = Array(1, 2, 3)
    assert_equal(to_json_string(a), String("[1,2,3]"))


def test_empty_array_serializes_compact() raises:
    assert_equal(to_json_string(Array()), String("[]"))


def test_object_serializes_compact() raises:
    var o = Object()
    o["x"] = Value(1)
    o["y"] = Value("z")
    assert_equal(to_json_string(o), String('{"x":1,"y":"z"}'))


def test_empty_object_serializes_compact() raises:
    assert_equal(to_json_string(Object()), String("{}"))


def test_value_serializes_every_scalar_arm() raises:
    assert_equal(to_json_string(Value(Int64(-7))), String("-7"))
    assert_equal(to_json_string(Value(UInt64(7))), String("7"))
    assert_equal(to_json_string(Value(Float64(0.5))), String("0.5"))
    assert_equal(to_json_string(Value("hi")), String('"hi"'))
    assert_equal(to_json_string(Value(True)), String("true"))
    assert_equal(to_json_string(Value(False)), String("false"))
    assert_equal(to_json_string(Value(None)), String("null"))


def test_value_serializes_object_and_array_arms_by_delegation() raises:
    # Also covers fix round 1 finding 1: `Value.serialize`'s object/array
    # branches now delegate to `Object.serialize`/`Array.serialize` instead
    # of duplicating their loops, so this pins that the delegated output is
    # still correct.
    var o = Object()
    o["a"] = Value(Array(1, 2))
    var v = Value(o^)
    assert_equal(to_json_string(v), String('{"a":[1,2]}'))


# ===========================================================================
# Parity: the old (reflection-based `write_json`) and new (emberserde
# `serialize`) paths are two independent hand-written implementations for
# these four types (see task-4-report.md's "dual trait conformance" design).
# Nothing enforced they agree until now (fix round 1, finding 2) — this is
# the guard against silent divergence while both paths coexist.
# ===========================================================================


def test_new_and_old_serialize_agree_on_every_arm() raises:
    # object -> array -> object nesting (the brief's required shape), plus
    # one instance of every `Value` arm: object, array, string, int, uint,
    # float, bool, null.
    var inner_arr = Array()
    inner_arr.append(Value(1))
    var deep_obj = Object()
    deep_obj["deep"] = Value(True)
    inner_arr.append(Value(deep_obj^))

    var nested_obj = Object()
    nested_obj["nested"] = Value(inner_arr^)

    var top_arr = Array()
    top_arr.append(Value(1))
    top_arr.append(Value("two"))
    top_arr.append(Value(3.5))
    top_arr.append(Value(False))
    top_arr.append(Value(None))

    var top = Object()
    top["obj"] = Value(nested_obj^)  # object -> array -> object
    top["arr"] = Value(top_arr^)
    top["str"] = Value("hello")
    top["int"] = Value(Int64(-42))
    top["uint"] = Value(UInt64(Int64.MAX) + 10)
    top["float"] = Value(3.25)
    top["bool"] = Value(True)
    top["null"] = Value(None)

    var value = Value(top^)
    assert_equal(to_json_string(value), old_serialize(value))


def test_new_and_old_serialize_agree_on_bare_array() raises:
    var a = Array(1, "two", Array(3, 4))
    assert_equal(to_json_string(a), old_serialize(a))


def test_new_and_old_serialize_agree_on_bare_object() raises:
    var o = Object()
    o["k"] = Value(Array(1, 2))
    assert_equal(to_json_string(o), old_serialize(o))


def test_new_and_old_serialize_agree_on_null() raises:
    assert_equal(to_json_string(Null()), old_serialize(Null()))


# ===========================================================================
# Pretty-print empty-container fix (fix round 1, finding 4 — binding
# ruling): `begin_*`/`end()` in `_serde/serializer.mojo` used to write the
# pretty newline unconditionally on both sides, producing `"{\n\n}"` for an
# empty container where `emberjson/_serialize/reflection.mojo`'s
# `PrettySerializer` produces `"{\n}"`. Per the ruling, compare directly
# against `PrettySerializer`'s own real output rather than a hand-written
# expected string. `Value`/`Object`/`Array`/`Null` themselves can't drive
# `PrettySerializer` (their old `write_json` shortcuts straight to the
# compact `Writable.write_to`, bypassing `begin_object`/`end_object`
# entirely — see `test_reflection_serialize.mojo::test_pretty_serialize`'s
# `"v": {"variant":"test"}`, printed compact even under `pretty=True`), so
# `Dict`/`List` — which *do* drive `PrettySerializer` for real via their own
# `JsonSerializable.write_json` — stand in as the reference generator for
# the equivalent map/seq shape.
# ===========================================================================


def test_pretty_empty_object_matches_pretty_serializer() raises:
    var reference = old_serialize[pretty=True](Dict[String, Int]())
    assert_equal(to_json_string[pretty=True](Object()), reference)


def test_pretty_empty_array_matches_pretty_serializer() raises:
    var reference = old_serialize[pretty=True](List[Int]())
    assert_equal(to_json_string[pretty=True](Array()), reference)


def test_pretty_nested_empty_object_matches_pretty_serializer() raises:
    # An empty object nested inside a non-empty pretty-printed object.
    var d = Dict[String, Dict[String, Int]]()
    d["a"] = Dict[String, Int]()
    var reference = old_serialize[pretty=True](d)

    var outer = Object()
    outer["a"] = Value(Object())
    assert_equal(to_json_string[pretty=True](outer), reference)


def test_pretty_nested_empty_array_matches_pretty_serializer() raises:
    # An empty array nested inside a non-empty pretty-printed array.
    var l: List[List[Int]] = [List[Int]()]
    var reference = old_serialize[pretty=True](l)

    var outer = Array()
    outer.append(Value(Array()))
    assert_equal(to_json_string[pretty=True](outer), reference)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
