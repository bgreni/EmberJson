from emberjson import (
    is_valid_utf8,
    parse,
    parse_document,
    parse_pointer,
    ParseOptions,
    Value,
)
from emberjson._utf8 import _is_valid_utf8_scalar
from std.testing import (
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
    TestSuite,
)


def check_both(bytes: List[Byte], expected: Bool, label: String) raises:
    """The dispatching validator (NEON at runtime) and the scalar
    reference must agree, and match the expectation."""
    var span = Span(bytes)
    assert_equal(is_valid_utf8(span), expected, label + " (dispatch)")
    assert_equal(
        _is_valid_utf8_scalar(span.unsafe_ptr(), len(span)),
        expected,
        label + " (scalar)",
    )


def sweep(pattern: List[Byte], expected: Bool, label: String) raises:
    """Places `pattern` at every offset around the 16-byte chunk
    boundaries (ASCII padding before, one ASCII byte after)."""
    for pad in range(0, 40):
        var buf = List[Byte]()
        for _ in range(pad):
            buf.append(0x61)
        for b in pattern:
            buf.append(b)
        buf.append(0x62)
        check_both(buf, expected, label + " @pad " + String(pad))


def sweep_at_end(pattern: List[Byte], expected: Bool, label: String) raises:
    """Like `sweep` but the pattern terminates the input (exercises the
    dangling-sequence checks, including exact chunk-boundary ends)."""
    for pad in range(0, 40):
        var buf = List[Byte]()
        for _ in range(pad):
            buf.append(0x61)
        for b in pattern:
            buf.append(b)
        check_both(buf, expected, label + " @end pad " + String(pad))


def test_valid_sequences() raises:
    sweep([0xC3, 0xA9], True, "é")
    sweep([0xE2, 0x82, 0xAC], True, "€")
    sweep([0xF0, 0x9F, 0x94, 0xA5], True, "🔥")
    # Boundary code points.
    sweep([0x7F], True, "U+007F")
    sweep([0xC2, 0x80], True, "U+0080")
    sweep([0xDF, 0xBF], True, "U+07FF")
    sweep([0xE0, 0xA0, 0x80], True, "U+0800")
    sweep([0xED, 0x9F, 0xBF], True, "U+D7FF (below surrogates)")
    sweep([0xEE, 0x80, 0x80], True, "U+E000 (above surrogates)")
    sweep([0xEF, 0xBF, 0xBF], True, "U+FFFF")
    sweep([0xF0, 0x90, 0x80, 0x80], True, "U+10000")
    sweep([0xF4, 0x8F, 0xBF, 0xBF], True, "U+10FFFF")
    sweep_at_end([0xF0, 0x9F, 0x94, 0xA5], True, "🔥 at end")
    check_both(List[Byte](), True, "empty input")


def test_invalid_sequences() raises:
    sweep([0x80], False, "bare continuation")
    sweep([0xC0, 0xAF], False, "overlong 2-byte")
    sweep([0xC1, 0xBF], False, "overlong 2-byte C1")
    sweep([0xE0, 0x80, 0x80], False, "overlong 3-byte")
    sweep([0xF0, 0x80, 0x80, 0x80], False, "overlong 4-byte")
    sweep([0xED, 0xA0, 0x80], False, "surrogate U+D800")
    sweep([0xED, 0xBF, 0xBF], False, "surrogate U+DFFF")
    sweep([0xF4, 0x90, 0x80, 0x80], False, "above U+10FFFF")
    sweep([0xF5, 0x80, 0x80, 0x80], False, "invalid lead F5")
    sweep([0xFF], False, "invalid byte FF")
    sweep([0xE2, 0x28, 0xA1], False, "broken continuation")
    sweep([0xC3], False, "truncated lead mid-input")
    # Truncations at the true end of input.
    sweep_at_end([0xC3], False, "dangling 2-byte lead")
    sweep_at_end([0xE2, 0x82], False, "dangling 3-byte lead")
    sweep_at_end([0xF0, 0x9F, 0x94], False, "dangling 4-byte lead")


def test_corpus_is_valid() raises:
    comptime files = [
        "bench_data/data/twitter.json",
        "bench_data/data/citm_catalog.json",
        "bench_data/data/canada.json",
    ]
    comptime for i in range(len(files)):
        comptime path = files[i]
        var data: String
        with open(path, "r") as f:
            data = f.read()
        assert_true(is_valid_utf8(StringSlice(data)))


def test_utf8_validation_default_on() raises:
    # {"a": "<C0 80>"} — invalid UTF-8 inside a string value, which the
    # parser's scanners do not themselves reject. Kept as raw bytes viewed
    # through a StringSlice: `String(unsafe_from_utf8=...)` debug-asserts
    # validity under -D ASSERT=all, both here and inside the DOM parser's
    # string materialization.
    var prefix = String('{"a": "')
    var suffix = String('"}')
    var bytes = List[Byte]()
    for b in prefix.as_bytes():
        bytes.append(b)
    bytes.append(0xC0)
    bytes.append(0x80)
    for b in suffix.as_bytes():
        bytes.append(b)
    var bad = StringSlice(unsafe_from_utf8=Span(bytes))

    # Rejected by DEFAULT on every entry point (RFC 8259: JSON text is
    # UTF-8).
    with assert_raises():
        _ = parse(bad)
    with assert_raises():
        _ = parse_document(bad)
    with assert_raises():
        _ = parse_pointer(bad, "/a")
    with assert_raises():
        _ = Value(parse_bytes=Span(bytes))

    # Opting out for trusted/raw input: the tape engine carries the raw
    # bytes through its arena untouched.
    comptime unchecked = ParseOptions(validate_utf8=False)
    var d0 = parse_document[unchecked](bad)
    assert_true(d0.root()["a"].is_string())

    # Valid multibyte content passes by default.
    var good = String('{"a": "héllo 🔥"}')
    assert_equal(parse(good)["a"].string(), "héllo 🔥")
    var d = parse_document(good)
    assert_equal(d.root()["a"].string(), "héllo 🔥")
    assert_equal(parse_pointer(good, "/a").string(), "héllo 🔥")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
