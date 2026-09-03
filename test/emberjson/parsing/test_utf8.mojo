from emberjson import (
    is_valid_utf8,
    from_json,
    parse_pointer,
    ParseOptions,
    Value,
    Document,
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
        _ = from_json[Value](bad)
    with assert_raises():
        _ = from_json[Document](bad)
    with assert_raises():
        _ = parse_pointer(bad, "/a")
    with assert_raises():
        _ = Value(parse_bytes=Span(bytes))

    # Opting out for trusted/raw input: the tape engine carries the raw
    # bytes through its arena untouched.
    comptime unchecked = ParseOptions(validate_utf8=False)
    var d0 = from_json[Document, unchecked](bad)
    assert_true(d0.root()["a"].is_string())

    # Valid multibyte content passes by default.
    var good = String('{"a": "héllo 🔥"}')
    assert_equal(from_json[Value](good)["a"].string(), "héllo 🔥")
    var d = from_json[Document](good)
    assert_equal(d.root()["a"].string(), "héllo 🔥")
    assert_equal(parse_pointer(good, "/a").string(), "héllo 🔥")


def test_satsub_exhaustive() raises:
    """Saturating unsigned subtract over every byte pair, at every width
    the UTF-8 kernel could be instantiated at."""
    _check_satsub[16]()
    _check_satsub[32]()


def _check_satsub[W: Int]() raises:
    from emberjson._utf8 import _satsub
    from emberjson.simd import SIMD8

    for x in range(256):
        var a = SIMD8[W](Byte(x))
        # Sweep b across all 256 values, W lanes at a time.
        for base in range(0, 256, W):
            var b = SIMD8[W](0)
            for lane in range(W):
                b[lane] = Byte((base + lane) % 256)
            var got = _satsub[W](a, b)
            for lane in range(W):
                var want = Byte(0) if Int(b[lane]) > x else Byte(
                    x - Int(b[lane])
                )
                assert_equal(
                    got[lane],
                    want,
                    "satsub W="
                    + String(W)
                    + " a="
                    + String(x)
                    + " b="
                    + String(Int(b[lane])),
                )


def _utf8_corpus() -> List[List[Byte]]:
    """Inputs that exercise chunk boundaries, truncation and every lead
    byte class."""
    var out = List[List[Byte]]()

    # Every byte value at every offset in a 200-byte ASCII field: this
    # crosses every chunk boundary and every phase at widths 16/32/64.
    for off in range(0, 200):
        for b in range(0, 256, 7):  # stride keeps the suite quick
            var buf = List[Byte]()
            for i in range(200):
                buf.append(Byte(ord("a")) if i != off else Byte(b))
            out.append(buf^)

    # Lengths that are exact multiples of 64, so the driver's
    # "input ended on a chunk boundary" branch (`error |= prev_incomplete`,
    # the only consumer of `_make_max_value[W]` at the end of input) is
    # reached at W=16, 32 AND 64 -- the 200-byte cases above always take
    # the partial-tail path at 32 and 64.
    var seqs = List[List[Byte]]()
    seqs.append([Byte(0xC3), Byte(0xA9)])
    seqs.append([Byte(0xE2), Byte(0x82), Byte(0xAC)])
    seqs.append([Byte(0xF0), Byte(0x9F), Byte(0x94), Byte(0xA5)])

    for L in [64, 128, 192]:
        # Pure ASCII: must be accepted.
        var ascii_buf = List[Byte]()
        for _ in range(L):
            ascii_buf.append(Byte(ord("a")))
        out.append(ascii_buf^)

        for si in range(len(seqs)):
            ref seq = seqs[si]
            # A complete multi-byte sequence ending exactly on the
            # boundary: accepted.
            var ok = List[Byte]()
            for _ in range(L - len(seq)):
                ok.append(Byte(ord("a")))
            for k in range(len(seq)):
                ok.append(seq[k])
            out.append(ok^)

            # The same sequence truncated, padded back to L with leading
            # ASCII, so the lead dangles at the true end of input with no
            # continuation after it: must be rejected. This is what
            # `prev_incomplete` exists to catch on the boundary branch.
            for cut in range(1, len(seq)):
                var kept = len(seq) - cut
                var bad = List[Byte]()
                for _ in range(L - kept):
                    bad.append(Byte(ord("a")))
                for k in range(kept):
                    bad.append(seq[k])
                out.append(bad^)

    # Every prefix of real multi-byte text, so each truncation of each
    # sequence is covered.
    var samples = List[String]()
    samples.append("héllo wörld")
    samples.append("日本語テキスト")
    samples.append("emoji 🎉🎊 and 𝔘𝔫𝔦𝔠𝔬𝔡𝔢")
    for s in samples:
        var bs = s.as_bytes()
        for n in range(0, len(bs) + 1):
            var t = List[Byte]()
            for k in range(n):
                t.append(bs[k])
            out.append(t^)
    return out^


def test_utf8_simd_matches_scalar_at_every_width() raises:
    """The width-generic kernel at every width it could be instantiated
    at, against the scalar reference."""
    from emberjson._utf8 import _is_valid_utf8_simd, _is_valid_utf8_scalar
    from emberjson.simd import HAS_BYTE_SHUFFLE

    comptime if HAS_BYTE_SHUFFLE:
        var corpus = _utf8_corpus()
        for item in corpus:
            var p = item.unsafe_ptr()
            var n = len(item)
            var want = _is_valid_utf8_scalar(p, n)
            assert_equal(_is_valid_utf8_simd[16](p, n), want, "W=16")
            assert_equal(_is_valid_utf8_simd[32](p, n), want, "W=32")
            # Not shipped (KERNEL_WIDTH is capped at 32), tested so
            # raising the cap is a one-line change.
            assert_equal(_is_valid_utf8_simd[64](p, n), want, "W=64")


def test_utf8_no_shuffle_matches_scalar() raises:
    """The no-shuffle fallback cannot be selected on either development
    machine, so it is called directly -- otherwise it would be dead code
    in every run of this suite."""
    from emberjson._utf8 import (
        _is_valid_utf8_no_shuffle,
        _is_valid_utf8_scalar,
    )

    var corpus = _utf8_corpus()
    for item in corpus:
        var p = item.unsafe_ptr()
        var n = len(item)
        assert_equal(
            _is_valid_utf8_no_shuffle(p, n),
            _is_valid_utf8_scalar(p, n),
            "no-shuffle path",
        )


def test_utf8_no_shuffle_pure_ascii() raises:
    """A pure-ASCII document must never reach the scalar validator, and
    must still be accepted at every length including chunk multiples."""
    from emberjson._utf8 import _is_valid_utf8_no_shuffle

    for n in range(0, 200):
        var buf = List[Byte]()
        for _ in range(n):
            buf.append(Byte(ord("x")))
        assert_true(
            _is_valid_utf8_no_shuffle(buf.unsafe_ptr(), n),
            "ascii length " + String(n),
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
