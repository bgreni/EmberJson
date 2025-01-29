from emberjson.object import Object
from emberjson.array import Array
from emberjson.value import Null, Value
from testing import *
from collections import Dict


def test_object():
    var s = '{"thing":123}'
    var ob = Object.from_string(s)
    assert_true("thing" in ob)
    assert_equal(ob["thing"].int(), 123)
    assert_equal(String(ob), s)


def test_to_from_dict():
    var d = Dict[String, Value]()
    d["key"] = False

    var o = Object(d^)
    assert_equal(o["key"].bool(), False)

    d = o.to_dict()
    assert_equal(d["key"].bool(), False)


def test_object_spaces():
    var s = '{ "Key" : "some value" }'
    var ob = Object.from_string(s)
    assert_true("Key" in ob)
    assert_equal(ob["Key"].string(), "some value")


def test_nested_object():
    var s = '{"nested": { "foo": null } }"'
    var ob = Object.from_string(s)
    assert_true("nested" in ob)
    assert_true(ob["nested"].isa[Object]())
    assert_true(ob["nested"].object()["foo"].isa[Null]())

    with assert_raises():
        _ = ob["DOES NOT EXIST"]


def test_arr_in_object():
    var s = '{"arr": [null, 2, "foo"]}'
    var ob = Object.from_string(s)
    assert_true("arr" in ob)
    assert_true(ob["arr"].isa[Array]())
    assert_equal(ob["arr"].array()[0].null(), Null())
    assert_equal(ob["arr"].array()[1].int(), 2)
    assert_equal(ob["arr"].array()[2].string(), "foo")


def test_multiple_keys():
    var s = '{"k1": 123, "k2": 456}'
    var ob = Object.from_string(s)
    assert_true("k1" in ob)
    assert_true("k2" in ob)
    assert_equal(ob["k1"].int(), 123)
    assert_equal(ob["k2"].int(), 456)
    assert_equal(String(ob), '{"k1":123,"k2":456}')


def test_invalid_key():
    var s = "{key: 123}"
    with assert_raises():
        _ = Object.from_string(s)


def test_single_quote_identifier():
    var s = "'key': 123"
    with assert_raises():
        _ = Object.from_string(s)


def test_single_quote_value():
    var s = "\"key\": '123'"
    with assert_raises():
        _ = Object.from_string(s)


def test_equality():
    var ob1 = Object()
    ob1["key"] = 123
    var ob2 = ob1
    var ob3 = ob1
    ob3["key"] = Null()

    assert_equal(ob1, ob2)
    assert_not_equal(ob1, ob3)


def test_bad_value():
    with assert_raises():
        _ = Object.from_string('{"key": nil}')


# def test_min_size_for_string():
#     assert_equal(Object.from_string('{"key": true, "foo": "bar"}').min_size_for_string(), 24)
