"""Series of tests that cover a series of bugs claude discovered.
"""

from emberjson import (
    from_json,
    Array,
    Document,
    Object,
    Value,
    to_json,
    minify,
    PointerIndex,
    CoerceString,
)
from emberjson._pointer import resolve_pointer, parse_int
from emberjson._serde import from_json as _serde_from_json
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
# object keys and string values used to be emitted as raw bytes without
# escaping special characters such as '"', '\n', '\t', etc.
# ===========================================================================


def test_c4_key_not_escaped() raises:
    var obj = Object()
    obj["key\nwith\nnewlines"] = Value("value")
    var out = to_json(obj)
    # Correct output would escape the newlines: "key\\nwith\\nnewlines"
    # Bug: literal newline bytes appear in the key — assert the fixed form.
    assert_true("\\n" in out)  # FAILS: newlines are not escaped


def test_c4_value_not_escaped() raises:
    var v = Value("line1\nline2")
    var out = to_json(v)
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
        _ = from_json[Value](r'{"key": "\uGGGG"}')


def test_c6_partially_invalid_hex_escape() raises:
    with assert_raises():
        _ = from_json[Value](r'{"key": "\u00GG"}')


# ===========================================================================
# [M-6] Surrogate pair validation — missing low-surrogate upper-bound check
# \uD800\uE000 has a second codepoint above the low-surrogate range
# (0xDC00..0xDFFF) but the missing upper-bound check lets it through.
# ===========================================================================


def test_m6_invalid_low_surrogate_range() raises:
    # Second codepoint 0xE000 is above the low-surrogate range — must raise.
    with assert_raises():
        _ = from_json[Value](r'{"key": "\uD800\uE000"}')


# ===========================================================================
# [H-3] Leading '+' accepted in numbers (violates RFC 8259 §6)
# ===========================================================================


def test_h3_leading_plus_in_number() raises:
    with assert_raises():
        _ = from_json[Value]('{"n": +42}')

    with assert_raises():
        _ = from_json[Int64]("+42")

    # Should trigger from_chars_slow
    # Making sure it will also reject a leading plus
    with assert_raises():
        _ = from_json[Float64]("+1.23456789012345678901")


# ===========================================================================
# [L-3] CoerceString converts JSON null to the string "null"
# Callers expecting CoerceString to always return meaningful user data may be
# surprised; null should raise or produce an Optional.
# ===========================================================================


def test_l3_coerce_string_null() raises:
    var cs = from_json[CoerceString]("null")
    # Documents the current buggy value; correct behaviour would be to raise.
    assert_equal(cs.value, "null")


# ===========================================================================
# [L-2] LazyString.unsafe_as_string_slice returns raw (unescaped) bytes
# Escape sequences such as \n are not decoded into the actual characters.
# ===========================================================================


def test_l2_lazy_string_not_decoded() raises:
    # Ported in Task 8 from `var p = Parser(s); deserialize[...](p)` (the
    # deleted `Parser`-driven reflection walker) to `from_json`,
    # which captures the same borrowed span. Same input, same assertions.
    var s = r'"hello\nworld"'  # JSON string containing \n escape
    var lazy = _serde_from_json[LazyString[origin_of(s)]](s)

    var raw = lazy.unsafe_as_string_slice()
    # raw contains "hello\nworld" (12 chars — literal backslash-n, not decoded)
    # Correct: should equal "hello" + newline + "world" (11 chars)
    assert_equal(
        raw.byte_length(), 12
    )  # documents the undecoded (buggy) length

    # Contrast: .get() DOES decode the escape correctly
    var lazy2 = _serde_from_json[LazyString[origin_of(s)]](s)
    assert_equal(lazy2.get(), "hello\nworld")


# ===========================================================================
# Padded-buffer boundary behaviour: inputs truncated mid-token at (or near)
# 64-byte buffer boundaries must terminate in the NUL padding with a clean
# error, never an out-of-bounds read (run under -D ASSERT=all).
# ===========================================================================


