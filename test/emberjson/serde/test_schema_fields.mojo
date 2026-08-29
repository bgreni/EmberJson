"""Schema wrappers driven through the emberserde path.

`test/emberjson/test_schema.mojo` keeps the same coverage on EmberJson's
legacy `deserialize`/`serialize` entry points; this file exercises the
emberserde `Deserializable`/`Serializable` conformances the wrappers
gained in the port, via `from_json_string`/`to_json_string`.
"""

from emberjson.schema import Default
from emberjson._serde import from_json_string, to_json_string
from emberserde import Defaulted, Field
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)


@fieldwise_init
struct Rec(Movable):
    var a: Int
    var b: Default[Int, 42]


@fieldwise_init
struct OptRec(Movable):
    var a: Int
    var b: Defaulted[Optional[Int], Optional[Int](5)]


##########################################################
# Default (emberserde `Field[T, default=...]`)
##########################################################


def test_default_fills_when_key_missing() raises:
    var r = from_json_string[Rec]('{"a":1}')
    assert_equal(r.a, 1)
    assert_equal(r.b.value, 42)
    assert_equal(r.b[], 42)


def test_default_present_key_wins() raises:
    var r = from_json_string[Rec]('{"a":1,"b":7}')
    assert_equal(r.b[], 7)


def test_default_explicit_null_raises() raises:
    # BEHAVIOR CHANGE (see task-6 report): emberserde's `Field` fills only
    # when the key is absent from the wire. An explicit `null` is a present
    # value of the wrong type for `Int`, so it is an error rather than a
    # silent fall back to the default.
    with assert_raises():
        _ = from_json_string[Rec]('{"a":1,"b":null}')


def test_optional_default_null_binds_none() raises:
    # The escape hatch for the old null-tolerant behaviour: make the payload
    # itself `Optional`. A missing key still takes the default; an explicit
    # `null` binds `None` instead of raising.
    var missing = from_json_string[OptRec]('{"a":1}')
    assert_true(missing.b[])
    assert_equal(missing.b[].value(), 5)

    var explicit = from_json_string[OptRec]('{"a":1,"b":null}')
    assert_false(explicit.b[])

    var present = from_json_string[OptRec]('{"a":1,"b":9}')
    assert_equal(present.b[].value(), 9)


def test_default_serializes_payload() raises:
    assert_equal(to_json_string(Rec(1, 42)), '{"a":1,"b":42}')


def test_default_missing_required_field_still_raises() raises:
    with assert_raises():
        _ = from_json_string[Rec]('{"b":7}')


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
