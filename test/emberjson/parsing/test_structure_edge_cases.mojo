from emberjson import (
    from_json,
    Parser,
    JSON,
    Object,
    Array,
    ParseOptions,
    StrictOptions,
    Value,
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
    var json = from_json[Value](s)
    assert_true(json.is_array())


def test_empty_structures() raises:
    assert_equal(String(from_json[Value]("[]")), "[]")
    assert_equal(String(from_json[Value]("{}")), "{}")
    assert_equal(String(from_json[Value]("[[]]")), "[[]]")
    assert_equal(String(from_json[Value]('{"a":{}}')), '{"a":{}}')
    assert_equal(String(from_json[Value]("[{},{}]")), "[{},{}]")


def test_duplicate_keys() raises:
    # Lenient parsing collapses duplicates with last-write-wins, matching dict
    # literal and `__setitem__` semantics (and RFC 8259's recommendation).
    var s = '{"a": 1, "a": 2}'
    var json = from_json[
        Value, ParseOptions(strict_mode=StrictOptions.LENIENT)
    ](s)
    assert_equal(json.object()["a"].int(), 2)
    assert_equal(len(json.object()), 1)

    with assert_raises():
        _ = from_json[Value](s)

    s = '{"a": 1, "b": 2, "a": "foo"}'
    json = from_json[Value, ParseOptions(strict_mode=StrictOptions.LENIENT)](s)
    assert_equal(json.object()["a"].string(), "foo")
    assert_equal(json.object()["b"].int(), 2)
    assert_equal(len(json.object()), 2)


def test_trailing_commas() raises:
    # arrays
    with assert_raises():
        _ = from_json[Value]("[1,]")
    with assert_raises():
        _ = from_json[Value]("[,1]")
    with assert_raises():
        _ = from_json[Value]("[1,,2]")

    # objects
    with assert_raises():
        _ = from_json[Value]('{"a":1,}')
    with assert_raises():
        _ = from_json[Value]('{,"a":1}')


def test_missing_delimiters() raises:
    with assert_raises():
        _ = from_json[Value]("[1 2]")
    with assert_raises():
        _ = from_json[Value]('{"a" 1}')
    with assert_raises():
        _ = from_json[Value]('{"a": 1 "b": 2}')


def test_control_chars() raises:
    # Unescaped newlines/tabs in strings are invalid
    with assert_raises():
        _ = from_json[Value]('"\n"')
    with assert_raises():
        _ = from_json[Value]('"\t"')

    # Although they are valid as whitespace outside strings
    var json = from_json[Value](" \n [ \t 1 \r ] \n ")
    assert_equal(json.array()[0].int(), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
