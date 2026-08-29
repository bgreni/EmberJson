"""The public facade's own entry points, exercised directly.

Two gaps this file exists to close.

**1. `ParseOptions` reaches reflection again.** The `Parser`-taking
`deserialize`/`try_deserialize` overloads were deleted along with the
legacy reflection walker, which left reflection-based deserialization with
no options channel at all. `deserialize`/`try_deserialize` are now
parameterized on `ParseOptions` and thread them down to the `Parser` that
`emberjson._serde.from_json_string` builds. Each option below is pinned
against its own default, so a test fails if the channel is ever cut again
rather than merely if the plumbing stops compiling.

**2. The public entry points are tested as public entry points.** The
suite's largest files (`test_schema_fields.mojo`, `test_lazy.mojo`,
`test_security.mojo`) drive the private `emberjson._serde` layer. That
layer deliberately does NOT validate UTF-8 -- only `parse` and
`deserialize` do -- so the gate needs pinning here, where it lives.
"""

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from emberjson import (
    Array,
    Null,
    Object,
    ParseOptions,
    StrictOptions,
    Value,
    deserialize,
    parse,
    serialize,
    to_string,
    try_deserialize,
    try_parse,
)
from emberjson._serde import from_json_string


@fieldwise_init
struct Point(Copyable, Defaultable, Movable):
    var x: Int
    var y: Int

    def __init__(out self):
        self.x = 0
        self.y = 0


@fieldwise_init
struct Wrapper(Copyable, Defaultable, Movable):
    var label: String
    var inner: Point

    def __init__(out self):
        self.label = ""
        self.inner = Point()


def _invalid_utf8_doc() -> String:
    """`{"x":1,"y":2,"z":"<C0 80>"}` -- a structurally valid document whose
    only ill-formed bytes (an overlong NUL) sit inside a value the parser
    never materializes, so the *only* thing that can reject it is the
    UTF-8 gate. Raw bytes viewed through `StringSlice(unsafe_from_utf8=)`
    then copied: the copy itself runs no validity assert, unlike
    `String(unsafe_from_utf8=)`.
    """
    var bytes = List[Byte]()
    for b in String('{"x":1,"y":2,"z":"').as_bytes():
        bytes.append(b)
    bytes.append(0xC0)
    bytes.append(0x80)
    for b in String('"}').as_bytes():
        bytes.append(b)
    return String(StringSlice(unsafe_from_utf8=Span(bytes)))


# ===============================================
# `ParseOptions` reaches reflection
# ===============================================


def test_deserialize_decodes_unicode_escapes_by_default() raises:
    # The control for the next test: without an options channel the two
    # would be indistinguishable.
    var v = deserialize[Value]('{"a": "\\u0041"}')
    assert_equal(v["a"].string(), "A")
    assert_equal(v["a"].string().byte_length(), 1)


def test_deserialize_ignore_unicode_option_reaches_the_parser() raises:
    comptime opts = ParseOptions(ignore_unicode=True)
    var v = deserialize[Value, opts]('{"a": "\\u0041"}')
    # Undecoded: the six raw bytes of the escape, not the one byte "A".
    assert_equal(v["a"].string(), "\\u0041")
    assert_equal(v["a"].string().byte_length(), 6)


def test_deserialize_strict_mode_option_reaches_the_parser() raises:
    with assert_raises(contains="trailing comma"):
        _ = deserialize[Value]("[1,2,]")

    comptime lenient = ParseOptions(strict_mode=StrictOptions.LENIENT)
    var v = deserialize[Value, lenient]("[1,2,]")
    assert_equal(len(v.array()), 2)
    assert_equal(v[0].int(), 1)
    assert_equal(v[1].int(), 2)


def test_deserialize_validate_utf8_option_can_be_turned_off() raises:
    var bad = _invalid_utf8_doc()
    with assert_raises(contains="Invalid UTF-8 in input"):
        _ = deserialize[Point](bad)

    comptime unchecked = ParseOptions(validate_utf8=False)
    var p = deserialize[Point, unchecked](bad)
    assert_equal(p.x, 1)
    assert_equal(p.y, 2)


def test_try_deserialize_threads_options_too() raises:
    var bad = _invalid_utf8_doc()
    assert_false(Bool(try_deserialize[Point](bad)))

    comptime unchecked = ParseOptions(validate_utf8=False)
    var p = try_deserialize[Point, unchecked](bad)
    assert_true(Bool(p))
    assert_equal(p.value().x, 1)


