from emberjson.utils import write
from emberjson import Value
from testing import assert_equal, assert_true, TestSuite


def test_string_builder_string():
    assert_equal(write(Value("foo bar")), '"foo bar"')


def test_write_escaped_string():
    # Quotes
    assert_equal(write(Value('foo "bar"')), r'"foo \"bar\""')

    # Backslash
    assert_equal(write(Value("foo \\ bar")), r'"foo \\ bar"')

    # Control chars
    assert_equal(write(Value("foo \b bar")), r'"foo \b bar"')
    assert_equal(write(Value("foo \f bar")), r'"foo \f bar"')
    assert_equal(write(Value("foo \n bar")), r'"foo \n bar"')
    assert_equal(write(Value("foo \r bar")), r'"foo \r bar"')
    assert_equal(write(Value("foo \t bar")), r'"foo \t bar"')

    # Null byte (should be \u0000)
    var null_str = String()
    null_str.append(Codepoint(0))
    assert_equal(write(Value(null_str)), r'"\u0000"')


def test_write_unicode_string():
    # Multi-byte UTF-8 (should not be escaped)
    assert_equal(write(Value("Hello ☃")), r'"Hello ☃"')
    # Emoji (should not be escaped)
    assert_equal(write(Value("😊")), r'"😊"')


def main():
    TestSuite.discover_tests[__functions_in_module()]().run()
