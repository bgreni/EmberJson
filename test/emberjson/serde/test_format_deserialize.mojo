from std.testing import assert_equal, TestSuite
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


def test_struct_from_wire() raises:
    var p = from_json_string[Point]('{"x":1,"y":2}')
    assert_equal(p.x, 1)
    assert_equal(p.y, 2)


def test_missing_field_reports_kind_and_path() raises:
    # `assert_true(False)` inside the `try` won't compile here: it raises
    # the untyped `Error`, while `from_json_string` raises the typed
    # `DeserializationError`, and a single `try` block can't mix raise
    # types under Mojo's typed-raises inference. Use a sentinel instead
    # (same idiom as emberserde's own `test_missing_field_raises`): if the
    # call doesn't raise, `kind` keeps its wrong default and the assertion
    # below fails.
    var kind = DerErrorKind.Custom
    try:
        _ = from_json_string[Point]('{"x":1}')
    except e:
        kind = e.kind
    assert_equal(String(kind), String("MissingField"))


def test_list_from_wire() raises:
    var xs = from_json_string[List[Int]]("[1,2,3]")
    assert_equal(len(xs), 3)
    assert_equal(xs[2], 3)


def test_error_path_points_at_nested_field() raises:
    var path = String("unset")
    try:
        _ = from_json_string[Outer]('{"label":"a","inner":{"x":1}}')
    except e:
        path = e.path
    assert_equal(path, String(".inner"))


# Reviewer's literal repro (Fix round 1): a plain, unescaped two-character
# field name binds correctly. Passes both before and after the escaped-key
# fix below — `expect_field_name`'s unescaped fast path was never the
# broken part — but the repro is reproduced verbatim so it stands as a
# permanent regression guard.
def test_two_char_field_name_binds() raises:
    var v = from_json_string[AB]('{"ab":1}')
    assert_equal(v.ab, 1)


# Same struct, same field, an ordinary key: guards the unescaped fast path
# in `expect_field_name` (the `_next_backslash` scan finding no backslash)
# stays correct as the escaped path (below) is added alongside it.
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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
