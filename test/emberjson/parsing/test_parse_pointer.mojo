from emberjson import (
    from_json,
    parse_pointer,
    try_parse_pointer,
    to_json,
    DerErrorKind,
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
    var v = from_json[Value](DOC)
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
        _ = from_json[Value](s)

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
        var v = from_json[Value](data)
        ref want = v.get(PointerIndex(pointer))
        assert_equal(
            to_json(got),
            to_json(want),
            String("corpus mismatch: ") + path + " " + pointer,
        )


def test_truncated_document_after_colon_raises_instead_of_aborting() raises:
    var docs: List[String] = ['{"a":', '{"a":{"b":', '{"a": 1, "b": {"c":']
    var paths: List[String] = ["/a", "/a/b", "/b/c"]
    for i in range(len(docs)):
        with assert_raises():
            _ = parse_pointer(docs[i], paths[i])
        assert_false(try_parse_pointer(docs[i], paths[i]))


def test_parse_pointer_agrees_on_escapes() raises:
    assert_equal(parse_pointer('{"h~éllo": 1}', "/h~0éllo").int(), 1)
    with assert_raises():
        _ = parse_pointer('{"x~2y": 16}', "/x~2y")


def test_parse_pointer_raises_typed_errors() raises:
    # The plain-`String`-path overload of `parse_pointer` builds
    # `PointerIndex` inside its own `try`, so this stays exactly the
    # public form documented in the module docstring/README/CLAUDE.md --
    # no local helper or pre-built `PointerIndex` needed.
    var kind = DerErrorKind.Custom
    var raised = False
    try:
        _ = parse_pointer('{"a":1}', "/b")
    except e:
        kind = e.kind
        raised = True
    assert_true(raised)
    assert_equal(kind, DerErrorKind.InvalidValue)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
