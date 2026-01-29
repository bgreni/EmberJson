from emberjson.array import Array
from emberjson import Object
from emberjson.value import Null, Value
from emberjson import parse
from testing import (
    assert_equal,
    assert_true,
    assert_false,
    assert_not_equal,
    TestSuite,
)


def test_array():
    var s = '[ 1, 2, "foo" ]'
    var arr = Array(parse_string=s)
    assert_equal(len(arr), 3)
    assert_equal(arr[0].int(), 1)
    assert_equal(arr[1].int(), 2)
    assert_equal(arr[2].string(), "foo")
    assert_equal(String(arr), '[1,2,"foo"]')
    arr[0] = 10
    assert_equal(arr[0].int(), 10)


def test_array_no_space():
    var s = '[1,2,"foo"]'
    var arr = Array(parse_string=s)
    assert_equal(len(arr), 3)
    assert_equal(arr[0].int(), 1)
    assert_equal(arr[1].int(), 2)
    assert_equal(arr[2].string(), "foo")


def test_nested_object():
    var s = '[false, null, [4.0], { "key": "bar" }]'
    var arr = Array(parse_string=s)
    assert_equal(len(arr), 4)
    assert_equal(arr[0].bool(), False)
    assert_equal(arr[1].null(), Null())
    ref nested_arr = arr[2].array()
    assert_equal(len(nested_arr), 1)
    assert_equal(nested_arr[0].float(), 4.0)
    ref ob = arr[3].object()
    assert_true("key" in ob)
    assert_equal(ob["key"].string(), "bar")


def test_contains():
    var s = '[false, 123, "str"]'
    var arr = Array(parse_string=s)
    assert_true(False in arr)
    assert_true(123 in arr)
    assert_true(String("str") in arr)
    assert_false(True in arr)
    assert_true(True not in arr)


def test_variadic_init():
    var arr = Array(123, "foo", Null())
    var ob = Object()
    ob["key"] = "value"

    var arr2 = Array(45, 45.5, Float64(45.5), arr.copy(), ob^)
    assert_equal(arr[0].int(), 123)
    assert_equal(arr[1].string(), "foo")
    assert_equal(arr[2].null(), Null())

    assert_equal(arr2[0], 45)
    assert_equal(arr2[1], 45.5)
    assert_equal(arr2[2], 45.5)
    assert_true(arr2[3].isa[Array]())
    assert_true(arr2[4].isa[Object]())


def test_equality():
    var arr1 = Array(123, 456)
    var arr2 = Array(123, 456)
    var arr3 = Array(123, "456")
    assert_equal(arr1, arr2)
    assert_not_equal(arr1, arr3)


def test_list_ctr():
    var l: List[Value] = [123, "foo", Null(), False]
    var arr = Array(l^)
    assert_equal(arr[0].int(), 123)
    assert_equal(arr[1].string(), "foo")
    assert_equal(arr[2].null(), Null())
    assert_equal(arr[3].bool(), False)

    assert_equal(arr.to_list(), [123, "foo", Null(), False])


def test_iter():
    var arr = Array(False, 123, None)

    var i = 0
    for el in arr:
        assert_equal(el, arr[i])
        i += 1

    i = 2
    for el in arr.reversed():
        assert_equal(el, arr[i])
        i -= 1


def test_list_literal():
    var a: Array = [123, 435, False, None, 12.32, "string"]
    assert_equal(a, Array(123, 435, False, None, 12.32, "string"))


def test_parse_simple_array():
    var s = "[123, 345]"
    var json = parse(s)
    assert_true(json.is_array())
    assert_equal(json.array()[0].int(), 123)
    assert_equal(json.array()[1].int(), 345)
    assert_equal(json.array()[0].int(), 123)

    assert_equal(String(json), "[123,345]")

    assert_equal(len(json), 2)

    json = parse("[1, 2, 3]")
    assert_true(json.is_array())
    assert_equal(json.array()[0], 1)
    assert_equal(json.array()[1], 2)
    assert_equal(json.array()[2], 3)


def test_setter_array_generic():
    var arr = parse('[123, "foo"]')
    arr.array()[0] = Null()
    assert_true(arr.array()[0].is_null())
    assert_equal(arr.array()[1], "foo")


def test_stringify_array_generic():
    var arr = parse('[123,"foo",false,null]')
    assert_equal(String(arr), '[123,"foo",false,null]')


def main():
    TestSuite.discover_tests[__functions_in_module()]().run()
