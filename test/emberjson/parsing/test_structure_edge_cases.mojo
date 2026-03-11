from emberjson import (
    parse,
    Parser,
    JSON,
    Object,
    Array,
    ParseOptions,
    StrictOptions,
)
from std.testing import assert_raises, assert_equal, assert_true, TestSuite


def test_deep_nesting() raises:
    # Generate deep JSON: [[[[...]]]]
    var depth = 500
    var s = String("[")
    for _ in range(depth):
        s += "["
    s += "123"
    for _ in range(depth):
        s += "]"
    s += "]"

    # Let's just check it doesn't crash.
    var json = parse(s)
    assert_true(json.is_array())


def test_empty_structures() raises:
    assert_equal(String(parse("[]")), "[]")
    assert_equal(String(parse("{}")), "{}")
    assert_equal(String(parse("[[]]")), "[[]]")
    assert_equal(String(parse('{"a":{}}')), '{"a":{}}')
    assert_equal(String(parse("[{},{}]")), "[{},{}]")


def test_duplicate_keys() raises:
    # first one wins
    var s = '{"a": 1, "a": 2}'
    var json = parse[ParseOptions(strict_mode=StrictOptions.LENIENT)](s)
    assert_equal(json.object()["a"].int(), 1)
    assert_equal(len(json.object()), 2)

    with assert_raises():
        _ = parse(s)

    s = '{"a": 1, "b": 2, "a": "foo"}'
    json = parse[ParseOptions(strict_mode=StrictOptions.LENIENT)](s)
    assert_equal(json.object()["a"].int(), 1)
    assert_equal(json.object()["b"].int(), 2)
    assert_equal(len(json.object()), 3)


def test_trailing_commas() raises:
    # arrays
    with assert_raises():
        _ = parse("[1,]")
    with assert_raises():
        _ = parse("[,1]")
    with assert_raises():
        _ = parse("[1,,2]")

    # objects
    with assert_raises():
        _ = parse('{"a":1,}')
    with assert_raises():
        _ = parse('{,"a":1}')


def test_missing_delimiters() raises:
    with assert_raises():
        _ = parse("[1 2]")
    with assert_raises():
        _ = parse('{"a" 1}')
    with assert_raises():
        _ = parse('{"a": 1 "b": 2}')


def test_control_chars() raises:
    # Unescaped newlines/tabs in strings are invalid
    with assert_raises():
        _ = parse('"\n"')
    with assert_raises():
        _ = parse('"\t"')

    # Although they are valid as whitespace outside strings
    var json = parse(" \n [ \t 1 \r ] \n ")
    assert_equal(json.array()[0].int(), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
