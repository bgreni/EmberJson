"""Task 7 coverage: the public entry points (`parse`, `try_parse`,
`to_string`, `serialize`, `deserialize`, `try_deserialize`) raise
emberserde's typed `DeserializationError`/`SerializationError` instead of a
bare `Error`.

`parse`/`try_parse` and `deserialize`/`try_deserialize` still run through
EmberJson's pre-existing hand-written `Parser` and reflection walker
(`emberjson/_deserialize/parser.mojo`, `emberjson/_deserialize/reflection.
mojo` -- neither modified by this task); `emberjson/__init__.mojo` wraps
what they raise at the public boundary. See the doc comments on `parse` and
`deserialize` there for exactly how `kind` is derived.

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


def test_deserialize_unknown_field_reports_unknown_field_kind() raises:
    var kind = DerErrorKind.Custom
    try:
        _ = deserialize[Point]('{"x":1,"y":2,"z":3}')
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


def test_deserialize_legacy_path_carries_no_wire_path() raises:
    # `deserialize`'s Parser-backed reflection walker
    # (`emberjson/_deserialize/reflection.mojo`, unmodified by this task --
    # `schema.mojo` and `Lazy` depend on it) never accumulates a wire path
    # as an error unwinds through nested structs: unlike emberserde's own
    # struct-walking framework (`expect_field_value` + `prepend_path`), a
    # nested failure's message names only the innermost field, with no
    # outer-struct context to build a `.inner.x`-style path from. This pins
    # that as the actual, current behavior rather than leaving it
    # unverified. Full path support already exists on the newer,
    # `_serde`-backed entry point -- see `test_format_deserialize.mojo`'s
    # `test_error_path_points_at_nested_field` (`from_json_string[Outer](...)`
    # there reports `path == ".inner"`).
    var path = String("unset")
    try:
        _ = deserialize[Outer]('{"label":"a","inner":{"x":1}}')
    except e:
        path = e.path
    assert_equal(path, String(""))


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
#
# Neither the reflection-based `serialize` nor `to_string` can currently
# raise (see the doc comment above `serialize` in `emberjson/__init__.mojo`)
# -- `raises SerializationError` is a signature-level contract, not a path
# exercised today. These pin that the round trip still works under the new
# (raising) signatures.


def test_serialize_round_trips() raises:
    var p = Point(1, 2)
    assert_equal(serialize(p), '{"x":1,"y":2}')


def test_to_string_round_trips() raises:
    var v = parse('{"a":1}')
    assert_equal(to_string(v), '{"a":1}')


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
