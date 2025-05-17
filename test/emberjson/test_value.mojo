from emberjson.value import Value, Null
from emberjson import Object, Array, JSON
from emberjson.utils import *
from testing import *


def test_bool():
    var s: String = "false"
    var v = Value.from_string(s)
    assert_true(v.isa[Bool]())
    assert_equal(v.get[Bool](), False)
    assert_equal(String(v), s)

    s = "true"
    v = Value.from_string(s)
    assert_true(v.isa[Bool]())
    assert_equal(v.get[Bool](), True)
    assert_equal(String(v), s)
    assert_true(v.is_bool())


def test_string():
    var s: String = '"Some String"'
    var v = Value.from_string(s)
    assert_true(v.isa[String]())
    assert_equal(v.get[String](), "Some String")
    assert_equal(String(v), s)

    s = '"Escaped"'
    v = Value.from_string(s)
    assert_true(v.isa[String]())
    assert_equal(v.get[String](), "Escaped")
    assert_equal(String(v), s)
    assert_true(v.is_string())

    # check short string
    s = '"s"'
    v = Value.from_string(s)
    assert_equal(v.string(), "s")
    assert_equal(String(v), s)

    with assert_raises():
        _ = Value.from_string(r"Invalid unicode \u123z escape")

    with assert_raises():
        _ = Value.from_string(r"Another invalid \uXYZG escape")

    with assert_raises():
        _ = Value.from_string(r"Wrong format \u12Z4 escape")

    with assert_raises():
        _ = Value.from_string(r"Wrong format \uFFFF escape")

    with assert_raises():
        _ = Value.from_string(r"Incomplete escape \u12 escape")


def test_null():
    var s: String = "null"
    var v = Value.from_string(s)
    assert_true(v.isa[Null]())
    assert_equal(v.get[Null](), Null())
    assert_equal(String(v), s)
    assert_true(v.is_null())

    assert_true(Value(None).is_null())

    with assert_raises(contains="Expected 'null'"):
        _ = Value.from_string("nil")


def test_integer():
    var v = Value.from_string("123")
    assert_true(v.is_int())
    assert_equal(v.int(), 123)
    assert_equal(v.uint(), 123)
    assert_equal(String(v), "123")
    assert_true(v.is_int())

    # test to make signed vs unsigned comparisons work
    assert_equal(Value(Int64(123)), Value(UInt64(123)))
    assert_equal(Value(UInt64(123)), Value(Int64(123)))
    assert_not_equal(Value(Int64(125)), Value(UInt64(123)))
    assert_not_equal(Value(UInt64(125)), Value(Int64(123)))
    assert_not_equal(Value(UInt64(Int64.MAX) + 10), Int64.MAX)
    assert_not_equal(Value(-123), Value(UInt64(123)))


def test_integer_leading_plus():
    var v = Value.from_string("+123")
    assert_true(v.is_int())
    assert_equal(v.int(), 123)
    assert_equal(v.uint(), 123)


def test_integer_negative():
    var v = Value.from_string("-123")
    assert_true(v.is_int())
    assert_equal(v.int(), -123)
    assert_equal(String(v), "-123")


def test_signed_overflow_to_unsigned():
    var n = UInt64(Int64.MAX) + 100
    var v = Value.from_string(String(n))
    assert_true(v.isa[UInt64]())
    assert_equal(v.uint(), n)
    assert_equal(String(v), String(n))
    assert_true(v.is_uint())


def test_float():
    var v = Value.from_string("43.5")
    assert_true(v.isa[Float64]())
    assert_almost_equal(v.get[Float64](), 43.5)
    assert_equal(String(v), "43.5")
    assert_true(v.is_float())


def test_eight_digits_after_dot():
    var v = Value.from_string("[342.12345678]").array()[0]
    assert_true(v.isa[Float64]())
    assert_almost_equal(v.get[Float64](), 342.12345678)
    assert_equal(String(v), "342.12345678")


def test_special_case_floats():
    var v = Value.from_string("2.2250738585072013e-308")
    assert_almost_equal(v.float(), 2.2250738585072013e-308)
    assert_true(v.isa[Float64]())

    v = Value.from_string("7.2057594037927933e+16")
    assert_true(v.isa[Float64]())
    assert_almost_equal(v.float(), 7.2057594037927933e16)

    v = Value.from_string("1e000000000000000000001")
    assert_true(v.isa[Float64]())
    assert_almost_equal(v.float(), 1e000000000000000000001)

    v = Value.from_string("3.1415926535897932384626433832795028841971693993751")
    assert_true(v.isa[Float64]())
    assert_almost_equal(v.float(), 3.1415926535897932384626433832795028841971693993751)

    with assert_raises():
        # This is "infinite"
        _ = Value.from_string("10000000000000000000000000000000000000000000e+308")

    v = Value.from_string(String(Float64.MAX_FINITE))
    assert_equal(v.float(), Float64.MAX_FINITE)

    v = Value.from_string(String(Float64.MIN_FINITE))
    assert_equal(v.float(), Float64.MIN_FINITE)


def test_float_leading_plus():
    var v = Value.from_string("+43.5")
    assert_true(v.isa[Float64]())
    assert_almost_equal(v.get[Float64](), 43.5)


def test_float_negative():
    var v = Value.from_string("-43.5")
    assert_true(v.isa[Float64]())
    assert_almost_equal(v.get[Float64](), -43.5)


def test_float_exponent():
    var v = Value.from_string("43.5e10")
    assert_true(v.isa[Float64]())
    assert_almost_equal(v.get[Float64](), 43.5e10)


def test_float_exponent_negative():
    var v = Value.from_string("-43.5e10")
    assert_true(v.isa[Float64]())
    assert_almost_equal(v.get[Float64](), -43.5e10)


def test_equality():
    var v1 = Value(34)
    var v2 = Value("Some string")
    var v3 = Value("Some string")
    assert_equal(v2, v3)
    assert_not_equal(v1, v2)

    def eq_self(v: Value):
        assert_equal(v, v)

    eq_self(Value(123))
    eq_self(Value(34.5))
    eq_self(Value(Null()))
    eq_self(Value(False))
    eq_self(Value(Array()))
    eq_self(Value(Object()))


def test_implicit_conversion():
    var val: Value = "a string"
    assert_equal(val.string(), "a string")
    val = 100
    assert_equal(val.int(), 100)
    val = False
    assert_false(val.bool())
    val = 1e10
    assert_almost_equal(val.float(), 1e10)
    val = Null()
    assert_equal(val.null(), Null())
    val = Object()
    assert_equal(val.object(), Object())
    val = Array(1, 2, 3)
    assert_equal(val.array(), Array(1, 2, 3))


def test_pretty():
    var v = Value.from_string("[123, 43564, false]")
    var expected: String = """[
    123,
    43564,
    false
]"""
    assert_equal(expected, write_pretty(v))

    v = Value.from_string('{"key": 123, "k2": null}')
    expected = """{
    "k2": null,
    "key": 123
}"""

    assert_equal(expected, write_pretty(v))


def test_booling():
    var a: Value = True
    assert_true(a)
    if not a:
        raise Error("Implicit bool failed")

    var trues = Array("some string", 123, 3.43)
    for t in trues:
        assert_true(t[])

    var falsies = Array("", 0, 0.0, False, Null(), None)
    for f in falsies:
        assert_false(f[])
