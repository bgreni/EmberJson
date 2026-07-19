from emberjson import (
    parse,
    parse_pointer,
    try_parse_pointer,
    to_string,
    PointerIndex,
    Value,
)
from std.testing import (
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
    TestSuite,
)


comptime DOC = (
    '{"a": {"b": [10, 20, {"c": "deep"}]}, "n": -5, "s": "str", "t": true,'
    ' "z": null, "0": "int-keyed", "sla/sh": 1, "til~de": 2, "esc\\u0062d":'
    ' 3, "arr": [[1, 2], [3, 4]]}'
)


def test_basic_paths() raises:
    var v = parse(DOC)
    comptime paths = [
        "/a",
        "/a/b",
        "/a/b/0",
        "/a/b/1",
        "/a/b/2",
        "/a/b/2/c",
        "/n",
        "/s",
        "/t",
        "/z",
        "/arr/1/0",
        "",
    ]
    comptime for i in range(len(paths)):
        comptime p = paths[i]
        var got = parse_pointer(DOC, p)
        ref want = v.get(PointerIndex(p))
        assert_true(got == want, String("mismatch at path: ") + p)


def test_pointer_semantics() raises:
    # RFC 6901 escaping: ~1 -> / and ~0 -> ~
    assert_equal(parse_pointer(DOC, "/sla~1sh").int(), 1)
    assert_equal(parse_pointer(DOC, "/til~0de").int(), 2)
    # Integer tokens double as object keys.
    assert_equal(parse_pointer(DOC, "/0").string(), "int-keyed")
    # Document keys containing JSON escapes match their decoded spelling.
    assert_equal(parse_pointer(DOC, "/escbd").int(), 3)


def test_errors() raises:
    with assert_raises():
        _ = parse_pointer(DOC, "/missing")
    with assert_raises():
        _ = parse_pointer(DOC, "/a/b/3")  # index out of bounds
    with assert_raises():
        _ = parse_pointer(DOC, "/a/b/x")  # string token against array
    with assert_raises():
        _ = parse_pointer(DOC, "/n/deeper")  # traverse a primitive
    with assert_raises():
        _ = parse_pointer(DOC, "bad-pointer")  # must start with /
    with assert_raises():
        _ = parse_pointer('{"a": nope}', "/a")  # target itself malformed

    assert_false(Bool(try_parse_pointer(DOC, "/missing")))
    assert_true(Bool(try_parse_pointer(DOC, "/n")))


def test_off_path_contract() raises:
    # Bytes that are only skipped over are not grammar-validated: this is
    # the documented contract of partial access. Both siblings before and
    # after the target may be garbage scalars.
    var s = '{"bad": nope, "good": 1, "worse": 12x34}'
    assert_equal(parse_pointer(s, "/good").int(), 1)
    # The same document is rejected by the full parser.
    with assert_raises():
        _ = parse(s)

    # Structural sanity of skipped regions IS still required.
    with assert_raises():
        _ = parse_pointer('{"bad": [1, {, "good": 1}', "/good")


def test_empty_pointer_full_validation() raises:
    # The empty pointer parses the whole document with full validation.
    var v = parse_pointer('{"a": 1}', "")
    assert_equal(v["a"].int(), 1)
    with assert_raises():
        _ = parse_pointer('{"a": nope}', "")


def test_corpus_paths() raises:
    comptime cases = [
        ("bench_data/data/twitter.json", "/search_metadata/count"),
        ("bench_data/data/twitter.json", "/statuses/0/id"),
        ("bench_data/data/twitter.json", "/statuses/99/user/screen_name"),
        ("bench_data/data/citm_catalog.json", "/areaNames"),
        ("bench_data/data/citm_catalog.json", "/performances/0/id"),
        ("bench_data/data/citm_catalog_minify.json", "/performances/0/id"),
        ("bench_data/data/canada.json", "/type"),
    ]
    comptime for i in range(len(cases)):
        comptime path = cases[i][0]
        comptime pointer = cases[i][1]
        var data: String
        with open(path, "r") as f:
            data = f.read()
        var got = parse_pointer(data, pointer)
        var v = parse(data)
        ref want = v.get(PointerIndex(pointer))
        assert_equal(
            to_string(got),
            to_string(want),
            String("corpus mismatch: ") + path + " " + pointer,
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