def test_truncation_at_chunk_boundaries() raises:
    # Leading whitespace positions the token's end exactly at the given
    # total length; trailing whitespace is legal so leading is what matters.
    def padded_to(total: Int, tail: String) -> String:
        return String(" ") * (total - tail.byte_length()) + tail

    for total in [63, 64, 65, 128]:
        # Number truncated mid-float: "1." with no fraction digits.
        with assert_raises():
            _ = from_json[Value](padded_to(total, "1."))
        # Unterminated string.
        with assert_raises():
            _ = from_json[Value](padded_to(total, '"abc'))
        # String ending in a bare backslash.
        with assert_raises():
            _ = from_json[Value](padded_to(total, '"a\\'))
        # Truncated exponent.
        with assert_raises():
            _ = from_json[Value](padded_to(total, "1e"))
        # Truncated atoms and containers.
        with assert_raises():
            _ = from_json[Value](padded_to(total, "tru"))
        with assert_raises():
            _ = from_json[Value](padded_to(total, "[1,2"))
        with assert_raises():
            _ = from_json[Value](padded_to(total, '{"k":'))
        # Valid values ending exactly on the boundary must still parse.
        assert_equal(from_json[Value](padded_to(total, "1234")).int(), 1234)
        assert_equal(from_json[Value](padded_to(total, '"ok"')).string(), "ok")
        assert_equal(
            len(from_json[Value](padded_to(total, "[1,2]")).array()), 2
        )


# ===========================================================================
# An embedded NUL after a scalar must be rejected, not treated as the
# `PaddedBuffer` pad. The index-driven engine (which `parse_document` takes
# for inputs >= PAD_INPUT_THRESHOLD) whitelisted NUL as a token terminator,
# so `123<NUL>4` parsed as `123` while the byte-walk engine rejected the
# same bytes — a parser differential that silently changed the value.
# ===========================================================================
def test_embedded_nul_after_scalar_is_rejected() raises:
    def with_nul(prefix: StringSlice, suffix: StringSlice) -> List[Byte]:
        var out = List[Byte]()
        for b in prefix.as_bytes():
            out.append(b)
        out.append(0)
        for b in suffix.as_bytes():
            out.append(b)
        return out^

    def as_slice(ref bytes: List[Byte]) -> StringSlice[origin_of(bytes)]:
        return StringSlice(unsafe_from_utf8=Span(bytes))

    # Short inputs (byte-walk engine) and padded inputs (index engine) must
    # agree, so pad past PAD_INPUT_THRESHOLD as well as staying under it.
    var filler = String()
    for i in range(12):
        filler += '"k' + String(i) + '":"vvvvvvvvvvvvvvvv",'

    for lead in [String(""), filler]:
        var after_number = with_nul("{" + lead + '"a":123', "4}")
        with assert_raises():
            _ = from_json[Document](as_slice(after_number))
        with assert_raises():
            _ = from_json[Value](as_slice(after_number))

        var after_literal = with_nul("{" + lead + '"a":true', "}")
        with assert_raises():
            _ = from_json[Document](as_slice(after_literal))
        with assert_raises():
            _ = from_json[Value](as_slice(after_literal))

        var in_array = with_nul("[" + "1", "2]")
        with assert_raises():
            _ = from_json[Document](as_slice(in_array))
        with assert_raises():
            _ = from_json[Value](as_slice(in_array))


# ===========================================================================
# RFC 8259 SS7: every byte U+0000-U+001F inside a JSON string must be
# escaped. The serial fallback scanners (`Parser.read_serial` and the
# matching fallback in `_tape_string`) only rejected \n \t \r, so any other
# raw control byte -- including an embedded NUL -- parsed successfully
# whenever the string was scanned by the serial path rather than the SIMD
# scanner. That happens for short (unpadded) inputs whose string opens with
# fewer than SIMD8_WIDTH bytes remaining.
# ===========================================================================


def test_raw_control_byte_in_string_is_rejected() raises:
    def with_byte(
        prefix: StringSlice, byte: Byte, suffix: StringSlice
    ) -> List[Byte]:
        var out = List[Byte]()
        for b in prefix.as_bytes():
            out.append(b)
        out.append(byte)
        for b in suffix.as_bytes():
            out.append(b)
        return out^

    def as_slice(ref bytes: List[Byte]) -> StringSlice[origin_of(bytes)]:
        return StringSlice(unsafe_from_utf8=Span(bytes))

    for byte in [Byte(0x00), Byte(0x01), Byte(0x1F)]:
        var data = with_byte('["a', byte, 'a"]')
        with assert_raises():
            _ = from_json[Value](as_slice(data))
        with assert_raises():
            _ = from_json[Document](as_slice(data))


