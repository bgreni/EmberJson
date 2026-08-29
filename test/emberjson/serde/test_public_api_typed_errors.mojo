"""Task 7/8 coverage: the public entry points (`parse`, `try_parse`,
`to_string`, `serialize`, `deserialize`, `try_deserialize`) raise
emberserde's typed `DeserializationError`/`SerializationError` instead of a
bare `Error`.

`parse`/`try_parse` drive EmberJson's hand-written `Parser`
(`emberjson/_deserialize/parser.mojo`) directly, and
`emberjson/__init__.mojo` translates the bare `Error` it still raises into
a typed one at the public boundary.

`deserialize`/`try_deserialize`/`serialize` ride `emberjson._serde`'s
`from_json_string`/`to_json_string` (Task 8), i.e. emberserde's
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

from std.testing import assert_equal, assert_true, assert_false, TestSuite
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
)
from emberserde import DenyUnknownFields


@fieldwise_init
struct Point(Copyable, Defaultable, Movable):
    var x: Int
    var y: Int

    def __init__(out self):
        self.x = 0
        self.y = 0


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
    # BEHAVIOR CHANGE (Task 8). The superseded reflection walker
    # (`emberjson/_deserialize/reflection.mojo`) raised
    # `"Unexpected field: z"` for *any* wire key it could not bind. The
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
    # from the walker's message text. Riding `from_json_string` instead
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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
