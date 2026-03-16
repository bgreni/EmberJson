"""Security regression tests for EmberJson.

Each test corresponds to a confirmed finding from SECURITY_REPORT.md.
Tests are written to FAIL while the bug exists and PASS once fixed.
Exception: tests for L-2 and L-3 assert the current buggy value to document
the exact behaviour; their comments explain what the correct value should be.

Severity legend: [C]=Critical, [H]=High, [M]=Medium, [L]=Low
"""

from emberjson import (
    parse,
    Array,
    Object,
    Value,
    serialize,
    deserialize,
    Parser,
    minify,
    PointerIndex,
    CoerceString,
)
from emberjson._pointer import resolve_pointer, parse_int
from emberjson.patch._patch import patch
from emberjson.lazy import LazyString
from std.testing import (
    assert_true,
    assert_false,
    assert_equal,
    assert_raises,
    TestSuite,
)


# ===========================================================================
# [M-2] Object.__bool__ and Array.__bool__ are inverted
# __bool__ returns (len == 0) so an empty container is truthy and a
# non-empty container is falsy — the opposite of expected behaviour.
# ===========================================================================


def test_m2_object_bool_inverted() raises:
    var empty_obj = Object()
    var filled_obj = Object()
    filled_obj["key"] = Value(1)

    assert_false(empty_obj.__bool__())
    assert_true(filled_obj.__bool__())


def test_m2_array_bool_inverted() raises:
    var empty_arr = Array()
    var filled_arr = Array()
    filled_arr.append(Value(1))

    assert_false(empty_arr.__bool__())
    assert_true(filled_arr.__bool__())


# ===========================================================================
# [C-4] Serializer does not escape strings (JSON injection)
# write_key and String.write_json emit raw string bytes without escaping
# special characters such as '"', '\n', '\t', etc.
# ===========================================================================


def test_c4_key_not_escaped() raises:
    var obj = Object()
    obj["key\nwith\nnewlines"] = Value("value")
    var out = serialize(obj)
    # Correct output would escape the newlines: "key\\nwith\\nnewlines"
    # Bug: literal newline bytes appear in the key — assert the fixed form.
    assert_true("\\n" in out)  # FAILS: newlines are not escaped


def test_c4_value_not_escaped() raises:
    var v = Value("line1\nline2")
    var out = serialize(v)
    # Correct: '"line1\\nline2"' (15 chars, newline escaped as \n)
    # Bug: '"line1' + newline + 'line2"' (literal newline inside JSON string)
    assert_equal(out, '"line1\\nline2"')  # FAILS: newline is not escaped


# ===========================================================================
# [H-5] JSON Pointer parse_int has no overflow check
# A numeric token longer than 19 digits overflows Int64 silently.
# ===========================================================================


def test_h5_parse_int_overflow() raises:
    # Should raise for a value that cannot fit in Int; instead wraps silently.
    with assert_raises():
        _ = parse_int("99999999999999999999999999999999")


# ===========================================================================
# [C-6] hex_to_u32 does not validate hex characters
# \uXXXX sequences with non-hex characters should raise a parse error;
# instead hex_to_u32 silently maps them via raw arithmetic.
# ===========================================================================


def test_c6_invalid_hex_escape() raises:
    with assert_raises():
        _ = parse(r'{"key": "\uGGGG"}')


def test_c6_partially_invalid_hex_escape() raises:
    with assert_raises():
        _ = parse(r'{"key": "\u00GG"}')


# ===========================================================================
# [M-6] Surrogate pair validation — missing low-surrogate upper-bound check
# \uD800\uE000 has a second codepoint above the low-surrogate range
# (0xDC00..0xDFFF) but the missing upper-bound check lets it through.
# ===========================================================================


def test_m6_invalid_low_surrogate_range() raises:
    # Second codepoint 0xE000 is above the low-surrogate range — must raise.
    with assert_raises():
        _ = parse(r'{"key": "\uD800\uE000"}')


# ===========================================================================
# [H-3] Leading '+' accepted in numbers (violates RFC 8259 §6)
# ===========================================================================


def test_h3_leading_plus_in_number() raises:
    with assert_raises():
        _ = parse('{"n": +42}')


# ===========================================================================
# [L-3] CoerceString converts JSON null to the string "null"
# Callers expecting CoerceString to always return meaningful user data may be
# surprised; null should raise or produce an Optional.
# ===========================================================================


def test_l3_coerce_string_null() raises:
    var cs = deserialize[CoerceString]("null")
    # Documents the current buggy value; correct behaviour would be to raise.
    assert_equal(cs.value, "null")


# ===========================================================================
# [L-2] LazyString.unsafe_as_string_slice returns raw (unescaped) bytes
# Escape sequences such as \n are not decoded into the actual characters.
# ===========================================================================


def test_l2_lazy_string_not_decoded() raises:
    var s = r'"hello\nworld"'  # JSON string containing \n escape
    var p = Parser(s)
    var lazy = deserialize[LazyString[origin_of(s)]](p^)

    var raw = lazy.unsafe_as_string_slice()
    # raw contains "hello\nworld" (12 chars — literal backslash-n, not decoded)
    # Correct: should equal "hello" + newline + "world" (11 chars)
    assert_equal(len(raw), 12)  # documents the undecoded (buggy) length

    # Contrast: .get() DOES decode the escape correctly
    var p2 = Parser(s)
    var lazy2 = deserialize[LazyString[origin_of(s)]](p2^)
    assert_equal(lazy2.get(), "hello\nworld")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
