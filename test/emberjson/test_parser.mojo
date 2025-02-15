from emberjson.parser import Parser
from emberjson import JSON, Null, Array, Object, parse
from testing import *


def test_parse():
    var s = '{"key": 123}'
    var p = Parser(s.unsafe_ptr(), len(s))
    var json = p.parse()
    _ = s
    assert_true(json.is_object())
    assert_equal(json.object()["key"].int(), 123)
    assert_equal(json.object()["key"].int(), 123)

    assert_equal(String(json), '{"key":123}')

    assert_equal(len(json), 1)

    s = "[123, 345]"
    json = parse(s)
    assert_true(json.is_array())
    assert_equal(json.array()[0].int(), 123)
    assert_equal(json.array()[1].int(), 345)
    assert_equal(json.array()[0].int(), 123)

    assert_equal(String(json), "[123,345]")

    assert_equal(len(json.array()), 2)
