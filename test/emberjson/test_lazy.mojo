from std.testing import TestSuite, assert_equal, assert_true, assert_raises

# Ported in Task 8 from the deleted `Parser`-driven reflection walker
# (`var p = Parser(s); deserialize[LazyX[origin_of(s)]](p)`) to the
# emberserde entry point. `from_json_string` builds the same `Parser` over
# the same input and captures the same borrowed span through
# `EmberJsonDeserializer.raw_bytes`; the inputs and expectations below are
# unchanged.
from emberjson._serde import from_json_string
from emberjson.lazy import (
    LazyString,
    LazyInt,
    LazyUInt,
    LazyFloat,
    LazyValue,
)


def test_lazy_int() raises:
    # Test simple int
    var single = "123"
    var s_single = from_json_string[LazyInt[origin_of(single)]](single)
    assert_equal(s_single.get(), 123)

    # Test negative int
    var negative = "-42"
    var s_negative = from_json_string[LazyInt[origin_of(negative)]](negative)
    assert_equal(s_negative.get(), -42)

    # Test large int
    var large = "9007199254740991"
    var s_large = from_json_string[LazyInt[origin_of(large)]](large)
    assert_equal(s_large.get(), 9007199254740991)


def test_lazy_uint() raises:
    # Test simple uint
    var single = "123"
    var s_single = from_json_string[LazyUInt[origin_of(single)]](single)
    assert_equal(s_single.get(), 123)

    # Test large uint
    var large = "18446744073709551615"
    var s_large = from_json_string[LazyUInt[origin_of(large)]](large)
    assert_equal(s_large.get(), 18446744073709551615)


def test_lazy_float() raises:
    # Test simple float
    var single = "123.456"
    var s_single = from_json_string[LazyFloat[origin_of(single)]](single)
    assert_equal(s_single.get(), 123.456)

    # Test negative float
    var negative = "-42.5"
    var s_negative = from_json_string[LazyFloat[origin_of(negative)]](negative)
    assert_equal(s_negative.get(), -42.5)

    # Test scientific notation
    var scientific = "1.23e4"
    var s_scientific = from_json_string[LazyFloat[origin_of(scientific)]](
        scientific
    )
    assert_equal(s_scientific.get(), 1.23e4)


def test_lazy_string() raises:
    # Test short string
    var short = '"short"'
    var s_short = from_json_string[LazyString[origin_of(short)]](short)
    assert_equal(s_short.get(), "short")

    assert_equal(s_short.unsafe_as_string_slice(), "short")

    # Test long string (longer than SIMD width, usually 32 bytes)
    var long_str = (
        '"this is a very long string that should trigger the SIMD path in the'
        ' parser logic 1234567890"'
    )
    var s_long = from_json_string[LazyString[origin_of(long_str)]](long_str)
    assert_equal(
        s_long.get(),
        (
            "this is a very long string that should trigger the SIMD path in"
            " the parser logic 1234567890"
        ),
    )

    # Test escaped quotes
    var escaped = '"has \\"escaped\\" quotes"'
    var s_escaped = from_json_string[LazyString[origin_of(escaped)]](escaped)
    assert_equal(s_escaped.get(), 'has "escaped" quotes')

    # Test escaped backslash
    var backslash = '"has \\\\ backslash"'
    var s_backslash = from_json_string[LazyString[origin_of(backslash)]](
        backslash
    )
    assert_equal(s_backslash.get(), "has \\ backslash")

    var mixed = '"foo \\" bar \\\\ baz"'
    var s_mixed = from_json_string[LazyString[origin_of(mixed)]](mixed)
    assert_equal(s_mixed.get(), 'foo " bar \\ baz')


def test_lazy_value() raises:
    # Test capturing a string
    var string_val = '"hello world"'
    var l_string = from_json_string[LazyValue[origin_of(string_val)]](
        string_val
    )
    assert_equal(l_string.get().string(), "hello world")

    # Test capturing an object
    var object_val = '{"key": [1, 2, 3]}'
    var l_object = from_json_string[LazyValue[origin_of(object_val)]](
        object_val
    )
    assert_true(l_object.get().is_object())
    assert_equal(l_object.get().object()["key"].array()[0].int(), 1)

    # Test capturing an integer
    var int_val = "12345"
    var l_int = from_json_string[LazyValue[origin_of(int_val)]](int_val)
    assert_equal(l_int.get().int(), 12345)

    # Test capturing a boolean
    var bool_val = "true"
    var l_bool = from_json_string[LazyValue[origin_of(bool_val)]](bool_val)
    assert_true(l_bool.get().bool())


def test_lazy_init_from_bytes() raises:
    var s = "123.42"
    var b = s.as_bytes()
    var l = LazyFloat[b.origin](b)
    assert_equal(l.get(), 123.42)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
