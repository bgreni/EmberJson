from emberjson._index import structural_index
from emberjson.utils import PaddedBuffer
from emberjson.constants import `{`, `}`, `[`, `]`, `:`, `,`, `"`, `\\`
from std.testing import assert_equal, assert_true, TestSuite


def reference_index(s: StringSlice) -> List[UInt32]:
    """Naive scalar mirror of the SIMD structural-index algorithm.

    Structural characters: operators outside strings, every real
    (non-escaped) quote, and the first byte of every scalar run. The
    escape state is tracked globally (backslash parity), matching the
    SIMD escape mask, and the in-string bit for a byte is the string
    state *after* processing it (inclusive prefix-XOR semantics).
    """
    var out = List[UInt32]()
    var bytes = s.as_bytes()
    var backslash_run = 0
    var in_str = False
    var prev_scalar = False
    for i in range(len(bytes)):
        var b = bytes[i]
        var escaped = (backslash_run % 2) == 1
        if b == `\\`:
            backslash_run += 1
        else:
            backslash_run = 0
        var real_quote = (b == `"`) and not escaped
        if real_quote:
            in_str = not in_str
        var is_op = (
            b == `{` or b == `}` or b == `[` or b == `]` or b == `:` or b == `,`
        )
        var is_ws = b == 0x20 or b == 0x09 or b == 0x0A or b == 0x0D
        var structural_op = (is_op and not in_str) or real_quote
        var scalar = not (is_ws or is_op or real_quote or in_str)
        if structural_op or (scalar and not prev_scalar):
            out.append(UInt32(i))
        prev_scalar = scalar
    return out^


def simd_index_unpadded(s: StringSlice) -> List[UInt32]:
    var positions = List[UInt32]()
    structural_index[False](s.unsafe_ptr(), s.byte_length(), positions)
    return positions^


def simd_index_padded(s: StringSlice) raises -> List[UInt32]:
    var buf = PaddedBuffer(s.as_bytes())
    var positions = List[UInt32]()
    var span = buf.span()
    structural_index[True](span.unsafe_ptr(), len(span), positions)
    return positions^


def assert_same_positions(
    a: List[UInt32], b: List[UInt32], label: String
) raises:
    assert_equal(len(a), len(b), label + " (count)")
    for i in range(len(a)):
        # Only build the failure message on mismatch: constructing it
        # eagerly costs more than the comparison over corpus-sized inputs.
        if a[i] != b[i]:
            assert_equal(a[i], b[i], label + " @ entry " + String(i))


def check(s: StringSlice) raises:
    var expected = reference_index(s)
    assert_same_positions(
        simd_index_unpadded(s), expected, "unpadded: " + String(s)
    )
    assert_same_positions(
        simd_index_padded(s), expected, "padded: " + String(s)
    )


def test_basic_documents() raises:
    check("{}")
    check("[]")
    check('{"a":1}')
    check('{"key": [1, 2.5, -3e4], "other": {"nested": true}}')
    check("[true,false,null]")
    check('  { "a" : "b" }  ')
    check('"just a string"')
    check("12345")
    check("")
    check(" ")


def test_strings_mask_structurals() raises:
    # Operators inside strings must not be structural.
    check('{"a":"{[,:]}"}')
    check('["{", "}", "[", "]", ":", ","]')
    # Escaped quotes stay inside the string.
    check(r'{"a":"x\"y"}')
    check(r'["\\", "\\\"", "\\\\"]')
    # Backslash runs of every parity before a quote.
    check(r'"a\"b"')
    check(r'"a\\"')
    check(r'"a\\\"b"')


def test_scalar_starts() raises:
    # Adjacent scalars separated by whitespace each get one start.
    check("1 2 3")
    check("true false")
    # Scalar right after a closing quote is pseudo-structural.
    check('"a"x')
    # Scalar runs are single tokens.
    check("truefalsenull")


def test_chunk_boundary_strings() raises:
    # Strings and escapes spanning the 64-byte chunk boundary.
    for pad in range(55, 75):
        var prefix = String("[") + '"' + String("a") * pad
        check(prefix + '"]')
        check(prefix + r"\"x" + '"]')
        check(prefix + r"\\" + '"]')
        check(prefix + r"\\\"" + '"]')
    # Backslash run crossing the boundary exactly.
    for run in range(1, 6):
        var s = String('"') + String("a") * (63 - run)
        s += String("\\") * run
        s += 'q"'
        check(s)
    # The recorded misclassification case for the naive run-start escape
    # scanner: an escaped backslash at the chunk boundary followed by more
    # backslashes, then a quote. Sweep runs starting at every offset that
    # straddles the 64-byte edge.
    for start in range(58, 70):
        for run in range(1, 8):
            var s = String('"') + String("a") * start
            s += String("\\") * run
            s += '"'
            # Odd runs escape the quote; append a real terminator.
            if run % 2 == 1:
                s += '"'
            check(s)


def test_chunk_boundary_scalars_and_ws() raises:
    # Long whitespace runs and scalar runs crossing chunk edges.
    check(String(" ") * 100 + "1")
    check(String("1") * 100)
    check(String(" ") * 63 + "[1]")
    check("[" + String(" ") * 70 + "1]")
    var many = String("[")
    for i in range(50):
        if i > 0:
            many += ","
        many += String(i)
    many += "]"
    check(many)


def test_corpus_files() raises:
    for name in [
        "bench_data/data/twitter.json",
        "bench_data/data/citm_catalog.json",
        "bench_data/data/citm_catalog_minify.json",
        "bench_data/data/canada.json",
        "bench_data/users_1k.json",
    ]:
        with open(name, "r") as f:
            var content = f.read()
            var expected = reference_index(content)
            assert_true(len(expected) > 0)
            assert_same_positions(
                simd_index_unpadded(content), expected, name + " unpadded"
            )
            assert_same_positions(
                simd_index_padded(content), expected, name + " padded"
            )


def test_classifier_exhaustive() raises:
    # Every byte value 0..255, laid out over four 64-byte chunks: the
    # classifier (whichever path is active) must match the scalar
    # predicates exactly.
    from emberjson._index.classifier import classify
    from emberjson._index.simd_ops import SimdInput

    var bytes = InlineArray[Byte, 256](fill=0)
    for i in range(256):
        bytes[i] = Byte(i)
    for chunk in range(4):
        var input = SimdInput.load(bytes.unsafe_ptr().unsafe_offset(chunk * 64))
        var block = classify(input)
        for lane in range(64):
            var b = Int(bytes[chunk * 64 + lane])
            var expect_op = (
                b == 0x7B
                or b == 0x7D
                or b == 0x5B
                or b == 0x5D
                or b == 0x3A
                or b == 0x2C
            )
            var expect_ws = b == 0x20 or b == 0x09 or b == 0x0A or b == 0x0D
            assert_equal(
                (block.op >> UInt64(lane)) & 1,
                UInt64(1 if expect_op else 0),
                "op mismatch for byte " + String(b),
            )
            assert_equal(
                (block.whitespace >> UInt64(lane)) & 1,
                UInt64(1 if expect_ws else 0),
                "ws mismatch for byte " + String(b),
            )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
