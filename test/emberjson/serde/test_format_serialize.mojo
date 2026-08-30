from std.testing import assert_equal, TestSuite
from emberjson._serde import to_json
from emberjson import Value, Object, Array, Null, parse
from std.hashlib import Hasher


@fieldwise_init
struct Point(Copyable, Movable):
    var x: Int
    var y: Int


def test_struct_serializes_compact() raises:
    assert_equal(to_json(Point(1, 2)), String('{"x":1,"y":2}'))


def test_string_is_escaped() raises:
    assert_equal(to_json(String('a"b')), String('"a\\"b"'))


def test_float_uses_teju() raises:
    assert_equal(to_json(Float64(0.1)), String("0.1"))


def test_list_serializes_as_array() raises:
    var xs: List[Int] = [1, 2, 3]
    assert_equal(to_json(xs), String("[1,2,3]"))


def test_pretty_nests_with_indent() raises:
    assert_equal(
        to_json[pretty=True](Point(1, 2)),
        String('{\n    "x": 1,\n    "y": 2\n}'),
    )


# ===========================================================================
# Direct coverage of Null/Array/Object/Value's own `serialize` (fix round 1,
# finding 3): the type-level tests above only ever exercised the (now
# deleted) `write_json`/`JsonSerializable` path via `String(v)`, never the
# emberserde-conforming `serialize`.
# ===========================================================================


def test_null_serializes_to_null_literal() raises:
    assert_equal(to_json(Null()), String("null"))


def test_array_serializes_compact() raises:
    var a = Array(1, 2, 3)
    assert_equal(to_json(a), String("[1,2,3]"))


def test_empty_array_serializes_compact() raises:
    assert_equal(to_json(Array()), String("[]"))


def test_object_serializes_compact() raises:
    var o = Object()
    o["x"] = Value(1)
    o["y"] = Value("z")
    assert_equal(to_json(o), String('{"x":1,"y":"z"}'))


def test_empty_object_serializes_compact() raises:
    assert_equal(to_json(Object()), String("{}"))


def test_non_string_dict_key_is_quoted() raises:
    # Non-`String` map keys still go through `EmberJsonMapSer.serialize_key`'s
    # generic scratch-buffer branch (Task 10 only fast-pathed `String`),
    # exercising the `else` side of that comptime split.
    var d = Dict[Int, Int]()
    d[1] = 2
    assert_equal(to_json(d), String('{"1":2}'))


def test_object_key_needing_escape_is_escaped() raises:
    # `EmberJsonMapSer.serialize_key` (Task 10) fast-paths `String` keys
    # straight into `write_escaped_string`, bypassing the generic
    # scratch-buffer path used for non-string keys — this pins that the
    # fast path still escapes, since every real `Object` key hits it.
    var o = Object()
    o['a"b'] = Value(1)
    o["c\\d"] = Value(2)
    assert_equal(to_json(o), String('{"a\\"b":1,"c\\\\d":2}'))


def test_value_serializes_every_scalar_arm() raises:
    assert_equal(to_json(Value(Int64(-7))), String("-7"))
    assert_equal(to_json(Value(UInt64(7))), String("7"))
    assert_equal(to_json(Value(Float64(0.5))), String("0.5"))
    assert_equal(to_json(Value("hi")), String('"hi"'))
    assert_equal(to_json(Value(True)), String("true"))
    assert_equal(to_json(Value(False)), String("false"))
    assert_equal(to_json(Value(None)), String("null"))


def test_value_serializes_object_and_array_arms_by_delegation() raises:
    # Also covers fix round 1 finding 1: `Value.serialize`'s object/array
    # branches now delegate to `Object.serialize`/`Array.serialize` instead
    # of duplicating their loops, so this pins that the delegated output is
    # still correct.
    var o = Object()
    o["a"] = Value(Array(1, 2))
    var v = Value(o^)
    assert_equal(to_json(v), String('{"a":[1,2]}'))


# ===========================================================================
# Byte-exact output pins. These started life (fix round 1, finding 2) as
# parity assertions against the old reflection-based `write_json` path,
# guarding the two hand-written implementations against silent divergence
# while both coexisted. Task 8 deleted that path, so the reference it
# compared against is gone — the expected strings below are the OLD path's
# real recorded output, inlined verbatim, so these keep pinning exactly the
# bytes they always pinned rather than degrading into a tautology.
# ===========================================================================