def test_raw_control_byte_in_string_rejected_via_reflection() raises:
    def with_byte(
        prefix: StringSlice, byte: Byte, suffix: StringSlice
    ) -> List[Byte]:
        var out = List[Byte]()
        for b in prefix.as_bytes():
            out.append(b)
        out.append(byte)
        for b in suffix.as_bytes():
            out.append(b)
        return out^

    def as_slice(ref bytes: List[Byte]) -> StringSlice[origin_of(bytes)]:
        return StringSlice(unsafe_from_utf8=Span(bytes))

    var data = with_byte('["a', 0, 'a"]')
    with assert_raises():
        _ = from_json[List[String]](as_slice(data))


def test_raw_nul_in_object_key_is_rejected() raises:
    def with_byte(
        prefix: StringSlice, byte: Byte, suffix: StringSlice
    ) -> List[Byte]:
        var out = List[Byte]()
        for b in prefix.as_bytes():
            out.append(b)
        out.append(byte)
        for b in suffix.as_bytes():
            out.append(b)
        return out^

    def as_slice(ref bytes: List[Byte]) -> StringSlice[origin_of(bytes)]:
        return StringSlice(unsafe_from_utf8=Span(bytes))

    var data = with_byte('{"a', 0, 'b":1}')
    with assert_raises():
        _ = from_json[Value](as_slice(data))
    with assert_raises():
        _ = from_json[Document](as_slice(data))


def test_raw_nul_in_top_level_string_is_rejected() raises:
    def with_byte(
        prefix: StringSlice, byte: Byte, suffix: StringSlice
    ) -> List[Byte]:
        var out = List[Byte]()
        for b in prefix.as_bytes():
            out.append(b)
        out.append(byte)
        for b in suffix.as_bytes():
            out.append(b)
        return out^

    def as_slice(ref bytes: List[Byte]) -> StringSlice[origin_of(bytes)]:
        return StringSlice(unsafe_from_utf8=Span(bytes))

    var data = with_byte('"a', 0, 'a"')
    with assert_raises():
        _ = from_json[Value](as_slice(data))
    with assert_raises():
        _ = from_json[Document](as_slice(data))


def test_raw_control_byte_rejected_at_every_scanner_boundary() raises:
    def with_byte(
        prefix: StringSlice, byte: Byte, suffix: StringSlice
    ) -> List[Byte]:
        var out = List[Byte]()
        for b in prefix.as_bytes():
            out.append(b)
        out.append(byte)
        for b in suffix.as_bytes():
            out.append(b)
        return out^

    def as_slice(ref bytes: List[Byte]) -> StringSlice[origin_of(bytes)]:
        return StringSlice(unsafe_from_utf8=Span(bytes))

    # Filler string elements used only to push the "a<NUL>a" string's
    # opening quote to a chosen offset in the overall buffer.
    var filler40 = String()
    for _ in range(4):
        filler40 += "0123456789"

    var filler120 = String()
    for _ in range(12):
        filler120 += "0123456789"

    # (a) "a<NUL>a" first in a 50-byte array: opens with >= SIMD8_WIDTH
    # bytes remaining, so the SIMD scanner handles it.
    var simd_path = with_byte('["a', 0, 'a","' + filler40 + '"]')
    with assert_raises():
        _ = from_json[Value](as_slice(simd_path))
    with assert_raises():
        _ = from_json[Document](as_slice(simd_path))

    # (b) "a<NUL>a" last in a 50-byte array: opens with < SIMD8_WIDTH bytes
    # remaining, so the unpadded parse falls back to the serial scanner.
    var serial_path = with_byte('["' + filler40 + '","a', 0, 'a"]')
    with assert_raises():
        _ = from_json[Value](as_slice(serial_path))
    with assert_raises():
        _ = from_json[Document](as_slice(serial_path))

    # (c) "a<NUL>a" last in a >=130-byte array: total length crosses
    # PAD_INPUT_THRESHOLD, so the padded engine (always SIMD) handles it.
    var padded_path = with_byte('["' + filler120 + '","a', 0, 'a"]')
    with assert_raises():
        _ = from_json[Value](as_slice(padded_path))
    with assert_raises():
        _ = from_json[Document](as_slice(padded_path))


