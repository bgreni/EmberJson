from emberjson import from_json, minify, to_json_pretty, Value
from std.testing import assert_equal, TestSuite
from std.sys import is_defined


@always_inline
def files_enabled() -> Bool:
    return not is_defined["DISABLE_TEST_FILES"]()


def test_minify() raises:
    assert_equal(
        minify('{"key"\r\n: \t123\n, "k": \r\t[123, false, [1, \r2,   3]]}'),
        '{"key":123,"k":[123,false,[1,2,3]]}',
    )


def test_minify_citm_catalog() raises:
    comptime if files_enabled():
        with open("./bench_data/data/citm_catalog.json", "r") as formatted:
            with open(
                "./bench_data/data/citm_catalog_minify.json", "r"
            ) as minified:
                assert_equal(minify(formatted.read()), minified.read())


def test_pretty_print_array() raises:
    var arr = from_json[Value]('[123,"foo",false,null]')
    var expected: String = """[
    123,
    "foo",
    false,
    null
]"""
    assert_equal(expected, to_json_pretty(arr))

    expected = """[
iamateapot123,
iamateapot"foo",
iamateapotfalse,
iamateapotnull
]"""
    assert_equal(expected, to_json_pretty[indent="iamateapot"](arr))

    arr = from_json[Value]('[123,"foo",false,{"key": null}]')
    expected = """[
    123,
    "foo",
    false,
    {
        "key": null
    }
]"""

    assert_equal(expected, to_json_pretty(arr))


def test_pretty_print_object() raises:
    var ob = from_json[Value]('{"k1": null, "k2": 123}')
    var expected = """{
    "k1": null,
    "k2": 123
}""".as_string_slice()
    assert_equal(expected, to_json_pretty(ob))

    ob = from_json[Value]('{"key": 123, "k": [123, false, null]}')

    expected = """{
    "key": 123,
    "k": [
        123,
        false,
        null
    ]
}""".as_string_slice()

    assert_equal(expected, to_json_pretty(ob))

    ob = from_json[Value]('{"key": 123, "k": [123, false, [1, 2, 3]]}')
    expected = """{
    "key": 123,
    "k": [
        123,
        false,
        [
            1,
            2,
            3
        ]
    ]
}""".as_string_slice()
    assert_equal(expected, to_json_pretty(ob))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
