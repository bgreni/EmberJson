from emberjson import parse, Parser, JSON, Object, Array
from testing import assert_raises, assert_equal, assert_true, TestSuite


def test_deep_nesting():
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


def test_empty_structures():
    assert_equal(String(parse("[]")), "[]")
    assert_equal(String(parse("{}")), "{}")
    assert_equal(String(parse("[[]]")), "[[]]")
    assert_equal(String(parse('{"a":{}}')), '{"a":{}}')
    assert_equal(String(parse("[{},{}]")), "[{},{}]")


def test_duplicate_keys():
    # JSON standard says behavior is undefined, but practically last-one-wins is common
    var s = '{"a": 1, "a": 2}'
    var json = parse(s)
    assert_equal(json.object()["a"].int(), 2)


def test_trailing_commas():
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


def test_missing_delimiters():
    with assert_raises():
        _ = parse("[1 2]")
    with assert_raises():
        _ = parse('{"a" 1}')
    with assert_raises():
        _ = parse('{"a": 1 "b": 2}')


def test_control_chars():
    # Unescaped newlines/tabs in strings are invalid
    with assert_raises():
        _ = parse('"\n"')
    with assert_raises():
        _ = parse('"\t"')

    # Although they are valid as whitespace outside strings
    var json = parse(" \n [ \t 1 \r ] \n ")
    assert_equal(json.array()[0].int(), 1)


def main():
    TestSuite.discover_tests[__functions_in_module()]().run()
