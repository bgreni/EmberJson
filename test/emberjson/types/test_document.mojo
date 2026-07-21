from emberjson import (
    parse,
    try_parse,
    parse_document,
    try_parse_document,
    to_string,
    Document,
    ParseOptions,
    StrictOptions,
    Value,
)
from std.os import listdir
from emberjson import Parser
from emberjson._deserialize.tape import TapeSink, _Arena
from emberjson._deserialize.tape_indexed import parse_document_tape_indexed
from emberjson.utils import PaddedBuffer


def indexed_doc[
    options: ParseOptions = ParseOptions()
](s: String) raises -> Document:
    """Parses via the stage-1 index + indexed tape builder, padding even
    tiny inputs so every test case exercises the indexed engine."""
    var sink = TapeSink(
        tape_capacity=s.byte_length() // 3 + 8,
        strings_capacity=s.byte_length() // 2 + 16,
    )
    var buf = PaddedBuffer(StringSlice(s).as_bytes())
    var p = Parser[options=options._padded()](padded=buf)
    parse_document_tape_indexed(p, sink)
    var tape = List[UInt64]()
    var strings = _Arena(capacity=0)
    swap(tape, sink.tape)
    swap(strings, sink.strings)
    return Document(
        tape^,
        strings^,
        StrictOptions.ALLOW_DUPLICATE_KEYS in options.strict_mode,
    )


from std.testing import (
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
    TestSuite,
)


def test_scalar_documents() raises:
    var d = parse_document("123")
    assert_true(d.root().is_int())
    assert_equal(d.root().int(), 123)

    var d2 = parse_document("-45")
    assert_equal(d2.root().int(), -45)

    var d3 = parse_document("18446744073709551615")
    assert_true(d3.root().is_uint())
    assert_equal(d3.root().uint(), UInt64.MAX)

    var d4 = parse_document("1.5")
    assert_true(d4.root().is_float())
    assert_equal(d4.root().float(), 1.5)

    var d5 = parse_document("true")
    assert_true(d5.root().is_bool())
    assert_equal(d5.root().bool(), True)

    var d6 = parse_document("false")
    assert_equal(d6.root().bool(), False)

    var d7 = parse_document("null")
    assert_true(d7.root().is_null())

    var d8 = parse_document('"hello"')
    assert_true(d8.root().is_string())
    assert_equal(d8.root().string(), "hello")
    assert_equal(d8.root().string_slice(), "hello")


def test_string_escapes() raises:
    var d = parse_document(r'"a\nb\t\"c\\"')
    assert_equal(d.root().string(), 'a\nb\t"c\\')

    var d2 = parse_document(r'"ü"')
    assert_equal(d2.root().string(), "ü")

    # Surrogate pair for 🔥
    var d3 = parse_document(r'"🔥"')
    assert_equal(d3.root().string(), "🔥")

    # Long enough to exercise the SIMD scan path
    var long_str = '"some example string of short length, not all that long"'
    var d4 = parse_document(long_str)
    assert_equal(
        d4.root().string(),
        "some example string of short length, not all that long",
    )

    # Escape beyond the first SIMD chunk
    var d5 = parse_document(r'"0123456789012345678\nrest of the string"')
    assert_equal(d5.root().string(), "0123456789012345678\nrest of the string")


def test_navigation() raises:
    var d = parse_document(
        '{"a": 1, "b": [1, 2.5, "x", null], "c": {"nested": true}, "d": "s"}'
    )
    var root = d.root()
    assert_true(root.is_object())
    assert_equal(len(root), 4)

    var obj = root.object()
    assert_equal(obj["a"].int(), 1)
    assert_true("a" in obj)
    assert_false("nope" in obj)

    var arr = root["b"].array()
    assert_equal(len(arr), 4)
    assert_equal(arr[0].int(), 1)
    assert_equal(arr[1].float(), 2.5)
    assert_equal(arr[2].string(), "x")
    assert_true(arr[3].is_null())

    assert_equal(root["c"]["nested"].bool(), True)
    assert_equal(root["d"].string(), "s")

    # Iteration preserves document order
    var keys = List[String]()
    for entry in obj:
        keys.append(String(entry.key))
    assert_equal(len(keys), 4)
    assert_equal(keys[0], "a")
    assert_equal(keys[1], "b")
    assert_equal(keys[2], "c")
    assert_equal(keys[3], "d")

    var total = 0
    for _ in root["b"].array():
        total += 1
    assert_equal(total, 4)

    with assert_raises():
        _ = obj["missing"]
    with assert_raises():
        _ = arr[4]