def test_escaped_and_printable_bytes_still_accepted() raises:
    def with_byte(
        prefix: StringSlice, byte: Byte, suffix: StringSlice
    ) -> List[Byte]:
        var out = List[Byte]()
        for b in prefix.as_bytes():
            out.append(b)
        out.append(byte)
        for b in suffix.as_bytes():
            out.append(b)
        return out^

    def as_slice(ref bytes: List[Byte]) -> StringSlice[origin_of(bytes)]:
        return StringSlice(unsafe_from_utf8=Span(bytes))

    # A properly-escaped NUL (a six-character escape sequence, no raw
    # byte) decodes to a single NUL byte, giving a 3-byte string element.
    var escaped_nul = from_json[Value]('["a\\u0000a"]')
    assert_equal(escaped_nul.array()[0].string().byte_length(), 3)

    # Raw DEL (0x7F) is not a control character under RFC 8259 SS7 and must
    # still be accepted unescaped.
    var del_data = with_byte('["a', 0x7F, 'a"]')
    _ = from_json[Value](as_slice(del_data))
    _ = from_json[Document](as_slice(del_data))

    # An escaped newline (backslash-n, not a raw LF byte) continues to
    # parse correctly.
    _ = from_json[Value]('["a\\na"]')
    _ = from_json[Document]('["a\\na"]')


# ===========================================================================
# [F3] `minify` reads past the end of a truncated string
# The string branch of `minify` never checked whether an escape (or a
# fallback chunk) ran the cursor off the end of the input before loading
# another `StringBlock` there; an unterminated escape let it walk past the
# buffer and copy garbage bytes into the output instead of raising.
# ===========================================================================


def test_minify_rejects_string_whose_escape_runs_into_eof() raises:
    # quote, backslash: the escape has no body
    with assert_raises():
        _ = minify('"\\')
    # quote, backslash, quote: the escape consumes the closing quote
    with assert_raises():
        _ = minify('"\\"')
    with assert_raises():
        _ = minify('["\\"]')
    # well-formed neighbours must be untouched
    assert_equal(minify('"a\\\\"'), '"a\\\\"')
    assert_equal(minify('"a\\""'), '"a\\""')
    assert_equal(minify('{"a": "x y"}'), '{"a":"x y"}')


# ===========================================================================
# [F4] The recursive `Value`/`Document` parsers have no nesting-depth limit
# The tape builder (`tape_indexed.mojo`) caps container nesting against a
# fixed-size scope stack, but the recursive-descent `Value` parser recurses
# on every open bracket with no counter at all — deeply nested input can
# overflow the call stack instead of raising a clean parse error.
# ===========================================================================


def _nested(open: String, close: String, n: Int, middle: String) -> String:
    var s = String()
    for _ in range(n):
        s += open
    s += middle
    for _ in range(n):
        s += close
    return s^


def test_nesting_at_the_limit_parses_on_every_strategy() raises:
    var ok = _nested("[", "]", 1024, "")
    _ = from_json[Value](ok)
    _ = from_json[Document](ok)


def test_nesting_beyond_the_limit_is_rejected_not_a_crash() raises:
    var arrays = _nested("[", "]", 1025, "")
    with assert_raises():
        _ = from_json[Value](arrays)
    with assert_raises():
        _ = from_json[Document](arrays)
    var objects = _nested('{"a":', "}", 1025, "1")
    with assert_raises():
        _ = from_json[Value](objects)
    with assert_raises():
        _ = from_json[Document](objects)
    # reflection reaches the same parser through `Value`-typed elements
    var via_reflection = _nested("[", "]", 2000, "")
    with assert_raises():
        _ = from_json[List[Value]](via_reflection)
    # 50 000 levels used to segfault `Value`; it must now be a clean raise
    var deep = _nested("[", "]", 50_000, "")
    with assert_raises():
        _ = from_json[Value](deep)


def test_minify_trailing_whitespace_does_not_over_read() raises:
    var doc = String('{"a":"xy"}')
    var padded = doc + String(" ") * 45
    assert_equal(minify(padded), doc)
    var spaces_only = String(" ") * 40
    assert_equal(minify(spaces_only), "")
    var leading = String(" ") * 20 + "[1, 2]" + String(" ") * 33
    assert_equal(minify(leading), "[1,2]")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
