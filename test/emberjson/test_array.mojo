from emberjson.array import Array
from emberjson import Object
from emberjson.value import Null, Value
from testing import assert_equal, assert_true, assert_false, assert_not_equal


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
    var nested_arr = arr[2].array()
    assert_equal(len(nested_arr), 1)
    assert_equal(nested_arr[0].float(), 4.0)
    var ob = arr[3].object()
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

    var arr2 = Array(45, 45.5, Float64(45.5), arr, ob)
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
    var arr = Array(List[Value](123, "foo", Null(), False))
    assert_equal(arr[0].int(), 123)
    assert_equal(arr[1].string(), "foo")
    assert_equal(arr[2].null(), Null())
    assert_equal(arr[3].bool(), False)

    assert_equal(arr.to_list(), List[Value](123, "foo", Null(), False))


def test_iter():
    var arr = Array(False, 123, None)

    var i = 0
    for el in arr:
        assert_equal(el[], arr[i])
        i += 1

    i = 2
    for el in arr.reversed():
        assert_equal(el[], arr[i])
        i -= 1


def test_list_literal():
    var a: Array = [123, 435, False, None, 12.32, "string"]
    assert_equal(a, Array(123, 435, False, None, 12.32, "string"))