def test_serializes_every_arm() raises:
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
    assert_equal(
        to_json(value),
        String(
            '{"obj":{"nested":[1,{"deep":true}]},"arr":[1,"two",3.5,false,'
            'null],"str":"hello","int":-42,"uint":9223372036854775817,'
            '"float":3.25,"bool":true,"null":null}'
        ),
    )


def test_serializes_bare_array() raises:
    var a = Array(1, "two", Array(3, 4))
    assert_equal(to_json(a), String('[1,"two",[3,4]]'))


def test_serializes_bare_object() raises:
    var o = Object()
    o["k"] = Value(Array(1, 2))
    assert_equal(to_json(o), String('{"k":[1,2]}'))


def test_serializes_null() raises:
    assert_equal(to_json(Null()), String("null"))


# ===========================================================================
# Pretty-print empty-container fix (fix round 1, finding 4 — binding
# ruling): `begin_*`/`end()` in `_serde/serializer.mojo` used to write the
# pretty newline unconditionally on both sides, producing `"{\n\n}"` for an
# empty container where the deleted `PrettySerializer` produced `"{\n}"`.
#
# These were written to compare against `PrettySerializer`'s own real
# output (via `Dict`/`List`, the only types whose old `write_json` actually
# drove it) rather than a hand-written string. That generator is gone with
# Task 8, so its recorded output is inlined verbatim below — same bytes,
# same guarantee.
# ===========================================================================


def test_pretty_empty_object() raises:
    assert_equal(to_json[pretty=True](Object()), String("{\n}"))


def test_pretty_empty_array() raises:
    assert_equal(to_json[pretty=True](Array()), String("[\n]"))


def test_pretty_nested_empty_object() raises:
    # An empty object nested inside a non-empty pretty-printed object.
    var outer = Object()
    outer["a"] = Value(Object())
    assert_equal(
        to_json[pretty=True](outer),
        String('{\n    "a": {\n    }\n}'),
    )


def test_pretty_nested_empty_array() raises:
    # An empty array nested inside a non-empty pretty-printed array.
    var outer = Array()
    outer.append(Value(Array()))
    assert_equal(to_json[pretty=True](outer), String("[\n    [\n    ]\n]"))


# ===========================================================================
# Output-buffering regression (Task 10): `to_json` used to write
# every token straight into the destination `String` with no batching,
# which was correct but ~3-5x slower than routing through
# `std.format._utils._WriteBufferStack` (see `emberjson.utils.write`'s
# equivalent pattern). Restoring the buffering risks silent truncation if
# the final `flush()` is dropped or misplaced, so this exercises an output
# large enough (> the buffer's default 4096-byte capacity) to force several
# internal overflow-triggered flushes plus the terminal one, and checks the
# result byte-for-byte against an independently constructed reference
# string built with plain `String` concatenation (no `_WriteBufferStack`
# involved).
# ===========================================================================


def test_large_array_survives_buffer_overflow() raises:
    comptime N = 2000
    var xs = List[Int]()
    for i in range(N):
        xs.append(i)

    var expected = String("[")
    for i in range(N):
        if i != 0:
            expected += ","
        expected += String(i)
    expected += "]"

    var got = to_json(xs)
    assert_equal(got.byte_length(), expected.byte_length())
    assert_equal(got, expected)


def test_large_pretty_array_survives_buffer_overflow() raises:
    comptime N = 500
    var xs = List[Int]()
    for i in range(N):
        xs.append(i)

    var expected = String("[\n")
    for i in range(N):
        expected += "    " + String(i)
        if i != N - 1:
            expected += ","
        expected += "\n"
    expected += "]"

    var got = to_json[pretty=True](xs)
    assert_equal(got.byte_length(), expected.byte_length())
    assert_equal(got, expected)


@fieldwise_init
struct CompositeKey(Copyable, Equatable, Hashable, Movable):
    var a: Int

    def __eq__(self, other: Self) -> Bool:
        return self.a == other.a

    def __ne__(self, other: Self) -> Bool:
        return self.a != other.a

    def __hash__(self, mut h: Some[Hasher]):
        h.update(self.a)


def test_composite_dict_key_is_escaped_to_valid_json() raises:
    # A non-string key stringifies through the scratch serializer; the
    # rendered text must be emitted as a properly escaped JSON string, not
    # wrapped in bare quotes (which produced unparseable output).
    var m = Dict[CompositeKey, Int]()
    m[CompositeKey(1)] = 2
    var got = to_json(m)
    assert_equal(got, String('{"{\\"a\\":1}":2}'))
    _ = parse(got)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