def test_empty_containers() raises:
    var d = parse_document('{"empty_obj": {}, "empty_arr": [], "x": 1}')
    assert_equal(len(d.root()["empty_obj"]), 0)
    assert_equal(len(d.root()["empty_arr"]), 0)
    assert_equal(d.root()["x"].int(), 1)

    var d2 = parse_document("[]")
    assert_equal(len(d2.root()), 0)
    var d3 = parse_document("{}")
    assert_equal(len(d3.root()), 0)


comptime PARITY_CASES = [
    "123",
    "-9082",
    "18446744073709551615",
    "1.5e10",
    "-0.25",
    "true",
    "false",
    "null",
    '"hello"',
    r'"esc\napesü🔥"',
    "[]",
    "{}",
    "[1, 2, 3]",
    '{"a": 1}',
    (
        '{"a": [1, 2.5, {"b": null, "c": [true, false, "deep"]}], "s":'
        ' "str", "n": -12, "u": 18446744073709551615, "f": 3.25e-4}'
    ),
    '[[[[1]]], {"k": [{"kk": 2}]}]',
    '{"": "empty key", "e": ""}',
]


def test_to_value_parity() raises:
    comptime for i in range(len(PARITY_CASES)):
        comptime s = PARITY_CASES[i]
        var d = parse_document(s)
        var v = parse(s)
        assert_true(d.to_value() == v, String("to_value mismatch for: ") + s)


def test_to_string_parity() raises:
    comptime for i in range(len(PARITY_CASES)):
        comptime s = PARITY_CASES[i]
        var d = parse_document(s)
        var v = parse(s)
        assert_equal(to_string(d), to_string(v))


def test_padded_path() raises:
    # Build an input comfortably above PAD_INPUT_THRESHOLD (128B) so the
    # PaddedBuffer + unchecked-read engine is exercised.
    var s = String('{"values": [')
    for i in range(50):
        if i > 0:
            s += ", "
        s += String(i)
    s += r'], "name": "padded ü input", "flag": true}'
    assert_true(s.byte_length() >= 128)

    var d = parse_document(s)
    var v = parse(s)
    assert_true(d.to_value() == v)
    assert_equal(to_string(d), to_string(v))
    assert_equal(len(d.root()["values"]), 50)
    assert_equal(d.root()["values"][49].int(), 49)
    assert_equal(d.root()["name"].string(), "padded ü input")


def test_strictness() raises:
    with assert_raises():
        _ = parse_document("[1, 2,]")
    with assert_raises():
        _ = parse_document('{"a": 1,}')
    with assert_raises():
        _ = parse_document('{"a": 1, "a": 2}')

    comptime lenient = ParseOptions(strict_mode=StrictOptions.LENIENT)
    var d = parse_document[lenient]("[1, 2,]")
    assert_equal(len(d.root()), 2)

    # Lenient duplicate keys: last-write-wins, matching the DOM parser.
    var d2 = parse_document[lenient]('{"a": 1, "b": 2, "a": 3}')
    assert_equal(d2.root()["a"].int(), 3)
    var v2 = parse[lenient]('{"a": 1, "b": 2, "a": 3}')
    assert_true(d2.to_value() == v2)


def test_errors() raises:
    comptime bad_cases = [
        "",
        "{",
        "[1,",
        '"abc',
        "tru",
        "falsy",
        "nul",
        '{"a":}',
        "[1 2]",
        '{"a" 1}',
        "1.2.3",
        "{]",
        "[1, 2}}",
        '{"a": 1} trailing',
    ]
    comptime for i in range(len(bad_cases)):
        comptime bad = bad_cases[i]
        with assert_raises():
            _ = parse_document(bad)

    assert_false(Bool(try_parse_document("{")))
    assert_true(Bool(try_parse_document("{}")))


