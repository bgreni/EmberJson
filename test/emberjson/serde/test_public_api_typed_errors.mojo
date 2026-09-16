"""Task 7/8 coverage: the public entry points (`parse`, `try_parse`,
`to_string`, `serialize`, `deserialize`, `try_deserialize`) raise
emberserde's typed `DeserializationError`/`SerializationError` instead of a
bare `Error`.

`parse`/`try_parse` drive EmberJson's hand-written `Parser`
(`emberjson/_deserialize/parser.mojo`) directly. Since F16 the `Parser`
raises `DeserializationError` itself, choosing the `DerErrorKind` at the
failure site, so `emberjson/__init__.mojo` translates nothing on the way
out -- a duplicate key reaches the caller as `DuplicateField`.

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
    from_json,
    try_from_json,
    to_json,
    to_json_pretty,
    parse_pointer,
    Document,
    Value,
    DeserializationError,
    SerializationError,
    DerErrorKind,
    ParseOptions,
    StrictOptions,
)
from emberserde import DenyUnknownFields
from emberjson._serde import from_json as _serde_from_json


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
struct OneField(Copyable, Defaultable, Movable):
    """One declared field, so every other wire key is routed through the
    framework's skip path -> `EmberJsonStructDe.skip_value` ->
    `Parser.skip_value`, which has no requested type at all."""

    var known: Int

    def __init__(out self):
        self.known = 0


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
        _ = from_json[Value]("{")
    except e:
        kind = String(e.kind)
    assert_true(kind != String(""))


def test_parse_malformed_json_reports_invalid_value_kind() raises:
    var kind = DerErrorKind.Custom
    try:
        _ = from_json[Value]("{")
    except e:
        kind = e.kind
    assert_equal(kind, DerErrorKind.InvalidValue)


def test_parse_invalid_utf8_reports_exact_message_and_kind() raises:
    # Brief: `is_valid_utf8` failure becomes
    # `DeserializationError("Invalid UTF-8 in input", DerErrorKind.InvalidValue)`.
    var kind = DerErrorKind.Custom
    var message = String("")
    try:
        _ = from_json[Value](_invalid_utf8_string())
    except e:
        kind = e.kind
        message = e.message
    assert_equal(kind, DerErrorKind.InvalidValue)
    assert_equal(message, "Invalid UTF-8 in input")


def test_try_parse_returns_none_on_malformed_json() raises:
    assert_false(Bool(try_from_json[Value]("{")))


def test_try_parse_returns_none_on_invalid_utf8() raises:
    assert_false(Bool(try_from_json[Value](_invalid_utf8_string())))


def test_try_parse_returns_value_on_valid_json() raises:
    var result = try_from_json[Value]('{"a":1}')
    assert_true(Bool(result))
    assert_equal(result.value()["a"].int(), 1)


# ===============================================
# deserialize / try_deserialize
# ===============================================


def test_deserialize_missing_field_reports_missing_field_kind() raises:
    var kind = DerErrorKind.Custom
    try:
        _ = from_json[Point]('{"x":1}')
    except e:
        kind = e.kind
    assert_equal(kind, DerErrorKind.MissingField)


def test_deserialize_type_mismatch_reports_type_mismatch_kind() raises:
    var kind = DerErrorKind.Custom
    try:
        _ = from_json[Point]('{"x":"nope","y":2}')
    except e:
        kind = e.kind
    assert_equal(kind, DerErrorKind.TypeMismatch)


def test_deserialize_duplicate_field_reports_duplicate_field_kind() raises:
    var kind = DerErrorKind.Custom
    try:
        _ = from_json[Point]('{"x":1,"x":2,"y":3}')
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
    var p = from_json[Point]('{"x":1,"y":2,"z":3}')
    assert_equal(p.x, 1)
    assert_equal(p.y, 2)


def test_deserialize_unknown_field_reports_unknown_field_kind() raises:
    # The opt-in half of the behavior change above: a type conforming to
    # `DenyUnknownFields` still gets the old rejection, now with a real
    # `UnknownField` kind rather than one reverse-engineered from message
    # text.
    var kind = DerErrorKind.Custom
    try:
        _ = from_json[StrictPoint]('{"x":1,"y":2,"z":3}')
    except e:
        kind = e.kind
    assert_equal(kind, DerErrorKind.UnknownField)


def test_deserialize_invalid_utf8_reports_invalid_value_kind() raises:
    var kind = DerErrorKind.Custom
    var message = String("")
    try:
        _ = from_json[Point](_invalid_utf8_string())
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
        _ = from_json[Outer]('{"label":"a","inner":{"x":1}}')
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
        _ = from_json[Nested](
            '{"tag":"t","middle":{"label":"a","inner":{"x":1}}}'
        )
    except e:
        path = e.path
    assert_equal(path, String(".middle.inner"))


def test_try_deserialize_returns_none_on_missing_field() raises:
    assert_false(Bool(try_from_json[Point]('{"x":1}')))


def test_try_deserialize_returns_none_on_invalid_utf8() raises:
    assert_false(Bool(try_from_json[Point](_invalid_utf8_string())))


def test_try_deserialize_returns_value_on_valid_input() raises:
    var result = try_from_json[Point]('{"x":1,"y":2}')
    assert_true(Bool(result))
    assert_equal(result.value().x, 1)
    assert_equal(result.value().y, 2)


# ===============================================
# serialize / to_string
# ===============================================


def test_serialize_round_trips() raises:
    var p = Point(1, 2)
    assert_equal(to_json(p), '{"x":1,"y":2}')


def test_to_string_round_trips() raises:
    var v = from_json[Value]('{"a":1}')
    assert_equal(to_json(v), '{"a":1}')


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
    var v = from_json[Value]('{"a": "\\u0041"}')
    assert_equal(v["a"].string(), "A")
    assert_equal(v["a"].string().byte_length(), 1)


def test_deserialize_ignore_unicode_option_reaches_the_parser() raises:
    comptime opts = ParseOptions(ignore_unicode=True)
    var v = from_json[Value, opts]('{"a": "\\u0041"}')
    # Undecoded: the six raw bytes of the escape, not the one byte "A".
    assert_equal(v["a"].string(), "\\u0041")
    assert_equal(v["a"].string().byte_length(), 6)


def test_deserialize_strict_mode_option_reaches_the_parser() raises:
    with assert_raises(contains="trailing comma"):
        _ = from_json[Value]("[1,2,]")

    comptime lenient = ParseOptions(strict_mode=StrictOptions.LENIENT)
    var v = from_json[Value, lenient]("[1,2,]")
    assert_equal(len(v.array()), 2)
    assert_equal(v[0].int(), 1)
    assert_equal(v[1].int(), 2)


def test_deserialize_validate_utf8_option_can_be_turned_off() raises:
    var bad = _invalid_utf8_doc()
    with assert_raises(contains="Invalid UTF-8 in input"):
        _ = from_json[Point](bad)

    comptime unchecked = ParseOptions(validate_utf8=False)
    var p = from_json[Point, unchecked](bad)
    assert_equal(p.x, 1)
    assert_equal(p.y, 2)


def test_try_deserialize_threads_options_too() raises:
    var bad = _invalid_utf8_doc()
    assert_false(Bool(try_from_json[Point](bad)))

    comptime unchecked = ParseOptions(validate_utf8=False)
    var p = try_from_json[Point, unchecked](bad)
    assert_true(Bool(p))
    assert_equal(p.value().x, 1)


def test_options_default_matches_the_no_options_spelling() raises:
    # Naming the default explicitly must not change anything: guards
    # against the default drifting away from `parse`'s.
    comptime defaults = ParseOptions()
    var a = from_json[Point]('{"x":1,"y":2}')
    var b = from_json[Point, defaults]('{"x":1,"y":2}')
    assert_equal(a.x, b.x)
    assert_equal(a.y, b.y)


# ===============================================
# The UTF-8 gate is a PUBLIC-entry-point gate
# ===============================================


def test_parse_accepts_invalid_utf8_when_validation_is_off() raises:
    # Proves the rejection above comes from the gate and not from the
    # parser stumbling over the bytes on its own.
    comptime unchecked = ParseOptions(validate_utf8=False)
    var v = from_json[Value, unchecked](_invalid_utf8_doc())
    assert_equal(v["x"].int(), 1)


def test_the_private_format_layer_does_not_validate_utf8() raises:
    # `emberjson._serde` is the format layer, not a public entry point:
    # it hands its input straight to the `Parser`. This asymmetry is
    # exactly why `from_json`/`to_json` are NOT re-exported
    # from `emberjson` -- two public spellings of "deserialize" with
    # different safety properties is a trap.
    var bad = _invalid_utf8_doc()
    var p = _serde_from_json[Point](bad)
    assert_equal(p.x, 1)
    assert_equal(p.y, 2)

    with assert_raises(contains="Invalid UTF-8 in input"):
        _ = from_json[Point](bad)


def test_valid_multibyte_input_passes_every_public_entry_point() raises:
    var good = String('{"label": "héllo \U0001f525", "inner": {"x":1,"y":2}}')
    var w = from_json[Wrapper](good)
    assert_equal(w.label, "héllo \U0001f525")
    assert_equal(w.inner.x, 1)
    assert_equal(from_json[Value](good)["label"].string(), "héllo \U0001f525")


# ===============================================
# `serialize` / `to_string` through the facade
# ===============================================


def test_serialize_pretty_through_the_facade() raises:
    var s = to_json_pretty(Point(1, 2))
    assert_equal(s, '{\n    "x": 1,\n    "y": 2\n}')


def test_to_string_pretty_through_the_facade() raises:
    var v = from_json[Value]('{"a":[1,2]}')
    assert_equal(
        to_json_pretty(v),
        '{\n    "a": [\n        1,\n        2\n    ]\n}',
    )


def test_serialize_empty_containers_through_the_facade() raises:
    var v = from_json[Value]('{"o":{},"a":[]}')
    assert_equal(to_json(v), '{"o":{},"a":[]}')
    assert_equal(
        to_json_pretty(v),
        '{\n    "o": {\n    },\n    "a": [\n    ]\n}',
    )


def test_grammar_errors_are_invalid_value_on_every_strategy() raises:
    var inputs: List[String] = ["[01]", "", "[1,]", "[tru]"]
    for s in inputs:
        var kind = DerErrorKind.Custom
        var raised = False
        try:
            _ = from_json[List[Int]](s)
        except e:
            kind = e.kind
            raised = True
        assert_true(raised, "expected a raise for " + s)
        assert_equal(kind, DerErrorKind.InvalidValue)


def test_shape_mismatch_is_type_mismatch() raises:
    var kind = DerErrorKind.Custom
    var raised = False
    try:
        _ = from_json[List[Int]]('["a"]')
    except e:
        kind = e.kind
        raised = True
    assert_true(raised)
    assert_equal(kind, DerErrorKind.TypeMismatch)


def test_truncated_bool_literal_is_invalid_value_on_every_target() raises:
    # "tru" does not finish spelling "true": it is malformed JSON, not a
    # well-formed bool of the wrong shape.
    # `Parser._other_value_opens_here`
    # (`emberjson/_deserialize/parser.mojo`) confirms the full keyword at
    # the cursor before ever calling a `t`/`f`/`n` byte a shape mismatch,
    # so this is `InvalidValue` on every strategy -- not the
    # target-dependent TypeMismatch/InvalidValue split F16 exists to
    # remove (`List[Int]` used to disagree with `Value` and `List[Bool]`
    # here).
    var kind = DerErrorKind.Custom
    var raised = False
    try:
        _ = from_json[List[Int]]("[tru]")
    except e:
        kind = e.kind
        raised = True
    assert_true(raised, "List[Int]")
    assert_equal(kind, DerErrorKind.InvalidValue)

    kind = DerErrorKind.Custom
    raised = False
    try:
        _ = from_json[List[Bool]]("[tru]")
    except e:
        kind = e.kind
        raised = True
    assert_true(raised, "List[Bool]")
    assert_equal(kind, DerErrorKind.InvalidValue)

    kind = DerErrorKind.Custom
    raised = False
    try:
        _ = from_json[Value]("[tru]")
    except e:
        kind = e.kind
        raised = True
    assert_true(raised, "Value")
    assert_equal(kind, DerErrorKind.InvalidValue)


def test_well_formed_bool_of_the_wrong_shape_is_still_type_mismatch() raises:
    # The companion case: a FULLY well-formed `true` where a number was
    # wanted is a genuine shape mismatch, unaffected by the keyword
    # verification above.
    var kind = DerErrorKind.Custom
    var raised = False
    try:
        _ = from_json[List[Int]]("[true]")
    except e:
        kind = e.kind
        raised = True
    assert_true(raised)
    assert_equal(kind, DerErrorKind.TypeMismatch)


def test_container_eof_is_invalid_value_not_type_mismatch() raises:
    # `begin_map`/`begin_struct` split EOF (no byte to disagree about --
    # a grammar failure) from a genuine wrong-shape byte, the same as
    # `begin_seq`/the scalar sites above.
    var kind = DerErrorKind.Custom
    var raised = False
    try:
        _ = from_json[Dict[String, Int]]("")
    except e:
        kind = e.kind
        raised = True
    assert_true(raised, "Dict[String, Int]")
    assert_equal(kind, DerErrorKind.InvalidValue)

    kind = DerErrorKind.Custom
    raised = False
    try:
        _ = from_json[Point]("")
    except e:
        kind = e.kind
        raised = True
    assert_true(raised, "Point (struct)")
    assert_equal(kind, DerErrorKind.InvalidValue)

    kind = DerErrorKind.Custom
    raised = False
    try:
        _ = from_json[Dict[String, Int]]("[1]")
    except e:
        kind = e.kind
        raised = True
    assert_true(raised, "Dict[String, Int] against an array")
    assert_equal(kind, DerErrorKind.TypeMismatch)


def test_serialize_bytes_honors_pretty() raises:
    # A `Span[Byte]` routes through `Serializer.serialize_bytes`, which
    # used to hand-write its brackets and so was the one container that
    # ignored `pretty`.
    var data: List[Byte] = [1, 2, 3]
    assert_equal(to_json(Span(data)), "[1,2,3]")
    assert_equal(to_json_pretty(Span(data)), "[\n    1,\n    2,\n    3\n]")

    var empty: List[Byte] = []
    assert_equal(to_json(Span(empty)), "[]")
    assert_equal(to_json_pretty(Span(empty)), "[\n]")


# ===========================================================================
# F16: the `Parser` decides the kind at the failure site
#
# Sentinel-variable idiom (see this file's module docstring): the assertion
# lives OUTSIDE the `try`, because `assert_true` raises an untyped `Error`
# and Mojo rejects mixing that with a typed `DeserializationError` raise in
# one `try` block.
# ===========================================================================


def test_duplicate_key_on_value_is_duplicate_field() raises:
    # `Parser.parse_object`'s strict-mode duplicate raise, now carrying the
    # same kind the reflection `Dict` path already reported.
    var kind = DerErrorKind.Custom
    var raised = False
    try:
        _ = from_json[Value]('{"a":1,"a":2}')
    except e:
        kind = e.kind
        raised = True
    assert_true(raised)
    assert_equal(kind, DerErrorKind.DuplicateField)


def test_integer_overflow_into_typed_target_is_type_mismatch() raises:
    # Well-formed JSON that does not fit the target width: a shape problem,
    # not a grammar one. There is no range kind, so `TypeMismatch`.
    var kind = DerErrorKind.Custom
    var raised = False
    try:
        _ = from_json[Int64]("9223372036854775808")
    except e:
        kind = e.kind
        raised = True
    assert_true(raised)
    assert_equal(kind, DerErrorKind.TypeMismatch)


def test_value_path_grammar_errors_are_invalid_value() raises:
    var inputs: List[String] = [
        "[01]",
        "",
        "[1,]",
        "[tru]",
        '{"a":}',
        "[1 2]",
    ]
    for s in inputs:
        var kind = DerErrorKind.Custom
        var raised = False
        try:
            _ = from_json[Value](s)
        except e:
            kind = e.kind
            raised = True
        assert_true(raised, "expected a raise for " + s)
        assert_equal(kind, DerErrorKind.InvalidValue)


# ===========================================================================
# F16 fix round 1
# ===========================================================================


def _f16_kind[T: Movable & Deinitable](s: String) raises -> DerErrorKind:
    var kind = DerErrorKind.Custom
    try:
        _ = from_json[T](s)
    except e:
        kind = e.kind
    return kind


def _f16_render[T: Movable & Deinitable](s: String) raises -> String:
    """The error's RENDERED form -- what `assert_raises(contains=...)` and
    a `print` see. `DeserializationError.write_to` appends " (<Kind>)", so
    an entry point that stringified an already-typed error into a fresh one
    shows up here as a SECOND suffix."""
    var rendered = String("<did not raise>")
    try:
        _ = from_json[T](s)
    except e:
        rendered = String(e)
    return rendered^


def _occurrences(haystack: String, needle: String) -> Int:
    return len(haystack.split(needle)) - 1


# ---------------------------------------------------------------------------
# Important 1: the shape test must not fire once a sign has been consumed.
# `_validate_number` is reachable from the UNTYPED skip path, which has no
# requested type to disagree with, so `-true` there is a malformed number.
# ---------------------------------------------------------------------------


def test_signed_garbage_on_the_skip_path_is_invalid_value() raises:
    # `unknown` is not a declared field of `OneField`, so the framework
    # skips it: `Parser.skip_value` -> `_expect_validated_bytes` ->
    # `_validate_number`, with no requested type anywhere in sight.
    assert_equal(
        _f16_kind[OneField]('{"known":1,"unknown":-true}'),
        DerErrorKind.InvalidValue,
    )


def test_sign_without_digits_is_invalid_value_not_type_mismatch() raises:
    # `-a` is a malformed NUMBER -- the type actually being parsed -- not a
    # well-formed value of some other type.
    assert_equal(_f16_kind[List[Int]]("[-a]"), DerErrorKind.InvalidValue)
    assert_equal(_f16_kind[List[Float64]]("[-a]"), DerErrorKind.InvalidValue)


def test_unmoved_cursor_still_reports_a_shape_mismatch() raises:
    # The companion case Important 1 must NOT break: nothing consumed, and
    # a complete value of another type opens at the cursor.
    assert_equal(_f16_kind[List[Float64]]('["a"]'), DerErrorKind.TypeMismatch)


# ---------------------------------------------------------------------------
# Important 2: the tape and pointer layers are typed too, so no entry point
# re-wraps a typed error into a second kind suffix.
# ---------------------------------------------------------------------------


def test_document_duplicate_key_is_duplicate_field() raises:
    # Matches `from_json[Value]` (see
    # `test_duplicate_key_on_value_is_duplicate_field`); before the tape
    # was typed this flattened to `InvalidValue`.
    assert_equal(
        _f16_kind[Document]('{"a":1,"a":2}'), DerErrorKind.DuplicateField
    )


def test_document_error_carries_exactly_one_kind_suffix() raises:
    assert_equal(_f16_kind[Document]("[1,"), DerErrorKind.InvalidValue)
    var rendered = _f16_render[Document]("[1,")
    assert_equal(_occurrences(rendered, "(InvalidValue)"), 1, rendered)


def test_parse_pointer_error_carries_exactly_one_kind_suffix() raises:
    var rendered = String("<did not raise>")
    var kind = DerErrorKind.Custom
    try:
        _ = parse_pointer('{"a": tru}', "/a")
    except e:
        kind = e.kind
        rendered = String(e)
    assert_equal(kind, DerErrorKind.InvalidValue)
    assert_equal(_occurrences(rendered, "(InvalidValue)"), 1, rendered)


def test_parse_pointer_key_not_found_is_still_invalid_value() raises:
    var kind = DerErrorKind.Custom
    var raised = False
    try:
        _ = parse_pointer('{"a":1}', "/b")
    except e:
        kind = e.kind
        raised = True
    assert_true(raised)
    assert_equal(kind, DerErrorKind.InvalidValue)


# ---------------------------------------------------------------------------
# Important 3: one class -- a well-formed JSON number the requested target
# cannot represent -- is `TypeMismatch`.
# ---------------------------------------------------------------------------


def test_negative_into_unsigned_target_is_type_mismatch() raises:
    assert_equal(_f16_kind[UInt64]("-5"), DerErrorKind.TypeMismatch)


def test_fractional_into_integer_target_is_type_mismatch() raises:
    assert_equal(_f16_kind[Int64]("1.5"), DerErrorKind.TypeMismatch)
    assert_equal(_f16_kind[List[Int]]("[1.5]"), DerErrorKind.TypeMismatch)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