def test_options_default_matches_the_no_options_spelling() raises:
    # Naming the default explicitly must not change anything: guards
    # against the default drifting away from `parse`'s.
    comptime defaults = ParseOptions()
    var a = deserialize[Point]('{"x":1,"y":2}')
    var b = deserialize[Point, defaults]('{"x":1,"y":2}')
    assert_equal(a.x, b.x)
    assert_equal(a.y, b.y)


# ===============================================
# The UTF-8 gate is a PUBLIC-entry-point gate
# ===============================================


def test_parse_rejects_invalid_utf8() raises:
    with assert_raises(contains="Invalid UTF-8 in input"):
        _ = parse(_invalid_utf8_doc())


def test_try_parse_returns_none_on_invalid_utf8() raises:
    assert_false(Bool(try_parse(_invalid_utf8_doc())))


def test_parse_accepts_invalid_utf8_when_validation_is_off() raises:
    # Proves the rejection above comes from the gate and not from the
    # parser stumbling over the bytes on its own.
    comptime unchecked = ParseOptions(validate_utf8=False)
    var v = parse[unchecked](_invalid_utf8_doc())
    assert_equal(v["x"].int(), 1)


def test_the_private_format_layer_does_not_validate_utf8() raises:
    # `emberjson._serde` is the format layer, not a public entry point:
    # it hands its input straight to the `Parser`. This asymmetry is
    # exactly why `from_json_string`/`to_json_string` are NOT re-exported
    # from `emberjson` -- two public spellings of "deserialize" with
    # different safety properties is a trap.
    var bad = _invalid_utf8_doc()
    var p = from_json_string[Point](bad)
    assert_equal(p.x, 1)
    assert_equal(p.y, 2)

    with assert_raises(contains="Invalid UTF-8 in input"):
        _ = deserialize[Point](bad)


def test_valid_multibyte_input_passes_every_public_entry_point() raises:
    var good = String('{"label": "héllo \U0001f525", "inner": {"x":1,"y":2}}')
    var w = deserialize[Wrapper](good)
    assert_equal(w.label, "héllo \U0001f525")
    assert_equal(w.inner.x, 1)
    assert_equal(parse(good)["label"].string(), "héllo \U0001f525")


# ===============================================
# `serialize` / `to_string` through the facade
# ===============================================


def test_serialize_struct_round_trips_through_the_facade() raises:
    var w = Wrapper("a", Point(1, 2))
    var s = serialize(w)
    assert_equal(s, '{"label":"a","inner":{"x":1,"y":2}}')
    var back = deserialize[Wrapper](s)
    assert_equal(back.label, "a")
    assert_equal(back.inner.x, 1)
    assert_equal(back.inner.y, 2)


def test_serialize_pretty_through_the_facade() raises:
    var s = serialize[pretty=True](Point(1, 2))
    assert_equal(s, '{\n    "x": 1,\n    "y": 2\n}')


def test_to_string_agrees_with_serialize_on_a_value() raises:
    var v = parse('{"a":[1,2],"b":{"c":null}}')
    assert_equal(to_string(v), serialize(v))
    assert_equal(to_string[pretty=True](v), serialize[pretty=True](v))


def test_to_string_pretty_through_the_facade() raises:
    var v = parse('{"a":[1,2]}')
    assert_equal(
        to_string[pretty=True](v),
        '{\n    "a": [\n        1,\n        2\n    ]\n}',
    )


def test_serialize_empty_containers_through_the_facade() raises:
    var v = parse('{"o":{},"a":[]}')
    assert_equal(to_string(v), '{"o":{},"a":[]}')
    assert_equal(
        to_string[pretty=True](v),
        '{\n    "o": {\n    },\n    "a": [\n    ]\n}',
    )


def test_serialize_bytes_honors_pretty() raises:
    # A `Span[Byte]` routes through `Serializer.serialize_bytes`, which
    # used to hand-write its brackets and so was the one container that
    # ignored `pretty`.
    var data: List[Byte] = [1, 2, 3]
    assert_equal(serialize(Span(data)), "[1,2,3]")
    assert_equal(
        serialize[pretty=True](Span(data)), "[\n    1,\n    2,\n    3\n]"
    )

    var empty: List[Byte] = []
    assert_equal(serialize(Span(empty)), "[]")
    assert_equal(serialize[pretty=True](Span(empty)), "[\n]")


def test_object_serialize_preserves_insertion_order() raises:
    # `Object.serialize` indexes its backing list rather than iterating it;
    # this pins that the rewrite kept the order (and the escaping) intact.
    var o = Object()
    o["z"] = 1
    o["a"] = Value('two"quoted')
    o["m"] = Array(1, Null())
    assert_equal(serialize(o), '{"z":1,"a":"two\\"quoted","m":[1,null]}')


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
