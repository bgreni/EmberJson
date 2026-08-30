"""Task 7/8 coverage: the public entry points (`parse`, `try_parse`,
`to_string`, `serialize`, `deserialize`, `try_deserialize`) raise
emberserde's typed `DeserializationError`/`SerializationError` instead of a
bare `Error`.

`parse`/`try_parse` drive EmberJson's hand-written `Parser`
(`emberjson/_deserialize/parser.mojo`) directly, and
`emberjson/__init__.mojo` translates the bare `Error` it still raises into
a typed one at the public boundary.

`deserialize`/`try_deserialize`/`serialize` ride `emberjson._serde`'s
`from_json`/`to_json` (Task 8), i.e. emberserde's
format-agnostic framework over that same `Parser`. Errors there are typed
at the source: a real `kind`, and a real `path` for a nested failure.

Sentinel-variable idiom throughout (not `assert_true(False)` inside the
`try`): Mojo rejects mixing an untyped `Error` raise (what `assert_true`
itself raises on failure) with a typed `DeserializationError`/
`SerializationError` raise in the same `try` block. Same idiom as
`emberserde/test/deserialize/test_struct.mojo`'s
`test_missing_field_raises` and this repo's own
`test_format_deserialize.mojo`.
"""

from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)
from emberjson import (
    parse,
    try_parse,
    deserialize,
    try_deserialize,
    serialize,
    to_string,
    Value,
    DeserializationError,
    SerializationError,
    DerErrorKind,
    ParseOptions,
    StrictOptions,
)
from emberserde import DenyUnknownFields
from emberjson._serde import from_json


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


@fieldwise_init
struct StrictPoint(Copyable, Defaultable, DenyUnknownFields, Movable):
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


@fieldwise_init
struct Nested(Copyable, Defaultable, Movable):
    var tag: String
    var middle: Outer

    def __init__(out self):
        self.tag = String()
        self.middle = Outer()


def _invalid_utf8_string() -> String:
    # `{"a": <overlong-encoded NUL>` -- same technique as
    # `test/emberjson/parsing/test_utf8.mojo`'s
    # `test_utf8_validation_default_on`: raw bytes viewed through
    # `StringSlice(unsafe_from_utf8=...)`, then materialized into an owned
    # `String` (no validity assert fires on the copy itself, only on
    # would-be codepoint-aware operations).
    var bytes = List[Byte]()
    bytes.append(0x7B)  # `{`
    bytes.append(0xC0)
    bytes.append(0x80)
    return String(StringSlice(unsafe_from_utf8=Span(bytes)))


# ===============================================
# parse / try_parse
# ===============================================


def test_parse_raises_typed_error() raises:
    # Brief's Step 1 test (task-7-brief.md), adapted to compile under the
    # typed-raises unification rule described above.
    var kind = String("")
    try:
        _ = parse("{")
    except e:
        kind = String(e.kind)
    assert_true(kind != String(""))


def test_parse_malformed_json_reports_invalid_value_kind() raises:
    var kind = DerErrorKind.Custom
    try:
        _ = parse("{")
    except e:
        kind = e.kind
    assert_equal(kind, DerErrorKind.InvalidValue)


def test_parse_invalid_utf8_reports_exact_message_and_kind() raises:
    # Brief: `is_valid_utf8` failure becomes
    # `DeserializationError("Invalid UTF-8 in input", DerErrorKind.InvalidValue)`.
    var kind = DerErrorKind.Custom
    var message = String("")
    try:
        _ = parse(_invalid_utf8_string())
    except e:
        kind = e.kind
        message = e.message
    assert_equal(kind, DerErrorKind.InvalidValue)
    assert_equal(message, "Invalid UTF-8 in input")


def test_try_parse_returns_none_on_malformed_json() raises:
    assert_false(Bool(try_parse("{")))


def test_try_parse_returns_none_on_invalid_utf8() raises:
    assert_false(Bool(try_parse(_invalid_utf8_string())))


def test_try_parse_returns_value_on_valid_json() raises:
    var result = try_parse('{"a":1}')
    assert_true(Bool(result))
    assert_equal(result.value()["a"].int(), 1)


# ===============================================
# deserialize / try_deserialize
# ===============================================


def test_deserialize_missing_field_reports_missing_field_kind() raises:
    var kind = DerErrorKind.Custom
    try:
        _ = deserialize[Point]('{"x":1}')
    except e:
        kind = e.kind
    assert_equal(kind, DerErrorKind.MissingField)


def test_deserialize_type_mismatch_reports_type_mismatch_kind() raises:
    var kind = DerErrorKind.Custom
    try:
        _ = deserialize[Point]('{"x":"nope","y":2}')
    except e:
        kind = e.kind
    assert_equal(kind, DerErrorKind.TypeMismatch)


def test_deserialize_duplicate_field_reports_duplicate_field_kind() raises:
    var kind = DerErrorKind.Custom
    try:
        _ = deserialize[Point]('{"x":1,"x":2,"y":3}')
    except e:
        kind = e.kind
    assert_equal(kind, DerErrorKind.DuplicateField)


