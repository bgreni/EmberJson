from testing import TestSuite, assert_equal, assert_true, assert_raises
from emberjson._deserialize import Parser, deserialize
from emberjson.lazy import (
    LazyString,
    LazyInt,
    LazyUInt,
    LazyFloat,
    LazyValue,
)


def test_lazy_int():
    # Test simple int
    var single = "123"
    var p_single = Parser(single)
    var s_single = deserialize[LazyInt[origin_of(single)]](p_single^)
    assert_equal(s_single.get(), 123)

    # Test negative int
    var negative = "-42"
    var p_negative = Parser(negative)
    var s_negative = deserialize[LazyInt[origin_of(negative)]](p_negative^)
    assert_equal(s_negative.get(), -42)

    # Test large int
    var large = "9007199254740991"
    var p_large = Parser(large)
    var s_large = deserialize[LazyInt[origin_of(large)]](p_large^)
    assert_equal(s_large.get(), 9007199254740991)


def test_lazy_uint():
    # Test simple uint
    var single = "123"
    var p_single = Parser(single)
    var s_single = deserialize[LazyUInt[origin_of(single)]](p_single^)
    assert_equal(s_single.get(), 123)

    # Test large uint
    var large = "18446744073709551615"
    var p_large = Parser(large)
    var s_large = deserialize[LazyUInt[origin_of(large)]](p_large^)
    assert_equal(s_large.get(), 18446744073709551615)


def test_lazy_float():
    # Test simple float
    var single = "123.456"
    var p_single = Parser(single)
    var s_single = deserialize[LazyFloat[origin_of(single)]](p_single^)
    assert_equal(s_single.get(), 123.456)

    # Test negative float
    var negative = "-42.5"
    var p_negative = Parser(negative)
    var s_negative = deserialize[LazyFloat[origin_of(negative)]](p_negative^)
    assert_equal(s_negative.get(), -42.5)

    # Test scientific notation
    var scientific = "1.23e4"
    var p_scientific = Parser(scientific)
    var s_scientific = deserialize[LazyFloat[origin_of(scientific)]](
        p_scientific^
    )
    assert_equal(s_scientific.get(), 1.23e4)


def test_lazy_string():
    # Test short string
    var short = '"short"'
    var p_short = Parser(short)
    var s_short = deserialize[LazyString[origin_of(short)]](p_short^)
    assert_equal(s_short.get(), "short")

    assert_equal(s_short.unsafe_as_string_slice(), "short")

    # Test long string (longer than SIMD width, usually 32 bytes)
    var long_str = '"this is a very long string that should trigger the SIMD path in the parser logic 1234567890"'
    var p_long = Parser(long_str)
    var s_long = deserialize[LazyString[origin_of(long_str)]](p_long^)
    assert_equal(
        s_long.get(),
        (
            "this is a very long string that should trigger the SIMD path in"
            " the parser logic 1234567890"
        ),
    )

    # Test escaped quotes
    var escaped = '"has \\"escaped\\" quotes"'
    var p_escaped = Parser(escaped)
    var s_escaped = deserialize[LazyString[origin_of(escaped)]](p_escaped^)
    assert_equal(s_escaped.get(), 'has "escaped" quotes')

    # Test escaped backslash
    var backslash = '"has \\\\ backslash"'
    var p_backslash = Parser(backslash)
    var s_backslash = deserialize[LazyString[origin_of(backslash)]](
        p_backslash^
    )
    assert_equal(s_backslash.get(), "has \\ backslash")

    var mixed = '"foo \\" bar \\\\ baz"'
    var p_mixed = Parser(mixed)
    var s_mixed = deserialize[LazyString[origin_of(mixed)]](p_mixed^)
    assert_equal(s_mixed.get(), 'foo " bar \\ baz')


def test_lazy_value():
    # Test capturing a string
    var string_val = '"hello world"'
    var p_string = Parser(string_val)
    var l_string = deserialize[LazyValue[origin_of(string_val)]](p_string^)
    assert_equal(l_string.get().string(), "hello world")

    # Test capturing an object
    var object_val = '{"key": [1, 2, 3]}'
    var p_object = Parser(object_val)
    var l_object = deserialize[LazyValue[origin_of(object_val)]](p_object^)
    assert_true(l_object.get().is_object())
    assert_equal(l_object.get().object()["key"].array()[0].int(), 1)

    # Test capturing an integer
    var int_val = "12345"
    var p_int = Parser(int_val)
    var l_int = deserialize[LazyValue[origin_of(int_val)]](p_int^)
    assert_equal(l_int.get().int(), 12345)

    # Test capturing a boolean
    var bool_val = "true"
    var p_bool = Parser(bool_val)
    var l_bool = deserialize[LazyValue[origin_of(bool_val)]](p_bool^)
    assert_true(l_bool.get().bool())


def test_lazy_init_from_bytes():
    var s = "123.42"
    var l = LazyFloat[origin_of(s)](s.as_bytes())
    assert_equal(l.get(), 123.42)


def main():
    TestSuite.discover_tests[__functions_in_module()]().run()
