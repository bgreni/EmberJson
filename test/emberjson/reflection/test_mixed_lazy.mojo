from emberjson import (
    from_json,
    to_json,
    LazyValue,
    LazyString,
    LazyInt,
)
from std.testing import (
    assert_equal,
    assert_true,
    assert_raises,
    TestSuite,
)


struct Mixed[origin: ImmOrigin](Movable):
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
    var m = from_json[Mixed[origin_of(s)]](s)

    # Eager fields are materialized during deserialize.
    assert_equal(m.id, 7)
    assert_equal(m.flag, True)

    # Lazy fields captured only their spans; materialize on demand.
    var heavy = m.heavy.get()
    assert_true(heavy["a"][2]["deep"].is_null())
    assert_equal(m.note.get(), "hello")

    # Reflection serialization re-emits the captured bytes verbatim.
    var out = to_json(m)
    assert_true("deep" in out)
    assert_true('"id":7' in out)


def test_lazy_subtree_validated_on_get() raises:
    # A lazy object or array is captured by counting its brackets, so
    # malformed content inside it passes `from_json` and is reported by
    # `.get()` (simdjson On Demand's "validate what you use").
    var bad = String(
        '{"id": 1, "flag": false, "heavy": {"a": nope}, "note": "x"}'
    )
    var m = from_json[Mixed[origin_of(bad)]](bad)
    with assert_raises():
        _ = m.heavy.get()


def test_field_order_independent() raises:
    var s = String('{"note": "n", "heavy": [1], "flag": false, "id": -3}')
    var m = from_json[Mixed[origin_of(s)]](s)
    assert_equal(m.id, -3)
    assert_equal(m.note.get(), "n")
    assert_equal(m.heavy.get()[0].int(), 1)


def test_escaped_field_keys_still_match() raises:
    # Keys spelled with JSON escapes match their decoded field names
    # (exercises the span-matcher's decode fallback).
    var s = String(r'{"\u0069d": 5, "flag": true, "heavy": 1, "note": "x"}')
    var m = from_json[Mixed[origin_of(s)]](s)
    assert_equal(m.id, 5)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