def test_deserialize_ignores_unknown_field_by_default() raises:
    # BEHAVIOR CHANGE (see CHANGELOG.md). EmberJson's superseded
    # hand-written reflection walker raised `"Unexpected field: z"` for
    # *any* wire key it could not bind. The
    # emberserde framework `deserialize` now rides
    # (`expect_struct` in `emberserde/deserialize/__init__.mojo`) skips an
    # unbound key instead, and only rejects it when the target type opts in
    # by conforming to `DenyUnknownFields` -- see the next test. This pins
    # the new default rather than leaving it implicit.
    var p = deserialize[Point]('{"x":1,"y":2,"z":3}')
    assert_equal(p.x, 1)
    assert_equal(p.y, 2)


def test_deserialize_unknown_field_reports_unknown_field_kind() raises:
    # The opt-in half of the behavior change above: a type conforming to
    # `DenyUnknownFields` still gets the old rejection, now with a real
    # `UnknownField` kind rather than one reverse-engineered from message
    # text.
    var kind = DerErrorKind.Custom
    try:
        _ = deserialize[StrictPoint]('{"x":1,"y":2,"z":3}')
    except e:
        kind = e.kind
    assert_equal(kind, DerErrorKind.UnknownField)


def test_deserialize_invalid_utf8_reports_invalid_value_kind() raises:
    var kind = DerErrorKind.Custom
    var message = String("")
    try:
        _ = deserialize[Point](_invalid_utf8_string())
    except e:
        kind = e.kind
        message = e.message
    assert_equal(kind, DerErrorKind.InvalidValue)
    assert_equal(message, "Invalid UTF-8 in input")


def test_deserialize_populates_path_for_nested_failure() raises:
    # Task 8's headline gain. Task 7's `deserialize` drove the reflection
    # walker, which had no path machinery at all: a nested failure's
    # `.path` was ALWAYS empty and its `.kind` had to be reverse-engineered
    # from the walker's message text. Riding `from_json` instead
    # means the framework's own `prepend_path` runs as the error unwinds
    # through `expect_field_value`, so `.path` now names the route to the
    # failure. `inner` is missing its required `y`, two levels down.
    var path = String("unset")
    var kind = DerErrorKind.Custom
    try:
        _ = deserialize[Outer]('{"label":"a","inner":{"x":1}}')
    except e:
        path = e.path
        kind = e.kind
    assert_equal(path, String(".inner"))
    assert_equal(kind, DerErrorKind.MissingField)


def test_deserialize_path_reaches_through_two_levels() raises:
    # One level deeper than the test above, so the assertion pins an
    # accumulated chain (`.middle.inner`) rather than a single segment that
    # a leaf-only implementation could also produce.
    var path = String("unset")
    try:
        _ = deserialize[Nested](
            '{"tag":"t","middle":{"label":"a","inner":{"x":1}}}'
        )
    except e:
        path = e.path
    assert_equal(path, String(".middle.inner"))


def test_try_deserialize_returns_none_on_missing_field() raises:
    assert_false(Bool(try_deserialize[Point]('{"x":1}')))


def test_try_deserialize_returns_none_on_invalid_utf8() raises:
    assert_false(Bool(try_deserialize[Point](_invalid_utf8_string())))


def test_try_deserialize_returns_value_on_valid_input() raises:
    var result = try_deserialize[Point]('{"x":1,"y":2}')
    assert_true(Bool(result))
    assert_equal(result.value().x, 1)
    assert_equal(result.value().y, 2)


# ===============================================
# serialize / to_string
# ===============================================


def test_serialize_round_trips() raises:
    var p = Point(1, 2)
    assert_equal(serialize(p), '{"x":1,"y":2}')


def test_to_string_round_trips() raises:
    var v = parse('{"a":1}')
    assert_equal(to_string(v), '{"a":1}')


# ===========================================================================
# Public entry points: the `ParseOptions` channel restored in the final fix
# wave, the UTF-8 gate's asymmetry against the private `_serde` layer, and
# facade-level serialization. Merged here from `test_public_entry_points.mojo`
# -- this file already owned the public-facade topic.
# ===========================================================================


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


def test_parse_accepts_invalid_utf8_when_validation_is_off() raises:
    # Proves the rejection above comes from the gate and not from the
    # parser stumbling over the bytes on its own.
    comptime unchecked = ParseOptions(validate_utf8=False)
    var v = parse[unchecked](_invalid_utf8_doc())
    assert_equal(v["x"].int(), 1)


def test_the_private_format_layer_does_not_validate_utf8() raises:
    # `emberjson._serde` is the format layer, not a public entry point:
    # it hands its input straight to the `Parser`. This asymmetry is
    # exactly why `from_json`/`to_json` are NOT re-exported
    # from `emberjson` -- two public spellings of "deserialize" with
    # different safety properties is a trap.
    var bad = _invalid_utf8_doc()
    var p = from_json[Point](bad)
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


def test_serialize_pretty_through_the_facade() raises:
    var s = serialize[pretty=True](Point(1, 2))
    assert_equal(s, '{\n    "x": 1,\n    "y": 2\n}')


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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
