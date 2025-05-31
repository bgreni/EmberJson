from testing import assert_equal, assert_true, assert_false, assert_not_equal

from emberjson import RawArray, RawObject, RawValue


def test_array():
    var s = '[ 1, 2, "foo" ]'
    var arr = RawArray(parse_string=s)
    assert_equal(len(arr), 3)
    assert_equal(arr[0].int(), 1)
    assert_equal(arr[1].int(), 2)
    assert_equal(arr[2].string(), "foo")
    assert_equal(String(arr), '[1,2,"foo"]')
    arr[0] = RawValue(parse_string="10")
    assert_equal(arr[0].int(), 10)


def test_array_no_space():
    var s = '[1,2,"foo"]'
    var arr = RawArray(parse_string=s)
    assert_equal(len(arr), 3)
    assert_equal(arr[0].int(), 1)
    assert_equal(arr[1].int(), 2)
    assert_equal(arr[2].string(), "foo")


def test_nested_object():
    var s = '[false, null, [4.0], { "key": "bar" }]'
    var arr = RawArray(parse_string=s)
    assert_equal(len(arr), 4)
    assert_equal(arr[0].bool(), False)
    assert_equal(arr[1].null(), None)
    var nested_arr = arr[2].array()
    assert_equal(len(nested_arr), 1)
    assert_equal(nested_arr[0].float(), 4.0)
    var ob = arr[3].object()
    assert_true("key" in ob)
    assert_equal(ob["key"].string(), "bar")


def test_contains():
    var s = '[false, 123, "str"]'
    var arr = RawArray(parse_string=s)
    assert_true(False in arr)
    assert_true(RawValue(parse_string="123") in arr)
    assert_true("str" in arr)
    assert_false(True in arr)
    assert_true(True not in arr)


def test_variadic_init():
    var arr = RawArray(RawValue(parse_string="123"), "foo", None)
    var ob = RawObject[StaticConstantOrigin]()
    ob["key"] = "value"

    var arr2 = RawArray(
        RawValue(parse_string="45"),
        RawValue(parse_string="45.5"),
        RawValue(parse_string="45.5"),
        RawValue(arr),
        RawValue(ob),
    )
    assert_equal(arr[0].int(), 123)
    assert_equal(arr[1].string(), "foo")
    assert_equal(arr[2].null(), None)

    assert_equal(arr2[0], RawValue(parse_string="45"))
    assert_equal(arr2[1], RawValue(parse_string="45.5"))
    assert_equal(arr2[2], RawValue(parse_string="45.5"))
    assert_true(arr2[3].is_array())
    assert_equal(arr2[3], arr)
    assert_true(arr2[4].is_object())
    assert_equal(arr2[4], ob)


def test_equality():
    var arr1 = RawArray(
        RawValue(parse_string="123"), RawValue(parse_string="456")
    )
    var arr2 = RawArray(
        RawValue(parse_string="123"), RawValue(parse_string="456")
    )
    var arr3 = RawArray(RawValue(parse_string="123"), "456")
    assert_equal(arr1, arr2)
    assert_not_equal(arr1, arr3)


def test_list_ctr():
    var arr = RawArray(
        List[RawValue[StaticConstantOrigin]](
            RawValue(parse_string="123"),
            "foo",
            RawValue(parse_string="null"),
            RawValue(parse_string="false"),
        )
    )
    assert_equal(arr[0].int(), 123)
    assert_equal(arr[1].string(), "foo")
    assert_equal(arr[2].null(), None)
    assert_equal(arr[3].bool(), False)

    assert_equal(
        arr.to_list(),
        List[RawValue[StaticConstantOrigin]](
            RawValue(parse_string="123"),
            "foo",
            RawValue(parse_string="null"),
            RawValue(parse_string="false"),
        ),
    )


def test_iter():
    var arr = RawArray(
        RawValue(parse_string="false"),
        RawValue(parse_string="123"),
        RawValue(parse_string="null"),
    )

    var it = arr.__iter__()
    var elt = it.__next__()
    assert_equal(elt[], arr[0])
    assert_equal(Bool(elt[]), False)
    assert_true(it.__has_next__())
    elt = it.__next__()
    assert_equal(elt[], arr[1])
    assert_equal(Bool(elt[]), True)
    assert_true(it.__has_next__())
    elt = it.__next__()
    assert_equal(elt[], arr[2])
    assert_equal(Bool(elt[]), False)

    assert_equal(len(it), 0)
    assert_false(it.__has_next__())

    i = 2
    for el in arr.reversed():
        assert_equal(el[], arr[i])
        i -= 1


def test_list_literal():
    var a: RawArray[StaticConstantOrigin] = [
        RawValue(parse_string="123"),
        RawValue(parse_string="435"),
        False,
        None,
        RawValue(parse_string="12.32"),
        "string",
    ]
    assert_equal(
        a,
        RawArray(
            RawValue(parse_string="123"),
            RawValue(parse_string="435"),
            False,
            None,
            RawValue(parse_string="12.32"),
            "string",
        ),
    )
