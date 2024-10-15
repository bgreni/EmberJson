from mojo_json.object import Object
from mojo_json.array import Array
from mojo_json.value import Null
from testing import *

def test_object():
    var s = '{"thing": 123}'
    var ob = Object.from_string(s)
    assert_true("thing" in ob)
    assert_equal(ob["thing"].int(), 123)
    assert_equal(str(ob), s)

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
    assert_true(ob["DOES NOT EXIST"].isa[Null]())

def test_arr_in_object():
    var s = '{"arr": [null, 2, "foo"]}'
    var ob = Object.from_string(s)
    assert_true("arr" in ob)
    assert_true(ob["arr"].isa[Array]())
    assert_equal(ob["arr"].array()[0].null(), Null())
    assert_equal(ob["arr"].array()[1].int(), 2)
    assert_equal(ob["arr"].array()[2].string(), "foo")

def test_multiple_keys():
    var s = '{"k1": 123, "k2": 456,}'
    var ob = Object.from_string(s)
    assert_true("k1" in ob)
    assert_true("k2" in ob)
    assert_equal(ob["k1"].int(), 123)
    assert_equal(ob["k2"].int(), 456)
    assert_equal(str(ob), '{"k1": 123, "k2": 456}')

def test_invalid_key():
    var s = '{key: 123}'
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