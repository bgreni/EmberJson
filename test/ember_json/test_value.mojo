from ember_json.value import Value, Null
from ember_json.utils import write_pretty
from testing import *

def test_bool():
    var s = "false"
    var v = Value.from_string(s)
    assert_true(v.isa[Bool]())
    assert_equal(v.get[Bool](), False)
    assert_equal(str(v), s)

    s = "true"
    v = Value.from_string(s)
    assert_true(v.isa[Bool]())
    assert_equal(v.get[Bool](), True)
    assert_equal(str(v), s)

    # with assert_raises(contains="Expected 'false'"):
    #     _ = Value.from_string("falsee")
    # with assert_raises(contains="Expected 'true'"):
    #     _ = Value.from_string("tue")

def test_string():
    var s = '"Some String"'
    var v = Value.from_string(s)
    assert_true(v.isa[String]())
    assert_equal(v.get[String](), "Some String")
    assert_equal(str(v), s)

    s = "\"Escaped\""
    v = Value.from_string(s)
    assert_true(v.isa[String]())
    assert_equal(v.get[String](), "Escaped")
    assert_equal(str(v), s)

def test_null():
    var s = "null"
    var v = Value.from_string(s)
    assert_true(v.isa[Null]())
    assert_equal(v.get[Null](), Null())
    assert_equal(str(v), s)

    with assert_raises(contains="Expected 'null'"):
        _ = Value.from_string("nil")

def test_number():
    var v = Value.from_string("123")
    assert_true(v.isa[Int]())
    assert_equal(v.get[Int](), 123)
    assert_equal(str(v), "123")

    v = Value.from_string("+123")
    assert_true(v.isa[Int]())
    assert_equal(v.get[Int](), 123)

    v = Value.from_string("-123")
    assert_true(v.isa[Int]())
    assert_equal(v.get[Int](), -123)
    assert_equal(str(v), "-123")

    v = Value.from_string("43.5")
    assert_true(v.isa[Float64]())
    assert_equal(v.get[Float64](), 43.5)
    assert_equal(str(v), "43.5")

    v = Value.from_string("+43.5")
    assert_true(v.isa[Float64]())
    assert_equal(v.get[Float64](), 43.5)

    v = Value.from_string("-43.5")
    assert_true(v.isa[Float64]())
    assert_equal(v.get[Float64](), -43.5)

    v = Value.from_string("43.5e10")
    assert_true(v.isa[Float64]())
    assert_equal(v.get[Float64](), 43.5e10)

    v = Value.from_string("-43.5e10")
    assert_true(v.isa[Float64]())
    assert_equal(v.get[Float64](), -43.5e10)

def test_equality():
    var v1 = Value(34)
    var v2 = Value("Some string")
    var v3 = Value("Some string")
    assert_equal(v2, v3)
    assert_not_equal(v1, v2)

def test_min_size_for_string():
    assert_equal(Value(12345).min_size_for_string(), 5)
    assert_equal(Value("foobar").min_size_for_string(), 8)
    assert_equal(Value(Null()).min_size_for_string(), 4)
    assert_equal(Value(True).min_size_for_string(), 4)
    assert_equal(Value(False).min_size_for_string(), 5)

def test_pretty():
    var v = Value.from_string("[123, 43564, false]")
    var expected = """[
    123,
    43564,
    false
]"""
    assert_equal(expected, write_pretty(v))

    v = Value.from_string('{"key": 123, "k2": null}')
    expected = """{
    "key": 123,
    "k2": null
}"""

    assert_equal(expected, write_pretty(v))