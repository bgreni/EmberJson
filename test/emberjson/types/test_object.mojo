from emberjson.object import Object
from emberjson.array import Array
from emberjson.value import Null, Value
from emberjson import parse, JSON
from std.testing import (
    assert_true,
    assert_equal,
    assert_raises,
    assert_not_equal,
    TestSuite,
)
from std.collections import Dict


def test_object() raises:
    var s = '{"thing":123}'
    var ob = Object(parse_string=s)
    assert_true("thing" in ob)
    assert_equal(ob["thing"].int(), 123)
    assert_equal(String(ob), s)

    ob["thing"] = "hello"
    assert_true("thing" in ob)
    assert_equal(ob["thing"].string(), "hello")


def test_to_from_dict() raises:
    var d = Dict[String, Value]()
    d["key"] = False

    var o = Object(d^)
    assert_equal(o["key"].bool(), False)

    d = o.to_dict()
    assert_equal(d["key"].bool(), False)


def test_object_spaces() raises:
    var s = '{ "Key" : "some value" }'
    var ob = Object(parse_string=s)
    assert_true("Key" in ob)
    assert_equal(ob["Key"].string(), "some value")


def test_nested_object() raises:
    var s = '{"nested": { "foo": null } }"'
    var ob = Object(parse_string=s)
    assert_true("nested" in ob)
    assert_true(ob["nested"].isa[Object]())
    assert_true(ob["nested"].object()["foo"].isa[Null]())

    with assert_raises():
        _ = ob["DOES NOT EXIST"].copy()


def test_arr_in_object() raises:
    var s = '{"arr": [null, 2, "foo"]}'
    var ob = Object(parse_string=s)
    assert_true("arr" in ob)
    assert_true(ob["arr"].isa[Array]())
    assert_equal(ob["arr"].array()[0].null(), Null())
    assert_equal(ob["arr"].array()[1].int(), 2)
    assert_equal(ob["arr"].array()[2].string(), "foo")


def test_multiple_keys() raises:
    var s = '{"k1": 123, "k2": 456}'
    var ob = Object(parse_string=s)
    assert_true("k1" in ob)
    assert_true("k2" in ob)
    assert_equal(ob["k1"].int(), 123)
    assert_equal(ob["k2"].int(), 456)
    assert_equal(String(ob), '{"k1":123,"k2":456}')


def test_invalid_key() raises:
    var s = "{key: 123}"
    with assert_raises():
        _ = Object(parse_string=s)


def test_single_quote_identifier() raises:
    var s = "'key': 123"
    with assert_raises():
        _ = Object(parse_string=s)


def test_single_quote_value() raises:
    var s = "\"key\": '123'"
    with assert_raises():
        _ = Object(parse_string=s)


def test_equality() raises:
    var ob1: Object = {"key": 123}
    var ob2 = ob1.copy()
    var ob3 = ob1.copy()
    ob3["key"] = Null()

    assert_equal(ob1, ob2)
    assert_not_equal(ob1, ob3)


def test_bad_value() raises:
    with assert_raises():
        _ = Object(parse_string='{"key": nil}')


def test_write() raises:
    var ob = Object()
    ob["foo"] = "stuff"
    ob["bar"] = 123
    assert_equal(String(ob), '{"foo":"stuff","bar":123}')


def test_nested_object_copy() raises:
    # NOTE: Catches: https://github.com/bgreni/EmberJson/pull/62
    var obj = Object()
    obj["type"] = Object()
    obj["id"] = "original_id"
    var copy = obj.copy()
    copy["id"] = "new_id"
    assert_equal(String(copy.copy()), '{"type":{},"id":"new_id"}')


def test_iter() raises:
    var ob: Object = {"a": "stuff", "b": 123, "c": 3.423}

    var keys: List[String] = ["a", "b", "c"]

    var i = 0
    for el in ob.keys():
        assert_equal(el, keys[i])
        i += 1

    i = 0
    # check that the default is to iterate over keys
    for el in ob:
        assert_equal(el, keys[i])
        i += 1

    var values = Array("stuff", 123, 3.423)

    i = 0
    for el in ob.values():
        assert_equal(el, values[i])
        i += 1


def test_dict_literal() raises:
    var o: Object = {"key": 1234, "key2": False}

    assert_equal(o["key"], 1234)
    assert_equal(o["key2"], False)


def test_parse_simple_object() raises:
    var s = '{"key": 123}'
    var json = parse(s)
    assert_true(json.is_object())
    assert_equal(json.object()["key"].int(), 123)
    assert_equal(json.object()["key"].int(), 123)

    assert_equal(String(json), '{"key":123}')

    assert_equal(len(json), 1)


def test_setter_object_generic() raises:
    var ob: Value = Object()
    ob.object()["key"] = "foo"
    assert_true("key" in ob)
    assert_equal(ob.object()["key"], "foo")


def test_repr_empty() raises:
    assert_equal(repr(Object()), "Object{}")


def test_repr_single_key() raises:
    var ob: Object = {"key": 42}
    assert_equal(repr(ob), 'Object{"key":SIMD[DType.int64, 1](42)}')


def test_repr_multiple_keys() raises:
    var ob: Object = {"a": 1, "b": "hello"}
    assert_equal(
        repr(ob),
        """Object{"a":SIMD[DType.int64, 1](1),"b":'hello'}""",
    )


def test_repr_nested() raises:
    var inner: Object = {"x": True}
    var outer = Object()
    outer["inner"] = inner.copy()
    assert_equal(
        repr(outer),
        'Object{"inner":Object{"x":True}}',
    )


def test_nested_access_generic() raises:
    var nested: Value = {"key": [True, None, {"inner2": False}]}

    assert_equal(nested["key"][2]["inner2"].bool(), False)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