def test_ignore_unicode() raises:
    comptime opts = ParseOptions(ignore_unicode=True)
    var d = parse_document[opts](r'"ü"')
    # Verbatim bytes, escapes left undecoded — same as the DOM parser.
    var v = parse[opts](r'"ü"')
    assert_equal(d.root().string(), v.string())


def test_corpus_parity() raises:
    comptime files = [
        "bench_data/data/twitter.json",
        "bench_data/data/citm_catalog.json",
        "bench_data/data/citm_catalog_minify.json",
        "bench_data/data/canada.json",
    ]
    comptime for i in range(len(files)):
        comptime path = files[i]
        var data: String
        with open(path, "r") as f:
            data = f.read()
        var d = parse_document(data)
        var v = parse(data)
        # Serialized-output comparison instead of `Value.__eq__`: equally
        # strong for parity (order + values), but linear — deep equality
        # is O(n^2) on citm's ~10k-key objects.
        var expected = to_string(v)
        assert_equal(to_string(d), expected)
        assert_equal(to_string(d.to_value()), expected)


def test_indexed_engine_parity() raises:
    comptime for i in range(len(PARITY_CASES)):
        comptime s = PARITY_CASES[i]
        var d = indexed_doc(s)
        var v = parse(s)
        assert_equal(to_string(d), to_string(v))
        assert_true(d.to_value() == v, String("indexed mismatch for: ") + s)

    comptime bad_cases = [
        "",
        "{",
        "[1,",
        '"abc',
        "tru",
        "falsy",
        "nul",
        '{"a":}',
        "[1 2]",
        '{"a" 1}',
        "1.2.3",
        "12x",
        "truex",
        "nullly",
        "{]",
        "[1, 2}}",
        '{"a": 1} trailing',
        "[1, 2,]",
        '{"a": 1,}',
        '{"a": 1, "a": 2}',
        '"a\nb"',
    ]
    comptime for i in range(len(bad_cases)):
        comptime bad = bad_cases[i]
        with assert_raises():
            _ = indexed_doc(bad)

    # Lenient semantics match the byte-walk engine.
    comptime lenient = ParseOptions(strict_mode=StrictOptions.LENIENT)
    var d2 = indexed_doc[lenient]('{"a": 1, "b": 2, "a": 3}')
    assert_equal(d2.root()["a"].int(), 3)
    var d3 = indexed_doc[lenient]("[1, 2,]")
    assert_equal(len(d3.root()), 2)


def test_indexed_engine_corpus() raises:
    comptime files = [
        "bench_data/data/twitter.json",
        "bench_data/data/citm_catalog.json",
        "bench_data/data/citm_catalog_minify.json",
        "bench_data/data/canada.json",
    ]
    comptime for i in range(len(files)):
        comptime path = files[i]
        var data: String
        with open(path, "r") as f:
            data = f.read()
        var d = indexed_doc(data)
        var v = parse(data)
        assert_equal(to_string(d), to_string(v))

    # Verdict agreement over the jsonchecker fixtures.
    var fixtures = listdir("bench_data/data/jsonchecker")
    for f in fixtures:
        if not f.endswith(".json"):
            continue
        var data: String
        with open("bench_data/data/jsonchecker/" + f, "r") as fh:
            data = fh.read()
        var byte_walk_ok = Bool(try_parse(data))
        var indexed_ok: Bool
        try:
            var d = indexed_doc(data)
            indexed_ok = True
            _ = d^
        except:
            indexed_ok = False
        assert_equal(
            byte_walk_ok,
            indexed_ok,
            String("indexed verdict mismatch on ") + f,
        )


def test_jsonchecker_differential() raises:
    # The tape and DOM engines must agree on every jsonchecker fixture:
    # same accept/reject verdict, identical serialization on accept.
    var files = listdir("bench_data/data/jsonchecker")
    var checked = 0
    for f in files:
        if not f.endswith(".json"):
            continue
        var data: String
        with open("bench_data/data/jsonchecker/" + f, "r") as fh:
            data = fh.read()
        var v = try_parse(data)
        var d = try_parse_document(data)
        assert_equal(Bool(v), Bool(d), String("verdict mismatch on ") + f)
        if v and d:
            assert_equal(to_string(d.value()), to_string(v.value()))
        checked += 1
    assert_true(checked >= 30)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
