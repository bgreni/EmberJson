from emberjson import (
    deserialize,
    try_deserialize,
    serialize,
    LazyValue,
    LazyString,
    LazyInt,
)
from std.testing import (
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
    TestSuite,
)


struct Mixed[origin: ImmutOrigin](Movable):
    """A struct mixing eagerly-parsed fields with lazily-captured ones:
    `heavy` and `note` only record their byte spans during deserialize
    and materialize on `.get()`."""

    var id: Int64
    var flag: Bool
    var heavy: LazyValue[Self.origin]
    var note: LazyString[Self.origin]


comptime DOC = (
    '{"id": 7, "flag": true, "heavy": {"a": [1, 2, {"deep": null}]},'
    ' "note": "hello"}'
)


def test_mixed_lazy_fields() raises:
    var s = String(DOC)
    var m = deserialize[Mixed[origin_of(s)]](s)

    # Eager fields are materialized during deserialize.
    assert_equal(m.id, 7)
    assert_equal(m.flag, True)

    # Lazy fields captured only their spans; materialize on demand.
    var heavy = m.heavy.get()
    assert_true(heavy["a"][2]["deep"].is_null())
    assert_equal(m.note.get(), "hello")

    # Reflection serialization re-emits the captured bytes verbatim.
    var out = serialize(m)
    assert_true("deep" in out)
    assert_true('"id":7' in out)


def test_lazy_subtree_validated_at_capture() raises:
    # The lazy subtree is grammar-validated when its span is captured,
    # even though it is not materialized: malformed content fails the
    # deserialize call itself, not a later .get().
    var bad = String(
        '{"id": 1, "flag": false, "heavy": {"a": nope}, "note": "x"}'
    )
    assert_false(Bool(try_deserialize[Mixed[origin_of(bad)]](bad)))


def test_field_order_independent() raises:
    var s = String('{"note": "n", "heavy": [1], "flag": false, "id": -3}')
    var m = deserialize[Mixed[origin_of(s)]](s)
    assert_equal(m.id, -3)
    assert_equal(m.note.get(), "n")
    assert_equal(m.heavy.get()[0].int(), 1)


def test_escaped_field_keys_still_match() raises:
    # Keys spelled with JSON escapes match their decoded field names
    # (exercises the span-matcher's decode fallback).
    var s = String(r'{"\u0069d": 5, "flag": true, "heavy": 1, "note": "x"}')
    var m = deserialize[Mixed[origin_of(s)]](s)
    assert_equal(m.id, 5)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
