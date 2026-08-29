from std.testing import assert_equal, TestSuite
from emberjson._serde import to_json_string


@fieldwise_init
struct Point(Copyable, Movable):
    var x: Int
    var y: Int


def test_struct_serializes_compact() raises:
    assert_equal(to_json_string(Point(1, 2)), String('{"x":1,"y":2}'))


def test_string_is_escaped() raises:
    assert_equal(to_json_string(String('a"b')), String('"a\\"b"'))


def test_float_uses_teju() raises:
    assert_equal(to_json_string(Float64(0.1)), String("0.1"))


def test_list_serializes_as_array() raises:
    var xs: List[Int] = [1, 2, 3]
    assert_equal(to_json_string(xs), String("[1,2,3]"))


def test_pretty_nests_with_indent() raises:
    assert_equal(
        to_json_string[pretty=True](Point(1, 2)),
        String('{\n    "x": 1,\n    "y": 2\n}'),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
