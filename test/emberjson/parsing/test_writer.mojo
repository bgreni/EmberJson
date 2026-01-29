from emberjson import parse, minify, write_pretty
from testing import assert_equal, TestSuite
from sys.param_env import is_defined


@always_inline
fn files_enabled() -> Bool:
    return not is_defined["DISABLE_TEST_FILES"]()


def test_minify():
    assert_equal(
        minify('{"key"\r\n: \t123\n, "k": \r\t[123, false, [1, \r2,   3]]}'),
        '{"key":123,"k":[123,false,[1,2,3]]}',
    )


def test_minify_citm_catalog():
    @parameter
    if files_enabled():
        with open("./bench_data/data/citm_catalog.json", "r") as formatted:
            with open(
                "./bench_data/data/citm_catalog_minify.json", "r"
            ) as minified:
                assert_equal(minify(formatted.read()), minified.read())


def test_pretty_print_array():
    var arr = parse('[123,"foo",false,null]')
    var expected: String = """[
    123,
    "foo",
    false,
    null
]"""
    assert_equal(expected, write_pretty(arr))

    expected = """[
iamateapot123,
iamateapot"foo",
iamateapotfalse,
iamateapotnull
]"""
    assert_equal(expected, write_pretty(arr, indent=String("iamateapot")))

    arr = parse('[123,"foo",false,{"key": null}]')
    expected = """[
    123,
    "foo",
    false,
    {
        "key": null
    }
]"""

    assert_equal(expected, write_pretty(arr))


def test_pretty_print_object():
    var ob = parse('{"k1": null, "k2": 123}')
    var expected = """{
    "k1": null,
    "k2": 123
}""".as_string_slice()
    assert_equal(expected, write_pretty(ob))

    ob = parse('{"key": 123, "k": [123, false, null]}')

    expected = """{
    "k": [
        123,
        false,
        null
    ],
    "key": 123
}""".as_string_slice()

    assert_equal(expected, write_pretty(ob))

    ob = parse('{"key": 123, "k": [123, false, [1, 2, 3]]}')
    expected = """{
    "k": [
        123,
        false,
        [
            1,
            2,
            3
        ]
    ],
    "key": 123
}""".as_string_slice()
    assert_equal(expected, write_pretty(ob))


def main():
    TestSuite.discover_tests[__functions_in_module()]().run()
